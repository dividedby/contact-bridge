import Foundation

/// An async mutex for everything that changes contacts: a sync run, Import, Merge (single and bulk) and Clean up all run
/// inside `withLock`, so a sync never reads or writes while a merge is half done, and the other way round.
///
/// Waiters are served in arrival order. A waiter whose task is cancelled leaves the queue with `CancellationError`;
/// the holder is never interrupted by the gate itself.
public actor WriteGate {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, any Error>
    }

    private var isHeld = false
    private var waiters: [Waiter] = []
    private var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    public init() {}

    /// Whether someone holds the gate right now.
    public var isLocked: Bool { isHeld }
    /// How many callers are queued behind the holder.
    public var waitingCount: Int { waiters.count }

    /// Runs `body` once nobody else holds the gate, and releases it afterwards however `body` ends.
    public func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard isHeld else {
            isHeld = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                notifyWatchers()
            }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    /// Hands the gate straight to the next waiter, so it is never free for a moment in between.
    private func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().continuation.resume()
            notifyWatchers()
        }
    }

    private func abandon(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        notifyWatchers()
    }

    /// For tests: returns once exactly `count` callers are queued behind the holder.
    func waitUntilQueued(_ count: Int) async {
        if waiters.count == count { return }
        await withCheckedContinuation { watchers.append((count, $0)) }
    }

    private func notifyWatchers() {
        let ready = watchers.filter { $0.count == waiters.count }
        watchers.removeAll { $0.count == waiters.count }
        for watcher in ready { watcher.continuation.resume() }
    }
}
