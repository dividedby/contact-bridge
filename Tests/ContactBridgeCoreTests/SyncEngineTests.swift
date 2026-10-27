import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

struct SyncEngineTests {
    /// Ann matches in Google; Bob exists only in iCloud. Not approved: a first-sync preview of one link and one create.
    private func firstSyncRig(schedule: SyncSchedule = SyncSchedule()) throws -> EngineRig {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"]), SyncFixtures.icloud("I2", "Bob", "Stone", phones: ["415-555-0002"])],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-2671"])]
        )
        return EngineRig(try ExecutorRig(world), schedule: schedule)
    }

    /// Starts an approved engine and waits for its first run to end.
    private func started(_ rig: EngineRig) async -> Int {
        await rig.startAndRun()
    }

    // MARK: first sync

    @Test("Before the first sync is approved nothing runs by itself, and the preview writes nothing anywhere")
    func previewOnly() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        for event in [SyncEvent.storeChanged, .timer, .wake, .networkBack, .settingsChanged] { await rig.engine.trigger(event) }
        await rig.advance(3600)
        let before = await rig.snapshot
        #expect(rig.google.listings == 0 && before.preview == nil)

        await rig.engine.refreshPreview()
        let snapshot = await rig.snapshot
        let preview = try #require(snapshot.preview)
        #expect(snapshot.status == .idle && !snapshot.firstSyncApproved)
        #expect(preview.links.map(\.name) == ["Ann Lee"] && preview.creates.map(\.name) == ["Bob Stone"] && preview.counts.review == 0)
        #expect(preview.backups.first?.contains("backup") == true)

        let people = await rig.base.world.google.allPeople.count
        #expect(people == 1 && rig.base.backupFolders() == 0)
        #expect(try rig.base.links.isEmpty && rig.base.reviews.load().isEmpty && rig.base.journal.load().entries.isEmpty)
        let state = try rig.state
        #expect(!state.firstSyncApproved && state.baselines.isEmpty && state.googleSyncToken == nil)
        await rig.engine.stop()
    }

    @Test("The preview names the contacts whose old links will be forgotten, and leaves out links that are re-matched instead")
    func previewNamesForgottenLinks() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("S", "Ann", "Lee", phones: ["415-555-2671"])],
            google: [SyncFixtures.person("Ann", "Lee", phones: ["415-555-2671"])]
        )
        world.links.links["GONE1"] = LinkEntry(googleResourceName: "people/c1", linkedAt: world.clock, displayName: "Ann Lee (merged)")
        world.links.links["GONE2"] = LinkEntry(googleResourceName: "people/c99", linkedAt: world.clock, displayName: "Zed Quinn")
        let rig = EngineRig(try ExecutorRig(world))
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()

        let preview = try #require(await rig.snapshot.preview)
        #expect(preview.forgottenLinks.map(\.name) == ["Zed Quinn"] && preview.forgottenLinks.first?.id == "GONE2")
        #expect(preview.links.map(\.name) == ["Ann Lee"] && preview.creates.isEmpty, "the survivor takes over Ann's Google contact")
        await rig.engine.stop()
    }

    @Test("Approving runs the previewed plan once: the link is made, Bob is created, a second approval does nothing")
    func approveRunsOnce() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        #expect(await rig.engine.approveFirstSync() == .noPreview)
        await rig.engine.refreshPreview()

        #expect(await rig.engine.approveFirstSync() == .started)
        let snapshot = await rig.snapshot
        #expect(snapshot.firstSyncApproved && snapshot.preview == nil && snapshot.status == .idle)
        #expect(snapshot.lastRun?.linksAdded == 1 && snapshot.lastRun?.created == 1 && snapshot.lastRun?.text == "Linked 1, created 1.")
        let people = await rig.base.world.google.allPeople
        #expect(people.count == 2 && people.filter { $0.contactBridgeSourceID == "I2" }.count == 1)
        #expect(try rig.state.firstSyncApproved && rig.base.links.keys.sorted() == ["I1", "I2"])

        #expect(await rig.engine.approveFirstSync() == .alreadyApproved)
        await rig.engine.syncNow()
        let after = await rig.base.world.google.allPeople.count
        #expect(after == 2, "no duplicate create")
        await rig.engine.stop()
    }

    @Test("Start syncing needs a known Google account email, and saves it with the approval")
    func approveNeedsAccountEmail() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        rig.setAccountEmail(nil)

        guard case .unavailable(let reason) = await rig.engine.approveFirstSync() else {
            Issue.record("approval must be refused while the account email is unknown")
            return
        }
        #expect(reason.contains("which Google account"))
        let people = await rig.base.world.google.allPeople.count
        #expect(try !rig.state.firstSyncApproved && rig.state.googleAccount == nil && people == 1)
        let refused = await rig.snapshot
        #expect(refused.preview != nil && !refused.firstSyncApproved)

        rig.setAccountEmail("me@example.com")
        #expect(await rig.engine.approveFirstSync() == .started)
        #expect(try rig.state.firstSyncApproved && rig.state.googleAccount == "me@example.com")
        await rig.engine.stop()
    }

    @Test("Two clicks on Start syncing at once start one run")
    func approveTwiceAtOnce() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        async let first = rig.engine.approveFirstSync()
        async let second = rig.engine.approveFirstSync()
        let outcomes = await [first, second]
        #expect(outcomes.contains(.started) && outcomes.contains(.alreadyApproved))
        #expect(await rig.base.world.google.allPeople.count == 2)
        await rig.engine.stop()
    }

    @Test("If the plan changed since the preview, approving shows the new preview instead of running")
    func approveAfterPreviewChanged() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        try await rig.base.addICloudContact("Carol", "Newman", phone: "415-555-0100")

        #expect(await rig.engine.approveFirstSync() == .previewChanged)
        let snapshot = await rig.snapshot
        #expect(!snapshot.firstSyncApproved && snapshot.preview?.creates.count == 2)
        #expect(try !rig.state.firstSyncApproved && rig.base.links.isEmpty)
        let people = await rig.base.world.google.allPeople.count
        #expect(people == 1)

        #expect(await rig.engine.approveFirstSync() == .started)
        #expect(await rig.base.world.google.allPeople.count == 3)
        await rig.engine.stop()
    }

    // MARK: scheduling

    @Test("An approved engine runs at start, and triggers are debounced into one run ten seconds after the last")
    func debounce() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        #expect(first == 1)
        let snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.lastRun?.text == "Nothing needed changing.")

        await rig.engine.trigger(.storeChanged)
        await rig.advance(5)
        await rig.engine.trigger(.storeChanged)
        await rig.engine.trigger(.networkBack)
        await rig.advance(9)
        #expect(rig.google.listings == first, "nine seconds after the last trigger is too soon")
        await rig.clock.waitForSleepers(2)
        await rig.advance(2)
        #expect(rig.google.listings == first + 1, "three triggers, one run")
        await rig.advance(600)
        #expect(rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("A stream of triggers cannot postpone a run for more than a minute")
    func maxDebounce() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.engine.trigger(.storeChanged)
        for _ in 0..<6 {
            await rig.advance(9)
            await rig.engine.trigger(.storeChanged)
        }
        #expect(rig.google.listings == first, "54 seconds in")
        await rig.clock.waitForSleepers(2)
        await rig.advance(6)
        #expect(rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("The 15-minute timer asks for a run, which then waits out the debounce")
    func timer() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.advance(899)
        #expect(rig.google.listings == first)
        await rig.advance(1)
        await rig.clock.waitForSleepers(2) // the timer again, and the debounce it asked for
        #expect(rig.google.listings == first)
        await rig.advance(10)
        #expect(rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("After a wake the run waits thirty seconds for the network")
    func wake() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.engine.trigger(.wake)
        await rig.advance(29)
        #expect(rig.google.listings == first)
        await rig.clock.waitForSleepers(2)
        await rig.advance(2)
        #expect(rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("Sync now runs at once, without waiting out the debounce")
    func syncNow() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.engine.trigger(.storeChanged)
        await rig.engine.syncNow()
        #expect(rig.google.listings == first + 1)
        await rig.advance(30)
        #expect(rig.google.listings == first + 1, "the pending debounce was folded into that run")
        await rig.engine.stop()
    }

    @Test("A change in iCloud is pushed to Google by the next run")
    func pushesChange() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        try await rig.base.setPhone("I1", "415-555-9999")
        await rig.engine.trigger(.storeChanged)
        await rig.clock.waitForSleepers(2)
        await rig.advance(10)
        let person = try await rig.base.googlePerson("people/c1")
        #expect(person.phoneNumbers?.map(\.value) == ["415-555-9999"])
        #expect(await rig.snapshot.lastRun?.updated == 1)
        await rig.engine.stop()
    }

    // MARK: back-off

    @Test("A run that Google stopped (rate limit) is not retried by triggers until a minute has passed")
    func backoffAfterHalt() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        try await rig.base.setPhone("I1", "415-555-9999")
        await rig.base.world.google.inject(.rateLimited(retryAfter: 30), on: .batchUpdate)

        await rig.engine.syncNow()
        var snapshot = await rig.snapshot
        #expect(snapshot.lastRun?.halted != nil && snapshot.status == .idle)
        #expect(snapshot.nextAttemptAt == rig.clock.now().addingTimeInterval(60))
        let after = rig.google.listings

        await rig.engine.trigger(.storeChanged)
        await rig.clock.waitForSleepers(2)
        await rig.advance(10)
        await rig.advance(40)
        #expect(rig.google.listings == after, "still inside the back-off")
        await rig.advance(11)
        #expect(rig.google.listings == after + 1)
        snapshot = await rig.snapshot
        #expect(snapshot.lastRun?.halted == nil && snapshot.lastRun?.updated == 1 && snapshot.nextAttemptAt == nil)
        await rig.engine.stop()
    }

    @Test("A run that fails shows the error and backs off, doubling with each failure in a row")
    func backoffAfterError() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        rig.google.failListings(with: .other(status: 500, message: "backend error"))

        await rig.engine.syncNow()
        var snapshot = await rig.snapshot
        guard case .failed = snapshot.status else {
            Issue.record("expected a failed status, got \(snapshot.status)")
            return
        }
        #expect(snapshot.nextAttemptAt == rig.clock.now().addingTimeInterval(60))
        let failed = rig.google.listings

        await rig.engine.trigger(.storeChanged)
        await rig.clock.waitForSleepers(2)
        await rig.advance(59)
        #expect(rig.google.listings == failed)
        await rig.advance(2)
        #expect(rig.google.listings == failed + 1, "retried after the minute, and failed again")
        snapshot = await rig.snapshot
        #expect(snapshot.nextAttemptAt == rig.clock.now().addingTimeInterval(120))

        rig.google.failListings(with: nil)
        await rig.engine.syncNow()
        snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.nextAttemptAt == nil && snapshot.lastRunAt != nil)
        await rig.engine.stop()
    }

    @Test("Once an account is saved, a run that cannot tell which account is signed in fails and retries; it is not an account change")
    func unknownEmailFailsTheRun() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        try #require(rig.state.googleAccount == "me@example.com")
        try await rig.base.setPhone("I1", "415-555-9999")
        rig.setAccountEmail(nil)
        let before = rig.google.listings

        await rig.engine.syncNow()
        let snapshot = await rig.snapshot
        guard case .failed(let message) = snapshot.status else {
            Issue.record("expected a failed status, got \(snapshot.status)")
            return
        }
        #expect(message.contains("which Google account") && snapshot.nextAttemptAt != nil)
        #expect(rig.google.listings == before, "Google was not read")
        #expect(try rig.state.pause == nil && rig.state.googleAccount == "me@example.com")
        let untouched = try await rig.base.googlePerson("people/c1")
        #expect(untouched.phoneNumbers?.map(\.value) != ["415-555-9999"])

        rig.setAccountEmail("me@example.com")
        await rig.engine.syncNow()
        #expect(await rig.snapshot.status == .idle)
        let pushed = try await rig.base.googlePerson("people/c1")
        #expect(pushed.phoneNumbers?.map(\.value) == ["415-555-9999"])
        await rig.engine.stop()
    }

    // MARK: pause and resume

    @Test("Saved review items are listed at launch, even when sync stays paused and no run completes")
    func savedReviewsListedAtLaunchWhilePaused() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        try rig.base.reviews.add(
            [ReviewCandidate(kind: .googleEdited, icloudID: "I1", resourceName: "people/c1", googleEtag: "e1", fields: [.nickname])], at: Date()
        )
        try rig.base.stateStore.update { $0.pause = .user }
        await rig.start()
        let shown = await firstSnapshot(of: rig) { !$0.reviewItems.isEmpty }
        #expect(shown?.reviewItems.map(\.kind) == [.googleEdited])
        #expect(shown?.reviewItems.first?.name != "Unknown contact")
        #expect(rig.google.listings == 0)
        await rig.engine.stop()
    }

    @Test("A run that stops for confirmation lists the saved review items and leaves them stored")
    func savedReviewsListedWhenConfirmationPauses() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        try rig.base.reviews.add(
            [ReviewCandidate(kind: .googleEdited, icloudID: "I4", resourceName: "people/c4", googleEtag: "e4", fields: [.nickname])], at: Date()
        )
        for id in ["I1", "I2", "I3"] { try await rig.base.world.store.delete(ids: [id], backup: .forTesting()) }
        await rig.start()
        await rig.engine.waitForRuns(1)
        let snapshot = await rig.snapshot
        #expect(snapshot.confirmationSummary != nil)
        #expect(snapshot.reviewItems.map(\.kind) == [.googleEdited])
        #expect(try rig.base.reviews.load().count == 1)
        await rig.engine.stop()
    }

    private func firstSnapshot(of rig: EngineRig, where condition: @escaping @Sendable (SyncSnapshot) -> Bool) async -> SyncSnapshot? {
        let stream = await rig.engine.snapshots()
        return await withTaskGroup(of: SyncSnapshot?.self) { group in
            group.addTask { for await snapshot in stream where condition(snapshot) { return snapshot }; return nil }
            group.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }


    @Test("Pause is the kill switch: saved, no trigger or Sync now reaches Google, and it holds in a new engine")
    func pauseStopsRuns() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.engine.pause()
        let paused = await rig.snapshot
        #expect(try paused.isUserPaused && rig.state.pause == .user)

        try await rig.base.setPhone("I1", "415-555-9999")
        for event in [SyncEvent.storeChanged, .timer, .wake] { await rig.engine.trigger(event) }
        await rig.advance(3600)
        await rig.engine.syncNow()
        #expect(rig.google.listings == first)
        let person = try await rig.base.googlePerson("people/c1")
        #expect(person.phoneNumbers?.map(\.value) != ["415-555-9999"])
        #expect(await rig.snapshot.status == .paused(.user))
        await rig.engine.stop()

        let next = EngineRig(rig.base)
        await next.start()
        await next.advance(3600)
        #expect(await next.snapshot.status == .paused(.user) && next.google.listings == 0)
        await next.engine.stop()
    }

    @Test("If the pause cannot be saved it still holds, Sync now included, and the screen is told it will not survive a relaunch")
    func pauseSaveFailure() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        try await rig.base.setPhone("I1", "415-555-9999")

        rig.flakyState.failWrites(true)
        await rig.engine.pause()
        let paused = await rig.snapshot
        #expect(paused.isUserPaused)
        let warning = try #require(paused.pauseSaveWarning)
        #expect(warning.contains("relaunch") && warning.contains("disk is full"))
        #expect(try rig.state.pause == nil, "nothing was saved")

        await rig.engine.syncNow()
        await rig.engine.trigger(.storeChanged)
        await rig.advance(3600)
        #expect(rig.google.listings == first, "the unsaved pause is still a pause")
        #expect(await rig.snapshot.status == .paused(.user))

        rig.flakyState.failWrites(false)
        await rig.engine.resume()
        let resumed = await rig.snapshot
        #expect(!resumed.isUserPaused && resumed.pauseSaveWarning == nil)
        #expect(rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("A pause that saves clears an earlier warning; a resume that cannot be saved stays paused and says so")
    func resumeSaveFailure() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        await rig.engine.pause()
        let clean = await rig.snapshot
        #expect(try clean.pauseSaveWarning == nil && rig.state.pause == .user)

        rig.flakyState.failWrites(true)
        await rig.engine.resume()
        let stuck = await rig.snapshot
        #expect(stuck.isUserPaused && stuck.status == .paused(.user))
        let warning = try #require(stuck.pauseSaveWarning)
        #expect(warning.contains("paused") && warning.contains("disk is full"))
        #expect(try rig.state.pause == .user && rig.google.listings == first)

        rig.flakyState.failWrites(false)
        await rig.engine.resume()
        let after = await rig.snapshot
        #expect(try after.pauseSaveWarning == nil && rig.state.pause == nil && rig.google.listings == first + 1)
        await rig.engine.stop()
    }

    @Test("Pausing during a run stops it; resuming clears the switch and runs once")
    func pauseDuringRunThenResume() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let first = await started(rig)
        try await rig.base.setPhone("I1", "415-555-9999")

        // The run is parked at the write gate, so it is "in flight" without touching Google.
        let (release, hold) = AsyncStream<Void>.makeStream()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let holder = Task { try await rig.gate.withLock { enteredSignal.yield(); for await _ in release { break } } }
        for await _ in entered { break }
        let updates = await rig.engine.snapshots()
        let running = Task { await rig.engine.syncNow() }
        for await update in updates where update.status == .running(.waitingForOtherChanges) { break }

        await rig.engine.pause()
        await running.value
        #expect(await rig.snapshot.status == .paused(.user))
        hold.yield(())
        try await holder.value
        #expect(rig.google.listings == first, "the cancelled run never read Google")

        await rig.engine.resume()
        let resumed = await rig.snapshot
        #expect(!resumed.isUserPaused)
        #expect(try rig.state.pause == nil)
        #expect(rig.google.listings == first + 1)
        let person = try await rig.base.googlePerson("people/c1")
        #expect(person.phoneNumbers?.map(\.value) == ["415-555-9999"])
        await rig.engine.stop()
    }

    // MARK: confirmation

    @Test("A run that wants to delete too much waits for the user; Confirm lets it through, and nothing else does")
    func confirmPath() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.base.world.store.delete(ids: [id], backup: .forTesting()) }

        await rig.start()
        await rig.engine.waitForRuns(1)
        let summary = try #require(await rig.snapshot.confirmationSummary)
        #expect(summary.contains("delete 3 of 6"))
        #expect(await rig.base.world.google.allPeople.count == 6)

        let listings = rig.google.listings
        await rig.engine.trigger(.storeChanged)
        await rig.advance(3600)
        #expect(rig.google.listings == listings, "no automatic run while the question is open")

        await rig.engine.confirmAndContinue()
        let snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.confirmationSummary == nil && snapshot.lastRun?.deleted == 3)
        #expect(await rig.base.world.google.allPeople.count == 3)
        await rig.engine.stop()
    }

    @Test("A pause about forgetting links carries the contacts' names beside the unchanged, name-free summary; Confirm and Keep paused clear them")
    func forgetLinksPauseCarriesNames() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        for n in 1...3 {
            try await rig.base.world.google.deleteContact(resourceName: "people/c\(n)")
            try await rig.base.world.store.delete(ids: ["I\(n)"], backup: .forTesting())
        }

        await rig.start()
        await rig.engine.waitForRuns(1)
        var snapshot = await rig.snapshot
        let summary = try #require(snapshot.confirmationSummary)
        #expect(summary.contains("forget 3 of 6 links to contacts gone from both sides") && !summary.contains("First1"))
        #expect(snapshot.pauseDetails.map(\.name) == ["First1 Last1", "First2 Last2", "First3 Last3"])
        #expect(snapshot.pauseDetails.map(\.id) == ["I1", "I2", "I3"] && snapshot.pauseDetails.allSatisfy { $0.detail == "gone from iCloud and Google" })
        #expect(try rig.base.links.count == 6, "nothing is forgotten before the user confirms")

        await rig.engine.keepPaused()
        snapshot = await rig.snapshot
        #expect(snapshot.status == .paused(.user) && snapshot.pauseDetails.isEmpty)
        await rig.engine.resume()
        #expect(await rig.snapshot.pauseDetails.count == 3, "asked again, with the same names")

        await rig.engine.confirmAndContinue()
        snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.confirmationSummary == nil && snapshot.pauseDetails.isEmpty)
        #expect(try rig.base.links.keys.sorted() == ["I4", "I5", "I6"])
        await rig.engine.stop()
    }

    /// Three contacts deleted on both sides and Google's sync token expired: the full listing lacks 3 of 6 linked contacts
    /// (the Google-missing guard) and, once that is allowed, the plan forgets 3 links (the forget-links guard).
    private func stackedGuardsRig() async throws -> EngineRig {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        for n in 1...3 {
            try await rig.base.world.google.deleteContact(resourceName: "people/c\(n)")
            try await rig.base.world.store.delete(ids: ["I\(n)"], backup: .forTesting())
        }
        await rig.base.world.google.expireSyncTokens()
        return rig
    }

    @Test("Two guards in a row: confirming the first and then the second lets the run through, with no third question")
    func stackedConfirmations() async throws {
        let rig = try await stackedGuardsRig()
        defer { rig.cleanUp() }
        _ = await started(rig)

        let first = try #require(await rig.snapshot.confirmationSummary)
        #expect(first.hasPrefix(SyncPlanner.googleMissingSummaryPrefix))
        await rig.engine.confirmAndContinue()
        let second = try #require(await rig.snapshot.confirmationSummary)
        #expect(second.contains("forget 3 of 6") && second != first)
        #expect(await rig.snapshot.pauseDetails.count == 3)

        await rig.engine.confirmAndContinue()
        let snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.confirmationSummary == nil && snapshot.pauseDetails.isEmpty)
        #expect(try rig.base.links.keys.sorted() == ["I4", "I5", "I6"])
        await rig.engine.stop()
    }

    @Test("Keep paused forgets what was confirmed: resuming asks the first question again")
    func keepPausedClearsConfirmations() async throws {
        let rig = try await stackedGuardsRig()
        defer { rig.cleanUp() }
        _ = await started(rig)
        await rig.engine.confirmAndContinue()
        #expect(await rig.snapshot.confirmationSummary?.contains("forget 3 of 6") == true)

        await rig.engine.keepPaused()
        await rig.engine.resume()
        #expect(await rig.snapshot.confirmationSummary?.hasPrefix(SyncPlanner.googleMissingSummaryPrefix) == true)
        #expect(try rig.base.links.count == 6)
        await rig.engine.stop()
    }

    @Test("A confirmation never carries over to a later, different run: a new summary asks again")
    func staleConfirmationsDoNotCarryOver() async throws {
        let rig = try await stackedGuardsRig()
        defer { rig.cleanUp() }
        _ = await started(rig)
        await rig.engine.confirmAndContinue()
        await rig.engine.confirmAndContinue()
        #expect(await rig.snapshot.status == .idle)

        // Later: more contacts vanish from Google and the token expires again. Different counts, so a fresh question.
        for n in 4...5 {
            try await rig.base.world.google.deleteContact(resourceName: "people/c\(n)")
            try await rig.base.world.store.delete(ids: ["I\(n)"], backup: .forTesting())
        }
        await rig.base.world.google.expireSyncTokens()
        await rig.engine.syncNow()
        let again = try #require(await rig.snapshot.confirmationSummary)
        #expect(again.hasPrefix(SyncPlanner.googleMissingSummaryPrefix) && again.contains("2 of 3"))
        #expect(try rig.base.links.keys.sorted() == ["I4", "I5", "I6"], "nothing was forgotten without a new OK")
        await rig.engine.stop()
    }

    @Test("Keep paused turns the confirmation into the kill switch; resuming asks again")
    func keepPaused() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.base.world.store.delete(ids: [id], backup: .forTesting()) }
        await rig.start()
        await rig.engine.waitForRuns(1)

        await rig.engine.keepPaused()
        #expect(await rig.snapshot.status == .paused(.user))
        await rig.engine.resume()
        #expect(await rig.snapshot.confirmationSummary != nil)
        #expect(await rig.base.world.google.allPeople.count == 6)
        await rig.engine.stop()
    }

    @Test("When Google stops listing many linked contacts, Confirm re-plans with the deletions allowed: reviews, never deletes")
    func confirmMassMissing() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        _ = await started(rig)
        for name in ["people/c1", "people/c2", "people/c3"] { try await rig.base.world.google.deleteContact(resourceName: name) }
        await rig.base.world.google.expireSyncTokens()

        await rig.engine.syncNow()
        let summary = try #require(await rig.snapshot.confirmationSummary)
        #expect(summary.contains("no longer lists 3 of 6"))
        #expect(try rig.base.reviews.load().isEmpty)

        await rig.engine.confirmAndContinue()
        let snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.pendingReviews == 3)
        #expect(snapshot.reviewItems.allSatisfy { $0.kind == .deletedInGoogle } && snapshot.reviewItems.map(\.name).contains("First1 Last1"))
        let kept = try await rig.base.world.store.fetchAll().count
        #expect(kept == 6, "nothing is deleted from iCloud")
        await rig.engine.stop()
    }

    // MARK: recovery and the published counts

    @Test("An interrupted run is settled before the next plan, so the contact it created is linked, not created twice")
    func recoveryBeforePlan() async throws {
        let rig = try await EngineRig.linked(count: 2)
        defer { rig.cleanUp() }
        _ = await started(rig)
        let carol = try await rig.base.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        rig.base.faulty.arm(.crashAfterApply, on: .batchCreate)

        await rig.engine.syncNow()
        guard case .failed = await rig.snapshot.status else {
            Issue.record("the crashed run should show as failed")
            return
        }
        #expect(try rig.base.journal.load().entries.count == 1 && rig.base.links[carol.sourceIdentifier] == nil)

        await rig.engine.syncNow()
        #expect(await rig.base.taggedPeople(carol.sourceIdentifier).count == 1)
        #expect(try rig.base.journal.load().entries.isEmpty && rig.base.links[carol.sourceIdentifier]?.origin == .createdInGoogle)
        #expect(await rig.snapshot.status == .idle)
        await rig.engine.stop()
    }

    @Test("Creates Google may or may not have applied are counted as waiting to confirm until a listing settles them")
    func unconfirmedCreates() async throws {
        let rig = try await EngineRig.linked(count: 2)
        defer { rig.cleanUp() }
        _ = await started(rig)
        let carol = try await rig.base.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        rig.base.faulty.setListingLag(true)
        rig.base.faulty.arm(.ambiguousAfterApply, on: .batchCreate)

        await rig.engine.syncNow()
        #expect(await rig.snapshot.unconfirmedCreates == 1)
        rig.clock.advance(by: 60)
        await rig.engine.syncNow()
        #expect(await rig.snapshot.unconfirmedCreates == 1, "held, not created again")

        rig.base.faulty.setListingLag(false)
        rig.clock.advance(by: 11 * 60)
        await rig.engine.syncNow()
        #expect(await rig.snapshot.unconfirmedCreates == 0)
        let tagged = await rig.base.taggedPeople(carol.sourceIdentifier)
        #expect(try tagged.count == 1 && rig.base.links[carol.sourceIdentifier] != nil)
        await rig.engine.stop()
    }

    @Test("Unreadable notes show as waiting contacts and a notes warning; the new contact is not created without its note")
    func notesUnavailable() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        try await rig.base.addICloudContact("Carol", "Newman", phone: "415-555-0100")
        struct Denied: Error {}
        rig.base.world.notes.setReadError(Denied())

        await rig.engine.syncNow()
        let snapshot = await rig.snapshot
        #expect(snapshot.notesUnavailable && snapshot.waitingForNotes == 1 && snapshot.status == .idle)
        #expect(await rig.base.world.google.allPeople.count == 6)
        await rig.engine.stop()
    }

    @Test("Stored review items are listed by kind and name")
    func reviewList() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        try await rig.base.world.editGoogle("people/c2", mask: "phoneNumbers") {
            $0.phoneNumbers = [GooglePhoneNumber(value: "415-555-7777", type: "mobile")]
        }
        await rig.engine.syncNow()
        let snapshot = await rig.snapshot
        #expect(snapshot.pendingReviews == 1)
        let item = try #require(snapshot.reviewItems.first)
        #expect(item.kind == .googleEdited && item.name == "First2 Last2" && item.fields == [.phones])
        await rig.engine.stop()
    }

    @Test("A preview refresh that fails keeps the old preview and reports the failure, so the screen can show both")
    func failedPreviewRefresh() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        let shown = try #require(await rig.snapshot.preview)

        rig.google.failListings(with: .other(status: 503, message: "Backend unavailable"))
        await rig.engine.refreshPreview()
        let snapshot = await rig.snapshot
        guard case .failed(let message) = snapshot.status else { Issue.record("expected a failure, got \(snapshot.status)"); return }
        #expect(message.contains("503") || message.contains("Backend unavailable"))
        #expect(snapshot.preview == shown)
        await rig.engine.stop()
    }

    @Test("Pairs the user chose to keep separate are handed to the planner: the iCloud contact is created, not offered as a match")
    func keepSeparateHonoured() async throws {
        let world = SyncWorld(
            icloud: [SyncFixtures.icloud("I1", "Ann", "Lee", phones: ["415-555-2671"])], google: [SyncFixtures.person("Ann", "Lee")]
        )
        world.state.keepSeparate = ["I1|people/c1"]
        let rig = EngineRig(try ExecutorRig(world))
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        let preview = try #require(await rig.snapshot.preview)
        #expect(preview.creates.map(\.name) == ["Ann Lee"] && preview.reviews.map(\.kind) == [.newInGoogle])
        await rig.engine.stop()
    }

    // MARK: not ready, lock

    @Test("Without a usable environment the run says what is missing and touches nothing; fixing it lets the next trigger run")
    func notReady() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        rig.setNotReady("Sign in with Google in Setup first.")
        await rig.start()
        await rig.engine.waitForRuns(1)
        let waiting = await rig.snapshot
        #expect(waiting.status == .notReady("Sign in with Google in Setup first.") && rig.google.listings == 0)

        rig.setNotReady(nil)
        await rig.engine.trigger(.settingsChanged)
        await rig.clock.waitForSleepers(2)
        await rig.advance(10)
        #expect(await rig.snapshot.status == .idle && rig.google.listings == 1)
        await rig.engine.stop()
    }

    @Test("If another copy holds the lock, syncing is off in this one: no run, no preview, no approval")
    func lockHeldElsewhere() async throws {
        let rig = try await EngineRig.linked(acquireLock: { throw SyncLockError.heldByAnotherInstance })
        defer { rig.cleanUp() }
        await rig.engine.start()
        guard case .disabled(let message) = await rig.snapshot.status else {
            Issue.record("expected a disabled status")
            return
        }
        #expect(message == SyncLockError.heldByAnotherInstance.localizedDescription)
        await rig.engine.trigger(.storeChanged)
        await rig.advance(3600)
        await rig.engine.syncNow()
        await rig.engine.refreshPreview()
        #expect(rig.google.listings == 0)
        #expect(await rig.engine.approveFirstSync() == .unavailable(message))
        await rig.engine.pause()
        #expect(try rig.state.pause == nil)
    }

    @Test("The engine takes the lock when it starts and gives it back when it stops")
    func lockLifecycle() async throws {
        final class Held: SyncLockHolding, Sendable {
            let released = Mutex(false)
            func release() { released.withLock { $0 = true } }
        }
        let held = Held()
        let rig = try await EngineRig.linked(acquireLock: { held })
        defer { rig.cleanUp() }
        await rig.engine.start()
        #expect(!held.released.withLock { $0 })
        await rig.engine.stop()
        #expect(held.released.withLock { $0 })
    }

    // MARK: edge cases

    @Test("A trigger that arrives during a run that then fails waits out the back-off instead of retrying at once")
    func triggerDuringFailingRun() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        _ = await started(rig)
        let held = rig.google.blockNextListing()
        rig.google.failListings(with: .other(status: 500, message: "backend error"))
        let running = Task { await rig.engine.syncNow() }
        for await _ in held.entered { break }

        await rig.engine.trigger(.storeChanged) // due ten seconds from now, before the back-off the failure will start
        await rig.clock.waitForSleepers(2)
        held.release.yield(())
        await running.value
        guard case .failed = await rig.snapshot.status else {
            Issue.record("the run should have failed")
            return
        }
        let failed = rig.google.listings

        await rig.advance(10)
        #expect(rig.google.listings == failed, "the waiter fired inside the back-off and must not run")
        guard rig.google.listings == failed else { return }
        await rig.clock.waitForSleepers(2) // re-armed for the end of the back-off
        rig.google.failListings(with: nil)
        await rig.advance(49)
        #expect(rig.google.listings == failed)
        await rig.advance(1)
        #expect(rig.google.listings == failed + 1)
        let snapshot = await rig.snapshot
        #expect(snapshot.status == .idle && snapshot.nextAttemptAt == nil)
        await rig.engine.stop()
    }

    @Test("Start syncing refuses while the kill switch is on")
    func approveWhilePaused() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        await rig.engine.pause()
        guard case .unavailable = await rig.engine.approveFirstSync() else {
            Issue.record("approval should be refused while paused")
            return
        }
        let people = await rig.base.world.google.allPeople.count
        #expect(try !rig.state.firstSyncApproved && people == 1)
        await rig.engine.resume()
        #expect(await rig.engine.approveFirstSync() == .started)
        await rig.engine.stop()
    }

    @Test("A run that fails after the approval was saved still reports that syncing started")
    func failureAfterApproval() async throws {
        let rig = try firstSyncRig()
        defer { rig.cleanUp() }
        await rig.start()
        await rig.engine.refreshPreview()
        rig.base.faulty.arm(.crashAfterApply, on: .batchCreate)

        #expect(await rig.engine.approveFirstSync() == .started)
        let snapshot = await rig.snapshot
        #expect(snapshot.firstSyncApproved)
        guard case .failed = snapshot.status else {
            Issue.record("the first run should show as failed")
            return
        }
        #expect(try rig.state.firstSyncApproved)
        await rig.engine.stop()
    }

    @Test("Confirming a delete guard does not wave through a different, mass-missing pause that appeared since")
    func confirmOnlyWhatWasShown() async throws {
        var limits = SyncPlanner.Limits()
        limits.minDeletes = 1
        let rig = try await EngineRig.linked(planner: SyncPlanner(limits: limits))
        defer { rig.cleanUp() }
        for id in ["I1", "I2", "I3"] { try await rig.base.world.store.delete(ids: [id], backup: .forTesting()) }
        await rig.start()
        await rig.engine.waitForRuns(1)
        let shown = try #require(await rig.snapshot.confirmationSummary)
        #expect(shown.contains("delete 3 of 6"))

        for name in ["people/c4", "people/c5", "people/c6"] { try await rig.base.world.google.deleteContact(resourceName: name) }
        await rig.base.world.google.expireSyncTokens()
        await rig.engine.confirmAndContinue()

        let summary = try #require(await rig.snapshot.confirmationSummary)
        #expect(summary.hasPrefix(SyncPlanner.googleMissingSummaryPrefix) && summary != shown)
        #expect(await rig.base.world.google.allPeople.count == 3, "nothing was deleted on the strength of the old confirmation")
        await rig.engine.stop()
    }

    @Test("A run queued behind another cannot start once the engine has stopped")
    func stopBeatsQueuedRun() async throws {
        let rig = try await EngineRig.linked()
        defer { rig.cleanUp() }
        let before = await started(rig)
        let (release, hold) = AsyncStream<Void>.makeStream()
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let holder = Task { try await rig.gate.withLock { enteredSignal.yield(); for await _ in release { break } } }
        for await _ in entered { break }
        let updates = await rig.engine.snapshots()
        let first = Task { await rig.engine.syncNow() }
        for await update in updates where update.status == .running(.waitingForOtherChanges) { break }
        let second = Task { await rig.engine.syncNow() }

        await rig.engine.stop()
        await first.value
        await second.value
        hold.yield(())
        try await holder.value
        #expect(rig.google.listings == before)
    }

    // MARK: stale first-link conflicts

    /// A first-link conflict as Phase 2 stored it: pinned, because the baseline already holds both sides.
    private func pinFirstLinkConflict(_ rig: EngineRig, _ id: String, _ resourceName: String) throws -> String {
        let baseline = try #require(try rig.state.baselines[id])
        let candidate = ReviewCandidate(kind: .bothEdited, icloudID: id, resourceName: resourceName, googleEtag: baseline.googleEtag, fields: [.phones])
        var plan = SyncPlan(isPreview: false)
        plan.review = [candidate]
        plan.links = [PlannedLink(icloudID: id, resourceName: resourceName, origin: .matched, isNewLink: true, baseline: baseline, reasons: [])]
        try rig.base.reviews.reconcile(with: plan, at: SyncFixtures.t0)
        return candidate.id
    }

    @Test("A pinned first-link conflict whose sides agree is cleared by the next full read, and nothing is written")
    func clearsSettledPinnedConflict() async throws {
        let rig = try await EngineRig.linked(count: 2)
        defer { rig.cleanUp() }
        let stale = try pinFirstLinkConflict(rig, "I1", "people/c1")
        let real = try pinFirstLinkConflict(rig, "I2", "people/c2")
        try await rig.base.world.editGoogle("people/c2", mask: "phoneNumbers") {
            $0.phoneNumbers = ($0.phoneNumbers ?? []) + [GooglePhoneNumber(value: "415-555-0099", type: "home")]
        }
        let people = await rig.base.world.google.allPeople
        let contacts = try await rig.base.world.store.fetchAll()

        await rig.start()
        await rig.engine.waitForRuns(1)
        #expect(try rig.base.reviews.load().map(\.id).contains(stale), "iCloud was not read in the first run: nothing is known about the pair")

        await rig.engine.syncNow()
        let left = try rig.base.reviews.load().map(\.id)
        #expect(!left.contains(stale) && left.contains(real), "\(left)")
        let peopleAfter = await rig.base.world.google.allPeople
        let contactsAfter = try await rig.base.world.store.fetchAll()
        #expect(peopleAfter == people && contactsAfter == contacts)
        await rig.engine.stop()
    }
}
