import Foundation
import Testing
@testable import ContactBridgeCore

struct MergePlanTests {
    private func record(
        _ id: String,
        given: String = "", middle: String = "", family: String = "", nickname: String = "",
        org: String = "", title: String = "",
        phones: [(String?, String)] = [], emails: [(String?, String)] = [],
        urls: [(String?, String)] = [], addresses: [(String?, PostalAddress)] = [],
        birthday: DateComponents? = nil
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: id.hasPrefix("g") ? .google : .icloud, sourceIdentifier: "S-\(id)",
            givenName: given, middleName: middle, familyName: family, nickname: nickname,
            organization: org, jobTitle: title,
            phones: phones.map { Labeled(label: $0.0, value: $0.1) },
            emails: emails.map { Labeled(label: $0.0, value: $0.1) },
            postalAddresses: addresses.map { Labeled(label: $0.0, value: $0.1) },
            urls: urls.map { Labeled(label: $0.0, value: $0.1) },
            birthday: birthday
        )
    }

    // MARK: structure

    @Test("Plan targets the survivor and lists the others for deletion in order")
    func identity() {
        let survivor = record("a", given: "Ann")
        let plan = MergePlan.build(survivor: survivor, others: [record("c"), record("b"), record("a"), record("c")])
        #expect(plan.survivorID == "a")
        #expect(plan.deleteIDs == ["c", "b"])
        #expect(plan.merged.id == "a")
        #expect(plan.merged.source == survivor.source)
        #expect(plan.merged.sourceIdentifier == "S-a")
    }

    // MARK: multi-value

    @Test("Phones union and dedupe by normalized value")
    func phonesUnion() {
        let plan = MergePlan.build(
            survivor: record("a", phones: [("mobile", "(415) 555-2671")]),
            others: [
                record("g1", phones: [("home", "+14155552671"), ("work", "212-555-3344")]),
                record("g2", phones: [(nil, "1 212 555 3344"), (nil, "415-555-9999")]),
            ]
        )
        #expect(plan.merged.phones.map(\.value) == ["(415) 555-2671", "212-555-3344", "415-555-9999"])
    }

    @Test("Survivor's label wins on collision; a missing label is filled from others")
    func labelPreference() {
        let plan = MergePlan.build(
            survivor: record("a", phones: [("mobile", "415-555-2671"), (nil, "212-555-3344")]),
            others: [record("g1", phones: [("home", "+14155552671"), ("work", "+12125553344")])]
        )
        #expect(plan.merged.phones == [
            Labeled(label: "mobile", value: "415-555-2671"),
            Labeled(label: "work", value: "212-555-3344"),
        ])
    }

    @Test("Phones with different extensions are distinct; unnormalizable ones dedupe on trimmed text")
    func phoneEdgeCases() {
        let plan = MergePlan.build(
            survivor: record("a", phones: [(nil, "415-555-2671 x1"), (nil, "555-1234")]),
            others: [record("g1", phones: [(nil, "415-555-2671 x2"), (nil, " 555-1234 "), (nil, "415-555-2671 ext 1")])]
        )
        #expect(plan.merged.phones.map(\.value) == ["415-555-2671 x1", "555-1234", "415-555-2671 x2"])
    }

    @Test("Emails dedupe case-insensitively and keep the first spelling")
    func emailsUnion() {
        let plan = MergePlan.build(
            survivor: record("a", emails: [("home", "Ann@Example.com")]),
            others: [record("g1", emails: [("work", " ann@example.COM "), ("work", "ann@work.com")])]
        )
        #expect(plan.merged.emails == [
            Labeled(label: "home", value: "Ann@Example.com"),
            Labeled(label: "work", value: "ann@work.com"),
        ])
    }

    @Test("URLs dedupe ignoring scheme, www, case and trailing slash")
    func urlsUnion() {
        let plan = MergePlan.build(
            survivor: record("a", urls: [("home", "https://www.Example.com/")]),
            others: [record("g1", urls: [(nil, "http://example.com"), (nil, "https://example.com/about")])]
        )
        #expect(plan.merged.urls.map(\.value) == ["https://www.Example.com/", "https://example.com/about"])
    }

    @Test("URL paths and queries are case-sensitive; only scheme and host fold")
    func urlPathCase() {
        let plan = MergePlan.build(
            survivor: record("a", urls: [(nil, "https://Example.com/About")]),
            others: [record("g1", urls: [
                (nil, "HTTP://WWW.EXAMPLE.COM/About/"),
                (nil, "https://example.com/about"),
                (nil, "https://example.com/?Q=1"),
                (nil, "https://example.com/?q=1"),
            ])]
        )
        #expect(plan.merged.urls.map(\.value) == [
            "https://Example.com/About", "https://example.com/about", "https://example.com/?Q=1", "https://example.com/?q=1",
        ])
    }

    @Test("Symbol-only address fields are never dropped, and still dedupe")
    func symbolAddress() {
        let hash = PostalAddress(street: "#")
        let plan = MergePlan.build(
            survivor: record("a", addresses: [("home", hash)]),
            others: [record("g1", addresses: [(nil, PostalAddress(street: "#")), (nil, PostalAddress(street: "?"))])]
        )
        #expect(plan.merged.postalAddresses.map(\.value) == [hash, PostalAddress(street: "?")])
    }

    @Test("Emoji and punctuation differences are conflicts, case and diacritics are not")
    func conflictKeyKeepsSymbols() {
        let rocket = MergePlan.build(
            survivor: record("a", org: "Acme"), others: [record("g1", org: "Acme \u{1F680}")]
        )
        #expect(rocket.conflicts.map(\.field) == [.organization])

        let punctuation = MergePlan.build(
            survivor: record("a", given: "O'Brien"), others: [record("g1", given: "OBrien")]
        )
        #expect(punctuation.conflicts.map(\.field) == [.givenName])

        let folded = MergePlan.build(
            survivor: record("a", given: "Jos\u{00E9}", org: " ACME  corp "), others: [record("g1", given: "JOSE", org: "acme corp")]
        )
        #expect(folded.conflicts.isEmpty)
    }

    @Test("Birthday candidates name the record that holds the displayed value, and picking yields it exactly")
    func birthdayPickKeepsYear() {
        let survivor = record("s", birthday: DateComponents(month: 3, day: 9))
        let a = record("a", birthday: DateComponents(year: 1990, month: 3, day: 9))
        let c = record("c", birthday: DateComponents(year: 1991, month: 3, day: 9))
        let plan = MergePlan.build(survivor: survivor, others: [a, c])
        #expect(plan.conflicts.map(\.field) == [.birthday])
        let candidates = plan.conflicts[0].candidates
        #expect(candidates.map(\.value) == ["1990-03-09", "1991-03-09"])
        #expect(candidates.map(\.recordID) == ["a", "c"])
        #expect(plan.conflicts[0].proposedRecordID == "a")
        #expect(plan.merged.birthday == a.birthday)

        for (id, expected) in [("a", a.birthday), ("c", c.birthday), ("s", survivor.birthday)] {
            let picked = MergePlan.build(survivor: survivor, others: [a, c], picks: [.birthday: id])
            #expect(picked.merged.birthday == expected)
            #expect(picked.conflicts.isEmpty)
        }
    }

    @Test("Discarded labels on collisions are recorded; filled or identical labels are not")
    func droppedLabels() {
        let plan = MergePlan.build(
            survivor: record("a", phones: [("mobile", "415-555-2671"), (nil, "212-555-3344")], emails: [("home", "a@x.com")]),
            others: [
                record("g1",
                       phones: [("home", "+14155552671"), ("work", "+12125553344")],
                       emails: [("HOME", "A@x.com"), ("work", "a@x.com")]),
                record("g2", phones: [("mobile", "4155552671"), (nil, "(415) 555-2671")]),
            ]
        )
        #expect(plan.merged.phones.map(\.label) == ["mobile", "work"])
        #expect(plan.droppedLabels == [
            DroppedLabel(field: .phones, value: "415-555-2671", keptLabel: "mobile", droppedLabel: "home"),
            DroppedLabel(field: .emails, value: "a@x.com", keptLabel: "home", droppedLabel: "work"),
        ])
        #expect(MergePlan.build(survivor: plan.merged, others: []).droppedLabels.isEmpty)
    }

    @Test("Addresses dedupe on folded fields and skip empty ones")
    func addressesUnion() {
        let home = PostalAddress(street: "1 Main St", city: "Austin", state: "TX", postalCode: "78701", country: "USA")
        let homeShouting = PostalAddress(street: "1 MAIN ST", city: "austin", state: "tx", postalCode: "78701", country: "usa")
        let work = PostalAddress(street: "9 Elm", city: "Austin", state: "TX", postalCode: "78702", country: "USA")
        let plan = MergePlan.build(
            survivor: record("a", addresses: [("home", home), (nil, PostalAddress())]),
            others: [record("g1", addresses: [("other", homeShouting), ("work", work)])]
        )
        #expect(plan.merged.postalAddresses == [Labeled(label: "home", value: home), Labeled(label: "work", value: work)])
    }

    @Test("Blank multi-value entries are dropped")
    func blanksDropped() {
        let plan = MergePlan.build(
            survivor: record("a", phones: [(nil, "  ")], emails: [(nil, "")], urls: [(nil, " ")]),
            others: []
        )
        #expect(plan.merged.phones.isEmpty && plan.merged.emails.isEmpty && plan.merged.urls.isEmpty)
    }

    // MARK: single-value

    @Test("Agreeing or one-sided single values merge without conflict")
    func noConflict() {
        let plan = MergePlan.build(
            survivor: record("a", given: "Ann", org: "Acme"),
            others: [record("g1", given: "ANN", family: "Lee", nickname: "Annie", org: "acme", title: "CTO")]
        )
        #expect(plan.conflicts.isEmpty)
        #expect(!plan.hasUnresolvedConflicts)
        #expect(plan.merged.givenName == "Ann")
        #expect(plan.merged.familyName == "Lee")
        #expect(plan.merged.organization == "Acme")
        #expect(plan.merged.jobTitle == "CTO")
        #expect(plan.merged.nickname == "Annie")
    }

    @Test("A blank survivor field is filled from the first other that has it")
    func fillsBlank() {
        let plan = MergePlan.build(
            survivor: record("a"),
            others: [record("g1", title: "CEO"), record("g2", title: "CTO")]
        )
        #expect(plan.merged.jobTitle == "CEO")
        #expect(plan.conflicts.map(\.field) == [.jobTitle])
    }

    @Test("Unresolved conflict is reported with the survivor's value proposed")
    func unresolvedConflict() {
        let plan = MergePlan.build(
            survivor: record("a", given: "Robert", org: "Acme"),
            others: [record("g1", given: "Bob", org: "Acme"), record("g2", given: "Bobby")]
        )
        #expect(plan.hasUnresolvedConflicts)
        #expect(plan.conflicts.count == 1)
        let conflict = plan.conflicts[0]
        #expect(conflict.field == .givenName)
        #expect(conflict.proposedRecordID == "a")
        #expect(conflict.candidates.map(\.value) == ["Robert", "Bob", "Bobby"])
        #expect(conflict.candidates.map(\.recordID) == ["a", "g1", "g2"])
        #expect(plan.merged.givenName == "Robert")
    }

    @Test("When the survivor is blank, the first non-blank candidate is proposed")
    func proposedFallback() {
        let plan = MergePlan.build(
            survivor: record("a"),
            others: [record("g1", family: "Lee"), record("g2", family: "Li")]
        )
        #expect(plan.conflicts[0].proposedRecordID == "g1")
        #expect(plan.merged.familyName == "Lee")
    }

    @Test("Explicit picks resolve conflicts and are applied")
    func picksApplied() {
        let plan = MergePlan.build(
            survivor: record("a", given: "Robert", title: "CTO"),
            others: [record("g1", given: "Bob", title: "CEO")],
            picks: [.givenName: "g1", .jobTitle: "a"]
        )
        #expect(plan.conflicts.isEmpty)
        #expect(!plan.hasUnresolvedConflicts)
        #expect(plan.merged.givenName == "Bob")
        #expect(plan.merged.jobTitle == "CTO")
    }

    @Test("A pick for one field leaves other conflicts unresolved")
    func partialPicks() {
        let plan = MergePlan.build(
            survivor: record("a", given: "Robert", org: "Acme"),
            others: [record("g1", given: "Bob", org: "Initech")],
            picks: [.givenName: "g1"]
        )
        #expect(plan.conflicts.map(\.field) == [.organization])
        #expect(plan.merged.givenName == "Bob")
        #expect(plan.merged.organization == "Acme")
    }

    @Test("Invalid picks are reported and ignored")
    func invalidPicks() {
        let plan = MergePlan.build(
            survivor: record("a", given: "Robert", family: "Smith"),
            others: [record("g1", given: "Bob")],
            picks: [.givenName: "nobody", .familyName: "g1"]
        )
        #expect(plan.invalidPicks == [.givenName, .familyName])
        #expect(plan.merged.givenName == "Robert")
        #expect(plan.merged.familyName == "Smith")
        #expect(plan.conflicts.map(\.field) == [.givenName])
    }

    @Test("Birthdays: year-less and full dates for the same day merge keeping the year")
    func birthdayCompatible() {
        let plan = MergePlan.build(
            survivor: record("a", birthday: DateComponents(month: 3, day: 9)),
            others: [record("g1", birthday: DateComponents(year: 1990, month: 3, day: 9))]
        )
        #expect(plan.conflicts.isEmpty)
        #expect(plan.merged.birthday == DateComponents(year: 1990, month: 3, day: 9))
    }

    @Test("Birthdays: different days conflict, with readable candidates, and picks apply")
    func birthdayConflict() {
        let survivor = record("a", birthday: DateComponents(year: 1990, month: 3, day: 9))
        let other = record("g1", birthday: DateComponents(month: 4, day: 1))
        let plan = MergePlan.build(survivor: survivor, others: [other])
        #expect(plan.conflicts.map(\.field) == [.birthday])
        #expect(plan.conflicts[0].candidates.map(\.value) == ["1990-03-09", "--04-01"])
        #expect(plan.merged.birthday == survivor.birthday)

        let picked = MergePlan.build(survivor: survivor, others: [other], picks: [.birthday: "g1"])
        #expect(picked.conflicts.isEmpty)
        #expect(picked.merged.birthday == DateComponents(month: 4, day: 1))
    }

    @Test("Birthday is taken from others when the survivor has none")
    func birthdayFill() {
        let plan = MergePlan.build(
            survivor: record("a"),
            others: [record("g1", birthday: DateComponents(year: 1990, month: 3, day: 9))]
        )
        #expect(plan.merged.birthday == DateComponents(year: 1990, month: 3, day: 9))
    }

    // MARK: empties and idempotence

    @Test("Merging empty records yields an empty record and no conflicts")
    func emptyFields() {
        let plan = MergePlan.build(survivor: record("a"), others: [record("g1"), record("g2")])
        #expect(plan.merged.isEmpty)
        #expect(plan.conflicts.isEmpty)
        #expect(plan.deleteIDs == ["g1", "g2"])
    }

    @Test("Merging a merged result with nothing changes nothing")
    func idempotent() {
        let first = MergePlan.build(
            survivor: record("a", given: "Ann", phones: [("mobile", "415-555-2671"), (nil, "415-555-2671")], emails: [("home", "a@x.com")]),
            others: [
                record("g1", given: "Annie", family: "Lee", phones: [("home", "+14155552671"), ("work", "212-555-3344")],
                       urls: [(nil, "https://example.com")], birthday: DateComponents(month: 3, day: 9)),
            ]
        )
        let again = MergePlan.build(survivor: first.merged, others: [])
        #expect(again.merged == first.merged)
        #expect(again.deleteIDs.isEmpty)
        #expect(again.isNoOp(for: first.merged))

        let third = MergePlan.build(survivor: again.merged, others: [])
        #expect(third.merged == first.merged)
    }

    @Test("Merging a duplicate-free record with nothing is a no-op")
    func noOp() {
        let survivor = record("a", given: "Ann", phones: [("mobile", "415-555-2671")], emails: [("home", "a@x.com")])
        let plan = MergePlan.build(survivor: survivor, others: [])
        #expect(plan.merged == survivor)
        #expect(plan.isNoOp(for: survivor))
        #expect(!MergePlan.build(survivor: survivor, others: [record("g1")]).isNoOp(for: survivor))
    }

    @Test("Inputs are never mutated")
    func pure() {
        let survivor = record("a", given: "Ann", phones: [("mobile", "415-555-2671")])
        let other = record("g1", given: "Bob", phones: [("home", "212-555-3344")])
        let copyS = survivor, copyO = other
        _ = MergePlan.build(survivor: survivor, others: [other], picks: [.givenName: "g1"])
        #expect(survivor == copyS && other == copyO)
    }
}
