import Foundation
import Network
import Testing
@testable import ContactBridgeCore

struct LoopbackRedirectParsingTests {
    @Test("Request lines parse into method and target")
    func requestLine() {
        let line = LoopbackRequestParser.requestLine(from: Data("GET /?code=a&state=b HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        #expect(line?.method == "GET" && line?.target == "/?code=a&state=b")
        #expect(LoopbackRequestParser.requestLine(from: Data("GET /".utf8)) == nil)
        #expect(LoopbackRequestParser.requestLine(from: Data("garbage\r\n".utf8)) == nil)
        #expect(LoopbackRequestParser.requestLine(from: Data()) == nil)
    }

    @Test("A redirect carries code and state, percent-decoded")
    func codeAndState() {
        let result = LoopbackRequestParser.classify(method: "GET", target: "/?state=xyz&code=4%2F0AbC-d_e&scope=a%20b", path: "/")
        #expect(result == .redirect(LoopbackRedirect(code: "4/0AbC-d_e", state: "xyz", error: nil, errorDescription: nil)))
    }

    @Test("An error redirect carries error and description, with plus as space")
    func errorRedirect() {
        let result = LoopbackRequestParser.classify(method: "GET", target: "/?error=access_denied&error_description=User+said+no&state=xyz", path: "/")
        #expect(result == .redirect(LoopbackRedirect(code: nil, state: "xyz", error: "access_denied", errorDescription: "User said no")))
    }

    @Test("Other paths, other methods, and queries with neither code nor error are ignored")
    func ignored() {
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/favicon.ico", path: "/") == .ignored)
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/favicon.ico?code=x&state=y", path: "/") == .ignored)
        #expect(LoopbackRequestParser.classify(method: "POST", target: "/?code=x&state=y", path: "/") == .ignored)
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/", path: "/") == .ignored)
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/?state=y", path: "/") == .ignored)
    }

    @Test("A custom redirect path is matched exactly")
    func customPath() {
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/cb?code=x&state=y", path: "/cb") != .ignored)
        #expect(LoopbackRequestParser.classify(method: "GET", target: "/?code=x&state=y", path: "/cb") == .ignored)
    }
}

struct LoopbackRedirectListenerTests {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    @Test("Receives the redirect on 127.0.0.1, answers with the close-window page, and shuts down")
    func receivesRedirect() async throws {
        let listener = LoopbackRedirectListener(expectedState: "the-state")
        let redirectURI = try await listener.start()
        #expect(redirectURI.host == "127.0.0.1")
        let port = try #require(redirectURI.port)
        #expect(port > 0)

        // A browser-ish stray request first: ignored, listener keeps waiting.
        let (_, favicon) = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/favicon.ico")))
        #expect((favicon as? HTTPURLResponse)?.statusCode == 404)

        let waited = Task { try await listener.waitForCode() }
        let (body, response) = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?code=the-code&state=the-state")))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("You can close this window"))
        #expect(try await waited.value == "the-code")

        // Shut down: nothing is listening any more.
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: URLError.self) {
            _ = try await self.session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?code=again&state=the-state")))
        }
    }

    @Test("A wrong state gets a 400 and is ignored; the listener keeps waiting for the real redirect")
    func wrongStateIgnored() async throws {
        let listener = LoopbackRedirectListener(expectedState: "right")
        let port = try #require(try await listener.start().port)
        let waited = Task { try await listener.waitForCode() }

        for forged in ["code=c&state=wrong", "error=access_denied&state=wrong", "code=c"] {
            let (_, response) = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?\(forged)")))
            #expect((response as? HTTPURLResponse)?.statusCode == 400 || (response as? HTTPURLResponse)?.statusCode == 404)
        }
        try await Task.sleep(for: .milliseconds(100))
        let (_, ok) = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?code=real&state=right")))
        #expect((ok as? HTTPURLResponse)?.statusCode == 200)
        #expect(try await waited.value == "real")
    }

    @Test("A request whose head arrives in two writes is still understood")
    func splitRequest() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try #require(try await listener.start().port)
        let waited = Task { try await listener.waitForCode() }
        let client = RawClient(port: port)
        try await client.connect()
        await client.send("GET /?code=split&state=s HTTP/1.1\r\nHo")
        try await Task.sleep(for: .milliseconds(150))
        await client.send("st: 127.0.0.1\r\nAccept: */*\r\n\r\n")
        let response = await client.readAll()
        #expect(response.hasPrefix("HTTP/1.1 200 OK"))
        #expect(try await waited.value == "split")
    }

    @Test("A connection that never completes its request is dropped after the read timeout")
    func readTimeout() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s", readTimeout: .milliseconds(200))
        let port = try #require(try await listener.start().port)
        let waited = Task { try await listener.waitForCode() }
        let stalled = RawClient(port: port)
        try await stalled.connect()
        await stalled.send("GET /?code=x")
        #expect(await stalled.closedWithin(.seconds(3)))
        // The listener is unaffected.
        _ = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?code=ok&state=s")))
        #expect(try await waited.value == "ok")
    }

    @Test("Only a handful of connections are served at once")
    func connectionCap() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s", maxConnections: 2, readTimeout: .seconds(30))
        let port = try #require(try await listener.start().port)
        let waited = Task { try await listener.waitForCode() }
        let clients = [RawClient(port: port), RawClient(port: port), RawClient(port: port)]
        for client in clients { try await client.connect() }
        try await Task.sleep(for: .milliseconds(300))
        var closed = 0
        for client in clients where await client.closedWithin(.milliseconds(400)) { closed += 1 }
        #expect(closed == 1)
        // Dropping the idle ones frees the slots.
        clients.forEach { $0.close() }
        try await Task.sleep(for: .milliseconds(300))
        _ = try await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?code=ok&state=s")))
        #expect(try await waited.value == "ok")
    }

    @Test("start() gives up when the listener stays in waiting instead of ready")
    func startTimeout() async throws {
        let (states, sink) = AsyncStream.makeStream(of: NWListener.State.self)
        sink.yield(.setup)
        sink.yield(.waiting(.posix(.ENETDOWN)))
        do {
            try await LoopbackRedirectListener.awaitReady(states, timeout: .milliseconds(150))
            Issue.record("expected a timeout")
        } catch GoogleAuthError.listenerFailed(let reason) {
            #expect(reason.contains("ready"))
        }
        sink.finish()
    }

    @Test("awaitReady returns on ready and throws on failure")
    func awaitReady() async throws {
        let (ready, readySink) = AsyncStream.makeStream(of: NWListener.State.self)
        readySink.yield(.waiting(.posix(.ENETDOWN)))
        readySink.yield(.ready)
        try await LoopbackRedirectListener.awaitReady(ready, timeout: .seconds(5))

        let (failed, failedSink) = AsyncStream.makeStream(of: NWListener.State.self)
        failedSink.yield(.failed(.posix(.EADDRINUSE)))
        await #expect(throws: GoogleAuthError.self) { try await LoopbackRedirectListener.awaitReady(failed, timeout: .seconds(5)) }
    }

    @Test("A user denial surfaces as authorizationDenied")
    func denied() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        let port = try #require(try await listener.start().port)
        let waited = Task { try await listener.waitForCode() }
        _ = try? await session().data(from: try #require(URL(string: "http://127.0.0.1:\(port)/?error=access_denied&state=s")))
        await #expect(throws: GoogleAuthError.authorizationDenied("access_denied")) { _ = try await waited.value }
    }

    @Test("Times out when no redirect arrives")
    func timeout() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s", timeout: .milliseconds(150))
        _ = try await listener.start()
        await #expect(throws: GoogleAuthError.timedOut) { _ = try await listener.waitForCode() }
    }

    @Test("Cancelling the waiting task cancels the flow")
    func cancellation() async throws {
        let listener = LoopbackRedirectListener(expectedState: "s")
        _ = try await listener.start()
        let task = Task { try await listener.waitForCode() }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: GoogleAuthError.cancelled) { _ = try await task.value }
    }
}


/// A minimal TCP client for sending hand-built requests to the listener.
final class RawClient: @unchecked Sendable {
    private let connection: NWConnection

    init(port: Int) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
    }

    func connect() async throws {
        let (states, sink) = AsyncStream.makeStream(of: NWConnection.State.self)
        connection.stateUpdateHandler = { sink.yield($0) }
        connection.start(queue: .global())
        for await state in states {
            switch state {
            case .ready: return
            case .failed(let error): throw error
            case .cancelled: throw URLError(.cancelled)
            default: continue
            }
        }
    }

    func send(_ text: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// Everything the server sends until it closes the connection.
    func readAll() async -> String {
        var buffer = Data()
        while true {
            let (data, finished) = await receiveOnce()
            if let data { buffer.append(data) }
            if finished { return String(decoding: buffer, as: UTF8.self) }
        }
    }

    /// True if the server closed (or reset) the connection within `duration`.
    func closedWithin(_ duration: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await self.readAll(); return true }
            group.addTask { try? await Task.sleep(for: duration); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { self.close() }
            return first
        }
    }

    func close() { connection.cancel() }

    private func receiveOnce() async -> (Data?, Bool) {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                continuation.resume(returning: (data, isComplete || error != nil))
            }
        }
    }
}
