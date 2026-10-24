import Foundation
import Testing
@testable import ContactBridgeCore

/// Builders for the sync detection and planning tests.
enum SyncFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let fieldsVersion = "fv-test"

    static func icloud(
        _ id: String, _ given: String, _ family: String, phones: [String] = [], emails: [String] = [], nickname: String = ""
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, nickname: nickname,
            phones: phones.map { Labeled(label: "mobile", value: $0) }, emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    /// A Google contact as the API would return it for create/seed (no identity yet).
    static func person(
        _ given: String, _ family: String, phones: [String] = [], emails: [String] = [], note: String? = nil, tag: String? = nil
    ) -> GooglePerson {
        var person = GooglePerson(
            names: [GoogleName(givenName: given, familyName: family)],
            phoneNumbers: phones.isEmpty ? nil : phones.map { GooglePhoneNumber(value: $0, type: "mobile") },
            emailAddresses: emails.isEmpty ? nil : emails.map { GoogleEmailAddress(value: $0, type: "home") }
        )
        if let note { person.extras["biographies"] = .array([.object(["value": .string(note), "contentType": .string("TEXT_PLAIN")])]) }
        if let tag { GoogleOwnership.setSourceID(tag, on: &person) }
        return person
    }

    static func receipt() -> BackupReceipt { .forTesting() }
}

/// An iCloud store, a Google fake and the sync files, driven through the real scanner, feed and planner. `commit` stands
/// in for the stage 3 executor: it stores what a successful run would.
final class SyncWorld: @unchecked Sendable {
    let store: InMemoryContactStore
    let google: FakeGoogleClient
    let notes: InMemoryNotesStore
    var state = SyncState()
    var links = LinkTable()
    var clock = SyncFixtures.t0
    var contactsRunning = false
    var planner = SyncPlanner()
    var account: String? = "me@example.com"
    var feedFieldsVersion = SyncFixtures.fieldsVersion
    private(set) var lastScan: ICloudScan?
    private(set) var lastFeed: GoogleFeed?

    init(
        icloud: [ContactRecord] = [], google people: [GooglePerson] = [], notes: [String: String] = [:], pageSize: Int = 100
    ) {
        store = InMemoryContactStore(records: icloud)
        google = FakeGoogleClient(people: people, pageSize: pageSize)
        self.notes = InMemoryNotesStore(notes: notes)
    }

    /// - Parameter autoFull: list Google in full when `SyncPlanner.requiresFullGoogleListing` says so, as the engine will.
    func plan(_ trigger: SyncTrigger = .scheduled, requireFullListing: Bool = false, autoFull: Bool = true) async throws -> SyncPlan {
        let running = contactsRunning
        let scanner = ICloudScanner(store: store, notes: notes, contactsAppRunning: { running }, now: { [clock] in clock })
        let scan = try await scanner.scan(state: state, links: links, trigger: trigger)
        let full = requireFullListing || (autoFull && SyncPlanner.requiresFullGoogleListing(icloud: scan, links: links, state: state))
        let feed = try await GoogleChangeFeed(client: google, fieldsVersion: feedFieldsVersion)
            .fetch(state: state, accountEmail: account, requireFullListing: full)
        lastScan = scan
        lastFeed = feed
        return planner.plan(icloud: scan, google: feed, state: state, links: links, now: clock)
    }

    /// Stores the links, baselines and checkpoint of `plan`, as a completed run would, and approves syncing.
    func commit(_ plan: SyncPlan) {
        for link in plan.links {
            links.links[link.icloudID] = LinkEntry(googleResourceName: link.resourceName, linkedAt: clock)
            state.baselines[link.icloudID] = link.baseline
        }
        for (id, baseline) in plan.baselineRefreshes { state.baselines[id] = baseline }
        for update in plan.updates { state.baselines[update.icloudID] = update.baseline }
        for id in plan.droppedLinks {
            links.links[id] = nil
            state.baselines[id] = nil
        }
        state.firstSyncApproved = true
        if let checkpoint = plan.checkpoint { state = checkpoint.applied(to: state) }
    }

    /// Plans and commits a first sync of whatever was seeded.
    @discardableResult
    func settle() async throws -> SyncPlan {
        let first = try await plan()
        commit(first)
        return first
    }

    func advance(hours: Double) { clock = clock.addingTimeInterval(hours * 3600) }

    func icloudRecord(_ id: String) async throws -> ContactRecord? {
        try await store.fetchAll().first { $0.sourceIdentifier == id }
    }

    func editICloud(_ id: String, _ change: (inout ContactRecord) -> Void) async throws {
        var record = try #require(await icloudRecord(id))
        change(&record)
        try await store.update(record, backup: SyncFixtures.receipt())
    }

    /// Edits the Google contact the way a user would (names, phones, emails, biographies masks as given).
    func editGoogle(_ resourceName: String, mask: String, _ change: (inout GooglePerson) -> Void) async throws {
        var person = try await google.getPerson(resourceName: resourceName)
        change(&person)
        _ = try await google.updateContact(
            resourceName: resourceName, etag: try #require(person.etag), person: person, updatePersonFields: mask
        )
    }
}

extension SyncWorld {
    /// `count` contacts that already match one to one and have synced: baselines, links, approved, notes read, token current.
    static func linked(count: Int) async throws -> SyncWorld {
        let icloud = (1...count).map { SyncFixtures.icloud("I\($0)", "First\($0)", "Last\($0)", phones: ["415-555-\(String(format: "%04d", $0))"]) }
        let people = icloud.map { SyncFixtures.person($0.givenName, $0.familyName, phones: [$0.phones[0].value]) }
        let world = SyncWorld(icloud: icloud, google: people)
        let listed = await world.google.allPeople
        for (record, person) in zip(icloud, listed) {
            let name = try #require(person.resourceName)
            world.links.links[record.sourceIdentifier] = LinkEntry(googleResourceName: name, linkedAt: world.clock)
            world.state.baselines[record.sourceIdentifier] = SyncBaseline(
                icloud: record, google: try #require(GooglePersonMapper.record(from: person)), googleEtag: try #require(person.etag),
                icloudNoteHash: NoteHash.hash(""), googleNoteHash: NoteHash.hash(""), syncedAt: world.clock
            )
        }
        let first = try await GoogleChangeFeed(client: world.google, fieldsVersion: world.feedFieldsVersion).fetch(state: SyncState())
        world.state.googleSyncToken = first.nextSyncToken
        world.state.fieldsVersion = world.feedFieldsVersion
        world.state.googleAccount = world.account
        world.state.icloudChangeToken = try await world.store.changeToken()
        world.state.icloudContainerID = try await world.store.containerID()
        world.state.lastNotesReadAt = world.clock
        world.state.firstSyncApproved = true
        return world
    }
}
