import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncReviewDraftTests {
    private let t0 = SyncFixtures.t0

    private func icloud(
        org: String = "", nickname: String = "", phones: [(String?, String)] = [], emails: [(String?, String)] = []
    ) -> ContactRecord {
        ContactRecord(
            id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "Leo", familyName: "Fischer", nickname: nickname, organization: org,
            phones: phones.map { Labeled(label: $0.0, value: $0.1) }, emails: emails.map { Labeled(label: $0.0, value: $0.1) }
        )
    }

    private func google(
        org: String = "", nickname: String = "", phones: [(String?, String)] = [], emails: [(String?, String)] = []
    ) -> ContactRecord {
        var record = icloud(org: org, nickname: nickname, phones: phones, emails: emails)
        record.id = "people/c1"
        record.source = .google
        record.sourceIdentifier = "people/c1"
        return record
    }

    private func baseline(_ icloud: ContactRecord, _ google: ContactRecord, notes: (String, String)? = nil) -> SyncBaseline {
        SyncBaseline(
            icloud: icloud, google: google, googleEtag: "e1", icloudNoteHash: NoteHash.hash(notes?.0 ?? ""),
            googleNoteHash: NoteHash.hash(notes?.1 ?? ""), syncedAt: t0
        )
    }

    private func row(_ draft: SyncReviewDraft, containing text: String) throws -> SyncReviewDraft.EntryRow {
        try #require(draft.lists.flatMap(\.rows).first { ($0.icloudText ?? $0.googleText ?? "").contains(text) })
    }

    private func numbers(_ list: [Labeled<String>]) -> [String] { list.map { "\($0.label ?? "-")|\($0.value)" } }

    // MARK: single-value groups

    @Test("A group only Google edited defaults to Google; picking iCloud keeps iCloud's value on both sides")
    func googleEditedDefault() throws {
        let base = icloud(org: "Acme")
        var draft = SyncReviewDraft(
            icloud: base, google: google(org: "Fischer Design"), base: baseline(base, google(org: "Acme")), reviewFields: [.organization]
        )
        let row = try #require(draft.singleRows.first { $0.field == .organization })
        #expect(row.needsChoice && row.pick == .google && row.icloudText == "Acme" && row.googleText == "Fischer Design")

        let resolved = draft.resolve()
        #expect(resolved.icloud.organization == "Fischer Design" && resolved.google.organization == "Fischer Design")
        #expect(resolved.changesICloud && !resolved.changesGoogle)

        draft.pick(.organization, .icloud)
        let kept = draft.resolve()
        #expect(kept.icloud.organization == "Acme" && kept.google.organization == "Acme")
        #expect(!kept.changesICloud && kept.changesGoogle)
    }

    @Test("A group both sides edited to different results defaults to iCloud")
    func bothEditedDefault() throws {
        let base = icloud(org: "Acme")
        var draft = SyncReviewDraft(
            icloud: icloud(org: "Brown & Co"), google: google(org: "Brown Consulting"), base: baseline(base, google(org: "Acme")),
            reviewFields: [.organization]
        )
        #expect(draft.singleRows.first { $0.field == .organization }?.pick == .icloud)
        #expect(draft.resolve().google.organization == "Brown & Co")
        draft.pick(.organization, .google)
        let resolved = draft.resolve()
        #expect(resolved.icloud.organization == "Brown Consulting" && resolved.google.organization == "Brown Consulting")
    }

    @Test("A group that is not under review keeps what the next sync would do: iCloud's edit still goes to Google")
    func otherEditsStillFlow() throws {
        let base = icloud(org: "Acme")
        let draft = SyncReviewDraft(
            icloud: icloud(org: "Acme", nickname: "Lio"), google: google(org: "Fischer Design"),
            base: baseline(base, google(org: "Acme")), reviewFields: [.organization]
        )
        let row = try #require(draft.singleRows.first { $0.field == .nickname })
        #expect(!row.needsChoice)
        let resolved = draft.resolve()
        #expect(resolved.google.nickname == "Lio" && resolved.icloud.nickname == "Lio")
        #expect(resolved.icloud.organization == "Fischer Design")
    }

    // MARK: list entries

    /// Eight phones, one per status.
    private func phoneScenario() -> (icloud: ContactRecord, google: ContactRecord, base: SyncBaseline) {
        let both = ("mobile", "415-555-0001"), removedInGoogle = ("home", "415-555-0002"), googleOnly = ("work", "415-555-0003")
        let addedInGoogle = ("other", "415-555-0004"), changedInGoogle = ("mobile", "415-555-0005"), changedInICloud = ("home", "415-555-0006")
        let addedInICloud = ("main", "415-555-0007"), removedInICloud = ("fax", "415-555-0008")

        let baseICloud = icloud(phones: [both, removedInGoogle, ("mobile", changedInGoogle.1), ("home", changedInICloud.1), removedInICloud])
        let baseGoogle = google(
            phones: [both, removedInGoogle, googleOnly, ("mobile", changedInGoogle.1), ("home", changedInICloud.1), removedInICloud]
        )
        let nowICloud = icloud(phones: [both, removedInGoogle, ("mobile", changedInGoogle.1), ("work", changedInICloud.1), addedInICloud])
        let nowGoogle = google(
            phones: [both, googleOnly, addedInGoogle, ("work", changedInGoogle.1), ("home", changedInICloud.1), removedInICloud]
        )
        return (nowICloud, nowGoogle, baseline(baseICloud, baseGoogle))
    }

    @Test("Every list entry gets the status and the choices that fit what happened to it")
    func entryStatuses() throws {
        let (i, g, base) = phoneScenario()
        let draft = SyncReviewDraft(icloud: i, google: g, base: base, reviewFields: [.phones])
        typealias Status = SyncReviewDraft.EntryStatus
        typealias Action = SyncReviewDraft.EntryAction

        let expected: [(String, Status, Action, [Action])] = [
            ("0001", .both, .keep, [.keep]),
            ("0002", .removedInGoogle, .removeFromICloud, [.removeFromICloud, .keepInICloud]),
            ("0003", .googleOnly, .keepInGoogleOnly, [.keepInGoogleOnly, .addToICloud, .removeFromGoogle]),
            ("0004", .addedInGoogle, .addToICloud, [.addToICloud, .keepInGoogleOnly, .removeFromGoogle]),
            ("0005", .changedInGoogle, .useGoogle, [.useGoogle, .useICloud]),
            ("0006", .changedInICloud, .useICloud, [.useICloud, .useGoogle]),
            ("0007", .addedInICloud, .keep, [.keep]),
            ("0008", .removedInICloud, .removeFromGoogle, [.removeFromGoogle, .addToICloud]),
        ]
        for (number, status, action, actions) in expected {
            let found = try row(draft, containing: number)
            #expect(found.status == status, "\(number)")
            #expect(found.action == action, "\(number)")
            #expect(found.actions == actions, "\(number)")
        }
        #expect(draft.lists.count == 1 && draft.lists[0].rows.count == 8)
        #expect(draft.lists[0].rows.filter(\.needsChoice).count == 6, "only the two settled entries need no decision")
    }

    @Test("With the defaults, a removal in Google is followed in iCloud, Google-only entries stay Google-only and Google's additions come over")
    func defaultResolution() throws {
        let (i, g, base) = phoneScenario()
        let resolved = SyncReviewDraft(icloud: i, google: g, base: base, reviewFields: [.phones]).resolve()
        #expect(numbers(resolved.icloud.phones) == [
            "mobile|415-555-0001", "work|415-555-0005", "work|415-555-0006", "main|415-555-0007", "other|415-555-0004",
        ])
        #expect(!resolved.icloud.phones.contains { $0.value == "415-555-0002" }, "Google's removal was applied to iCloud")
        #expect(!resolved.icloud.phones.contains { $0.value == "415-555-0003" }, "a Google-only phone is not copied to iCloud")
        #expect(resolved.google.phones.contains { $0.value == "415-555-0003" }, "and stays in Google")
        #expect(!resolved.google.phones.contains { $0.value == "415-555-0008" }, "iCloud's removal reaches Google")
        #expect(resolved.google.phones.contains { $0.value == "415-555-0007" }, "iCloud's addition reaches Google")
        #expect(resolved.google.phones.first { $0.value == "415-555-0006" }?.label == "work", "iCloud's relabel reaches Google")
        #expect(resolved.icloud.phones.first { $0.value == "415-555-0005" }?.label == "work", "Google's relabel reaches iCloud")
        #expect(!resolved.google.phones.contains { $0.value == "415-555-0002" }, "the removal in Google is not silently undone")
    }

    @Test("A removal in Google is reviewable: keeping the phone in iCloud puts it back in Google")
    func removalIsReviewable() throws {
        let (i, g, base) = phoneScenario()
        var draft = SyncReviewDraft(icloud: i, google: g, base: base, reviewFields: [.phones])
        let removed = try row(draft, containing: "0002")
        draft.setAction(.keepInICloud, forEntry: removed.id)
        let resolved = draft.resolve()
        #expect(resolved.icloud.phones.contains { $0.value == "415-555-0002" })
        #expect(resolved.google.phones.contains { $0.value == "415-555-0002" })

        // A choice the row does not offer is ignored.
        draft.setAction(.removeFromGoogle, forEntry: removed.id)
        #expect(try row(draft, containing: "0002").action == .keepInICloud)
    }

    @Test("A removal in Google defaults to keeping the phone when iCloud edited it too")
    func removalOfEditedEntry() throws {
        let base = baseline(icloud(phones: [("home", "415-555-0002")]), google(phones: [("home", "415-555-0002")]))
        let draft = SyncReviewDraft(icloud: icloud(phones: [("work", "415-555-0002")]), google: google(), base: base, reviewFields: [.phones])
        #expect(try row(draft, containing: "0002").action == .keepInICloud)
    }

    @Test("Each Google-only choice lands where it says")
    func googleOnlyChoices() throws {
        let base = baseline(icloud(), google(emails: [("work", "leo@work.example")]))
        let now = google(emails: [("work", "leo@work.example")])
        var draft = SyncReviewDraft(icloud: icloud(), google: now, base: base, reviewFields: [.emails])
        let entry = try #require(draft.lists.first?.rows.first)
        #expect(entry.status == .googleOnly)

        draft.setAction(.addToICloud, forEntry: entry.id)
        var resolved = draft.resolve()
        #expect(resolved.icloud.emails.map(\.value) == ["leo@work.example"] && resolved.google.emails.map(\.value) == ["leo@work.example"])

        draft.setAction(.removeFromGoogle, forEntry: entry.id)
        resolved = draft.resolve()
        #expect(resolved.icloud.emails.isEmpty && resolved.google.emails.isEmpty && resolved.changesGoogle && !resolved.changesICloud)

        draft.setAction(.keepInGoogleOnly, forEntry: entry.id)
        resolved = draft.resolve()
        #expect(resolved.icloud.emails.isEmpty && resolved.google.emails.map(\.value) == ["leo@work.example"] && !resolved.changesGoogle)
    }

    @Test("Entries are paired by their normalized key, so a phone spelled differently is the same entry")
    func pairedByKey() throws {
        let base = baseline(icloud(phones: [("mobile", "415-555-0001")]), google(phones: [("mobile", "+1 415 555 0001")]))
        let draft = SyncReviewDraft(
            icloud: icloud(phones: [("mobile", "415-555-0001")]), google: google(phones: [("mobile", "+1 415 555 0001")]),
            base: base, reviewFields: [.phones]
        )
        let rows = try #require(draft.lists.first?.rows)
        #expect(rows.count == 1 && rows[0].status == .both)
        #expect(draft.isSettled)
    }

    @Test("Keep iCloud everywhere: iCloud's values win, Google-only entries stay, nothing in iCloud changes")
    func keepICloudEverywhere() throws {
        let (i, g, base) = phoneScenario()
        var draft = SyncReviewDraft(icloud: i, google: g, base: base, reviewFields: [.phones, .organization])
        draft.chooseICloudEverywhere()
        let resolved = draft.resolve()
        #expect(!resolved.changesICloud)
        #expect(resolved.icloud == i)
        // iCloud's phones are Google's phones, plus the Google-only one and the Google addition.
        let google = Set(resolved.google.phones.map(\.value))
        #expect(google == ["415-555-0001", "415-555-0002", "415-555-0003", "415-555-0004", "415-555-0005", "415-555-0006", "415-555-0007"])
        #expect(resolved.google.phones.first { $0.value == "415-555-0005" }?.label == "mobile")
    }

    @Test("A blank side never wins by default: the other side's value is picked, whatever the diff says")
    func blankSideNeverWinsByDefault() throws {
        var mine = icloud(), theirs = google()
        theirs.birthday = DateComponents(year: 1994, month: 4, day: 6)
        // First link: the baseline is both sides as they are.
        var draft = SyncReviewDraft(icloud: mine, google: theirs, base: baseline(mine, theirs), reviewFields: [.birthday])
        var row = try #require(draft.singleRows.first { $0.field == .birthday })
        #expect(row.needsChoice && row.pick == .google)
        var resolved = draft.resolve()
        #expect(resolved.icloud.birthday?.year == 1994 && resolved.google.birthday?.year == 1994)

        draft.pick(.birthday, .icloud)
        #expect(draft.singleRows.first { $0.field == .birthday }?.pick == .icloud, "an explicit pick still stands")

        // The other way round, and Google-edited with a blank iCloud side that both edited.
        mine.birthday = DateComponents(year: 1994, month: 4, day: 6)
        theirs.birthday = nil
        draft = SyncReviewDraft(icloud: mine, google: theirs, base: baseline(mine, theirs), reviewFields: [.birthday])
        row = try #require(draft.singleRows.first { $0.field == .birthday })
        #expect(row.pick == .icloud)
        resolved = draft.resolve()
        #expect(resolved.google.birthday?.year == 1994)

        let before = icloud(org: "Acme")
        let edited = SyncReviewDraft(
            icloud: icloud(), google: google(org: "Fischer Design"), base: baseline(before, google(org: "Acme")), reviewFields: [.organization]
        )
        #expect(edited.singleRows.first { $0.field == .organization }?.pick == .google, "iCloud cleared it, Google changed it")
    }

    @Test("Keep iCloud for all still leaves Google's value where iCloud is blank")
    func keepICloudKeepsGoogleOnly() throws {
        let mine = icloud()
        var theirs = google()
        theirs.birthday = DateComponents(year: 1994, month: 4, day: 6)
        var draft = SyncReviewDraft(icloud: mine, google: theirs, base: baseline(mine, theirs), reviewFields: [.birthday])
        draft.chooseICloudEverywhere()
        #expect(draft.keptFromGoogle == [.birthday])
        let resolved = draft.resolve()
        #expect(resolved.icloud.birthday == nil && resolved.google.birthday?.year == 1994 && !resolved.changesICloud && !resolved.changesGoogle)
    }

    @Test("A blank note never wins by default either")
    func blankNoteNeverWins() throws {
        let record = icloud()
        let blankICloud = SyncReviewDraft(
            icloud: record, google: google(), base: baseline(record, google(), notes: ("", "from Google")), reviewFields: [.note],
            icloudNote: "", googleNote: "from Google"
        )
        #expect(blankICloud.noteRow?.pick == .google && blankICloud.resolve().note == "from Google")
        let blankGoogle = SyncReviewDraft(
            icloud: record, google: google(), base: baseline(record, google(), notes: ("from iCloud", "")), reviewFields: [.note],
            icloudNote: "from iCloud", googleNote: ""
        )
        #expect(blankGoogle.noteRow?.pick == .icloud && blankGoogle.resolve().note == "from iCloud")
        var kept = blankICloud
        kept.chooseICloudEverywhere()
        #expect(kept.keptFromGoogle == [.note] && kept.resolve().note == nil)
    }

    @Test("The same address spelled USA in one side and US in the other is one Same row")
    func addressCountrySpellings() throws {
        var mine = icloud(), theirs = google()
        mine.postalAddresses = [Labeled(label: "home", value: PostalAddress(street: "308 Liberty St", city: "Hutto", state: "TX", postalCode: "78634", country: "USA"))]
        theirs.postalAddresses = [Labeled(label: nil, value: PostalAddress(street: "308 Liberty St", city: "Hutto", state: "TX", postalCode: "78634", country: "US"))]
        let draft = SyncReviewDraft(icloud: mine, google: theirs, base: baseline(mine, theirs), reviewFields: [.postalAddresses])
        let rows = try #require(draft.lists.first?.rows)
        #expect(rows.count == 1 && rows[0].status == .both && rows[0].icloudText != nil && rows[0].googleText != nil)
        #expect(draft.isSettled)
    }

    // MARK: note

    @Test("The note is a pick between iCloud, Google and the two combined")
    func notePicks() throws {
        let record = icloud()
        let base = baseline(record, google(), notes: ("old", "old"))
        var draft = SyncReviewDraft(
            icloud: record, google: google(), base: base, reviewFields: [.note], icloudNote: "old", googleNote: "old, plus Google's addition"
        )
        let row = try #require(draft.noteRow)
        #expect(row.differs && row.pick == .google && !draft.noteUnreadable)
        #expect(draft.resolve().note == "old, plus Google's addition")
        draft.pickNote(.icloud)
        #expect(draft.resolve().note == "old")
        draft.pickNote(.combine)
        #expect(draft.resolve().note == "old\n\nold, plus Google's addition")
        #expect(draft.noteRow?.combinedText == "old\n\nold, plus Google's addition")
    }

    @Test("A note both sides changed defaults to iCloud's; an unreadable note is left alone")
    func noteDefaultsAndUnreadable() throws {
        let record = icloud()
        let base = baseline(record, google(), notes: ("old", "old"))
        let both = SyncReviewDraft(
            icloud: record, google: google(), base: base, reviewFields: [.note], icloudNote: "mine", googleNote: "theirs"
        )
        #expect(both.noteRow?.pick == .icloud && both.resolve().note == "mine")

        let unreadable = SyncReviewDraft(
            icloud: record, google: google(), base: base, reviewFields: [.note], icloudNote: nil, googleNote: "theirs"
        )
        #expect(unreadable.noteRow == nil && unreadable.noteUnreadable && unreadable.resolve().note == nil)
    }

    @Test("An iCloud-only note edit still goes to Google, and a note nobody edited is untouched")
    func noteNotUnderReview() throws {
        let record = icloud(org: "Acme")
        let base = baseline(record, google(org: "Acme"), notes: ("old", "old"))
        let pushes = SyncReviewDraft(
            icloud: record, google: google(org: "Other"), base: base, reviewFields: [.organization], icloudNote: "new", googleNote: "old"
        )
        #expect(pushes.noteRow == nil && pushes.resolve().note == "new")
        let quiet = SyncReviewDraft(
            icloud: record, google: google(org: "Other"), base: base, reviewFields: [.organization], icloudNote: "old", googleNote: "old"
        )
        #expect(quiet.resolve().note == nil)
    }

    @Test("A pair that already agrees is settled and resolves to itself")
    func settled() {
        let record = icloud(org: "Acme", phones: [("mobile", "415-555-0001")])
        let draft = SyncReviewDraft(
            icloud: record, google: google(org: "Acme", phones: [("mobile", "415-555-0001")]),
            base: baseline(record, google(org: "Acme", phones: [("mobile", "415-555-0001")])), reviewFields: [.phones, .organization]
        )
        #expect(draft.isSettled && !draft.hasChoices)
        let resolved = draft.resolve()
        #expect(!resolved.changesICloud && !resolved.changesGoogle)
    }
}
