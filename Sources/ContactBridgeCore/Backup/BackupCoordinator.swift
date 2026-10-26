import Foundation

/// What a backup must cover for the operation about to use it.
public struct BackupRequirement: Sendable, Equatable {
    /// The container the operation will write to. A receipt for any other container does not count.
    public var containerID: String?
    /// A merge folds notes in, so the backup must hold them.
    public var needsNotes: Bool
    /// An import reads Google, so the backup must hold the Google side too.
    public var needsGoogle: Bool

    public init(containerID: String?, needsNotes: Bool = false, needsGoogle: Bool = false) {
        self.containerID = containerID
        self.needsNotes = needsNotes
        self.needsGoogle = needsGoogle
    }
}

/// A writer together with the container it will back up.
public struct BackupSetup: Sendable {
    public var writer: BackupWriter
    public var containerID: String?

    public init(writer: BackupWriter, containerID: String? = nil) {
        self.writer = writer
        self.containerID = containerID
    }
}

public enum BackupCoordinatorError: Error, Sendable, Equatable {
    /// A backup was taken but it still does not cover what the operation needs (`what` names the gap).
    case requirementNotMet(String)
}

extension BackupCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requirementNotMet(let what):
            "A backup was taken, but it does not include \(what), which this step needs. Nothing was changed. Fix that in Setup and try again."
        }
    }
}

/// Hands out backup receipts for the mutating screens. A cached receipt is reused only while it is recent AND covers what
/// the caller needs: same container, notes if required, Google if required. Concurrent callers for the same container
/// share a single backup run.
public actor BackupCoordinator {
    private struct Coverage {
        var containerID: String?
        var notes: Bool
        var google: Bool
    }

    private let makeSetup: @Sendable () async throws -> BackupSetup
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private var inFlight: (key: String??, task: Task<(BackupReceipt, Coverage), Error>)?
    private var cached: (receipt: BackupReceipt, coverage: Coverage)?

    /// The most recent successful backup still trusted for reuse.
    public var latest: BackupReceipt? { cached?.receipt }

    /// - Parameter makeSetup: called for every new backup, so it can reflect the current container, sign-in and notes access.
    public init(
        makeSetup: @escaping @Sendable () async throws -> BackupSetup, maxAge: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeSetup = makeSetup
        self.maxAge = maxAge
        self.now = now
    }

    /// For callers with a single, unnamed container.
    public init(
        makeWriter: @escaping @Sendable () async throws -> BackupWriter, maxAge: TimeInterval = 3600,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(makeSetup: { BackupSetup(writer: try await makeWriter()) }, maxAge: maxAge, now: now)
    }

    /// Forget the cached receipt (the container, notes access or sign-in changed).
    public func invalidate() {
        cached = nil
    }

    /// Always takes a new backup (or joins one already running for the same container).
    public func backUpNow() async throws -> BackupReceipt {
        try await takeBackup(joining: .any).0
    }

    /// - Parameter maxAge: how old a reused receipt may be; the coordinator's own limit when nil. Sync's Google writes pass
    ///   24 hours, since they need a Google backup but not a minutes-old one.
    public func freshReceipt(
        requiring requirement: BackupRequirement = BackupRequirement(containerID: nil), maxAge limit: TimeInterval? = nil
    ) async throws -> BackupReceipt {
        if let cached, cached.receipt.isFresh(maxAge: limit ?? maxAge, now: now()), Self.meets(requirement, cached.coverage) {
            return cached.receipt
        }
        return try await newBackup(requiring: requirement)
    }

    /// Always takes a new backup (or joins one already running for the same container) and checks it covers `requirement`.
    /// The new receipt replaces the cached one, so `freshReceipt` hands it out until it ages.
    public func newBackup(requiring requirement: BackupRequirement) async throws -> BackupReceipt {
        let (receipt, coverage) = try await takeBackup(joining: .container(requirement.containerID))
        guard coverage.containerID == requirement.containerID else {
            throw BackupCoordinatorError.requirementNotMet("the selected contacts account")
        }
        guard !requirement.needsNotes || coverage.notes else { throw BackupCoordinatorError.requirementNotMet("notes") }
        guard !requirement.needsGoogle || coverage.google else { throw BackupCoordinatorError.requirementNotMet("your Google contacts") }
        return receipt
    }

    private static func meets(_ requirement: BackupRequirement, _ coverage: Coverage) -> Bool {
        coverage.containerID == requirement.containerID
            && (!requirement.needsNotes || coverage.notes)
            && (!requirement.needsGoogle || coverage.google)
    }

    private enum Join {
        /// Take part in any run already going.
        case any
        /// Only a run that was started for this container.
        case container(String?)

        func accepts(_ key: String??) -> Bool {
            switch self {
            case .any: true
            case .container(let wanted): key == .some(wanted)
            }
        }

        var key: String?? {
            switch self {
            case .any: .none
            case .container(let id): .some(id)
            }
        }
    }

    private func takeBackup(joining policy: Join) async throws -> (BackupReceipt, Coverage) {
        if let running = inFlight {
            if policy.accepts(running.key) { return try await running.task.value }
            _ = try? await running.task.value // a run for another container: let it finish, then take our own
            if let again = inFlight, policy.accepts(again.key) { return try await again.task.value }
        }
        let make = makeSetup
        // Registered before anything suspends, so concurrent callers see it and share it.
        let task = Task { () -> (BackupReceipt, Coverage) in
            let setup = try await make()
            let receipt = try await setup.writer.createBackup()
            return (receipt, Coverage(
                containerID: setup.containerID, notes: receipt.manifest.notesIncluded, google: receipt.manifest.sources.contains("google")
            ))
        }
        inFlight = (policy.key, task)
        defer { if inFlight?.task == task { inFlight = nil } }
        let result = try await task.value
        cached = (result.0, result.1)
        return result
    }
}
