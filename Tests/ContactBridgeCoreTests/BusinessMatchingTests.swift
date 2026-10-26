import Foundation
import Testing
@testable import ContactBridgeCore

/// Businesses (organization-only contacts) saved the same way on both sides link without asking; people never do on a name alone.
struct BusinessMatchingTests {
    private func business(
        _ id: String = "I1", org: String = "CVS Pharmacy", phones: [String] = [], emails: [String] = [], urls: [String] = [],
        nickname: String = ""
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: id, nickname: nickname, organization: org,
            phones: phones.map { Labeled(label: "other", value: $0) }, emails: emails.map { Labeled(label: "work", value: $0) },
            urls: urls.map { Labeled(label: "homepage", value: $0) }
        )
    }

    private func businessPerson(
        org: String = "CVS Pharmacy", phones: [String] = [], emails: [String] = [], urls: [String] = [], nickname: String? = nil,
        note: String? = nil
    ) -> GooglePerson {
        var person = GooglePerson(
            nicknames: nickname.map { [GoogleNickname(value: $0)] }, organizations: [GoogleOrganization(name: org)],
            phoneNumbers: phones.isEmpty ? nil : phones.map { GooglePhoneNumber(value: $0, type: "other") },
            emailAddresses: emails.isEmpty ? nil : emails.map { GoogleEmailAddress(value: $0, type: "work") },
            urls: urls.isEmpty ? nil : urls.map { GoogleUrl(value: $0, type: "homepage") }
        )
        if let note { person.extras["biographies"] = .array([.object(["value": .string(note), "contentType": .string("TEXT_PLAIN")])]) }
        return person
    }

    // MARK: import planner (identifier reasons)

    @Test("A shared company and short code is an identifier match: linked, with no import-anyway offer")
    func shortCodeIsAnIdentifier() throws {
        let result = ImportPlanner().plan(
            icloud: [business(phones: ["898287"])],
            connections: [ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", organization: "CVS Pharmacy", phones: [Labeled(label: "other", value: "898287")])],
            otherContacts: []
        )
        let link = try #require(result.links.first)
        #expect(result.links.count == 1 && result.toImport.isEmpty)
        #expect(link.reasons.contains { $0.hasPrefix("same company and short code") })
        #expect(!link.isNameOnly)
    }

    @Test("A shared website is an identifier match too")
    func websiteIsAnIdentifier() throws {
        func sam(_ id: String, source: ContactSource, site: String) -> ContactRecord {
            ContactRecord(id: id, source: source, sourceIdentifier: id, givenName: "Sam", urls: [Labeled(label: "homepage", value: site)])
        }
        let result = ImportPlanner().plan(
            icloud: [sam("i1", source: .icloud, site: "https://sam.example.com/")],
            connections: [sam("people/c1", source: .google, site: "http://www.sam.example.com")], otherContacts: []
        )
        let link = try #require(result.links.first)
        #expect(result.links.count == 1 && link.reasons == ["same website sam.example.com"] && !link.isNameOnly)
    }

    @Test("A name-only match still offers import anyway")
    func nameOnlyStillOffers() throws {
        let result = ImportPlanner().plan(
            icloud: [ContactRecord(id: "i1", source: .icloud, sourceIdentifier: "i1", givenName: "Ann", familyName: "Lee")],
            connections: [ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", givenName: "Ann", familyName: "Lee")],
            otherContacts: []
        )
        #expect(try #require(result.links.first).isNameOnly)
    }

    // MARK: sync matching pass

    private func plan(_ icloud: [ContactRecord], _ google: [GooglePerson], notes: [String: String] = [:]) async throws -> SyncPlan {
        try await SyncWorld(icloud: icloud, google: google, notes: notes).plan()
    }

    @Test("The same short-code sender saved on both sides links without a review")
    func shortCodeSender() async throws {
        let plan = try await plan([business(phones: ["898287"])], [businessPerson(phones: ["898287"])])
        #expect(plan.links.map(\.icloudID) == ["I1"] && plan.links.first?.origin == .matched)
        #expect(plan.review.isEmpty && plan.creates.isEmpty)
    }

    @Test("A different short code from the same company is not linked")
    func differentShortCode() async throws {
        let plan = try await plan([business(phones: ["898287"])], [businessPerson(phones: ["898288"])])
        #expect(plan.links.isEmpty)
    }

    @Test("Two people with the same name and nothing else are never linked on the name alone")
    func peopleStayPossible() async throws {
        let plan = try await plan(
            [ContactRecord(id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "John", familyName: "Smith")],
            [GooglePerson(names: [GoogleName(givenName: "John", familyName: "Smith")])]
        )
        #expect(plan.links.isEmpty && plan.creates.isEmpty && plan.review.map(\.id) == ["possibleLink|I1|people/c1"])
    }
}
