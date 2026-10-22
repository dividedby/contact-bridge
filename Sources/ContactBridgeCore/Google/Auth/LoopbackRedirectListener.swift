import Foundation
import Network

/// What Google appended to the redirect.
public struct LoopbackRedirect: Sendable, Hashable {
    public var code: String?
    public var state: String?
    public var error: String?
    public var errorDescription: String?
}

public enum LoopbackRequest: Sendable, Hashable {
    case redirect(LoopbackRedirect)
    /// Anything that is not the OAuth redirect (favicon, preconnects, other paths or methods).
    case ignored
}

/// Pure parsing of the loopback listener's HTTP traffic.
public enum LoopbackRequestParser {
    /// The request line once it is complete (terminated by a newline); nil while incomplete or malformed.
    public static func requestLine(from data: Data) -> (method: String, target: String)? {
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    public static func classify(method: String, target: String, path: String) -> LoopbackRequest {
        guard method == "GET" else { return .ignored }
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == path else { return .ignored }
        let query = pieces.count > 1 ? queryItems(String(pieces[1])) : [:]
        let redirect = LoopbackRedirect(
            code: query["code"].flatMap { $0.isEmpty ? nil : $0 },
            state: query["state"],
            error: query["error"].flatMap { $0.isEmpty ? nil : $0 },
            errorDescription: query["error_description"]
        )
        guard redirect.code != nil || redirect.error != nil else { return .ignored }
        return .redirect(redirect)
    }

    static func queryItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = decode(String(kv[0]))
            if items[key] == nil { items[key] = kv.count > 1 ? decode(String(kv[1])) : "" }
        }
        return items
    }

    private static func decode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

/// One-shot OAuth redirect receiver bound to 127.0.0.1 on an OS-assigned port.
///
/// `start()` returns the redirect URI to register with the authorization request; `waitForCode()` resolves with the
/// authorization code, or throws on denial, timeout or cancellation. After the first valid redirect (or any failure)
/// the listener closes. Requests for other paths, and redirects with the wrong state, are answered 4xx and ignored, so
/// a stray page on the machine cannot abort the sign-in. Connections that stall are dropped after `readTimeout`, and at
/// most `maxConnections` are served at once.
public actor LoopbackRedirectListener {
    private let expectedState: String
    private let path: String
    private let timeout: Duration
    private let readTimeout: Duration
    private let startTimeout: Duration
    private let maxConnections: Int
    private let queue = DispatchQueue(label: "dev.dividedby.contactbridge.loopback")

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var outcome: Result<String, GoogleAuthError>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init(
        expectedState: String, redirectPath: String = "/", timeout: Duration = .seconds(300),
        maxConnections: Int = 8, readTimeout: Duration = .seconds(10), startTimeout: Duration = .seconds(5)
    ) {
        self.expectedState = expectedState
        self.path = redirectPath
        self.timeout = timeout
        self.maxConnections = maxConnections
        self.readTimeout = readTimeout
        self.startTimeout = startTimeout
    }

    /// Starts listening and returns the redirect URI (`http://127.0.0.1:PORT`).
    public func start() async throws -> URL {
        guard listener == nil, outcome == nil else { throw GoogleAuthError.listenerFailed("listener already used") }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { throw GoogleAuthError.listenerFailed(error.localizedDescription) }

        let (states, stateSink) = AsyncStream.makeStream(of: NWListener.State.self)
        listener.stateUpdateHandler = { stateSink.yield($0) }
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.start(queue: queue)

        do {
            try await Self.awaitReady(states, timeout: startTimeout)
        } catch {
            listener.cancel()
            throw error
        }
        let port = listener.port?.rawValue
        stateSink.finish()
        guard let port else {
            listener.cancel()
            throw GoogleAuthError.listenerFailed("no port assigned")
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { await self?.finish(.failure(.listenerFailed(error.localizedDescription))) }
            }
        }
        self.listener = listener
        let timeout = timeout
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(.timedOut))
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path == "/" ? "" : path)") else {
            throw GoogleAuthError.listenerFailed("could not form the redirect URI")
        }
        return url
    }

    /// Waits for `.ready`. A listener that sits in `.waiting` (no usable network path) never becomes ready on its own, so
    /// anything other than ready within `timeout` is a failure.
    static func awaitReady(_ states: AsyncStream<NWListener.State>, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in states {
                    switch state {
                    case .ready: return
                    case .failed(let error): throw GoogleAuthError.listenerFailed(error.localizedDescription)
                    case .cancelled: throw GoogleAuthError.listenerFailed("listener cancelled before it was ready")
                    default: continue
                    }
                }
                throw GoogleAuthError.listenerFailed("listener ended before it was ready")
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw GoogleAuthError.listenerFailed("the local listener did not become ready in time (still waiting for the network stack)")
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    public func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let outcome {
                    continuation.resume(with: outcome.mapError { $0 as Error })
                } else if waiter != nil {
                    continuation.resume(throwing: GoogleAuthError.listenerFailed("already waiting"))
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    /// Fails a pending wait with `.cancelled` and closes the listener. Safe to call at any time, including after completion.
    public func cancel() {
        finish(.failure(.cancelled))
    }

    // MARK: internals

    private func finish(_ result: Result<String, GoogleAuthError>) {
        guard outcome == nil else { return }
        outcome = result
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        waiter?.resume(with: result.mapError { $0 as Error })
        waiter = nil
    }

    private func accept(_ connection: NWConnection) async {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        guard connections.count < maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: queue)

        guard let head = await Self.readRequestHead(connection, timeout: readTimeout) else {
            connections[id] = nil
            connection.cancel()
            return
        }
        guard let line = LoopbackRequestParser.requestLine(from: head) else {
            await respond(to: connection, status: 400, body: Self.page("Bad request."))
            return
        }
        switch LoopbackRequestParser.classify(method: line.method, target: line.target, path: path) {
        case .ignored:
            await respond(to: connection, status: 404, body: Self.page("Not found."))
        case .redirect(let redirect):
            guard redirect.state == expectedState else {
                await respond(to: connection, status: 400, body: Self.page("This sign-in response did not match the request."))
                return
            }
            if let error = redirect.error {
                await respond(to: connection, status: 200, body: Self.page("Sign-in was not completed. You can close this window and return to Contact Bridge."))
                finish(.failure(.authorizationDenied(error)))
            } else if let code = redirect.code {
                await respond(to: connection, status: 200, body: Self.page("Signed in. You can close this window and return to Contact Bridge."))
                finish(.success(code))
            }
        }
    }

    private func respond(to connection: NWConnection, status: Int, body: String) async {
        connections[ObjectIdentifier(connection)] = nil
        let reason = status == 200 ? "OK" : status == 404 ? "Not Found" : "Bad Request"
        let payload = Data(body.utf8)
        var response = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(payload)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
        connection.cancel()
    }

    /// Reads until the blank line that ends the request head (GETs have no body), so closing never resets unread data.
    /// Gives up, closing the connection, if the head is not complete within `timeout`.
    private static func readRequestHead(_ connection: NWConnection, timeout: Duration) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await readUntilBlankLine(connection) }
            group.addTask {
                do { try await Task.sleep(for: timeout) } catch { return nil }
                connection.cancel()
                return nil
            }
            let head = await group.next() ?? nil
            group.cancelAll()
            return head
        }
    }

    private static func readUntilBlankLine(_ connection: NWConnection) async -> Data? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.count < 16 * 1024 {
            let (data, finished) = await withCheckedContinuation { (continuation: CheckedContinuation<(Data?, Bool), Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
                    continuation.resume(returning: (data, isComplete || error != nil))
                }
            }
            if let data { buffer.append(data) }
            if buffer.range(of: terminator) != nil { return buffer }
            if finished { return nil }
        }
        return buffer
    }

    private static func page(_ message: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>Contact Bridge</title></head><body style=\"font-family: -apple-system, sans-serif; text-align: center; margin-top: 20vh\"><h2>Contact Bridge</h2><p>\(message)</p></body></html>"
    }
}
