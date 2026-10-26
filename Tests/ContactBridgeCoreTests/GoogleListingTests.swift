import Testing
@testable import ContactBridgeCore

struct GoogleListingTests {
    private func person(_ given: String) -> GooglePerson {
        GooglePerson(names: [GoogleName(givenName: given, familyName: "Test")])
    }

    @Test("allConnections and allOtherContacts follow every page")
    func followsPages() async throws {
        let client = FakeGoogleClient(people: (0..<5).map { person("P\($0)") }, otherContacts: (0..<3).map { person("O\($0)") }, pageSize: 2)
        let connections = try await client.allConnections()
        #expect(connections.compactMap { $0.names?.first?.givenName } == ["P0", "P1", "P2", "P3", "P4"])
        let others = try await client.allOtherContacts()
        #expect(others.compactMap { $0.names?.first?.givenName } == ["O0", "O1", "O2"])
    }

    @Test("An empty account lists as empty")
    func empty() async throws {
        let client = FakeGoogleClient()
        #expect(try await client.allConnections().isEmpty)
        #expect(try await client.allOtherContacts().isEmpty)
    }

    /// Always answers with the same next-page token.
    private struct LoopingClient: GoogleContactsClient {
        func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
            GooglePeoplePage(people: [], nextPageToken: "same")
        }
        func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage { GooglePeoplePage(people: [], nextPageToken: "same") }
        func getPerson(resourceName: String) async throws -> GooglePerson { fatalError() }
        func createContact(_ person: GooglePerson) async throws -> GooglePerson { fatalError() }
        func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson { fatalError() }
        func deleteContact(resourceName: String) async throws { fatalError() }
        func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] { fatalError() }
        func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] { fatalError() }
        func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] { fatalError() }
        func ensureGroup(named name: String) async throws -> String { fatalError() }
        func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws { fatalError() }
    }

    @Test("A listing that repeats a page token throws instead of looping")
    func repeatedTokenStops() async {
        await #expect(throws: GoogleListingError.pagingDidNotTerminate("connections")) { _ = try await LoopingClient().allConnections() }
        await #expect(throws: GoogleListingError.pagingDidNotTerminate("otherContacts")) { _ = try await LoopingClient().allOtherContacts() }
    }
}
