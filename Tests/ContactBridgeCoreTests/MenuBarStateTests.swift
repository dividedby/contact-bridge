import Foundation
import Testing
@testable import ContactBridgeCore

struct MenuBarStateTests {
    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ status: SyncStatus, approved: Bool = true, reviews: Int = 0, ran: Bool = true, halted: String? = nil) -> MenuBarState {
        var snapshot = SyncSnapshot()
        snapshot.status = status
        snapshot.firstSyncApproved = approved
        if ran {
            snapshot.lastRunAt = Self.at
            var report = SyncRunReport()
            report.halted = halted
            snapshot.lastRun = SyncRunSummary(finishedAt: Self.at, report: report)
        }
        snapshot.reviewItems = (0..<reviews).map { SyncReviewSummary(id: "r\($0)", kind: .googleEdited, name: "n", detail: nil, fields: []) }
        return MenuBarState(snapshot, timeText: { _ in "3:41 PM" })
    }

    @Test("The status line for each state")
    func statusLines() {
        #expect(state(.idle).statusLine == "Synced at 3:41 PM")
        #expect(state(.running(.readingGoogle)).statusLine == "Syncing…")
        #expect(state(.paused(.user)).statusLine == "Paused")
        #expect(state(.paused(.needsConfirmation(summary: "x"))).statusLine == "Waiting for your OK")
        #expect(state(.paused(.accountChanged)).statusLine == "Paused: the Google account changed")
        #expect(state(.paused(.containerChanged)).statusLine == "Paused: the iCloud account changed")
        #expect(state(.disabled("another copy")).statusLine == "Syncing is off")
        #expect(state(.notStarted, approved: false, ran: false).statusLine == "Starting…")
        #expect(state(.notReady("sign in"), approved: false, ran: false).statusLine == "Finish setup in Contact Bridge")
        #expect(state(.failed("offline")).statusLine == "Last sync failed, will retry")
        #expect(state(.idle, approved: false, ran: false).statusLine == "Syncing has not started")
        #expect(state(.idle, ran: false).statusLine == "Waiting for the first sync")
        #expect(state(.idle, halted: "rate limited").statusLine == "Stopped early, will retry")
    }

    @Test("The icon: attention for reviews or a confirmation, syncing, paused, otherwise normal")
    func icons() {
        #expect(state(.idle).icon == .normal)
        #expect(state(.idle, reviews: 2).icon == .needsAttention)
        #expect(state(.running(.applying)).icon == .syncing)
        #expect(state(.running(.applying), reviews: 2).icon == .syncing)
        #expect(state(.paused(.user)).icon == .paused)
        #expect(state(.paused(.user), reviews: 1).icon == .paused)
        #expect(state(.paused(.accountChanged)).icon == .paused)
        #expect(state(.paused(.needsConfirmation(summary: "x"))).icon == .needsAttention)
    }

    @Test("The review line appears only when something waits")
    func reviewLine() {
        #expect(state(.idle).reviewLine == nil)
        #expect(state(.idle, reviews: 1).reviewLine == "1 to review")
        #expect(state(.idle, reviews: 12).reviewLine == "12 to review")
    }

    @Test("Sync now and Pause or Resume are offered only when they can work")
    func commands() {
        let idle = state(.idle)
        #expect(idle.canSyncNow && idle.pauseControl == .pause)

        let running = state(.running(.planning))
        #expect(!running.canSyncNow && running.pauseControl == .pause)

        let paused = state(.paused(.user))
        #expect(!paused.canSyncNow && paused.pauseControl == .resume)

        let confirming = state(.paused(.needsConfirmation(summary: "x")))
        #expect(!confirming.canSyncNow && confirming.needsConfirmation && confirming.pauseControl == .pause)

        let accountPause = state(.paused(.accountChanged))
        #expect(accountPause.canSyncNow && accountPause.pauseControl == .pause)

        let failed = state(.failed("x"))
        #expect(failed.canSyncNow && failed.pauseControl == .pause)

        let notApproved = state(.idle, approved: false, ran: false)
        #expect(!notApproved.canSyncNow && notApproved.pauseControl == .none)

        for off in [state(.disabled("x"), approved: false, ran: false), state(.notStarted, approved: false, ran: false)] {
            #expect(!off.canSyncNow && off.pauseControl == .none)
        }
    }

    @Test("Times read as a time of day today and with the date on other days")
    func timeText() {
        let calendar = Calendar(identifier: .gregorian)
        let today = MenuBarState.defaultTimeText(Self.at, now: Self.at.addingTimeInterval(60), calendar: calendar)
        let earlier = MenuBarState.defaultTimeText(Self.at, now: Self.at.addingTimeInterval(3 * 86_400), calendar: calendar)
        #expect(today == Self.at.formatted(date: .omitted, time: .shortened))
        #expect(earlier == Self.at.formatted(date: .abbreviated, time: .shortened) && earlier != today)
    }
}

struct ActivationRulesTests {
    private let window = WindowTraits(isTitled: true, isPanel: false, isShownOrParked: true)

    @Test("An app window keeps the app regular; with none it is menu-bar only")
    func presence() {
        #expect(ActivationRules.presence(for: []) == .menuBarOnly)
        #expect(ActivationRules.presence(for: [window]) == .regular)
        #expect(ActivationRules.presence(for: [window, window]) == .regular)
    }

    @Test("Status item windows, panels and closed windows do not count")
    func notAppWindows() {
        let statusItem = WindowTraits(isTitled: false, isPanel: false, isShownOrParked: true)
        let panel = WindowTraits(isTitled: true, isPanel: true, isShownOrParked: true)
        let closed = WindowTraits(isTitled: true, isPanel: false, isShownOrParked: false)
        #expect(ActivationRules.presence(for: [statusItem, panel, closed]) == .menuBarOnly)
        #expect(ActivationRules.presence(for: [statusItem, panel, closed, window]) == .regular)
    }

    @Test("Only a launch at login with Start in menu bar on starts without a window")
    func launchWindow() {
        #expect(ActivationRules.showsWindowAtLaunch(launchedAtLogin: false, startInMenuBar: true))
        #expect(ActivationRules.showsWindowAtLaunch(launchedAtLogin: false, startInMenuBar: false))
        #expect(ActivationRules.showsWindowAtLaunch(launchedAtLogin: true, startInMenuBar: false))
        #expect(!ActivationRules.showsWindowAtLaunch(launchedAtLogin: true, startInMenuBar: true))
    }

    @Test("While suppressing, only an app window that is on screen is put away")
    func hideForLaunch() {
        let panel = WindowTraits(isTitled: true, isPanel: true, isShownOrParked: true)
        let statusItem = WindowTraits(isTitled: false, isPanel: false, isShownOrParked: true)
        #expect(ActivationRules.shouldHideForLaunch(window, isOnScreen: true, suppressing: true))
        #expect(!ActivationRules.shouldHideForLaunch(window, isOnScreen: false, suppressing: true))
        #expect(!ActivationRules.shouldHideForLaunch(window, isOnScreen: true, suppressing: false))
        #expect(!ActivationRules.shouldHideForLaunch(panel, isOnScreen: true, suppressing: true))
        #expect(!ActivationRules.shouldHideForLaunch(statusItem, isOnScreen: true, suppressing: true))
    }
}
