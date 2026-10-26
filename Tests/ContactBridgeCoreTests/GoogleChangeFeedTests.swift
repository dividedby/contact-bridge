import Foundation
import Testing
@testable import ContactBridgeCore

struct GoogleChangeFeedTests {
    private let fieldsVersion = SyncFixtures.fieldsVersion

    private func feed(_ client: FakeGoogleClient, version: String? = nil) -> GoogleChangeFeed {
        GoogleChangeFeed(client: client, fieldsVersion: version ?? fieldsVersion)
    }

    private func people(_ count: Int) -> [GooglePerson] {
        (1...count).map { SyncFixtures.person("P\($0)", "Lee", phones: ["415-555-01\(String(format: "%02d", $0))"]) }
    }

    @Test("Without a sync token the whole book is listed, across pages, and a token comes back")
    func firstListing() async throws {
        let client = FakeGoogleClient(people: people(5), pageSize: 2)
        let result = try await feed(client).fetch(state: SyncState())
        #expect(result.status == .ok && result.mode == .full(.noToken) && result.isFullListing)
        #expect(result.people.count == 5 && result.deleted.isEmpty)
        #expect(result.nextSyncToken != nil && result.fieldsVersion == fieldsVersion)
    }

    @Test("With a valid token only the changes come back, and deletion markers are kept apart from live people")
    func incremental() async throws {
        let client = FakeGoogleClient(people: people(4))
        let first = try await feed(client).fetch(state: SyncState())
        let state = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: fieldsVersion)

        let none = try await feed(client).fetch(state: state)
        #expect(none.mode == .incremental && none.people.isEmpty && none.deleted.isEmpty)

        var edited = try await client.getPerson(resourceName: "people/c2")
        edited.names = [GoogleName(givenName: "Changed", familyName: "Lee")]
        _ = try await client.updateContact(resourceName: "people/c2", etag: try #require(edited.etag), person: edited, updatePersonFields: "names")
        try await client.deleteContact(resourceName: "people/c3")
        let added = try await client.createContact(SyncFixtures.person("New", "Face"))

        let result = try await feed(client).fetch(state: state)
        #expect(result.mode == .incremental && !result.isFullListing)
        #expect(Set(result.people.keys) == ["people/c2", try #require(added.resourceName)])
        #expect(result.deleted == ["people/c3"])
        #expect(result.people.values.allSatisfy { !$0.isDeleted })
        #expect(result.nextSyncToken != nil && result.nextSyncToken != first.nextSyncToken)
    }

    @Test("An expired sync token falls back to a full listing with a fresh token")
    func tokenExpired() async throws {
        let client = FakeGoogleClient(people: people(3))
        let first = try await feed(client).fetch(state: SyncState())
        await client.expireSyncTokens()
        let state = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: fieldsVersion)
        let result = try await feed(client).fetch(state: state)
        #expect(result.mode == .full(.tokenExpired))
        #expect(result.people.count == 3 && result.deleted.isEmpty)
        #expect(result.nextSyncToken != nil && result.nextSyncToken != first.nextSyncToken)
    }

    @Test("A sync token issued for other fields is not used: the book is listed in full")
    func fieldsVersionChanged() async throws {
        let client = FakeGoogleClient(people: people(3))
        let first = try await feed(client).fetch(state: SyncState())
        let state = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: "older-fields")
        let result = try await feed(client).fetch(state: state)
        #expect(result.mode == .full(.fieldsVersionChanged))
        #expect(result.people.count == 3, "an incremental call would have found no changes")
        #expect(result.fieldsVersion == fieldsVersion)

        let unset = try await feed(client).fetch(state: SyncState(googleSyncToken: first.nextSyncToken))
        #expect(unset.mode == .full(.fieldsVersionChanged))
    }

    @Test("A full listing can be demanded even though the token is good")
    func requested() async throws {
        let client = FakeGoogleClient(people: people(2))
        let first = try await feed(client).fetch(state: SyncState())
        let state = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: fieldsVersion)
        let result = try await feed(client).fetch(state: state, requireFullListing: true)
        #expect(result.mode == .full(.requested) && result.people.count == 2)
    }

    @Test("A different account pauses and lists nothing; the same one (any case) or none stored goes on")
    func accountChanged() async throws {
        let client = FakeGoogleClient(people: people(2))
        let paused = try await feed(client).fetch(state: SyncState(googleAccount: "me@example.com"), accountEmail: "other@example.com")
        #expect(paused.status == .paused(.accountChanged) && paused.pause == .accountChanged && paused.people.isEmpty)

        let same = try await feed(client).fetch(state: SyncState(googleAccount: "me@example.com"), accountEmail: "ME@example.com")
        #expect(same.status == .ok && same.people.count == 2)

        let adopted = try await feed(client).fetch(state: SyncState(), accountEmail: "me@example.com")
        #expect(adopted.account == "me@example.com")
        let neither = try await feed(client).fetch(state: SyncState(), accountEmail: nil)
        #expect(neither.status == .ok && neither.account == nil)
    }

    @Test("A saved account with no known current email fails the run before Google is read: unconfirmed, not changed")
    func accountUnconfirmed() async throws {
        let client = FakeGoogleClient(people: people(2))
        await #expect(throws: GoogleChangeFeedError.accountUnconfirmed) {
            try await feed(client).fetch(state: SyncState(googleAccount: "me@example.com"), accountEmail: nil)
        }
        await #expect(throws: GoogleChangeFeedError.accountUnconfirmed) {
            try await feed(client).fetch(state: SyncState(googleAccount: "me@example.com"), accountEmail: "", requireFullListing: true)
        }
        #expect(GoogleChangeFeedError.accountUnconfirmed.localizedDescription.contains("which Google account"))
    }

    @Test("The ownership tag index maps iCloud ids to resource names")
    func ownershipIndex() async throws {
        let client = FakeGoogleClient(people: [SyncFixtures.person("A", "Lee", tag: "I1"), SyncFixtures.person("B", "Lee")])
        let result = try await feed(client).fetch(state: SyncState())
        #expect(result.ownershipIndex == ["I1": "people/c1"])
    }

    @Test("A listing that never ends is an error, not a hang")
    func runawayPaging() async throws {
        let client = LoopingClient()
        await #expect(throws: GoogleListingError.pagingDidNotTerminate("connections")) {
            try await GoogleChangeFeed(client: client, fieldsVersion: "v").fetch(state: SyncState())
        }
    }

    @Test("The real client asks for biographies, and the fields version is a stable digest of its field list")
    func fieldsVersionDigest() {
        #expect(URLSessionGoogleContactsClient.personFields.split(separator: ",").contains("biographies"))
        #expect(GoogleChangeFeed.currentFieldsVersion == GoogleChangeFeed.currentFieldsVersion)
        #expect(GoogleChangeFeed.currentFieldsVersion.count == 64)
    }

    @Test("Notes are read from biographies; none, blank or read-only entries mean an empty note, which is a known hash")
    func noteFromPerson() {
        #expect(GooglePersonMapper.note(of: SyncFixtures.person("A", "B", note: "Hello\nthere")) == "Hello\nthere")
        #expect(GooglePersonMapper.note(of: SyncFixtures.person("A", "B")) == "")
        #expect(GooglePersonMapper.noteHash(of: SyncFixtures.person("A", "B")) == NoteHash.hash(""))
        #expect(GooglePersonMapper.noteHash(of: SyncFixtures.person("A", "B", note: " Hi ")) == NoteHash.hash("Hi"))

        var profile = SyncFixtures.person("A", "B")
        profile.extras["biographies"] = .array([
            .object(["value": .string("From profile"), "metadata": .object(["source": .object(["type": .string("PROFILE")])])]),
            .object(["value": .string("Mine"), "metadata": .object(["source": .object(["type": .string("CONTACT")])])]),
            .object(["value": .string("  ")]),
        ])
        #expect(GooglePersonMapper.note(of: profile) == "Mine")
    }

    /// Always answers with another page.
    private struct LoopingClient: GoogleContactsClient {
        func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
            GooglePeoplePage(people: [], nextPageToken: "page-\((Int(pageToken?.dropFirst(5) ?? "0") ?? 0) + 1)")
        }
        func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage { GooglePeoplePage(people: []) }
        func getPerson(resourceName: String) async throws -> GooglePerson { GooglePerson() }
        func createContact(_ person: GooglePerson) async throws -> GooglePerson { person }
        func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson { person }
        func deleteContact(resourceName: String) async throws {}
        func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] { [] }
        func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] { [] }
        func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] { [] }
        func ensureGroup(named name: String) async throws -> String { "" }
        func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {}
    }
}
