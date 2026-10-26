import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncNoticeTests {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func review(_ id: String) -> SyncReviewSummary {
        SyncReviewSummary(id: id, kind: .googleEdited, name: id, detail: nil, fields: [.phones])
    }

    /// A snapshot after finished run number `run` (run times differ so each counts as a new run).
    private func settled(_ ids: [String] = [], run: Double = 1, halted: String? = nil) -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        snapshot.status = .idle
        snapshot.firstSyncApproved = true
        snapshot.lastRunAt = Self.t0.addingTimeInterval(run * 60)
        var report = SyncRunReport()
        report.halted = halted
        snapshot.lastRun = SyncRunSummary(finishedAt: snapshot.lastRunAt ?? Self.t0, report: report)
        snapshot.reviewItems = ids.map(review)
        return snapshot
    }

    private func with(_ status: SyncStatus, from base: SyncSnapshot = SyncSnapshot()) -> SyncSnapshot {
        var snapshot = base
        snapshot.status = status
        return snapshot
    }

    // MARK: reviews

    @Test("A review item that was not there before is announced once, with the total waiting")
    func reviewAppears() {
        var tracker = SyncNoticeTracker()
        #expect(tracker.observe(with(.idle)).isEmpty)
        let update = tracker.observe(settled(["a", "b"]))
        #expect(update.post.count == 1)
        let notice = update.post.first
        #expect(notice?.kind == .reviews && notice?.body == "2 contacts need your review" && notice?.destination == .reviewList)
        // The same list again, and snapshots in between, say nothing more.
        #expect(tracker.observe(settled(["a", "b"])).isEmpty)
        #expect(tracker.observe(with(.running(.planning), from: settled(["a", "b"]))).isEmpty)
        #expect(tracker.observe(settled(["a", "b"], run: 2)).isEmpty)
    }

    @Test("One item reads as singular")
    func singular() {
        var tracker = SyncNoticeTracker()
        #expect(tracker.observe(settled(["a"])).post.first?.body == "1 contact needs your review")
    }

    @Test("Review items already stored at launch are not announced, new ones are")
    func knownAtLaunch() {
        var tracker = SyncNoticeTracker(knownReviewIDs: ["a", "b"])
        #expect(tracker.observe(with(.idle)).isEmpty)
        #expect(tracker.observe(settled(["a", "b"])).isEmpty)
        let update = tracker.observe(settled(["a", "b", "c"], run: 2))
        #expect(update.post.first?.body == "3 contacts need your review")
    }

    @Test("The empty list before the first finished run is not read as everything settled")
    func emptyBeforeFirstRun() {
        var tracker = SyncNoticeTracker(knownReviewIDs: ["a"])
        var starting = SyncSnapshot()
        starting.status = .idle
        #expect(tracker.observe(starting).isEmpty)
        #expect(tracker.observe(settled(["a"])).isEmpty)
    }

    @Test("A shrinking list says nothing; a replacement item does, and an emptied list retracts the notice")
    func shrinkReplaceClear() {
        var tracker = SyncNoticeTracker()
        #expect(tracker.observe(settled(["a", "b"])).post.count == 1)
        #expect(tracker.observe(settled(["a"], run: 2)).isEmpty)
        let replaced = tracker.observe(settled(["c"], run: 3))
        #expect(replaced.post.count == 1 && replaced.post.first?.body == "1 contact needs your review")
        let cleared = tracker.observe(settled([], run: 4))
        #expect(cleared.post.isEmpty && cleared.retract == [.reviews])
        #expect(tracker.observe(settled([], run: 5)).isEmpty)
        // The same item coming back is news again.
        #expect(tracker.observe(settled(["c"], run: 6)).post.count == 1)
    }

    // MARK: pauses

    @Test("A confirmation pause is announced once, points at the confirmation, and is retracted when syncing runs again")
    func confirmationPause() {
        var tracker = SyncNoticeTracker()
        let paused = with(.paused(.needsConfirmation(summary: "12 deletes")), from: settled())
        let update = tracker.observe(paused)
        #expect(update.post.count == 1 && update.post.first?.kind == .pause)
        #expect(update.post.first?.destination == .confirmation && update.post.first?.body == "12 deletes")
        #expect(tracker.observe(paused).isEmpty)

        // The engine passes through "running" on every re-check; that must not re-announce the same pause.
        #expect(tracker.observe(with(.running(.planning), from: paused)).isEmpty)
        #expect(tracker.observe(paused).isEmpty)

        #expect(tracker.observe(with(.paused(.needsConfirmation(summary: "40 updates")), from: paused)).post.count == 1)
        #expect(tracker.observe(settled(run: 2)).retract == [.pause])
        #expect(tracker.observe(settled(run: 3)).retract.isEmpty)
    }

    @Test("Account, container and empty-listing pauses are announced; the user's own pause is not")
    func otherPauses() {
        for reason in [PauseReason.accountChanged, .containerChanged, .googleEmpty] {
            var tracker = SyncNoticeTracker()
            let update = tracker.observe(with(.paused(reason), from: settled()))
            #expect(update.post.first?.title == "Syncing is paused" && update.post.first?.body == reason.explanation)
            #expect(update.post.first?.destination == .status)
        }
        var tracker = SyncNoticeTracker()
        #expect(tracker.observe(with(.paused(.user), from: settled())).isEmpty)
        #expect(tracker.observe(with(.paused(.notesUnavailable), from: settled())).isEmpty)
    }

    @Test("Pausing yourself after a confirmation retracts the stale notice")
    func keepPausedRetracts() {
        var tracker = SyncNoticeTracker()
        _ = tracker.observe(with(.paused(.needsConfirmation(summary: "x")), from: settled()))
        #expect(tracker.observe(with(.paused(.user), from: settled())).retract == [.pause])
    }

    // MARK: failures

    @Test("Only the second failure in a row is announced, once, and a good run clears it")
    func failureStreak() {
        var tracker = SyncNoticeTracker()
        var failed = with(.failed("offline"), from: settled())
        #expect(tracker.observe(failed).isEmpty)
        #expect(tracker.observe(with(.running(.readingGoogle), from: failed)).isEmpty)
        failed.nextAttemptAt = Self.t0
        let second = tracker.observe(with(.failed("offline"), from: failed))
        #expect(second.post.count == 1 && second.post.first?.kind == .failing && second.post.first?.body == "offline")
        #expect(tracker.observe(with(.running(.readingGoogle), from: failed)).isEmpty)
        #expect(tracker.observe(with(.failed("offline"), from: failed)).isEmpty)

        #expect(tracker.observe(settled(run: 2)).retract == [.failing])
        // A new streak starts from zero.
        #expect(tracker.observe(with(.failed("again"), from: settled(run: 2))).isEmpty)
    }

    @Test("A snapshot that only changes other fields while failed does not count again")
    func failureSnapshotsInPlace() {
        var tracker = SyncNoticeTracker()
        var failed = with(.failed("offline"), from: settled())
        _ = tracker.observe(failed)
        failed.nextAttemptAt = Self.t0.addingTimeInterval(60)
        #expect(tracker.observe(failed).isEmpty)
    }

    @Test("Runs that stop early count as failures; a good run in between resets the streak")
    func haltedRuns() {
        var tracker = SyncNoticeTracker()
        #expect(tracker.observe(settled(run: 1, halted: "rate limited")).isEmpty)
        #expect(tracker.observe(settled(run: 1, halted: "rate limited")).isEmpty) // same run again
        #expect(tracker.observe(settled(run: 2)).isEmpty)
        #expect(tracker.observe(settled(run: 3, halted: "rate limited")).isEmpty)
        let update = tracker.observe(settled(run: 4, halted: "signed out"))
        #expect(update.post.first?.body == "signed out")
    }

    // MARK: states that never notify

    @Test("Starting up, setup problems and a disabled engine say nothing")
    func quietStates() {
        var tracker = SyncNoticeTracker()
        for status in [SyncStatus.notStarted, .disabled("another copy"), .notReady("sign in"), .idle, .running(.applying)] {
            #expect(tracker.observe(with(status)).isEmpty)
        }
    }
}
