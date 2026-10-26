import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

/// A clock that only moves when a test says so. Sleepers wait for an absolute deadline, so time passing before a sleeper
/// registers cannot stretch its wait.
final class ManualSyncClock: SyncClock, Sendable {
    private struct Sleeper {
        var id: UUID
        var due: Date
        var continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var sleepers: [Sleeper] = []
        var watchers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state: Mutex<State>

    init(start: Date = SyncFixtures.t0) {
        state = Mutex(State(now: start))
    }

    func now() -> Date { state.withLock { $0.now } }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Date) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let (due, watching) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    if deadline <= state.now { return (true, []) }
                    state.sleepers.append(Sleeper(id: id, due: deadline, continuation: continuation))
                    return (false, Self.ready(&state))
                }
                for watcher in watching { watcher.resume() }
                if due {
                    continuation.resume()
                } else if Task.isCancelled {
                    cancel(id)
                }
            }
        } onCancel: {
            cancel(id)
        }
    }

    /// Watchers whose sleeper count has been reached; call with the lock held, resume them outside it.
    private static func ready(_ state: inout State) -> [CheckedContinuation<Void, Never>] {
        let hit = state.watchers.filter { $0.count == state.sleepers.count }
        state.watchers.removeAll { $0.count == state.sleepers.count }
        return hit.map(\.continuation)
    }

    private func cancel(_ id: UUID) {
        let (sleeper, watching) = state.withLock { state -> (Sleeper?, [CheckedContinuation<Void, Never>]) in
            guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else { return (nil, []) }
            let removed = state.sleepers.remove(at: index)
            return (removed, Self.ready(&state))
        }
        sleeper?.continuation.resume(throwing: CancellationError())
        for watcher in watching { watcher.resume() }
    }

    /// Returns once exactly `count` tasks are asleep on this clock. Tests call it before moving time, so that a sleeper
    /// that is still on its way to sleep cannot miss the move.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate = state.withLock { state -> Bool in
                if state.sleepers.count == count { return true }
                state.watchers.append((count, continuation))
                return false
            }
            if immediate { continuation.resume() }
        }
    }

    /// Moves time and wakes the sleepers it reaches. Returns how many woke.
    @discardableResult
    func advance(by seconds: TimeInterval) -> Int {
        let (woken, watching) = state.withLock { state -> ([Sleeper], [CheckedContinuation<Void, Never>]) in
            state.now = state.now.addingTimeInterval(seconds)
            let due = state.sleepers.filter { $0.due <= state.now }
            state.sleepers.removeAll { $0.due <= state.now }
            return (due.sorted { $0.due < $1.due }, Self.ready(&state))
        }
        for sleeper in woken { sleeper.continuation.resume() }
        for watcher in watching { watcher.resume() }
        return woken.count
    }
}

/// Forwards to another client, counts listings and can make them fail.
final class CountingGoogle: GoogleContactsClient, Sendable {
    private let inner: any GoogleContactsClient
    private let counts = Mutex((listings: 0, gets: 0))
    private let listingFailure = Mutex<GoogleAPIError?>(nil)
    private let blocker = Mutex<(entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)?>(nil)

    init(_ inner: any GoogleContactsClient) {
        self.inner = inner
    }

    var listings: Int { counts.withLock { $0.listings } }
    func failListings(with error: GoogleAPIError?) { listingFailure.withLock { $0 = error } }

    /// Holds the next listing until `release` is signalled. `entered` yields once that listing has started.
    func blockNextListing() -> (entered: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        blocker.withLock { $0 = (enteredContinuation, release) }
        return (entered, releaseContinuation)
    }

    func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
        counts.withLock { $0.listings += 1 }
        if let held = blocker.withLock({ state -> (entered: AsyncStream<Void>.Continuation, release: AsyncStream<Void>)? in
            defer { state = nil }
            return state
        }) {
            held.entered.yield()
            for await _ in held.release { break }
        }
        if let error = listingFailure.withLock({ $0 }) { throw error }
        return try await inner.listConnections(syncToken: syncToken, pageToken: pageToken)
    }
    func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage { try await inner.listOtherContacts(pageToken: pageToken) }
    func getPerson(resourceName: String) async throws -> GooglePerson { try await inner.getPerson(resourceName: resourceName) }
    func createContact(_ person: GooglePerson) async throws -> GooglePerson { try await inner.createContact(person) }
    func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson {
        try await inner.updateContact(resourceName: resourceName, etag: etag, person: person, updatePersonFields: updatePersonFields)
    }
    func deleteContact(resourceName: String) async throws { try await inner.deleteContact(resourceName: resourceName) }
    func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] { try await inner.batchCreate(people) }
    func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] { try await inner.batchUpdate(updates) }
    func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] { try await inner.batchDelete(resourceNames) }
    func ensureGroup(named name: String) async throws -> String { try await inner.ensureGroup(named: name) }
    func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
        try await inner.addMembers(groupResourceName: groupResourceName, memberResourceNames: memberResourceNames)
    }
}

/// Forwards to another state store and can make every write fail, to test what the engine does when saving does not work.
final class FlakyStateStore: SyncStateStoring, Sendable {
    struct WriteFailure: Error, LocalizedError {
        var errorDescription: String? { "disk is full" }
    }

    private let inner: any SyncStateStoring
    private let failing = Mutex(false)

    init(_ inner: any SyncStateStoring) {
        self.inner = inner
    }

    func failWrites(_ fail: Bool) { failing.withLock { $0 = fail } }

    func load() throws -> SyncState { try inner.load() }

    func save(_ state: SyncState) throws {
        if failing.withLock({ $0 }) { throw WriteFailure() }
        try inner.save(state)
    }

    @discardableResult
    func update(_ change: (inout SyncState) throws -> Void) throws -> SyncState {
        if failing.withLock({ $0 }) { throw WriteFailure() }
        return try inner.update(change)
    }
}

/// A `SyncEngine` over an `ExecutorRig`'s world and stores, driven by a manual clock.
final class EngineRig: @unchecked Sendable {
    let base: ExecutorRig
    let clock = ManualSyncClock()
    let google: CountingGoogle
    let gate = WriteGate()
    let engine: SyncEngine
    /// What the engine saves its state through; `failWrites` makes saving fail.
    let flakyState: FlakyStateStore
    private final class Reason: Sendable {
        let value: Mutex<String?>
        init(_ initial: String? = nil) { value = Mutex(initial) }
    }

    private let notReady = Reason()
    private let accountEmail = Reason("me@example.com")

    init(
        _ base: ExecutorRig, planner: SyncPlanner = SyncPlanner(), schedule: SyncSchedule = SyncSchedule(),
        acquireLock: (@Sendable () throws -> any SyncLockHolding)? = nil
    ) {
        self.base = base
        flakyState = FlakyStateStore(base.stateStore)
        // The engine reads Google with the real field list, so a stored token must have been issued for it.
        if (try? base.stateStore.load().googleSyncToken) != nil {
            _ = try? base.stateStore.update { $0.fieldsVersion = GoogleChangeFeed.currentFieldsVersion }
        }
        let google = CountingGoogle(base.faulty)
        self.google = google
        let store = base.world.store, notes = base.world.notes
        let notReady = notReady, accountEmail = accountEmail
        let gate = gate
        engine = SyncEngine(
            environment: {
                if let reason = notReady.value.withLock({ $0 }) { return .notReady(reason) }
                return .ready(SyncEnvironment(store: store, notes: notes, google: google, accountEmail: accountEmail.value.withLock { $0 }))
            },
            links: base.linkStore, state: flakyState, reviews: base.reviews, journal: base.journal, history: base.history,
            backups: base.backups, gate: gate, clock: clock, schedule: schedule, planner: planner, acquireLock: acquireLock
        )
    }

    /// Six synced contacts, approved.
    static func linked(
        count: Int = 6, planner: SyncPlanner = SyncPlanner(), acquireLock: (@Sendable () throws -> any SyncLockHolding)? = nil
    ) async throws -> EngineRig {
        EngineRig(try await ExecutorRig.linked(count: count), planner: planner, acquireLock: acquireLock)
    }

    func setNotReady(_ reason: String?) { notReady.value.withLock { $0 = reason } }
    /// The signed-in account's email as the next run sees it; nil is "signed in, email unknown".
    func setAccountEmail(_ email: String?) { accountEmail.value.withLock { $0 = email } }

    var snapshot: SyncSnapshot { get async { await engine.current } }
    var state: SyncState { get throws { try base.stateStore.load() } }

    /// Starts the engine and waits for its timer to be asleep, so time can be moved from here on.
    func start() async {
        await engine.start()
        await clock.waitForSleepers(1)
    }

    /// Starts an approved engine and waits for its first run to end. Returns the listings it made.
    func startAndRun() async -> Int {
        await start()
        await engine.waitForRuns(1)
        return google.listings
    }

    /// Moves time forward and waits until the engine has handled every wake-up that released, and any run they began.
    /// The caller makes sure the sleepers it means to wake have registered (`clock.waitForSleepers`).
    func advance(_ seconds: TimeInterval) async {
        let before = await engine.handledWakeups
        let woken = clock.advance(by: seconds)
        await engine.waitForWakeups(before + woken)
        await engine.waitUntilIdle()
    }

    func cleanUp() { base.cleanUp() }
}
