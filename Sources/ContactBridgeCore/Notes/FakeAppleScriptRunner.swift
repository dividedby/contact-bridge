import Foundation

/// Scripted stand-in for tests and previews: each run or call consumes the next response, in order, and is recorded.
/// With no response left it fails with error -1, so a test that makes an unexpected extra call is loud about it.
///
/// `@unchecked Sendable`: NSAppleEventDescriptor is not Sendable; all state is guarded by `lock`.
public final class FakeAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
    public enum Call {
        case run(source: String)
        case call(handler: String, source: String, arguments: [NSAppleEventDescriptor])
    }

    private let lock = NSLock()
    private var responses: [Result<NSAppleEventDescriptor, AppleScriptError>]
    private var recorded: [Call] = []

    public init(responses: [Result<NSAppleEventDescriptor, AppleScriptError>] = []) {
        self.responses = responses
    }

    public var calls: [Call] { lock.withLock { recorded } }

    public func run(source: String) async throws -> NSAppleEventDescriptor {
        try next(.run(source: source))
    }

    public func call(handler: String, in source: String, arguments: [NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor {
        try next(.call(handler: handler, source: source, arguments: arguments))
    }

    private func next(_ call: Call) throws -> NSAppleEventDescriptor {
        let response: Result<NSAppleEventDescriptor, AppleScriptError>? = lock.withLock {
            recorded.append(call)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let response else { throw AppleScriptError(number: -1, message: "FakeAppleScriptRunner has no scripted response left.") }
        return try response.get()
    }
}
