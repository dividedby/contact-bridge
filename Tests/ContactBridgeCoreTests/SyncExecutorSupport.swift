import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

/// A Google client that forwards to a `FakeGoogleClient` and can misreport or "crash" after a batch call has really
/// been applied, which the fake's own failure injection cannot do.
final class FaultyGoogle: GoogleContactsClient, Sendable {
    enum Fault: Sendable {
        /// The batch is applied, then every result is reported as `ambiguous` (the answer was lost).
        case ambiguousAfterApply
        /// The batch is applied, then the call dies (the process was killed before it could record anything).
        case crashAfterApply
    }

    struct Crash: Error {}

    let inner: FakeGoogleClient
    private let armed = Mutex<[FakeGoogleClient.Operation: Fault]>([:])
    private let lagging = Mutex(false)

    init(_ inner: FakeGoogleClient) {
        self.inner = inner
    }

    /// While on, listings leave out every contact that carries an ownership tag, as a listing that lags behind creates does.
    func setListingLag(_ on: Bool) { lagging.withLock { $0 = on } }

    func arm(_ fault: Fault, on operation: FakeGoogleClient.Operation) { armed.withLock { $0[operation] = fault } }

    private func finish(_ results: [GoogleBatchResult], _ operation: FakeGoogleClient.Operation) throws -> [GoogleBatchResult] {
        switch armed.withLock({ $0.removeValue(forKey: operation) }) {
        case .ambiguousAfterApply?:
            return results.map { GoogleBatchResult(resourceName: $0.resourceName, outcome: .ambiguous(reason: "the answer was lost")) }
        case .crashAfterApply?:
            throw Crash()
        case nil:
            return results
        }
    }

    func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
        var page = try await inner.listConnections(syncToken: syncToken, pageToken: pageToken)
        if lagging.withLock({ $0 }) { page.people.removeAll { $0.contactBridgeSourceID != nil } }
        return page
    }
    func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage { try await inner.listOtherContacts(pageToken: pageToken) }
    func getPerson(resourceName: String) async throws -> GooglePerson { try await inner.getPerson(resourceName: resourceName) }
    func createContact(_ person: GooglePerson) async throws -> GooglePerson { try await inner.createContact(person) }
    func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson {
        try await inner.updateContact(resourceName: resourceName, etag: etag, person: person, updatePersonFields: updatePersonFields)
    }
    func deleteContact(resourceName: String) async throws { try await inner.deleteContact(resourceName: resourceName) }
    func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] {
        try finish(try await inner.batchCreate(people), .batchCreate)
    }
    func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] {
        try finish(try await inner.batchUpdate(updates), .batchUpdate)
    }
    func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] {
        try finish(try await inner.batchDelete(resourceNames), .batchDelete)
    }
    func ensureGroup(named name: String) async throws -> String { try await inner.ensureGroup(named: name) }
    func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
        try await inner.addMembers(groupResourceName: groupResourceName, memberResourceNames: memberResourceNames)
    }
}

final class TestClock: Sendable {
    private let time = Mutex(SyncFixtures.t0.timeIntervalSince1970)
    func now() -> Date { Date(timeIntervalSince1970: time.withLock { $0 }) }
    func advance(hours: Double) { time.withLock { $0 += hours * 3600 } }
    func advance(minutes: Double) { time.withLock { $0 += minutes * 60 } }
}

/// A `SyncWorld` plus the stores and executor that act on it. The world plans from whatever is in the stores.
final class ExecutorRig: @unchecked Sendable {
    let world: SyncWorld
    let faulty: FaultyGoogle
    let clock = TestClock()
    let linkStore = InMemoryLinkStore()
    let stateStore: InMemorySyncStateStore
    let reviews = InMemoryReviewStore()
    let journal = InMemorySyncJournalStore()
    let history: any SyncHistoryStoring
    let directory: URL
    let backups: BackupCoordinator

    init(_ world: SyncWorld, history: any SyncHistoryStoring = InMemorySyncHistoryStore()) throws {
        self.world = world
        self.history = history
        faulty = FaultyGoogle(world.google)
        stateStore = InMemorySyncStateStore(world.state)
        try linkStore.add(world.links.links.map { ImportedLink(icloudID: $0.key, googleResourceName: $0.value.googleResourceName) }, at: world.clock)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("executor-tests-\(UUID().uuidString)", isDirectory: true)
        let store = world.store, google = world.google, notes = world.notes, directory = directory, clock = clock
        backups = BackupCoordinator(makeSetup: {
            BackupSetup(writer: BackupWriter(store: store, google: google, notes: notes, baseDirectory: directory, now: { clock.now() }))
        }, now: { clock.now() })
    }

    /// Eight contacts that already match and have synced.
    static func linked(count: Int = 6, history: any SyncHistoryStoring = InMemorySyncHistoryStore()) async throws -> ExecutorRig {
        try ExecutorRig(try await SyncWorld.linked(count: count), history: history)
    }

    func makeExecutor() -> SyncExecutor {
        let clock = clock
        return SyncExecutor(
            google: faulty, links: linkStore, state: stateStore, reviews: reviews, journal: journal, history: history,
            backups: backups, now: { clock.now() }
        )
    }

    func plan(_ trigger: SyncTrigger = .scheduled, requireFullListing: Bool = false) async throws -> SyncPlan {
        world.state = try stateStore.load()
        world.links = try linkStore.load()
        world.clock = clock.now()
        return try await world.plan(trigger, requireFullListing: requireFullListing)
    }

    func run(_ plan: SyncPlan) async throws -> SyncRunReport { try await makeExecutor().execute(plan: plan) }

    /// Plans and executes in one go.
    @discardableResult
    func sync() async throws -> SyncRunReport { try await run(try await plan()) }

    var state: SyncState { get throws { try stateStore.load() } }
    var links: [String: LinkEntry] { get throws { try linkStore.load().links } }

    func backupFolders() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { !$0.hasPrefix(".") }.count
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func googlePerson(_ resourceName: String) async throws -> GooglePerson { try await world.google.getPerson(resourceName: resourceName) }

    func taggedPeople(_ icloudID: String) async -> [GooglePerson] {
        await world.google.allPeople.filter { $0.contactBridgeSourceID == icloudID }
    }

    func setPhone(_ id: String, _ phone: String) async throws {
        try await world.editICloud(id) { $0.phones = [Labeled(label: "mobile", value: phone)] }
    }

    /// A brand-new iCloud contact with a note, as the user would add one.
    @discardableResult
    func addICloudContact(_ given: String, _ family: String, phone: String, note: String? = nil) async throws -> ContactRecord {
        let created = try await world.store.create(SyncFixtures.icloud("", given, family, phones: [phone]), backup: .forTesting())
        if let note { try await world.notes.setNote(note, forID: created.sourceIdentifier) }
        return created
    }
}
