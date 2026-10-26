import Foundation
import Testing
@testable import ContactBridgeCore

/// When two existing contacts are first linked, only differences the user could choose between become a `bothEdited` item.
struct FirstLinkAgreementTests {
    private let street = "5020 N Hermitage Ave"

    private func ann(
        phones: [Labeled<String>] = [], emails: [Labeled<String>] = [], urls: [Labeled<String>] = [],
        addresses: [Labeled<PostalAddress>] = [], nickname: String = "", birthday: DateComponents? = nil
    ) -> ContactRecord {
        ContactRecord(
            id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "Ann", familyName: "Lee", nickname: nickname, phones: phones,
            emails: emails, postalAddresses: addresses, urls: urls, birthday: birthday
        )
    }

    private func person(
        phones: [(String, String?)] = [], emails: [(String, String?)] = [], urls: [(String, String?)] = [],
        addresses: [GoogleAddress] = [], nickname: String? = nil, birthday: GoogleDate? = nil, note: String? = nil
    ) -> GooglePerson {
        var person = GooglePerson(
            names: [GoogleName(givenName: "Ann", familyName: "Lee")],
            nicknames: nickname.map { [GoogleNickname(value: $0)] },
            phoneNumbers: phones.isEmpty ? nil : phones.map { GooglePhoneNumber(value: $0.0, type: $0.1) },
            emailAddresses: emails.isEmpty ? nil : emails.map { GoogleEmailAddress(value: $0.0, type: $0.1) },
            addresses: addresses.isEmpty ? nil : addresses,
            urls: urls.isEmpty ? nil : urls.map { GoogleUrl(value: $0.0, type: $0.1) },
            birthdays: birthday.map { [GoogleBirthday(date: $0)] }
        )
        if let note { person.extras["biographies"] = .array([.object(["value": .string(note), "contentType": .string("TEXT_PLAIN")])]) }
        return person
    }

    private func plan(_ icloud: ContactRecord, _ google: GooglePerson, note: String = "") async throws -> (SyncWorld, SyncPlan) {
        // A phone number in common keeps the pair a confident match whatever else differs.
        let world = SyncWorld(icloud: [icloud], google: [google], notes: note.isEmpty ? [:] : ["I1": note])
        return (world, try await world.plan())
    }

    private func anchoredICloud(
        phones: [Labeled<String>] = [], emails: [Labeled<String>] = [], urls: [Labeled<String>] = [],
        addresses: [Labeled<PostalAddress>] = [], nickname: String = "", birthday: DateComponents? = nil
    ) -> ContactRecord {
        ann(phones: [Labeled(label: "mobile", value: "415-555-2671")] + phones, emails: emails, urls: urls, addresses: addresses, nickname: nickname, birthday: birthday)
    }

    private func anchoredGoogle(
        phones: [(String, String?)] = [], emails: [(String, String?)] = [], urls: [(String, String?)] = [],
        addresses: [GoogleAddress] = [], nickname: String? = nil, birthday: GoogleDate? = nil, note: String? = nil
    ) -> GooglePerson {
        person(phones: [("415-555-2671", "mobile")] + phones, emails: emails, urls: urls, addresses: addresses, nickname: nickname, birthday: birthday, note: note)
    }

    /// What the review screen builds for a stored first-link item.
    private func draft(_ world: SyncWorld, _ plan: SyncPlan, note: String = "") throws -> SyncReviewDraft {
        let link = try #require(plan.links.first)
        let candidate = try #require(plan.review.first { $0.kind == .bothEdited })
        let person = try #require(world.lastFeed?.people[link.resourceName])
        return SyncReviewDraft(
            icloud: try #require(world.lastScan?.records.first), google: try #require(GooglePersonMapper.record(from: person, source: .google)),
            base: link.baseline, reviewFields: candidate.fields, icloudNote: note, googleNote: GooglePersonMapper.note(of: person)
        )
    }

    @Test("The same phone, email and website under different labels is not a conflict; each side keeps its own label")
    func labelsAlone() async throws {
        let (world, plan) = try await plan(
            ann(
                phones: [Labeled(label: "iPhone", value: "(415) 555-2671"), Labeled(label: nil, value: "415-555-0002")],
                emails: [Labeled(label: "home", value: "ann@example.com")], urls: [Labeled(label: "homepage", value: "https://ann.example.com")]
            ),
            person(
                phones: [("+1 415-555-2671", "mobile"), ("415-555-0002", "work")], emails: [("Ann@Example.com", nil)],
                urls: [("http://www.ann.example.com/", "work")]
            )
        )
        #expect(plan.links.count == 1)
        #expect(plan.review.isEmpty, "\(plan.review)")
        let link = try #require(plan.links.first)
        #expect(link.baseline.icloud.phones.first?.label == "iPhone" && link.baseline.google.phones.first?.label == "mobile")
        #expect(plan.updates.isEmpty)
        _ = world
    }

    @Test("The same address under a different label, with a line break instead of a comma and US for USA, is no conflict")
    func addressSpelling() async throws {
        let icloudAddress = PostalAddress(street: "\(street), Unit 3", city: "Chicago", state: "IL", postalCode: "60626", country: "USA")
        let google = GoogleAddress(
            type: nil, streetAddress: "\(street)\nUnit 3", city: "Chicago", region: "IL", postalCode: "60626", country: "US"
        )
        let (_, plan) = try await plan(anchoredICloud(addresses: [Labeled(label: "home", value: icloudAddress)]), anchoredGoogle(addresses: [google]))
        #expect(plan.links.count == 1 && plan.review.isEmpty, "\(plan.review)")
    }

    @Test("A genuinely different entry or value is still a conflict")
    func genuineDifferences() async throws {
        let other = GoogleAddress(type: "home", streetAddress: "1 Main St", city: "Austin", region: "TX", postalCode: "78701", country: "US")
        let (_, plan) = try await plan(
            anchoredICloud(
                phones: [Labeled(label: "home", value: "415-555-0002")], emails: [Labeled(label: nil, value: "a@example.com")], nickname: "Annie"
            ),
            anchoredGoogle(phones: [("415-555-0003", "home")], emails: [("b@example.com", nil)], addresses: [other])
        )
        #expect(plan.review.map(\.kind) == [.bothEdited])
        #expect(plan.review[0].fields == [.nickname, .phones, .emails, .postalAddresses])
    }

    /// Every `bothEdited` candidate `link()` produces must show the user something on the review screen: with the baseline the
    /// planner stores, a group that is not settled would otherwise read "The two sides agree now" and ask nothing.
    @Test("Any first-link conflict shows something to choose on the review screen")
    func conflictsAreChoosable() async throws {
        let cases: [(String, ContactRecord, GooglePerson, String)] = [
            ("different nickname", anchoredICloud(nickname: "Annie"), anchoredGoogle(nickname: "An"), ""),
            ("nickname only in Google", anchoredICloud(), anchoredGoogle(nickname: "An"), ""),
            ("birthday blank in iCloud", anchoredICloud(), anchoredGoogle(birthday: GoogleDate(year: 1994, month: 4, day: 6)), ""),
            (
                "different birthdays", anchoredICloud(birthday: DateComponents(year: 1994, month: 4, day: 6)),
                anchoredGoogle(birthday: GoogleDate(year: 1994, month: 4, day: 7)), ""
            ),
            ("extra Google phone", anchoredICloud(), anchoredGoogle(phones: [("415-555-0003", "home")]), ""),
            (
                "different emails", anchoredICloud(emails: [Labeled(label: nil, value: "a@example.com")]),
                anchoredGoogle(emails: [("b@example.com", nil)]), ""
            ),
            (
                "extra Google website", anchoredICloud(), anchoredGoogle(urls: [("https://ann.example.com", nil)]), ""
            ),
            (
                "different address", anchoredICloud(addresses: [Labeled(label: nil, value: PostalAddress(street: "1 A St", city: "Austin", country: "USA"))]),
                anchoredGoogle(addresses: [GoogleAddress(streetAddress: "2 B St", city: "Austin", country: "US")]), ""
            ),
            ("different note", anchoredICloud(), anchoredGoogle(note: "from Google"), "from iCloud"),
            ("note only in iCloud", anchoredICloud(), anchoredGoogle(), "from iCloud"),
        ]
        for (name, icloud, google, note) in cases {
            let (world, plan) = try await plan(icloud, google, note: note)
            #expect(plan.review.map(\.kind) == [.bothEdited], "\(name): \(plan.review)")
            let draft = try draft(world, plan, note: note)
            #expect(draft.hasChoices && !draft.isSettled, "\(name) shows nothing to choose")
        }
    }

    @Test("An entry only iCloud has is a conflict that is shown, though it needs no choice: saving sends it to Google")
    func iCloudOnlyEntry() async throws {
        let (world, plan) = try await plan(anchoredICloud(phones: [Labeled(label: "home", value: "415-555-0002")]), anchoredGoogle())
        #expect(plan.review.map(\.kind) == [.bothEdited])
        let draft = try draft(world, plan)
        #expect(!draft.isSettled)
        #expect(draft.lists.flatMap(\.rows).map(\.status) == [.both, .addedInICloud])
    }
}
