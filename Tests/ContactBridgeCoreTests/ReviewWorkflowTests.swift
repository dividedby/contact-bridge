import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct ReviewWorkflowTests {
    // MARK: fixtures

    private func setOrganization(_ rig: ReviewRig, google name: String, icloud: String? = nil, id: Int = 2) async throws {
        try await rig.world.editGoogle("people/c\(id)", mask: "organizations") { $0.organizations = [GoogleOrganization(name: name)] }
        if let icloud { try await rig.world.editICloud("I\(id)") { $0.organization = icloud } }
    }

    private func addGooglePhone(_ rig: ReviewRig, _ number: String, id: Int = 2) async throws {
        try await rig.world.editGoogle("people/c\(id)", mask: "phoneNumbers") {
            $0.phoneNumbers = ($0.phoneNumbers ?? []) + [GooglePhoneNumber(value: number, type: "home")]
        }
    }

    private func googleOrg(_ rig: ReviewRig, id: Int = 2) async throws -> String? {
        try await rig.base.googlePerson("people/c\(id)").organizations?.first?.name
    }

    // MARK: edits

    @Test("Edited in Google: the choices are saved to iCloud under a fresh backup with notes, and both baselines move so nothing echoes")
    func googleEditedApply() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await addGooglePhone(rig, "415-555-7777")
        try await rig.syncOnce()
        let id = "googleEdited|I2|people/c2"
        #expect(try rig.item(id).fields == [.organization, .phones])

        let detail = try await rig.detail(id)
        let draft = try #require(detail.draft)
        #expect(draft.singleRows.first { $0.field == .organization }?.pick == .google)
        #expect(draft.lists.first?.rows.contains { $0.status == .addedInGoogle } == true)
        #expect(rig.base.backupFolders() == 0 && rig.world.store.mutationLog.isEmpty)

        let outcome = try await rig.workflows.apply(detail)
        #expect(outcome == .done(warnings: []))

        let saved = try await rig.icloud("I2")
        #expect(saved.organization == "Fischer Design" && saved.phones.map(\.value).contains("415-555-7777"))
        let log = try #require(rig.world.store.mutationLog.last)
        #expect(log.kind == .update && log.ids == ["I2"])
        let receipt = try #require(await rig.base.backups.latest)
        #expect(log.receiptID == receipt.id && receipt.manifest.notesIncluded && rig.base.backupFolders() == 1)

        // Google already held the result: no Google write, but the baseline is the pair as it now is.
        let person = try await rig.base.googlePerson("people/c2")
        #expect(try rig.base.history.entries().isEmpty)
        let baseline = try #require(try rig.state.baselines["I2"])
        #expect(baseline.icloud == saved && baseline.google == GooglePersonMapper.record(from: person) && baseline.googleEtag == person.etag)
        #expect(baseline.icloudNoteHash == NoteHash.hash("") && baseline.googleNoteHash == NoteHash.hash(""))
        #expect(try rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Edited in both places: iCloud's value is copied back to Google through the executor (backup, history, journal), and nothing echoes")
    func bothEditedCopiesBack() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Brown Consulting", icloud: "Brown & Co")
        try await rig.syncOnce()
        let id = "bothEdited|I2|people/c2"
        let detail = try await rig.detail(id)
        #expect(detail.draft?.singleRows.first { $0.field == .organization }?.pick == .icloud)
        let before = try await rig.base.googlePerson("people/c2")
        let written = rig.world.store.mutationLog.count

        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))

        #expect(try await googleOrg(rig) == "Brown & Co")
        #expect(try await rig.icloud("I2").organization == "Brown & Co" && rig.world.store.mutationLog.count == written, "iCloud kept its own value")
        let history = try rig.base.history.entries().filter { $0.icloudID == "I2" }
        #expect(history.map(\.confirmed) == [false, true] && history.first?.before?.etag == before.etag)
        #expect(try rig.base.journal.load().entries.isEmpty)
        let person = try await rig.base.googlePerson("people/c2")
        let baseline = try #require(try rig.state.baselines["I2"])
        #expect(baseline.googleEtag == person.etag && baseline.google == GooglePersonMapper.record(from: person))
        #expect(rig.base.backupFolders() == 1, "the Google backup the executor needs")
        #expect(try rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Edited in both places: picking Google's value changes iCloud and leaves Google alone")
    func bothEditedPickGoogle() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Brown Consulting", icloud: "Brown & Co")
        try await rig.syncOnce()
        var detail = try await rig.detail("bothEdited|I2|people/c2")
        detail.draft?.pick(.organization, .google)
        let etag = try await rig.base.googlePerson("people/c2").etag

        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        #expect(try await rig.icloud("I2").organization == "Brown Consulting")
        #expect(try await googleOrg(rig) == "Brown Consulting")
        #expect(try await rig.base.googlePerson("people/c2").etag == etag, "Google was not written")
        try await rig.expectSettled()
    }

    @Test("A phone removed in Google is a row the user confirms: following it removes it from iCloud, keeping it puts it back in Google")
    func removalIsConfirmed() async throws {
        for keep in [false, true] {
            let rig = try await ReviewRig.linked()
            defer { rig.cleanUp() }
            try await rig.world.editICloud("I2") { $0.phones.append(Labeled(label: "home", value: "415-555-8888")) }
            try await rig.syncOnce()  // pushes the second phone to Google
            try await rig.world.editGoogle("people/c2", mask: "phoneNumbers") { $0.phoneNumbers = Array(($0.phoneNumbers ?? []).prefix(1)) }
            try await rig.syncOnce()
            var detail = try await rig.detail("googleEdited|I2|people/c2")
            let row = try #require(detail.draft?.lists.first?.rows.first { $0.status == .removedInGoogle })
            #expect(row.action == .removeFromICloud, "following Google is the default for a Google edit")
            if keep { detail.draft?.setAction(.keepInICloud, forEntry: row.id) }

            #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
            let phones = try await rig.icloud("I2").phones.map(\.value)
            let google = try await rig.base.googlePerson("people/c2").phoneNumbers?.map(\.value) ?? []
            #expect(phones.contains("415-555-8888") == keep && google.contains("415-555-8888") == keep)
            try await rig.expectSettled()
        }
    }

    @Test("A Google-only entry stays Google-only through a decision about something else")
    func googleOnlyStays() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editGoogle("people/c2", mask: "emailAddresses") {
            $0.emailAddresses = [GoogleEmailAddress(value: "work@fischer.example", type: "work")]
        }
        try await rig.syncOnce()
        var detail = try await rig.detail("googleEdited|I2|people/c2")
        let row = try #require(detail.draft?.lists.first?.rows.first)
        #expect(row.status == .addedInGoogle)
        detail.draft?.setAction(.keepInGoogleOnly, forEntry: row.id)

        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        #expect(try await rig.icloud("I2").emails.isEmpty)
        #expect(try await rig.base.googlePerson("people/c2").emailAddresses?.map(\.value) == ["work@fischer.example"])
        let baseline = try #require(try rig.state.baselines["I2"])
        #expect(baseline.google.emails.map(\.value) == ["work@fischer.example"] && baseline.icloud.emails.isEmpty)
        // Not an edit on either side any more: a later plan leaves the contact alone.
        let next = try await rig.base.plan(.syncNow)
        #expect(!next.review.contains { $0.icloudID == "I2" } && !next.updates.contains { $0.icloudID == "I2" })
    }

    @Test("A note is picked, combined and saved to both sides with both hashes known")
    func noteCombined() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.notes.setNote("mine", forID: "I2")
        try await rig.world.editGoogle("people/c2", mask: "biographies") {
            $0.extras["biographies"] = .array([.object(["value": .string("theirs"), "contentType": .string("TEXT_PLAIN")])])
        }
        try await rig.syncOnce()
        let id = "bothEdited|I2|people/c2"
        #expect(try rig.item(id).fields == [.note])

        var detail = try await rig.detail(id)
        #expect(detail.icloudNote == "mine" && detail.googleNote == "theirs")
        detail.draft?.pickNote(.combine)
        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))

        #expect(rig.world.notes.writes.last?.id == "I2" && rig.world.notes.writes.last?.note == "mine\n\ntheirs")
        let person = try await rig.base.googlePerson("people/c2")
        #expect(GooglePersonMapper.note(of: person) == "mine\n\ntheirs")
        let baseline = try #require(try rig.state.baselines["I2"])
        #expect(baseline.icloudNoteHash == NoteHash.hash("mine\n\ntheirs") && baseline.googleNoteHash == NoteHash.hash("mine\n\ntheirs"))
        try await rig.expectSettled()
    }

    @Test("If either contact moved since it was shown, nothing is written: the item is refreshed and the user looks again")
    func changedSinceShown() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Brown Consulting", icloud: "Brown & Co")
        try await rig.syncOnce()
        let id = "bothEdited|I2|people/c2"
        let stored = try rig.item(id)
        let written = rig.world.store.mutationLog.count
        let etag = try await rig.base.googlePerson("people/c2").etag

        // Google moved.
        var detail = try await rig.detail(id)
        try await rig.world.editGoogle("people/c2", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Bobby")] }
        var outcome = try await rig.workflows.apply(detail)
        guard case .changedSinceShown(let afterGoogle?) = outcome else { Issue.record("expected a refresh, got \(outcome)"); return }
        #expect(afterGoogle.stamp.googleEtag != etag && afterGoogle.draft != nil)
        #expect(try rig.item(id).googleEtag == afterGoogle.stamp.googleEtag && stored.googleEtag != afterGoogle.stamp.googleEtag, "the stored item follows")
        #expect(rig.world.store.mutationLog.count == written)
        #expect(try await googleOrg(rig) == "Brown Consulting")

        // iCloud moved.
        detail = afterGoogle
        try await rig.world.editICloud("I2") { $0.jobTitle = "Chief" }
        outcome = try await rig.workflows.apply(detail)
        guard case .changedSinceShown(let afterICloud?) = outcome else { Issue.record("expected a refresh, got \(outcome)"); return }
        #expect(afterICloud.icloud?.jobTitle == "Chief")
        #expect(try rig.item(id).icloudFingerprint == afterICloud.stamp.icloudFingerprint)

        // The note moved.
        detail = afterICloud
        try await rig.world.notes.setNote("a new note", forID: "I2")
        outcome = try await rig.workflows.apply(detail)
        guard case .changedSinceShown(let afterNote?) = outcome else { Issue.record("expected a refresh, got \(outcome)"); return }
        #expect(afterNote.icloudNote == "a new note")

        // What the user looked at last is what gets applied.
        #expect(try await rig.workflows.apply(afterNote).isDone)
        #expect(try await googleOrg(rig) == "Brown & Co")
        #expect(try await rig.icloud("I2").nickname == "Bobby")
        #expect(GooglePersonMapper.note(of: try await rig.base.googlePerson("people/c2")) == "a new note", "iCloud's note edit went along")
    }

    @Test("Without notes access a decision refuses before touching anything")
    func needsNotes() async throws {
        let rig = try await ReviewRig.linked(notes: false)
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let detail = try await rig.detail("googleEdited|I2|people/c2")
        await #expect(throws: ReviewWorkflowError.notesUnavailable) { try await rig.workflows.apply(detail) }
        #expect(rig.world.store.mutationLog.isEmpty && rig.base.backupFolders() == 0)
        #expect(try rig.storedItems.count == 1)
    }

    @Test("When Google refuses the write the iCloud half stays saved, the item stays, and a second try settles it")
    func googleFailure() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editICloud("I2") { $0.phones = [Labeled(label: "work", value: $0.phones[0].value)] }
        try await rig.world.editGoogle("people/c2", mask: "phoneNumbers") {
            let first = $0.phoneNumbers?.first
            $0.phoneNumbers = [GooglePhoneNumber(value: first?.value, type: "home"), GooglePhoneNumber(value: "415-555-7777", type: "other")]
        }
        // A pending push for the same group would be reviewed together; the plan holds both.
        try await rig.syncOnce()
        let id = "bothEdited|I2|people/c2"
        let detail = try await rig.detail(id)

        await rig.world.google.inject(.rateLimited(retryAfter: 30), on: .batchUpdate)
        do {
            _ = try await rig.workflows.apply(detail)
            Issue.record("expected the Google write to fail")
        } catch let error as ReviewWorkflowError {
            guard case .googleWriteFailed(_, let icloudSaved) = error else { Issue.record("wrong error \(error)"); return }
            #expect(icloudSaved)
        }
        #expect(try await rig.icloud("I2").phones.map(\.value).contains("415-555-7777"), "Google's addition was saved in iCloud")
        #expect(try rig.item(id).kind == .bothEdited)
        #expect(try rig.base.journal.load().entries.isEmpty)
        #expect(try rig.state.baselines["I2"]?.google.phones.count == 1, "the baseline did not move")

        // iCloud changed under the old view, so the retry starts from a fresh one.
        let retry = try await rig.workflows.apply(detail)
        guard case .changedSinceShown(let fresh?) = retry else { Issue.record("expected a refresh"); return }
        #expect(try await rig.workflows.apply(fresh).isDone)
        #expect(try await rig.base.googlePerson("people/c2").phoneNumbers?.map(\.value).contains("415-555-7777") == true)
        try await rig.expectSettled()
    }

    // MARK: iCloud change token

    @Test("After an iCloud write the stored change token is re-read, so the next scan finds nothing changed")
    func tokenReread() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let before = try rig.state.icloudChangeToken
        _ = try await rig.workflows.apply(try await rig.detail("googleEdited|I2|people/c2"))
        let after = try await rig.world.store.changeToken()
        #expect(try rig.state.icloudChangeToken == after && after != before)
        _ = try await rig.base.plan(.scheduled)
        #expect(rig.world.lastScan?.status == .unchanged)
    }

    @Test("The token stays put while another conflict is open: every scan must read the whole book")
    func tokenHeldForOpenConflict() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design", id: 2)
        try await setOrganization(rig, google: "Other Co", id: 3)
        try await rig.syncOnce()
        let stored = try rig.state.icloudChangeToken
        #expect(try rig.storedItems.count == 2)

        _ = try await rig.workflows.apply(try await rig.detail("googleEdited|I2|people/c2"))
        #expect(try rig.state.icloudChangeToken == stored)
        _ = try await rig.base.plan(.scheduled)
        #expect(rig.world.lastScan?.status == .changed)
    }

    @Test("The token stays put when something else changed iCloud since the last scan, so that edit is still seen")
    func tokenHeldForForeignEdit() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let stored = try rig.state.icloudChangeToken
        let detail = try await rig.detail("googleEdited|I2|people/c2")
        try await rig.world.editICloud("I5") { $0.nickname = "Fi" }

        _ = try await rig.workflows.apply(detail)
        #expect(try rig.state.icloudChangeToken == stored)
        #expect(try await rig.base.plan(.scheduled).updates.map(\.icloudID) == ["I5"])
    }

    // MARK: new in Google

    private func addPriya(_ rig: ReviewRig, note: String? = "Met at the expo.") async throws {
        let person = SyncFixtures.person("Priya", "Patel", phones: ["415-555-0301"], emails: ["priya@example.com"], note: note)
        _ = try await rig.world.google.createContact(person)
    }

    @Test("Import copies the Google contact and its note into iCloud, links it as imported and baselines it with both hashes")
    func importContact() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let resource = try #require(item.resourceName)

        let detail = try await rig.workflows.loadDetail(item)
        #expect(detail.name == "Priya Patel" && detail.googleNote == "Met at the expo.")
        #expect(try await rig.workflows.importToICloud(detail) == .done(warnings: []))

        let created = try #require(try await rig.world.store.fetchAll().first { $0.givenName == "Priya" })
        #expect(created.phones.map(\.value) == ["415-555-0301"] && created.emails.map(\.value) == ["priya@example.com"])
        #expect(rig.world.store.mutationLog.last?.kind == .create && rig.base.backupFolders() == 1)
        let link = try #require(try rig.base.links[created.sourceIdentifier])
        #expect(link.googleResourceName == resource && link.effectiveOrigin == .imported)
        #expect(rig.world.notes.writes.last?.id == created.sourceIdentifier && rig.world.notes.writes.last?.note == "Met at the expo.")
        let baseline = try #require(try rig.state.baselines[created.sourceIdentifier])
        #expect(baseline.icloud == created && baseline.icloudNoteHash == NoteHash.hash("Met at the expo."))
        #expect(baseline.googleNoteHash == baseline.icloudNoteHash)
        #expect(try await rig.base.googlePerson(resource).etag == baseline.googleEtag)
        #expect(try rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Import refuses a Google contact that was edited since it was shown")
    func importStale() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let detail = try await rig.workflows.loadDetail(item)
        try await rig.world.editGoogle(try #require(item.resourceName), mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Pri")] }

        let outcome = try await rig.workflows.importToICloud(detail)
        guard case .changedSinceShown(let fresh?) = outcome else { Issue.record("expected a refresh"); return }
        #expect(rig.world.store.mutationLog.isEmpty)
        #expect(try await rig.world.store.fetchAll().count == 6)
        #expect(try await rig.workflows.importToICloud(fresh).isDone)
        #expect(try await rig.world.store.fetchAll().count == 7)
    }

    @Test("Ignore keeps the contact out of the list for good; Show ignored names it and un-ignoring offers it again")
    func ignoreAndUnignore() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let resource = try #require(item.resourceName)

        try await rig.workflows.ignore(item)
        #expect(try rig.state.ignoredGoogle == [resource] && rig.storedItems.isEmpty)
        // Edited later, it still stays ignored.
        try await rig.world.editGoogle(resource, mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Pri")] }
        try await rig.syncOnce()
        #expect(try rig.storedItems.isEmpty)

        let ignored = try await rig.workflows.loadIgnored()
        #expect(ignored.map(\.name) == ["Priya Patel"] && ignored.first?.resourceName == resource && ignored.first?.detail == "priya@example.com")

        try await rig.workflows.unignore([resource])
        let state = try rig.state
        #expect(state.ignoredGoogle.isEmpty && state.googleSyncToken == nil, "the next sync lists Google in full")
        try await rig.syncOnce()
        #expect(try rig.storedItems.map(\.kind) == [.newInGoogle])
    }

    // MARK: deleted in Google

    private func deleteInGoogle(_ rig: ReviewRig, _ id: Int) async throws {
        try await rig.world.google.deleteContact(resourceName: "people/c\(id)")
        try await rig.syncOnce()
    }

    @Test("Deleted in Google, delete here too: backup with notes, the iCloud contact, its link and baseline are gone")
    func deleteFromICloud() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await deleteInGoogle(rig, 3)
        let id = "deletedInGoogle|I3|people/c3"
        let detail = try await rig.detail(id)
        #expect(detail.icloud?.sourceIdentifier == "I3" && !detail.stamp.hasGoogle)

        #expect(try await rig.workflows.deleteFromICloud(detail) == .done(warnings: []))
        #expect(try await rig.world.icloudRecord("I3") == nil)
        let log = try #require(rig.world.store.mutationLog.last)
        let receipt = try #require(await rig.base.backups.latest)
        #expect(log.kind == .delete && log.ids == ["I3"] && log.receiptID == receipt.id)
        #expect(receipt.manifest.notesIncluded)
        #expect(try rig.base.links["I3"] == nil && rig.state.baselines["I3"] == nil && rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Deleted in Google, put it back: a new Google contact with the note, linked as created by sync")
    func putBack() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.notes.setNote("keep me", forID: "I3")
        try await deleteInGoogle(rig, 3)
        let detail = try await rig.detail("deletedInGoogle|I3|people/c3")
        let before = await rig.world.google.allPeople.count

        #expect(try await rig.workflows.putBackInGoogle(detail) == .done(warnings: []))
        let made = try #require(await rig.base.taggedPeople("I3").first)
        let name = try #require(made.resourceName)
        #expect(await rig.world.google.allPeople.count == before + 1 && name != "people/c3")
        #expect(GooglePersonMapper.note(of: made) == "keep me")
        let link = try #require(try rig.base.links["I3"])
        #expect(link.googleResourceName == name && link.effectiveOrigin == .createdInGoogle)
        let baseline = try #require(try rig.state.baselines["I3"])
        #expect(baseline.icloudNoteHash == NoteHash.hash("keep me") && baseline.googleNoteHash == NoteHash.hash("keep me"))
        #expect(baseline.googleEtag == made.etag && rig.world.store.mutationLog.isEmpty, "iCloud was not touched")
        #expect(try rig.storedItems.isEmpty && rig.base.journal.load().entries.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Deleted in Google: an iCloud edit since it was shown stops both ways out")
    func deletedInGoogleStale() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await deleteInGoogle(rig, 3)
        let detail = try await rig.detail("deletedInGoogle|I3|people/c3")
        try await rig.world.editICloud("I3") { $0.nickname = "Three" }
        let written = rig.world.store.mutationLog.count

        guard case .changedSinceShown(let fresh?) = try await rig.workflows.deleteFromICloud(detail) else { Issue.record("expected a refresh"); return }
        guard case .changedSinceShown = try await rig.workflows.putBackInGoogle(detail) else { Issue.record("expected a refresh"); return }
        #expect(rig.world.store.mutationLog.count == written)
        #expect(try await rig.icloud("I3").nickname == "Three")
        #expect(try rig.item("deletedInGoogle|I3|people/c3").icloudFingerprint == fresh.stamp.icloudFingerprint)
    }

    // MARK: deleted in iCloud, edited in Google

    private func deleteInICloudEditInGoogle(_ rig: ReviewRig) async throws {
        try await rig.world.store.delete(ids: ["I1"], backup: .forTesting())
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        try await rig.syncOnce()
    }

    @Test("Keep it deleted: the Google contact is deleted through the executor (backup, history), and the link is forgotten")
    func keepDeleted() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await deleteInICloudEditInGoogle(rig)
        let id = "deletedInICloudEditedInGoogle|I1|people/c1"
        let detail = try await rig.detail(id)
        #expect(detail.google?.nickname == "Annie" && detail.googleBefore?.nickname == "" && detail.icloud == nil)
        let before = try await rig.base.googlePerson("people/c1")

        #expect(try await rig.workflows.keepDeleted(detail) == .done(warnings: []))
        await #expect(throws: GoogleAPIError.notFound) { try await rig.base.googlePerson("people/c1") }
        #expect(try rig.base.links["I1"] == nil && rig.state.baselines["I1"] == nil && rig.storedItems.isEmpty)
        let history = try rig.base.history.entries().filter { $0.operation == .delete }
        #expect(history.map(\.confirmed) == [false, true] && history.first?.before?.etag == before.etag)
        #expect(rig.base.backupFolders() == 1)
        #expect(try rig.base.journal.load().entries.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Restore: iCloud gets the contact back from Google (with its note) and the new contact takes over the link")
    func restore() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await rig.world.editGoogle("people/c1", mask: "biographies") {
            $0.extras["biographies"] = .array([.object(["value": .string("Google note"), "contentType": .string("TEXT_PLAIN")])])
        }
        try await deleteInICloudEditInGoogle(rig)
        let detail = try await rig.detail("deletedInICloudEditedInGoogle|I1|people/c1")

        #expect(try await rig.workflows.restoreToICloud(detail) == .done(warnings: []))
        let restored = try #require(try await rig.world.store.fetchAll().first { $0.givenName == "First1" })
        #expect(restored.sourceIdentifier != "I1" && restored.nickname == "Annie")
        #expect(rig.world.store.mutationLog.last?.kind == .create && rig.base.backupFolders() == 1)
        #expect(rig.world.notes.writes.last?.id == restored.sourceIdentifier && rig.world.notes.writes.last?.note == "Google note")
        #expect(try rig.base.links["I1"] == nil && rig.state.baselines["I1"] == nil)
        let link = try #require(try rig.base.links[restored.sourceIdentifier])
        #expect(link.googleResourceName == "people/c1" && link.effectiveOrigin == .imported)
        let baseline = try #require(try rig.state.baselines[restored.sourceIdentifier])
        #expect(baseline.icloud == restored && baseline.icloudNoteHash == NoteHash.hash("Google note") && baseline.googleNoteHash == baseline.icloudNoteHash)
        #expect(try await rig.base.googlePerson("people/c1").etag == baseline.googleEtag && rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Restore: a profile-photo opt-out for the old contact does not carry over to the restored one")
    func restoreDropsOptOut() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try rig.base.stateStore.update { $0.profilePhotoOptOut = ["I1", "I2"] }
        try await deleteInICloudEditInGoogle(rig)
        let detail = try await rig.detail("deletedInICloudEditedInGoogle|I1|people/c1")

        #expect(try await rig.workflows.restoreToICloud(detail) == .done(warnings: []))
        #expect(try rig.state.profilePhotoOptOut == ["I2"])
    }

    @Test("Deleted here, edited in Google: if Google changed again since it was shown, nothing is deleted")
    func keepDeletedStale() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await deleteInICloudEditInGoogle(rig)
        let id = "deletedInICloudEditedInGoogle|I1|people/c1"
        let detail = try await rig.detail(id)
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Ann-again")] }

        guard case .changedSinceShown(let fresh?) = try await rig.workflows.keepDeleted(detail) else { Issue.record("expected a refresh"); return }
        #expect(fresh.google?.nickname == "Ann-again")
        #expect(try await rig.base.googlePerson("people/c1").nicknames?.first?.value == "Ann-again")
        #expect(try rig.item(id).googleEtag == fresh.stamp.googleEtag)
    }

    // MARK: deleting the contact

    @Test("New in Google, delete it: Google backup first, the contact is logged and deleted, and the item goes")
    func deleteNewFromGoogle() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let resource = try #require(item.resourceName)
        let detail = try await rig.workflows.loadDetail(item)
        let before = try await rig.base.googlePerson(resource)

        #expect(try await rig.workflows.deleteFromGoogle(detail) == .done(warnings: []))
        await #expect(throws: GoogleAPIError.notFound) { try await rig.base.googlePerson(resource) }
        #expect(rig.base.backupFolders() == 1 && rig.world.store.mutationLog.isEmpty)
        let logged = try rig.base.history.entries().filter { $0.operation == .delete }
        #expect(logged.count == 1 && logged.first?.resourceName == resource && logged.first?.before?.etag == before.etag)
        #expect(try rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("New in Google, delete it: a Google edit since it was shown stops it")
    func deleteNewFromGoogleStale() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let item = try #require(try rig.storedItems.first { $0.kind == .newInGoogle })
        let resource = try #require(item.resourceName)
        let detail = try await rig.workflows.loadDetail(item)
        try await rig.world.editGoogle(resource, mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Pri")] }

        guard case .changedSinceShown(let fresh?) = try await rig.workflows.deleteFromGoogle(detail) else { Issue.record("expected a refresh"); return }
        #expect(try await rig.base.googlePerson(resource).nicknames?.first?.value == "Pri")
        #expect(try await rig.workflows.deleteFromGoogle(fresh).isDone)
        await #expect(throws: GoogleAPIError.notFound) { try await rig.base.googlePerson(resource) }
    }

    @Test("Edited in Google, delete from both: iCloud goes under a backup with notes, then Google through the executor, and the pair is forgotten")
    func deleteLinkedFromBoth() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let detail = try await rig.detail("googleEdited|I2|people/c2")

        #expect(try await rig.workflows.deleteFromBoth(detail) == .done(warnings: []))
        #expect(try await rig.world.store.fetchAll().contains { $0.sourceIdentifier == "I2" } == false)
        let log = try #require(rig.world.store.mutationLog.last)
        #expect(log.kind == .delete && log.ids == ["I2"])
        let receipt = try #require(await rig.base.backups.latest)
        #expect(log.receiptID == receipt.id && receipt.manifest.notesIncluded)
        await #expect(throws: GoogleAPIError.notFound) { try await rig.base.googlePerson("people/c2") }
        #expect(try rig.base.links["I2"] == nil && rig.state.baselines["I2"] == nil && rig.storedItems.isEmpty)
        #expect(try rig.base.history.entries().filter { $0.operation == .delete }.map(\.confirmed) == [false, true])
        try await rig.expectSettled()
    }

    @Test("Delete from both: an iCloud edit since it was shown stops it before anything is deleted")
    func deleteLinkedStale() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let detail = try await rig.detail("googleEdited|I2|people/c2")
        try await rig.world.editICloud("I2") { $0.nickname = "Bee" }

        guard case .changedSinceShown = try await rig.workflows.deleteFromBoth(detail) else { Issue.record("expected a refresh"); return }
        #expect(try await rig.world.store.fetchAll().contains { $0.sourceIdentifier == "I2" })
        #expect(try await rig.base.googlePerson("people/c2").resourceName == "people/c2")
        #expect(rig.base.backupFolders() == 0)
    }

    // MARK: possible match

    private func possibleWorld() throws -> ReviewRig {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"])], google: [SyncFixtures.person("Ann", "Lee")]
        )
        return try ReviewRig.firstSync(world)
    }

    @Test("Link ties the pair together as matched; the next sync takes the baseline from both sides and asks about what differs")
    func linkPair() async throws {
        let rig = try possibleWorld()
        defer { rig.cleanUp() }
        try await rig.syncOnce()
        let id = "possibleLink|I1|people/c1"
        let detail = try await rig.detail(id)
        #expect(detail.icloud?.displayName == "Ann Lee" && detail.google?.displayName == "Ann Lee")

        #expect(try await rig.workflows.link(detail) == .done(warnings: []))
        let link = try #require(try rig.base.links["I1"])
        #expect(link.googleResourceName == "people/c1" && link.effectiveOrigin == .matched)
        #expect(try rig.storedItems.isEmpty && rig.state.icloudChangeToken == nil && rig.state.baselines["I1"] == nil)

        try await rig.syncOnce()
        let baseline = try #require(try rig.state.baselines["I1"])
        #expect(baseline.icloudNoteHash != nil && baseline.googleNoteHash != nil)
        let pinned = try #require(try rig.storedItems.first)
        #expect(pinned.id == "bothEdited|I1|people/c1" && pinned.pinned && pinned.fields == [.phones])
        #expect(try rig.base.links["I1"]?.effectiveOrigin == .matched)
    }

    @Test("Keep separate is saved, honoured by the next plan (the iCloud contact is created in Google) and survives a restart")
    func keepSeparate() async throws {
        let rig = try possibleWorld()
        defer { rig.cleanUp() }
        try await rig.syncOnce()
        let item = try rig.item("possibleLink|I1|people/c1")
        try await rig.workflows.keepSeparate(item)
        #expect(try rig.state.keepSeparate == ["I1|people/c1"] && rig.storedItems.isEmpty)

        let report = try await rig.syncOnce()
        #expect(report.created == 1)
        #expect(await rig.base.taggedPeople("I1").count == 1)
        #expect(try rig.storedItems.map(\.id) == ["newInGoogle||people/c1"], "the other Google contact is a different person: offered as new")
        #expect(try rig.base.links["I1"]?.effectiveOrigin == .createdInGoogle)
    }

    @Test("A stale possible match is refused when one of the contacts got linked meanwhile")
    func linkStale() async throws {
        let rig = try possibleWorld()
        defer { rig.cleanUp() }
        try await rig.syncOnce()
        let detail = try await rig.detail("possibleLink|I1|people/c1")
        try rig.base.linkStore.add([ImportedLink(icloudID: "other", googleResourceName: "people/c1")], at: rig.base.clock.now())

        #expect(try await rig.workflows.link(detail) == .changedSinceShown(nil))
        #expect(try rig.base.links["I1"] == nil && rig.storedItems.isEmpty)
    }

    // MARK: first-link conflicts

    /// `count` pairs that match confidently (same name and phone) but differ in company; Google also has an email of its own.
    private func firstLinkRig(count: Int = 3) async throws -> ReviewRig {
        let icloud = (1...count).map {
            var record = SyncFixtures.icloud("I\($0)", "First\($0)", "Last\($0)", phones: ["415-555-01\(String(format: "%02d", $0))"])
            record.organization = "Acme \($0)"
            return record
        }
        let people = (1...count).map { index -> GooglePerson in
            var person = SyncFixtures.person("First\(index)", "Last\(index)", phones: ["415-555-01\(String(format: "%02d", index))"], emails: ["g\(index)@example.com"])
            person.organizations = [GoogleOrganization(name: "Other \(index)")]
            return person
        }
        let rig = try ReviewRig.firstSync(SyncWorld(icloud: icloud, google: people))
        try await rig.syncOnce()
        return rig
    }

    @Test("A first-link conflict is pinned; resolving it clears it, and the Google-only email stays Google-only")
    func pinnedResolved() async throws {
        let rig = try await firstLinkRig(count: 1)
        defer { rig.cleanUp() }
        let item = try #require(try rig.storedItems.first)
        #expect(item.kind == .bothEdited && item.pinned && item.fields == [.organization, .emails])
        let detail = try await rig.workflows.loadDetail(item)
        let draft = try #require(detail.draft)
        #expect(draft.singleRows.first { $0.field == .organization }?.pick == .icloud)
        #expect(draft.lists.first?.rows.first?.status == .googleOnly)

        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        #expect(try rig.storedItems.isEmpty)
        #expect(try await googleOrg(rig, id: 1) == "Acme 1")
        #expect(try await rig.base.googlePerson("people/c1").emailAddresses?.map(\.value) == ["g1@example.com"])
        #expect(try await rig.icloud("I1").emails.isEmpty)
        try await rig.expectSettled()
    }

    @Test("A pinned conflict goes when either contact is gone")
    func pinnedCleared() async throws {
        for iCloudSide in [false, true] {
            let rig = try await firstLinkRig(count: 2)
            defer { rig.cleanUp() }
            #expect(try rig.storedItems.count == 2 && rig.storedItems.allSatisfy(\.pinned))
            if iCloudSide {
                try await rig.world.store.delete(ids: ["I1"], backup: .forTesting())
            } else {
                try await rig.world.google.deleteContact(resourceName: "people/c1")
            }
            let report = try await rig.syncOnce()
            let ids = try rig.storedItems.map(\.id)
            #expect(ids.contains("bothEdited|I2|people/c2") && !ids.contains("bothEdited|I1|people/c1"))
            if iCloudSide {
                #expect(report.deleted == 1 && report.blockedByReview.isEmpty, "the pinned item no longer blocks the delete")
            } else {
                #expect(ids.contains("deletedInGoogle|I1|people/c1"))
            }
        }
    }

    @Test("Keep iCloud for all: iCloud's values go to Google in one pass, Google-only entries stay, iCloud is untouched")
    func bulkKeepICloud() async throws {
        let rig = try await firstLinkRig(count: 3)
        defer { rig.cleanUp() }
        let items = try rig.storedItems
        #expect(items.count == 3 && items.allSatisfy { $0.kind == .bothEdited && $0.pinned })
        let before = rig.world.store.mutationLog.count

        let report = try await rig.workflows.keepICloudForAll(items)
        #expect(report.applied.count == 3 && report.failed.isEmpty && report.skipped.isEmpty)
        for index in 1...3 {
            #expect(try await googleOrg(rig, id: index) == "Acme \(index)")
            #expect(try await rig.base.googlePerson("people/c\(index)").emailAddresses?.map(\.value) == ["g\(index)@example.com"])
            let baseline = try #require(try rig.state.baselines["I\(index)"])
            let person = try await rig.base.googlePerson("people/c\(index)")
            #expect(baseline.googleEtag == person.etag && baseline.google == GooglePersonMapper.record(from: person))
            #expect(baseline.icloudNoteHash != nil && baseline.googleNoteHash != nil)
        }
        #expect(rig.world.store.mutationLog.count == before, "no iCloud write")
        #expect(await rig.world.google.batchCallSizes(.batchUpdate) == [3], "one batch for all three")
        #expect(try rig.base.history.entries().filter { $0.operation == .update && !$0.confirmed }.count == 3)
        #expect(try rig.storedItems.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Keep iCloud for all leaves items of other kinds alone")
    func bulkSkipsOtherKinds() async throws {
        let rig = try await firstLinkRig(count: 1)
        defer { rig.cleanUp() }
        try await addPriya(rig)
        try await rig.syncOnce()
        let all = try rig.storedItems
        let report = try await rig.workflows.keepICloudForAll(all)
        #expect(report.applied == ["bothEdited|I1|people/c1"] && report.skipped.count == 1)
        #expect(try rig.storedItems.map(\.kind) == [.newInGoogle])
    }

    // MARK: keep iCloud for all: only what was shown

    @Test("Keep iCloud for all skips an item whose Google contact moved on since the list was made, and leaves the Google edit alone")
    func bulkSkipsMovedItems() async throws {
        let rig = try await firstLinkRig(count: 3)
        defer { rig.cleanUp() }
        let items = try rig.storedItems
        // Google edit after linking (contact 1) and an iCloud edit after linking (contact 2).
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        try await rig.world.editICloud("I2") { $0.jobTitle = "Chief" }

        let report = try await rig.workflows.keepICloudForAll(items)
        #expect(report.applied == ["bothEdited|I3|people/c3"])
        #expect(Set(report.changedSinceShown) == ["bothEdited|I1|people/c1", "bothEdited|I2|people/c2"])
        #expect(try await rig.base.googlePerson("people/c1").nicknames?.first?.value == "Annie", "the Google edit was not overwritten")
        #expect(try await googleOrg(rig, id: 1) == "Other 1")
        #expect(try await googleOrg(rig, id: 2) == "Other 2")
        #expect(try Set(rig.storedItems.map(\.id)) == ["bothEdited|I1|people/c1", "bothEdited|I2|people/c2"])
    }

    @Test("A decision removes the item and the conflicts it showed, never a conflict about the same contact that it did not")
    func clearsOnlyWhatWasShown() async throws {
        let rig = try await firstLinkRig(count: 1)
        defer { rig.cleanUp() }
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Annie")] }
        try await rig.syncOnce()
        #expect(try rig.storedItems.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.bothEdited, .googleEdited])
        let pinned = try rig.item("bothEdited|I1|people/c1")

        // Keep iCloud for all settles exactly the first-link item's groups; here it stands back instead, and removes nothing.
        let report = try await rig.workflows.keepICloudForAll([pinned])
        #expect(report.applied.isEmpty && report.changedSinceShown == [pinned.id])
        #expect(try rig.storedItems.count == 2)

        // Opening the item shows the nickname too (it is in the same view), so deciding settles both.
        let detail = try await rig.workflows.loadDetail(pinned)
        #expect(detail.draft?.reviewFields.contains(.nickname) == true)
        #expect(try await rig.workflows.apply(detail) == .done(warnings: []))
        #expect(try rig.storedItems.isEmpty)
    }

    /// A first-link pair where iCloud has no company and no note, and Google has both.
    private func blankICloudRig() async throws -> ReviewRig {
        let icloud = [SyncFixtures.icloud("I1", "First1", "Last1", phones: ["415-555-0101"])]
        var person = SyncFixtures.person("First1", "Last1", phones: ["415-555-0101"], note: "Google's note")
        person.organizations = [GoogleOrganization(name: "Other 1")]
        let rig = try ReviewRig.firstSync(SyncWorld(icloud: icloud, google: [person]))
        try await rig.syncOnce()
        return rig
    }

    @Test("Keep iCloud for all never erases a Google company or note that iCloud has none of: it stays in Google, and the result says so")
    func bulkKeepsGoogleWhereICloudIsBlank() async throws {
        let rig = try await blankICloudRig()
        defer { rig.cleanUp() }
        let item = try #require(try rig.storedItems.first)
        #expect(item.fields == [.organization, .note])
        let written = rig.world.store.mutationLog.count

        let report = try await rig.workflows.keepICloudForAll([item])
        #expect(report.applied == [item.id] && report.keptFromGoogle[item.id] == [.organization, .note])
        #expect(report.warnings.contains { $0.contains("First1 Last1") && $0.contains("company") && $0.contains("note") })
        let person = try await rig.base.googlePerson("people/c1")
        #expect(person.organizations?.first?.name == "Other 1" && GooglePersonMapper.note(of: person) == "Google's note")
        #expect(rig.world.store.mutationLog.count == written)
        let record = try await rig.icloud("I1")
        #expect(record.organization.isEmpty)
        try await rig.expectSettled()
    }

    @Test("Use iCloud for everything keeps Google's value where iCloud has none; an explicit pick of nothing still clears it")
    func singleItemKeepsGoogleWhereICloudIsBlank() async throws {
        let rig = try await blankICloudRig()
        defer { rig.cleanUp() }
        var detail = try await rig.detail("bothEdited|I1|people/c1")
        detail.draft?.chooseICloudEverywhere()
        let draft = try #require(detail.draft)
        #expect(draft.keptFromGoogle == [.organization, .note])
        let resolved = draft.resolve()
        #expect(resolved.google.organization == "Other 1" && resolved.icloud.organization.isEmpty && resolved.note == nil)

        detail.draft?.pick(.organization, .icloud)
        detail.draft?.pickNote(.icloud)
        let cleared = try #require(detail.draft).resolve()
        #expect(cleared.google.organization.isEmpty && cleared.note == "")
        #expect(try #require(detail.draft).keptFromGoogle.isEmpty)
    }

    // MARK: keep deleted only deletes what was shown

    @Test("Keep deleted deletes only the Google version the user saw: an edit made meanwhile goes back to review")
    func keepDeletedApprovesOneEtag() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await deleteInICloudEditInGoogle(rig)
        let id = "deletedInICloudEditedInGoogle|I1|people/c1"
        let seen = try #require(try await rig.base.googlePerson("people/c1").etag)
        let baseline = try #require(try rig.state.baselines["I1"])
        var plan = SyncPlan(isPreview: false)
        plan.deletes = [PlannedDelete(icloudID: "I1", resourceName: "people/c1", baseline: baseline)]

        // Google changes after the user looked, before the delete.
        try await rig.world.editGoogle("people/c1", mask: "nicknames") { $0.nicknames = [GoogleNickname(value: "Ann-again")] }
        let run = try await rig.base.makeExecutor().execute(plan: plan, approvedDeletes: ["I1": seen])
        #expect(run.deleted == 0 && run.reviewsAdded == [id])
        #expect(try await rig.base.googlePerson("people/c1").nicknames?.first?.value == "Ann-again")
        let refreshed = try rig.item(id)
        let now = try await rig.base.googlePerson("people/c1").etag
        #expect(refreshed.googleEtag != seen && refreshed.googleEtag == now)

        // The same plan with the version that is there now goes through.
        let current = try #require(try await rig.base.googlePerson("people/c1").etag)
        let second = try await rig.base.makeExecutor().execute(plan: plan, approvedDeletes: ["I1": current])
        #expect(second.deleted == 1)
    }

    // MARK: iCloud moved during the backup

    @Test("If iCloud changes while the backup is taken, nothing is written: the user looks again")
    func iCloudMovedDuringBackup() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let detail = try await rig.detail("googleEdited|I2|people/c2")

        let world = rig.world
        let directory = rig.base.directory
        let sneaky = Mutex(true)
        let backups = BackupCoordinator(makeSetup: {
            if sneaky.withLock({ let first = $0; $0 = false; return first }) { try await world.editICloud("I2") { $0.nickname = "Sneaky" } }
            return BackupSetup(writer: BackupWriter(store: world.store, google: world.google, notes: world.notes, baseDirectory: directory))
        })
        let workflows = ReviewWorkflows(
            store: world.store, google: rig.base.faulty, notes: world.notes, backups: backups, links: rig.base.linkStore,
            state: rig.base.stateStore, reviews: rig.base.reviews, journal: rig.base.journal, history: rig.base.history, gate: rig.gate
        )
        let written = world.store.mutationLog.count

        let outcome = try await workflows.apply(detail)
        guard case .changedSinceShown(let fresh?) = outcome else { Issue.record("expected a refresh, got \(outcome)"); return }
        #expect(fresh.icloud?.nickname == "Sneaky")
        #expect(world.store.mutationLog.count == written + 1, "only the other edit was written")
        #expect(try await rig.icloud("I2").organization.isEmpty)
        #expect(try rig.storedItems.count == 1)
    }

    // MARK: gate

    @Test("A decision waits for the write gate, like every other write")
    func insideTheGate() async throws {
        let rig = try await ReviewRig.linked()
        defer { rig.cleanUp() }
        try await setOrganization(rig, google: "Fischer Design")
        try await rig.syncOnce()
        let detail = try await rig.detail("googleEdited|I2|people/c2")

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        let holder = Task {
            try await rig.gate.withLock {
                enteredContinuation.yield()
                for await _ in release { break }
            }
        }
        for await _ in entered { break }
        let decision = Task { try await rig.workflows.apply(detail) }
        await rig.gate.waitUntilQueued(1)
        #expect(rig.world.store.mutationLog.isEmpty, "nothing is written while another change holds the gate")
        releaseContinuation.yield()
        try await holder.value
        #expect(try await decision.value.isDone)
        #expect(rig.world.store.mutationLog.count == 1)
    }

    // MARK: end to end

    @Test("End to end through the engine: a Google edit appears, is decided, and the next sync finds nothing to send back")
    func endToEnd() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let workflows = ReviewWorkflows(
            store: rig.base.world.store, google: rig.google, notes: rig.base.world.notes, backups: rig.base.backups, links: rig.base.linkStore,
            state: rig.base.stateStore, reviews: rig.base.reviews, journal: rig.base.journal, history: rig.base.history, gate: rig.gate,
            now: { rig.clock.now() }
        )
        _ = await rig.startAndRun()
        try await rig.base.world.editGoogle("people/c2", mask: "organizations") { $0.organizations = [GoogleOrganization(name: "Fischer Design")] }
        try await rig.base.world.editGoogle("people/c2", mask: "phoneNumbers") {
            $0.phoneNumbers = ($0.phoneNumbers ?? []) + [GooglePhoneNumber(value: "415-555-7777", type: "home")]
        }
        await rig.engine.syncNow()
        let listed = try #require(await rig.snapshot.reviewItems.first)
        #expect(listed.kind == .googleEdited && listed.name == "First2 Last2" && listed.fields == [.organization, .phones])

        let item = try #require(try rig.base.reviews.load().first { $0.id == listed.id })
        let detail = try await workflows.loadDetail(item)
        #expect(try await workflows.apply(detail) == .done(warnings: []))
        await rig.engine.syncNow()

        let snapshot = await rig.snapshot
        #expect(snapshot.reviewItems.isEmpty && snapshot.lastRun?.text == "Nothing needed changing.")
        #expect(snapshot.lastRun?.updated == 0 && snapshot.lastRun?.conflictsFound == 0)
        let plan = try await rig.base.plan(.syncNow)
        #expect(plan.isEmpty && plan.updates.isEmpty && plan.review.isEmpty && plan.baselineRefreshes.isEmpty)
        #expect(try await rig.base.world.icloudRecord("I2")?.organization == "Fischer Design")
        await rig.engine.stop()
    }
}

private extension ReviewOutcome {
    var isDone: Bool {
        if case .done = self { true } else { false }
    }
}
