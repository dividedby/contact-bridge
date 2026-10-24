import Foundation
import Testing
@testable import ContactBridgeCore

/// One multi-value list type, with helpers to write and read it on a record. Item `n` has a distinct normalized key.
struct ListKind: Sendable, CustomTestStringConvertible {
    typealias Item = (label: String?, n: Int)

    let field: SyncField
    let text: @Sendable (Int) -> String
    let write: @Sendable (inout ContactRecord, [Item]) -> Void
    /// "label|text" per entry, in record order.
    let read: @Sendable (ContactRecord) -> [String]

    var testDescription: String { field.rawValue }

    func expected(_ items: [Item]) -> [String] { items.map { "\($0.label ?? "-")|\(text($0.n))" } }

    static let phones = ListKind(
        field: .phones, text: { "(415) 555-01\(String(format: "%02d", $0))" },
        write: { record, items in
            record.phones = items.map { Labeled(label: $0.label, value: "(415) 555-01\(String(format: "%02d", $0.n))") }
        },
        read: { $0.phones.map { "\($0.label ?? "-")|\($0.value)" } }
    )
    static let emails = ListKind(
        field: .emails, text: { "p\($0)@example.com" },
        write: { record, items in record.emails = items.map { Labeled(label: $0.label, value: "p\($0.n)@example.com") } },
        read: { $0.emails.map { "\($0.label ?? "-")|\($0.value)" } }
    )
    static let urls = ListKind(
        field: .urls, text: { "https://site\($0).example.com" },
        write: { record, items in record.urls = items.map { Labeled(label: $0.label, value: "https://site\($0.n).example.com") } },
        read: { $0.urls.map { "\($0.label ?? "-")|\($0.value)" } }
    )
    static let addresses = ListKind(
        field: .postalAddresses, text: { "\($0) Main St" },
        write: { record, items in
            record.postalAddresses = items.map { Labeled(label: $0.label, value: PostalAddress(street: "\($0.n) Main St", city: "Town")) }
        },
        read: { $0.postalAddresses.map { "\($0.label ?? "-")|\($0.value.street)" } }
    )
    static let all = [phones, emails, urls, addresses]
}

struct ThreeWayDiffTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_800_003_600)

    private func icloudRecord() -> ContactRecord {
        ContactRecord(id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "Ann", familyName: "Lee")
    }

    private func googleRecord() -> ContactRecord {
        ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", givenName: "Ann", familyName: "Lee")
    }

    private func baseline(icloud: ContactRecord? = nil, google: ContactRecord? = nil, icloudNote: String? = nil, googleNote: String? = nil) -> SyncBaseline {
        SyncBaseline(
            icloud: icloud ?? icloudRecord(), google: google ?? googleRecord(), googleEtag: "etag-1",
            icloudNoteHash: icloudNote, googleNoteHash: googleNote, syncedAt: t0
        )
    }

    private func run(
        _ icloud: ContactRecord, _ google: ContactRecord, base: SyncBaseline, icloudNote: String? = nil, googleNote: String? = nil
    ) -> LinkDiff {
        ThreeWayDiff.diff(icloud: icloud, google: google, base: base, icloudNoteHash: icloudNote, googleNoteHash: googleNote, at: t1)
    }

    /// Builds the four records of a list scenario and diffs them. Items are `(label, n)`; label is "home" unless given.
    private func listDiff(
        _ kind: ListKind, baseICloud: [Int], baseGoogle: [Int], icloud: [Int], google: [Int], labels: [Int: String] = [:]
    ) -> LinkDiff {
        func items(_ ns: [Int]) -> [ListKind.Item] { ns.map { (label: labels[$0] ?? "home", n: $0) } }
        var bi = icloudRecord(), bg = googleRecord(), i = icloudRecord(), g = googleRecord()
        kind.write(&bi, items(baseICloud))
        kind.write(&bg, items(baseGoogle))
        kind.write(&i, items(icloud))
        kind.write(&g, items(google))
        return run(i, g, base: baseline(icloud: bi, google: bg))
    }

    private func home(_ ns: [Int], _ kind: ListKind) -> [String] { kind.expected(ns.map { (label: "home", n: $0) }) }

    // MARK: lists

    @Test("An entry added in iCloud is pushed to Google and both baselines take it", arguments: ListKind.all)
    func iCloudOnlyAdd(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1], icloud: [1, 2], google: [1])
        #expect(diff.changes[kind.field] == .pushToGoogle)
        #expect(diff.pushFields == [kind.field] && diff.reviewFields.isEmpty)
        #expect(kind.read(diff.desiredGoogle) == home([1, 2], kind))
        #expect(kind.read(diff.updatedBaseline.icloud) == home([1, 2], kind))
        #expect(kind.read(diff.updatedBaseline.google) == home([1, 2], kind))
        #expect(diff.updatedBaseline.syncedAt == t1)
    }

    @Test("An entry removed in iCloud is removed from Google", arguments: ListKind.all)
    func iCloudOnlyRemove(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1, 2], baseGoogle: [1, 2], icloud: [1], google: [1, 2])
        #expect(diff.changes[kind.field] == .pushToGoogle && diff.pushFields == [kind.field])
        #expect(kind.read(diff.desiredGoogle) == home([1], kind))
    }

    @Test("An entry added in Google alone is a review item: nothing is pushed and the baseline holds", arguments: ListKind.all)
    func googleOnlyAdd(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1], icloud: [1], google: [1, 2])
        #expect(diff.changes[kind.field] == .googleEdited)
        #expect(diff.pushFields.isEmpty && diff.reviewFields == [kind.field])
        #expect(kind.read(diff.updatedBaseline.icloud) == home([1], kind))
        #expect(kind.read(diff.updatedBaseline.google) == home([1], kind))
    }

    @Test("An entry removed in Google that iCloud also has is a review item", arguments: ListKind.all)
    func googleOnlyRemove(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1, 2], baseGoogle: [1, 2], icloud: [1, 2], google: [1])
        #expect(diff.changes[kind.field] == .googleEdited && diff.pushFields.isEmpty)
    }

    @Test("The same addition on both sides only moves the baselines", arguments: ListKind.all)
    func bothEqual(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1], icloud: [1, 2], google: [1, 2])
        #expect(diff.changes[kind.field] == .bothEditedEqual)
        #expect(diff.pushFields.isEmpty && diff.reviewFields.isEmpty)
        #expect(kind.read(diff.updatedBaseline.icloud) == home([1, 2], kind))
        #expect(kind.read(diff.updatedBaseline.google) == home([1, 2], kind))
    }

    @Test("Different additions on both sides are a review item and the baseline holds", arguments: ListKind.all)
    func bothDifferent(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1], icloud: [1, 2], google: [1, 3])
        #expect(diff.changes[kind.field] == .bothEditedDifferent)
        #expect(diff.pushFields.isEmpty && diff.reviewFields == [kind.field])
        #expect(kind.read(diff.updatedBaseline.icloud) == home([1], kind))
        #expect(kind.read(diff.updatedBaseline.google) == home([1], kind))
    }

    @Test("Google-only entries and Google's order survive an iCloud addition", arguments: ListKind.all)
    func googleOnlyPreservedOnAdd(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [9, 1], icloud: [1, 2], google: [9, 1])
        #expect(diff.changes[kind.field] == .pushToGoogle)
        #expect(kind.read(diff.desiredGoogle) == home([9, 1, 2], kind))
        #expect(kind.read(diff.updatedBaseline.icloud) == home([1, 2], kind))
        #expect(kind.read(diff.updatedBaseline.google) == home([9, 1, 2], kind))
    }

    @Test("Google-only entries survive an iCloud removal", arguments: ListKind.all)
    func googleOnlyPreservedOnRemove(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1, 9], icloud: [], google: [1, 9])
        #expect(diff.changes[kind.field] == .pushToGoogle)
        #expect(kind.read(diff.desiredGoogle) == home([9], kind))
    }

    @Test("Editing only Google-only entries moves only the Google baseline", arguments: ListKind.all)
    func googleOnlyChange(kind: ListKind) {
        let removed = listDiff(kind, baseICloud: [1], baseGoogle: [1, 9], icloud: [1], google: [1])
        #expect(removed.changes[kind.field] == .googleOnlyChange)
        #expect(removed.pushFields.isEmpty && removed.reviewFields.isEmpty)
        #expect(kind.read(removed.updatedBaseline.google) == home([1], kind))
        #expect(kind.read(removed.updatedBaseline.icloud) == home([1], kind))

        var bi = icloudRecord(), bg = googleRecord(), g = googleRecord()
        kind.write(&bi, [(label: "home", n: 1)])
        kind.write(&bg, [(label: "home", n: 1), (label: "home", n: 9)])
        kind.write(&g, [(label: "home", n: 1), (label: "work", n: 9)])
        let relabelled = run(bi, g, base: baseline(icloud: bi, google: bg))
        #expect(relabelled.changes[kind.field] == .googleOnlyChange && relabelled.pushFields.isEmpty)
        #expect(kind.read(relabelled.updatedBaseline.google) == kind.expected([(label: "home", n: 1), (label: "work", n: 9)]))
    }

    @Test("An iCloud edit next to a Google-only change pushes; a new Google entry beside it is reviewed", arguments: ListKind.all)
    func pushNextToGoogleOnlyChange(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1], baseGoogle: [1, 9], icloud: [1, 2], google: [1, 8])
        // 8 is new in Google (not Google-only at the baseline): that is an edit of the shared list.
        #expect(diff.changes[kind.field] == .bothEditedDifferent)

        let quiet = listDiff(kind, baseICloud: [1], baseGoogle: [1, 9], icloud: [1, 2], google: [1])
        #expect(quiet.changes[kind.field] == .pushToGoogle)
        #expect(kind.read(quiet.desiredGoogle) == home([1, 2], kind))
    }

    @Test("An iCloud label change relabels the Google entry and keeps its place", arguments: ListKind.all)
    func labelChange(kind: ListKind) {
        var bi = icloudRecord(), bg = googleRecord(), i = icloudRecord(), g = googleRecord()
        kind.write(&bi, [(label: "home", n: 1), (label: "home", n: 2)])
        kind.write(&bg, [(label: "home", n: 9), (label: "home", n: 1), (label: "home", n: 2)])
        kind.write(&i, [(label: "work", n: 1), (label: "home", n: 2)])
        kind.write(&g, [(label: "home", n: 9), (label: "home", n: 1), (label: "home", n: 2)])
        let diff = run(i, g, base: baseline(icloud: bi, google: bg))
        #expect(diff.changes[kind.field] == .pushToGoogle && diff.pushFields == [kind.field])
        #expect(kind.read(diff.desiredGoogle) == kind.expected([(label: "home", n: 9), (label: "work", n: 1), (label: "home", n: 2)]))
    }

    @Test("A label change in Google alone is a review item", arguments: ListKind.all)
    func googleLabelChange(kind: ListKind) {
        var bi = icloudRecord(), bg = googleRecord(), g = googleRecord()
        kind.write(&bi, [(label: "home", n: 1)])
        kind.write(&bg, [(label: "home", n: 1)])
        kind.write(&g, [(label: "work", n: 1)])
        let relabelled = run(bi, g, base: baseline(icloud: bi, google: bg))
        #expect(relabelled.changes[kind.field] == .googleEdited)
    }

    @Test("Our own write echoing back is a no-op", arguments: ListKind.all)
    func echo(kind: ListKind) {
        var bi = icloudRecord(), bg = googleRecord(), i = icloudRecord()
        kind.write(&bi, [(label: "home", n: 1)])
        kind.write(&bg, [(label: "home", n: 1)])
        kind.write(&i, [(label: "home", n: 1), (label: "work", n: 2)])
        let first = run(i, bg, base: baseline(icloud: bi, google: bg))
        #expect(first.needsPush)

        // Google returns what we sent; the baseline is the diff's updated one with that person's record.
        let echoed = run(i, first.desiredGoogle, base: first.updatedBaseline)
        #expect(echoed.changes.values.allSatisfy { $0 == .unchanged })
        #expect(!echoed.needsPush && !echoed.needsReview)
        #expect(echoed.desiredGoogle == first.desiredGoogle)
    }

    @Test("Reordering or reformatting a list is not a change", arguments: ListKind.all)
    func reorderIsNothing(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1, 2], baseGoogle: [1, 2], icloud: [2, 1], google: [2, 1])
        #expect(diff.changes[kind.field] == .unchanged)
        #expect(!diff.needsPush)
    }

    @Test("Removing every entry in iCloud empties the Google list, which the mask clears", arguments: ListKind.all)
    func pushEmptiesList(kind: ListKind) {
        let diff = listDiff(kind, baseICloud: [1, 2], baseGoogle: [1, 2], icloud: [], google: [1, 2])
        #expect(diff.changes[kind.field] == .pushToGoogle && diff.pushFields == [kind.field])
        #expect(kind.read(diff.desiredGoogle).isEmpty)

        var existing = person()
        existing.emailAddresses = [GoogleEmailAddress(value: "p1@example.com", type: "home")]
        existing.phoneNumbers = [GooglePhoneNumber(value: "(415) 555-0101", type: "home")]
        existing.urls = [GoogleUrl(value: "https://site1.example.com", type: "home")]
        existing.addresses = [GoogleAddress(type: "home", streetAddress: "1 Main St", city: "Town")]
        let payload = GooglePersonMapper.updatePayload(for: diff.desiredGoogle, existing: existing, restrictedTo: diff.pushFields)
        #expect(payload.updatePersonFields == kind.field.peopleAPIField)
        #expect(payload.person.phoneNumbers == nil && payload.person.emailAddresses == nil && payload.person.addresses == nil)
    }

    @Test("Adopting a Google-only entry in iCloud needs no write")
    func adoptGoogleOnly() {
        let diff = listDiff(.phones, baseICloud: [1], baseGoogle: [1, 2], icloud: [1, 2], google: [1, 2])
        #expect(diff.changes[.phones] == .pushToGoogle)
        #expect(diff.pushFields.isEmpty)
        #expect(ListKind.phones.read(diff.updatedBaseline.icloud) == home([1, 2], .phones))
    }

    @Test("A format-only edit in iCloud is copied as spelled; entries it did not touch keep Google's spelling")
    func exactEditsCopy() {
        var bi = icloudRecord(), bg = googleRecord()
        bi.phones = [Labeled(label: "mobile", value: "(415) 555-0100"), Labeled(label: "work", value: "(415) 555-0101")]
        bi.emails = [Labeled(label: nil, value: "Ann@Example.com")]
        bg.phones = [Labeled(label: "mobile", value: "+14155550100"), Labeled(label: "work", value: "+1 415-555-0101")]
        bg.emails = [Labeled(label: nil, value: "ann@example.com")]
        let base = baseline(icloud: bi, google: bg)
        #expect(run(bi, bg, base: base).changes.values.allSatisfy { $0 == .unchanged })

        var i = bi
        i.phones[0].value = "415-555-0100"
        i.emails[0].value = "Ann@example.com"
        let diff = run(i, bg, base: base)
        #expect(diff.changes[.phones] == .pushToGoogle && diff.changes[.emails] == .pushToGoogle)
        #expect(diff.pushFields == [.phones, .emails])
        #expect(diff.desiredGoogle.phones.map(\.value) == ["415-555-0100", "+1 415-555-0101"])
        #expect(diff.desiredGoogle.emails.map(\.value) == ["Ann@example.com"])
        #expect(diff.updatedBaseline.google.emails == diff.desiredGoogle.emails)
    }

    @Test("A label edited only in case is an edit")
    func labelCase() {
        var bi = icloudRecord(), bg = googleRecord()
        bi.phones = [Labeled(label: "Mobile", value: "(415) 555-0100")]
        bg.phones = [Labeled(label: "Mobile", value: "(415) 555-0100")]
        var i = bi
        i.phones[0].label = "mobile"
        let diff = run(i, bg, base: baseline(icloud: bi, google: bg))
        #expect(diff.changes[.phones] == .pushToGoogle && diff.desiredGoogle.phones.first?.label == "mobile")
    }

    @Test("Two list edits that agree after normalizing push iCloud's spelling without a review")
    func listBothEqualDifferentSpelling() {
        var bi = icloudRecord(), bg = googleRecord()
        bi.emails = [Labeled(label: "home", value: "a@example.com")]
        bg.emails = [Labeled(label: "home", value: "a@example.com")]
        var i = bi, g = bg
        i.emails.append(Labeled(label: "home", value: "New@Example.com"))
        g.emails.append(Labeled(label: "home", value: "new@example.com"))
        let diff = run(i, g, base: baseline(icloud: bi, google: bg))
        #expect(diff.changes[.emails] == .bothEditedEqual && diff.pushFields == [.emails] && !diff.needsReview)
        #expect(diff.desiredGoogle.emails.map(\.value) == ["a@example.com", "New@Example.com"])

        g.emails[1].value = "New@Example.com"
        #expect(!run(i, g, base: baseline(icloud: bi, google: bg)).needsPush)
    }

    @Test("A blank entry never counts as an entry")
    func blankEntries() {
        var i = icloudRecord()
        i.phones = [Labeled(label: "home", value: "  ")]
        #expect(run(i, googleRecord(), base: baseline()).changes[.phones] == .unchanged)
    }

    // MARK: single values

    @Test("A name edited in iCloud only is pushed with the name group")
    func nameICloudOnly() {
        var i = icloudRecord()
        i.givenName = "Anne"
        let diff = run(i, googleRecord(), base: baseline())
        #expect(diff.changes[.name] == .pushToGoogle && diff.pushFields == [.name])
        #expect(diff.desiredGoogle.givenName == "Anne" && diff.desiredGoogle.familyName == "Lee")
        #expect(diff.desiredGoogle.id == "people/c1" && diff.desiredGoogle.source == .google)
        #expect(diff.updatedBaseline.icloud.givenName == "Anne" && diff.updatedBaseline.google.givenName == "Anne")
        #expect(diff.changes.filter { $0.value != .unchanged }.count == 1)
    }

    @Test("A name edited in Google only is reviewed, not pushed")
    func nameGoogleOnly() {
        var g = googleRecord()
        g.givenName = "Anne"
        let diff = run(icloudRecord(), g, base: baseline())
        #expect(diff.changes[.name] == .googleEdited && diff.reviewFields == [.name] && diff.pushFields.isEmpty)
        #expect(diff.updatedBaseline.google.givenName == "Ann")
        #expect(diff.desiredGoogle.givenName == "Anne")
    }

    @Test("The same name edit on both sides only moves the baselines; different edits are reviewed")
    func nameBoth() {
        var i = icloudRecord(), g = googleRecord()
        i.givenName = "Anne"
        g.givenName = "Anne"
        let equal = run(i, g, base: baseline())
        #expect(equal.changes[.name] == .bothEditedEqual && !equal.needsPush && !equal.needsReview)
        #expect(equal.updatedBaseline.icloud.givenName == "Anne" && equal.updatedBaseline.google.givenName == "Anne")

        g.givenName = "Annie"
        let different = run(i, g, base: baseline())
        #expect(different.changes[.name] == .bothEditedDifferent && different.reviewFields == [.name])
        #expect(different.updatedBaseline.icloud.givenName == "Ann")
    }

    @Test("Both sides edit a name to the same thing in different spelling: iCloud's form is pushed, no review")
    func nameBothDifferentSpelling() {
        var i = icloudRecord(), g = googleRecord()
        i.givenName = "José"
        g.givenName = "JOSE"
        let diff = run(i, g, base: baseline())
        #expect(diff.changes[.name] == .bothEditedEqual && !diff.needsReview)
        #expect(diff.pushFields == [.name] && diff.desiredGoogle.givenName == "José")
        #expect(diff.updatedBaseline.google.givenName == "José" && diff.updatedBaseline.icloud.givenName == "José")
    }

    @Test("A case-only or accent-only edit in iCloud is pushed", arguments: [("Mcdonald", "McDonald"), ("Jose", "José"), ("ann", "Ann")])
    func caseAndAccentEdits(from: String, to: String) {
        var b = icloudRecord(), bg = googleRecord(), i = icloudRecord()
        b.familyName = from
        bg.familyName = from
        i.familyName = to
        let diff = run(i, bg, base: baseline(icloud: b, google: bg))
        #expect(diff.changes[.name] == .pushToGoogle && diff.pushFields == [.name])
        #expect(diff.desiredGoogle.familyName == to)
    }

    @Test("A case-only change in Google alone is a review item")
    func googleCaseChange() {
        var g = googleRecord()
        g.familyName = "LEE"
        let diff = run(icloudRecord(), g, base: baseline())
        #expect(diff.changes[.name] == .googleEdited && diff.pushFields.isEmpty && diff.reviewFields == [.name])
    }

    @Test("Surrounding whitespace alone is not an edit")
    func whitespaceOnly() {
        var i = icloudRecord()
        i.givenName = " Ann "
        i.familyName = "Lee\n"
        #expect(run(i, googleRecord(), base: baseline()).changes[.name] == .unchanged)
    }

    @Test("Organization and job title are one group; nickname and birthday are their own")
    func otherSingles() {
        var i = icloudRecord()
        i.jobTitle = "CEO"
        i.nickname = "Annie"
        i.birthday = DateComponents(year: 1990, month: 3, day: 9)
        let diff = run(i, googleRecord(), base: baseline())
        #expect(diff.pushFields == [.organization, .nickname, .birthday])
        #expect(diff.desiredGoogle.jobTitle == "CEO" && diff.desiredGoogle.nickname == "Annie")
        #expect(diff.desiredGoogle.birthday == DateComponents(year: 1990, month: 3, day: 9))
        #expect(diff.changes[.name] == .unchanged)
    }

    @Test("Adding a year to a year-less birthday is an edit")
    func birthdayYear() {
        var b = icloudRecord(), i = icloudRecord()
        b.birthday = DateComponents(month: 3, day: 9)
        i.birthday = DateComponents(year: 1990, month: 3, day: 9)
        var bg = googleRecord()
        bg.birthday = DateComponents(month: 3, day: 9)
        let diff = run(i, bg, base: baseline(icloud: b, google: bg))
        #expect(diff.changes[.birthday] == .pushToGoogle)
    }

    @Test("Clearing a single value in iCloud clears it in Google")
    func clearing() {
        var b = icloudRecord(), bg = googleRecord()
        b.nickname = "Annie"
        bg.nickname = "Annie"
        let diff = run(icloudRecord(), bg, base: baseline(icloud: b, google: bg))
        #expect(diff.changes[.nickname] == .pushToGoogle && diff.desiredGoogle.nickname == "")
    }

    @Test("A review field is held back while other iCloud edits still push with a narrow mask")
    func mixedFields() throws {
        var i = icloudRecord(), g = googleRecord()
        i.phones = [Labeled(label: "mobile", value: "(415) 555-0100")]
        g.givenName = "Anne"
        let diff = run(i, g, base: baseline())
        #expect(diff.changes[.phones] == .pushToGoogle && diff.changes[.name] == .googleEdited)
        #expect(diff.pushFields == [.phones] && diff.reviewFields == [.name])
        #expect(diff.updatedBaseline.icloud.phones.count == 1 && diff.updatedBaseline.google.phones.count == 1)
        #expect(diff.updatedBaseline.google.givenName == "Ann")
        #expect(SyncField.updateMask(for: diff.pushFields) == "phoneNumbers")
    }

    @Test("The baseline takes the listed etag only when one is given")
    func etag() {
        #expect(run(icloudRecord(), googleRecord(), base: baseline()).updatedBaseline.googleEtag == "etag-1")
        let diff = ThreeWayDiff.diff(icloud: icloudRecord(), google: googleRecord(), base: baseline(), googleEtag: "etag-2", at: t1)
        #expect(diff.updatedBaseline.googleEtag == "etag-2")
    }

    @Test("Nothing changed means nothing to do")
    func quiet() {
        let diff = run(icloudRecord(), googleRecord(), base: baseline())
        #expect(diff.changes.count == SyncField.allCases.count)
        #expect(diff.changes.values.allSatisfy { $0 == .unchanged })
        #expect(!diff.needsPush && !diff.needsReview)
        #expect(diff.desiredGoogle == googleRecord())
    }

    // MARK: notes

    struct NoteCase: Sendable, CustomTestStringConvertible {
        var icloud: String?, google: String?, baseICloud: String?, baseGoogle: String?
        var change: FieldChange
        var pushes: Bool
        var testDescription: String { "\(icloud ?? "nil")/\(google ?? "nil") vs \(baseICloud ?? "nil")/\(baseGoogle ?? "nil") -> \(change)" }
    }

    @Test("Notes compare through hashes; a note is only compared when all four hashes are known", arguments: [
        NoteCase(icloud: "a", google: "a", baseICloud: "a", baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: nil, google: "a", baseICloud: "a", baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: "a", baseICloud: nil, baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: nil, google: nil, baseICloud: "a", baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: "a", baseICloud: "a", baseGoogle: "a", change: .pushToGoogle, pushes: true),
        NoteCase(icloud: "b", google: "b", baseICloud: "a", baseGoogle: "b", change: .pushToGoogle, pushes: false),
        NoteCase(icloud: "a", google: "b", baseICloud: "a", baseGoogle: "a", change: .googleEdited, pushes: false),
        NoteCase(icloud: nil, google: "b", baseICloud: "a", baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: nil, baseICloud: "a", baseGoogle: "a", change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: "a", baseICloud: "a", baseGoogle: nil, change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: nil, baseICloud: "a", baseGoogle: nil, change: .unchanged, pushes: false),
        NoteCase(icloud: "b", google: "b", baseICloud: "a", baseGoogle: "a", change: .bothEditedEqual, pushes: false),
        NoteCase(icloud: "b", google: "c", baseICloud: "a", baseGoogle: "a", change: .bothEditedDifferent, pushes: false),
    ])
    func notes(_ c: NoteCase) {
        let diff = run(
            icloudRecord(), googleRecord(), base: baseline(icloudNote: c.baseICloud, googleNote: c.baseGoogle),
            icloudNote: c.icloud, googleNote: c.google
        )
        #expect(diff.changes[.note] == c.change)
        #expect(diff.pushFields.contains(.note) == c.pushes)
        #expect(diff.reviewFields.contains(.note) == c.change.needsReview)
    }

    @Test("Clearing a note in iCloud pushes a clear; an unread note never does")
    func clearedNote() {
        let empty = NoteHash.hash("")
        let base = baseline(icloudNote: NoteHash.hash("hello"), googleNote: NoteHash.hash("hello"))

        let cleared = run(icloudRecord(), googleRecord(), base: base, icloudNote: empty, googleNote: NoteHash.hash("hello"))
        #expect(cleared.changes[.note] == .pushToGoogle && cleared.pushFields == [.note])
        #expect(cleared.updatedBaseline.icloudNoteHash == empty && cleared.updatedBaseline.googleNoteHash == empty)

        let unread = run(icloudRecord(), googleRecord(), base: base, icloudNote: nil, googleNote: NoteHash.hash("hello"))
        #expect(unread.changes[.note] == .unchanged && !unread.pushFields.contains(.note))
        #expect(unread.updatedBaseline.icloudNoteHash == NoteHash.hash("hello"))

        let googleCleared = run(icloudRecord(), googleRecord(), base: base, icloudNote: NoteHash.hash("hello"), googleNote: empty)
        #expect(googleCleared.changes[.note] == .googleEdited && googleCleared.pushFields.isEmpty)

        let bothCleared = run(icloudRecord(), googleRecord(), base: base, icloudNote: empty, googleNote: empty)
        #expect(bothCleared.changes[.note] == .bothEditedEqual && !bothCleared.needsPush && !bothCleared.needsReview)
        #expect(bothCleared.updatedBaseline.icloudNoteHash == empty && bothCleared.updatedBaseline.googleNoteHash == empty)
    }

    @Test("Note hashes in the baseline advance with the sync, stay when any hash is unknown, and hold under review")
    func noteBaseline() {
        let pushed = run(icloudRecord(), googleRecord(), base: baseline(icloudNote: "a", googleNote: "a"), icloudNote: "b", googleNote: "a")
        #expect(pushed.updatedBaseline.icloudNoteHash == "b" && pushed.updatedBaseline.googleNoteHash == "b")

        let unknown = run(icloudRecord(), googleRecord(), base: baseline(icloudNote: "a", googleNote: "a"))
        #expect(unknown.updatedBaseline.icloudNoteHash == "a" && unknown.updatedBaseline.googleNoteHash == "a")

        let unseeded = run(icloudRecord(), googleRecord(), base: baseline(), icloudNote: "x", googleNote: "y")
        #expect(unseeded.changes[.note] == .unchanged)
        #expect(unseeded.updatedBaseline.icloudNoteHash == nil && unseeded.updatedBaseline.googleNoteHash == nil)

        let halfKnown = run(icloudRecord(), googleRecord(), base: baseline(icloudNote: "a", googleNote: "a"), icloudNote: "b")
        #expect(halfKnown.updatedBaseline.icloudNoteHash == "a" && halfKnown.updatedBaseline.googleNoteHash == "a")

        let held = run(icloudRecord(), googleRecord(), base: baseline(icloudNote: "a", googleNote: "a"), icloudNote: "b", googleNote: "c")
        #expect(held.updatedBaseline.icloudNoteHash == "a" && held.updatedBaseline.googleNoteHash == "a")
    }

    // MARK: mapper restrictedTo

    private func person() -> GooglePerson {
        GooglePerson(
            resourceName: "people/c1", etag: "etag-1",
            names: [GoogleName(givenName: "Ann", familyName: "Lee")],
            phoneNumbers: [GooglePhoneNumber(value: "(415) 555-0109", type: "mobile")],
            emailAddresses: [GoogleEmailAddress(value: "ann@example.com", type: "home")],
            birthdays: [GoogleBirthday(text: "March")]
        )
    }

    @Test("A restricted update carries and masks only the requested groups, in declaration order")
    func restrictedMask() throws {
        let existing = person()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.givenName = "Anne"
        record.phones.append(Labeled(label: "work", value: "(415) 555-0100"))
        record.emails = []

        let phones = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.phones])
        #expect(phones.updatePersonFields == "phoneNumbers")
        #expect(phones.person.phoneNumbers?.count == 2)
        #expect(phones.person.names == nil && phones.person.emailAddresses == nil)
        #expect(phones.person.etag == "etag-1" && phones.resourceName == "people/c1")

        let several = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.emails, .name])
        #expect(several.updatePersonFields == "names,emailAddresses")
        #expect(several.person.names?.first?.givenName == "Anne")
        #expect(several.person.emailAddresses == nil && several.person.phoneNumbers == nil)
    }

    @Test("Restricting to every group equals the unrestricted update")
    func restrictedAll() throws {
        let existing = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        let record = try #require(GooglePersonMapper.record(from: existing))
        let full = GooglePersonMapper.updatePayload(for: record, existing: existing)
        let all = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: Set(SyncField.allCases))
        #expect(all == full)
    }

    @Test("A text-only Google birthday stays out of the mask unless the record has a date")
    func restrictedBirthday() throws {
        let existing = person()
        let record = try #require(GooglePersonMapper.record(from: existing))
        #expect(GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.birthday]).updatePersonFields == "")
        var dated = record
        dated.birthday = DateComponents(month: 3, day: 9)
        let payload = GooglePersonMapper.updatePayload(for: dated, existing: existing, restrictedTo: [.birthday])
        #expect(payload.updatePersonFields == "birthdays" && payload.person.birthdays?.first?.date == GoogleDate(month: 3, day: 9))
    }

    @Test("clientData joins the mask only when the ownership tag is missing")
    func restrictedOwnership() throws {
        var existing = person()
        let record = try #require(GooglePersonMapper.record(from: existing))
        let tagged = GooglePersonMapper.updatePayload(for: record, existing: existing, ownershipSourceID: "I1", restrictedTo: [.phones])
        #expect(tagged.updatePersonFields == "phoneNumbers,clientData")
        #expect(GoogleOwnership.sourceID(of: tagged.person) == "I1")

        GoogleOwnership.setSourceID("I1", on: &existing)
        let already = GooglePersonMapper.updatePayload(for: record, existing: existing, ownershipSourceID: "I1", restrictedTo: [.phones])
        #expect(already.updatePersonFields == "phoneNumbers" && already.person.clientData == nil)
        let none = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.phones])
        #expect(none.updatePersonFields == "phoneNumbers")
    }

    @Test("A note is sent as biographies only when requested and known; a known blank note clears it")
    func restrictedNote() throws {
        let existing = person()
        let record = try #require(GooglePersonMapper.record(from: existing))
        let sent = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.note], note: "Met at the fair")
        #expect(sent.updatePersonFields == "biographies")
        let json = String(decoding: try JSONEncoder().encode(sent.person), as: UTF8.self)
        #expect(json.contains("Met at the fair") && json.contains("TEXT_PLAIN"))

        let unknown = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.note, .phones], note: nil)
        #expect(unknown.updatePersonFields == "phoneNumbers" && unknown.person.extras.isEmpty)

        for note in ["", "  \n"] {
            let cleared = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.note], note: note)
            #expect(cleared.updatePersonFields == "biographies" && cleared.person.extras.isEmpty)
        }
        let unrequested = GooglePersonMapper.updatePayload(for: record, existing: existing, restrictedTo: [.phones], note: "x")
        #expect(unrequested.updatePersonFields == "phoneNumbers")
    }

    @Test("A diff's desired record turns into a narrow payload that keeps Google-only entries first")
    func diffToPayload() throws {
        var existing = person()
        existing.phoneNumbers = [
            GooglePhoneNumber(value: "(415) 555-0109", type: "mobile"), GooglePhoneNumber(value: "(415) 555-0101", type: "home"),
        ]
        let google = try #require(GooglePersonMapper.record(from: existing))
        var bi = icloudRecord()
        bi.phones = [Labeled(label: "home", value: "(415) 555-0101")]
        var i = bi
        i.phones.append(Labeled(label: "work", value: "(415) 555-0102"))
        var bg = google
        bg.phones = google.phones
        let diff = run(i, google, base: baseline(icloud: bi, google: bg))
        #expect(diff.pushFields == [.phones])

        let payload = GooglePersonMapper.updatePayload(for: diff.desiredGoogle, existing: existing, restrictedTo: diff.pushFields)
        #expect(payload.updatePersonFields == "phoneNumbers")
        #expect(payload.person.phoneNumbers?.map(\.value) == ["(415) 555-0109", "(415) 555-0101", "(415) 555-0102"])
        #expect(payload.person.phoneNumbers?.map(\.type) == ["mobile", "home", "work"])
    }

    @Test("Update masks list the requested groups in declaration order")
    func updateMask() {
        #expect(SyncField.updateMask(for: [.note, .name, .urls]) == "names,urls,biographies")
        #expect(SyncField.updateMask(for: []) == "")
        #expect(SyncField.recordFields.count == SyncField.allCases.count - 1)
    }
}
