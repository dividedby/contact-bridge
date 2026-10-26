import Contacts
import Foundation
import Testing
@testable import ContactBridgeCore

/// After importing, the next plan must list the Google contact as already in iCloud, for every common contact shape.
struct ImportRoundTripTests {
    private func person(_ json: String) throws -> GooglePerson {
        try JSONDecoder().decode(GooglePerson.self, from: Data(json.utf8))
    }

    /// What the real store hands back after a save: the record through CNContact and back, under a new identifier.
    private func saved(_ record: ContactRecord) -> ContactRecord {
        CNContactMapper.record(from: CNContactMapper.makeContact(from: record))
    }

    @Test("An imported contact is already in iCloud on the next plan", arguments: [
        #"{"resourceName": "people/c1", "etag": "e", "names": [{"givenName": "Ann", "familyName": "Lee", "metadata": {"primary": true, "source": {"type": "CONTACT"}}}], "phoneNumbers": [{"value": "(415) 555-2671", "canonicalForm": "+14155552671", "type": "mobile", "metadata": {"primary": true, "source": {"type": "CONTACT"}}}]}"#,
        #"{"resourceName": "people/c2", "etag": "e", "names": [{"givenName": "Mom", "metadata": {"source": {"type": "CONTACT"}}}], "phoneNumbers": [{"value": "415-555-0100", "metadata": {"source": {"type": "CONTACT"}}}]}"#,
        #"{"resourceName": "people/c3", "etag": "e", "organizations": [{"name": "Acme Dental", "metadata": {"source": {"type": "CONTACT"}}}], "phoneNumbers": [{"value": "+1 512 555 0199", "metadata": {"source": {"type": "CONTACT"}}}]}"#,
        #"{"resourceName": "people/c4", "etag": "e", "emailAddresses": [{"value": "Someone@Example.com", "metadata": {"source": {"type": "CONTACT"}}}]}"#,
        #"{"resourceName": "people/c5", "etag": "e", "names": [{"givenName": "Bo", "familyName": "Ng", "metadata": {"source": {"type": "CONTACT"}}}]}"#,
    ])
    func importedIsLinked(json: String) throws {
        let google = try person(json)
        let planner = ImportPlanner()
        let before = planner.plan(icloud: [], googleConnections: [google], googleOtherContacts: [])
        let candidate = try #require(before.toImport.first)

        let after = planner.plan(icloud: [saved(candidate.record)], googleConnections: [google], googleOtherContacts: [])
        #expect(after.toImport.isEmpty, "still offered for import: \(candidate.record.displayName)")
        #expect(after.links.map(\.googleResourceName) == [google.resourceName])
    }

    @Test("A short-code business imported twice shows up as a Dedupe cluster")
    func shortCodeBusinessImportedTwiceClusters() throws {
        let google = try person(#"{"resourceName": "people/c9", "etag": "e", "organizations": [{"name": "Acme Bank", "metadata": {"source": {"type": "CONTACT"}}}], "phoneNumbers": [{"value": "72727", "type": "other", "metadata": {"source": {"type": "CONTACT"}}}]}"#)
        let planner = ImportPlanner()
        let candidate = try #require(planner.plan(icloud: [], googleConnections: [google], googleOtherContacts: []).toImport.first)
        #expect(candidate.isShortCodeSender)

        var first = saved(candidate.record)
        first.id = "icloud-1"
        first.sourceIdentifier = "icloud-1"
        var second = saved(candidate.record)
        second.id = "icloud-2"
        second.sourceIdentifier = "icloud-2"

        let clusters = DuplicateMatcher().findClusters(in: [first, second])
        let cluster = try #require(clusters.first)
        #expect(clusters.count == 1)
        #expect(cluster.members.map(\.id) == ["icloud-1", "icloud-2"])
        #expect(cluster.level == .high)
        #expect(cluster.reasons == ["same company and short code 72727"])

        // The plan against those copies calls the Google contact already imported.
        let after = planner.plan(icloud: [first, second], googleConnections: [google], googleOtherContacts: [])
        #expect(after.toImport.isEmpty)
        #expect(after.links.map(\.googleResourceName) == [google.resourceName])
    }
}
