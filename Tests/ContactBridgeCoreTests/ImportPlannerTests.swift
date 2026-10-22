import Foundation
import Testing
@testable import ContactBridgeCore

struct ImportPlannerTests {
    private let planner = ImportPlanner()

    private func icloud(
        _ id: String, _ given: String, _ family: String, phones: [String] = [], emails: [String] = [], org: String = ""
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, givenName: given, familyName: family, organization: org,
            phones: phones.map { Labeled(label: "mobile", value: $0) }, emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    private func google(
        _ id: String, _ given: String, _ family: String, phones: [String] = [], emails: [String] = [],
        source: ContactSource = .google
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: source, sourceIdentifier: id, givenName: given, familyName: family,
            phones: phones.map { Labeled(label: "mobile", value: $0) }, emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    private func plan(_ icloud: [ContactRecord], _ connections: [ContactRecord] = [], _ others: [ContactRecord] = []) -> ImportPlan {
        planner.plan(icloud: icloud, connections: connections, otherContacts: others)
    }

    // MARK: connections

    @Test("A connection with no iCloud counterpart is imported and selected by default")
    func unmatchedConnectionImports() {
        let result = plan([icloud("i1", "Ann", "Lee", phones: ["415-555-0001"])], [google("people/c1", "Bob", "Stone", phones: ["415-555-0002"])])
        #expect(result.toImport.map(\.id) == ["people/c1"])
        #expect(result.toImport.allSatisfy { $0.isSelected })
        #expect(result.links.isEmpty && result.possibleMatches.isEmpty && result.otherContactCandidates.isEmpty)
    }

    @Test("A high-confidence match is already in iCloud: recorded as a link, not imported")
    func highConfidenceIsLinked() throws {
        let result = plan(
            [icloud("i1", "Ann", "Lee", phones: ["(415) 555-2671"])],
            [google("people/c1", "Ann", "Lee", phones: ["+1 415-555-2671"])]
        )
        #expect(result.toImport.isEmpty)
        let link = try #require(result.links.first)
        #expect(result.links.count == 1)
        #expect(link.icloudID == "i1" && link.googleResourceName == "people/c1")
        #expect(link.level == .high)
        #expect(!link.isNameOnly && link.importAnywayCandidate == nil)
        #expect(link.reasons.contains("same name"))
        #expect(link.icloudName == "Ann Lee" && link.googleName == "Ann Lee")
    }

    @Test("Medium confidence (same full name, nothing else to compare) also counts as already in iCloud")
    func mediumConfidenceIsLinked() throws {
        let result = plan([icloud("i1", "Ann", "Lee")], [google("people/c1", "Ann", "Lee")])
        #expect(result.toImport.isEmpty)
        let link = try #require(result.links.first)
        #expect(link.level == .medium)
        #expect(result.possibleMatches.isEmpty)
        // No shared phone or email: a common name can hide a different person, so the UI offers "Import anyway".
        #expect(link.isNameOnly)
        let candidate = try #require(link.importAnywayCandidate)
        #expect(candidate.id == "people/c1" && !candidate.isSelected && candidate.record.source == .google)
    }

    @Test("A low-confidence pair stays importable and is listed as a possible match")
    func lowConfidenceIsPossibleMatch() throws {
        // Same email, different first names: a family address, not the same person.
        let result = plan(
            [icloud("i1", "John", "Smith", emails: ["family@example.com"])],
            [google("people/c1", "Jane", "Smith", emails: ["family@example.com"])]
        )
        #expect(result.toImport.map(\.id) == ["people/c1"])
        #expect(result.toImport[0].isSelected)
        #expect(result.links.isEmpty)
        let possible = try #require(result.possibleMatches.first)
        #expect(result.possibleMatches.count == 1)
        #expect(possible.icloudID == "i1" && possible.googleID == "people/c1" && possible.googleSource == .google)
        #expect(possible.level == .low)
        #expect(possible.icloudName == "John Smith" && possible.googleName == "Jane Smith")
        #expect(possible.flags.contains(.sharedEmailDifferentNames))
        #expect(result.possibleMatches(forGoogleID: "people/c1") == [possible])
        #expect(result.possibleMatches(forGoogleID: "people/zzz").isEmpty)
    }

    @Test("A medium score carrying a conflict flag is a possible match, not a link")
    func conflictFlaggedMediumIsNotALink() throws {
        // Shared phone AND email with different first names: scores medium, but the matcher calls it a conflict.
        let result = plan(
            [icloud("i1", "John", "Smith", phones: ["415-555-0100"], emails: ["home@example.com"])],
            [google("people/c1", "Jane", "Smith", phones: ["415-555-0100"], emails: ["home@example.com"])]
        )
        let possible = try #require(result.possibleMatches.first)
        #expect(possible.confidence >= ConfidenceLevel.mediumThreshold)
        #expect(possible.flags.contains { $0.isConflict })
        #expect(result.links.isEmpty)
        #expect(result.toImport.map(\.id) == ["people/c1"])
    }

    @Test("Weaker iCloud candidates for an already-linked connection are not listed as possible matches")
    func linkedConnectionHasNoPossibleMatches() {
        let result = plan(
            [
                icloud("i1", "Ann", "Lee", phones: ["415-555-2671"]),
                icloud("i2", "Anne", "Leigh", emails: ["x@example.com"]),
            ],
            [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"], emails: ["x@example.com"])]
        )
        #expect(result.links.count == 1)
        #expect(result.possibleMatches.isEmpty)
    }

    @Test("With several iCloud matches, the link goes to the strongest; ties go to the lowest id")
    func bestMatchWins() {
        let strongest = plan(
            [
                icloud("i1", "Ann", "Lee", emails: ["ann@example.com"]),
                icloud("i2", "Ann", "Lee", phones: ["415-555-2671"], emails: ["ann@example.com"]),
            ],
            [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"], emails: ["ann@example.com"])]
        )
        #expect(strongest.links.map(\.icloudID) == ["i2"])

        let tied = plan(
            [icloud("i2", "Ann", "Lee", phones: ["415-555-2671"]), icloud("i1", "Ann", "Lee", phones: ["415-555-2671"])],
            [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"])]
        )
        #expect(tied.links.map(\.icloudID) == ["i1"])
    }

    @Test("Two Google duplicates of one iCloud contact each get their own link")
    func googleDuplicatesEachLink() {
        let result = plan(
            [icloud("i1", "Ann", "Lee", phones: ["415-555-2671"])],
            [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"]), google("people/c2", "Ann", "Lee", phones: ["415-555-2671"])]
        )
        #expect(result.toImport.isEmpty)
        #expect(result.links.map(\.googleResourceName) == ["people/c1", "people/c2"])
        #expect(result.links.allSatisfy { $0.icloudID == "i1" })
    }

    @Test("Duplicates inside iCloud do not hide a connection's match")
    func icloudDuplicatesDoNotInterfere() {
        let result = plan(
            [icloud("i1", "Ann", "Lee", phones: ["415-555-2671"]), icloud("i2", "Ann", "Lee", phones: ["415-555-2671"])],
            [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"]), google("people/c2", "Bob", "Stone", phones: ["415-555-9999"])]
        )
        #expect(result.links.map(\.googleResourceName) == ["people/c1"])
        #expect(result.toImport.map(\.id) == ["people/c2"])
    }

    // MARK: other contacts

    @Test("Unmatched other contacts are candidates and are NOT selected by default")
    func otherContactsNotSelected() {
        let result = plan(
            [icloud("i1", "Ann", "Lee", phones: ["415-555-0001"])], [],
            [google("otherContacts/c1", "Cara", "Dune", emails: ["cara@example.com"], source: .googleOther)]
        )
        #expect(result.otherContactCandidates.map(\.id) == ["otherContacts/c1"])
        #expect(result.otherContactCandidates.allSatisfy { !$0.isSelected })
        #expect(result.otherContactCandidates[0].record.source == .googleOther)
        #expect(result.toImport.isEmpty)
    }

    @Test("An other contact already in iCloud is dropped, and creates no link")
    func otherContactInICloudIsDropped() {
        let result = plan(
            [icloud("i1", "Cara", "Dune", emails: ["cara@example.com"])], [],
            [google("otherContacts/c1", "Cara", "Dune", emails: ["cara@example.com"], source: .googleOther)]
        )
        #expect(result.otherContactCandidates.isEmpty)
        #expect(result.links.isEmpty)
    }

    @Test("An other contact that duplicates a connection is dropped, whether or not that connection is imported")
    func otherContactMatchingConnectionIsDropped() {
        let result = plan(
            [],
            [google("people/c1", "Cara", "Dune", emails: ["cara@example.com"])],
            [google("otherContacts/c1", "Cara", "Dune", emails: ["cara@example.com"], source: .googleOther)]
        )
        #expect(result.toImport.map(\.id) == ["people/c1"])
        #expect(result.otherContactCandidates.isEmpty)
    }

    @Test("A low-confidence other-contact pair is a possible match carrying the other-contact source")
    func otherContactPossibleMatch() throws {
        let result = plan(
            [icloud("i1", "John", "Smith", emails: ["family@example.com"])], [],
            [google("otherContacts/c1", "Jane", "Smith", emails: ["family@example.com"], source: .googleOther)]
        )
        #expect(result.otherContactCandidates.map(\.id) == ["otherContacts/c1"])
        let possible = try #require(result.possibleMatches.first)
        #expect(possible.googleSource == .googleOther && possible.googleID == "otherContacts/c1")
    }

    // MARK: robustness

    @Test("Empty input gives an empty plan")
    func emptyInput() {
        #expect(plan([]).isEmpty)
        let onlyICloud = plan([icloud("i1", "Ann", "Lee")])
        #expect(onlyICloud.isEmpty)
    }

    @Test("An empty iCloud book imports every connection")
    func emptyAddressBook() {
        let result = plan([], [google("people/c1", "A", "One"), google("people/c2", "B", "Two")])
        #expect(result.toImport.map(\.id) == ["people/c1", "people/c2"])
    }

    @Test("Google records with no data are not offered")
    func blankRecordsSkipped() {
        let blank = ContactRecord(id: "people/c9", source: .google, sourceIdentifier: "people/c9")
        let result = plan([], [blank, google("people/c1", "A", "One")])
        #expect(result.toImport.map(\.id) == ["people/c1"])
    }

    @Test("The plan does not depend on input order")
    func deterministic() {
        let icloudRecords = [
            icloud("i1", "Ann", "Lee", phones: ["415-555-2671"]), icloud("i2", "John", "Smith", emails: ["family@example.com"]),
            icloud("i3", "Zed", "Zero", phones: ["415-555-0003"]),
        ]
        let connections = [
            google("people/c1", "Ann", "Lee", phones: ["415-555-2671"]), google("people/c2", "Jane", "Smith", emails: ["family@example.com"]),
            google("people/c3", "Yan", "Young"), google("people/c4", "Bea", "Bright", phones: ["415-555-0004"]),
        ]
        let others = [
            google("otherContacts/c1", "Cara", "Dune", emails: ["cara@example.com"], source: .googleOther),
            google("otherContacts/c2", "Dan", "Dune", emails: ["dan@example.com"], source: .googleOther),
        ]
        let baseline = plan(icloudRecords, connections, others)
        #expect(!baseline.toImport.isEmpty && !baseline.links.isEmpty && !baseline.possibleMatches.isEmpty)
        for seed in 1...6 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let shuffled = plan(
                icloudRecords.shuffled(using: &generator), connections.shuffled(using: &generator), others.shuffled(using: &generator)
            )
            #expect(shuffled == baseline)
        }
        // Names, not ids, drive the display order.
        #expect(baseline.toImport.map(\.id) == ["people/c4", "people/c2", "people/c3"])
    }

    // MARK: Google shapes

    @Test("Plans from People API data skip deleted stubs and read names, phones and emails")
    func fromGooglePeople() async throws {
        var deleted = GooglePerson()
        deleted.metadata = GooglePersonMetadata(deleted: true)
        let client = FakeGoogleClient(
            people: [
                GooglePersonMapper.createPayload(for: google("x", "Ann", "Lee", phones: ["415-555-2671"])),
                GooglePersonMapper.createPayload(for: google("x", "Bob", "Stone", phones: ["415-555-0002"])),
                deleted,
            ],
            otherContacts: [GooglePersonMapper.createPayload(for: google("x", "Cara", "Dune", emails: ["cara@example.com"]))]
        )
        let result = planner.plan(
            icloud: [icloud("i1", "Ann", "Lee", phones: ["+14155552671"])],
            googleConnections: try await client.allConnections(),
            googleOtherContacts: try await client.allOtherContacts()
        )
        #expect(result.links.map(\.icloudID) == ["i1"])
        #expect(result.toImport.map(\.record.givenName) == ["Bob"])
        #expect(result.toImport[0].record.source == .google)
        #expect(result.toImport[0].googleResourceName.hasPrefix("people/"))
        #expect(result.otherContactCandidates.map(\.record.givenName) == ["Cara"])
        #expect(result.otherContactCandidates[0].record.source == .googleOther)
    }

    // MARK: known links

    @Test("A connection the app already imported is never offered again, even when nothing matches")
    func knownLinkIsAlreadyInICloud() throws {
        // The saved copy shares nothing with the Google contact, so only the link can say they belong together.
        let result = planner.plan(
            icloud: [icloud("i9", "", "")],
            connections: [google("people/c1", "Ann", "Lee", phones: ["415-555-2671"])],
            otherContacts: [],
            knownLinks: ["people/c1": "i9"]
        )
        #expect(result.toImport.isEmpty)
        let link = try #require(result.links.first)
        #expect(link.icloudID == "i9" && link.googleResourceName == "people/c1")
        #expect(link.reasons == ["imported by Contact Bridge"] && !link.isNameOnly)
    }

    @Test("A link whose iCloud contact is gone no longer hides the Google contact")
    func staleKnownLinkIsIgnored() {
        let result = planner.plan(
            icloud: [], connections: [google("people/c1", "Ann", "Lee")], otherContacts: [], knownLinks: ["people/c1": "gone"]
        )
        #expect(result.toImport.map(\.googleResourceName) == ["people/c1"])
        #expect(result.links.isEmpty)
    }
}
