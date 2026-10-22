import Foundation

/// A failed AppleScript run, with AppleScript's own error number (`NSAppleScriptErrorNumber`).
public struct AppleScriptError: Error, Sendable, Equatable {
    /// errAEEventNotPermitted: the user has not allowed (or has denied) Automation for the target app.
    public static let notAuthorized = -1743
    /// procNotFound: the target app is not running (or still launching).
    public static let appNotRunning = -600

    public var number: Int
    public var message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }
}

/// Runs AppleScript. Kept tiny so tests can fake it: no test ever sends a real Apple Event.
public protocol AppleScriptRunning: Sendable {
    /// Compiles and runs `source`, returning its result.
    func run(source: String) async throws -> NSAppleEventDescriptor

    /// Compiles `source` (which defines `handler`) and calls the handler with `arguments` as its positional parameters.
    /// Arguments travel as Apple Event descriptors, never as script text, so no value needs escaping.
    func call(handler: String, in source: String, arguments: [NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor
}

/// `NSAppleScript` on one dedicated serial queue (NSAppleScript is not thread-safe, so every instance is created, compiled
/// and run there and never leaves it). Hand-test note: if a script ever misbehaves off the main thread, this is the place to look.
public final class NSAppleScriptRunner: AppleScriptRunning {
    private struct Result: @unchecked Sendable { let descriptor: NSAppleEventDescriptor }

    /// Shared by every runner: the OSA component is process-wide, so two queues would still run scripts concurrently.
    private static let queue = DispatchQueue(label: "dev.dividedby.contactbridge.applescript")

    public init() {}

    public func run(source: String) async throws -> NSAppleEventDescriptor {
        try await onQueue { Result(descriptor: try Self.execute(source: source, event: nil)) }.descriptor
    }

    public func call(handler: String, in source: String, arguments: [NSAppleEventDescriptor]) async throws -> NSAppleEventDescriptor {
        // The descriptors are only read on the queue; callers hand over ownership.
        let box = Result(descriptor: NSAppleEventDescriptor.list())
        for (index, argument) in arguments.enumerated() { box.descriptor.insert(argument, at: index + 1) }
        return try await onQueue {
            Result(descriptor: try Self.execute(source: source, event: Self.subroutineEvent(handler: handler, arguments: box.descriptor)))
        }.descriptor
    }

    private func onQueue(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Swift.Result { try work() }) }
        }
    }

    // MARK: NSAppleScript plumbing (queue only)

    // Four-character codes from the AppleScript suite ('ascr'/'psbr'/'snam'/'----'), spelled out because the Carbon
    // constants are not visible from Foundation.
    private static let scriptSuite: AEEventClass = 0x6173_6372
    private static let subroutineEvent: AEEventID = 0x7073_6272
    private static let subroutineName: AEKeyword = 0x736E_616D
    private static let directObject: AEKeyword = 0x2D2D_2D2D

    private static func subroutineEvent(handler: String, arguments: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: scriptSuite, eventID: subroutineEvent, targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(-1), transactionID: AETransactionID(0)
        )
        // AppleScript handler names are case-insensitive; the event carries the lower-cased name.
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: subroutineName)
        event.setParam(arguments, forKeyword: directObject)
        return event
    }

    private static func execute(source: String, event: NSAppleEventDescriptor?) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError(number: -2741, message: "Could not create a script from the source.")
        }
        var info: NSDictionary?
        guard script.compileAndReturnError(&info) else { throw error(from: info) }
        let result = event.map { script.executeAppleEvent($0, error: &info) } ?? script.executeAndReturnError(&info)
        if info != nil { throw error(from: info) }
        return result
    }

    private static func error(from info: NSDictionary?) -> AppleScriptError {
        let number = (info?["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue ?? -1
        let message = (info?["NSAppleScriptErrorMessage"] as? String) ?? (info?["NSAppleScriptErrorBriefMessage"] as? String) ?? "AppleScript failed."
        return AppleScriptError(number: number, message: message)
    }
}
