import AppKit
import ContactBridgeCore
import Foundation

/// Everything the app talks to the outside world through, so the live app, `--demo` and previews differ only here.
struct AppDependencies {
    var isDemo: Bool
    /// A store for the given container id (nil: no container chosen yet; only authorization calls are made on it).
    var makeStore: (_ containerID: String?) -> any ContactStoring
    var containerLister: any ContactContainerListing
    var notes: any NotesStoring
    var links: any LinkStoring
    var dismissals: any DismissalStoring
    /// The sync files (baselines and switches, review list, journal, history).
    var syncState: any SyncStateStoring
    var reviews: any ReviewStoring
    var syncJournal: any SyncJournalStoring
    var syncHistory: any SyncHistoryStoring
    /// Held by sync runs and by Import, Merge and Clean up, so they never interleave.
    var writeGate: WriteGate
    /// The second-instance guard, taken when sync starts. Nil in demo mode, which must not claim the real lock.
    var acquireSyncLock: (@Sendable () throws -> any SyncLockHolding)?
    /// Whether Contacts is running, so a background sync may read notes without launching it.
    var contactsAppRunning: @Sendable () -> Bool
    var backupDirectory: URL
    var defaults: UserDefaults
    /// "Open at login". Live: `SMAppService.mainApp`. Demo: a fake that registers nothing.
    var loginItem: any LoginItemControlling
    /// System notifications, or nil where they must not run (demo mode, a process that is not an installed app).
    var notifications: (any NotificationDelivering)?
    /// Said under the "Notify me" switch when `notifications` is nil.
    var notificationsUnavailableReason: String?
    var signIn: SignInController
    /// The People API client for the current sign-in, or nil when signed out.
    var googleClient: @MainActor (SignInController) -> (any GoogleContactsClient)?

    /// `--demo` on the command line, or CONTACT_BRIDGE_DEMO set to anything but "" and "0".
    static var demoRequested: Bool {
        if CommandLine.arguments.contains("--demo") { return true }
        let value = ProcessInfo.processInfo.environment["CONTACT_BRIDGE_DEMO"] ?? ""
        return !value.isEmpty && value != "0"
    }

    /// `--demo-notifications` (with `--demo`), or CONTACT_BRIDGE_DEMO_NOTIFICATIONS set to anything but "" and "0": a demo run
    /// that may show real notifications, to try them out.
    static var demoNotificationsRequested: Bool {
        if CommandLine.arguments.contains("--demo-notifications") { return true }
        let value = ProcessInfo.processInfo.environment["CONTACT_BRIDGE_DEMO_NOTIFICATIONS"] ?? ""
        return !value.isEmpty && value != "0"
    }

    /// `--demo-forget-links` (with `--demo`), or CONTACT_BRIDGE_DEMO_FORGET_LINKS set to anything but "" and "0": the demo also
    /// holds old links to six deleted contacts, so Start syncing leads to the "forget old links" confirmation.
    static var demoForgetLinksRequested: Bool {
        if CommandLine.arguments.contains("--demo-forget-links") { return true }
        let value = ProcessInfo.processInfo.environment["CONTACT_BRIDGE_DEMO_FORGET_LINKS"] ?? ""
        return !value.isEmpty && value != "0"
    }

    @MainActor
    static func live() -> AppDependencies {
        let adapter = CNContactStoreAdapter()
        return AppDependencies(
            isDemo: false,
            makeStore: { CNContactStoreAdapter(containerID: $0) },
            containerLister: adapter,
            notes: ContactsAppNotesProvider(),
            links: LinkStore(),
            dismissals: DismissalStore(),
            syncState: SyncStateStore(),
            reviews: ReviewStore(),
            syncJournal: SyncJournalStore(),
            syncHistory: SyncHistoryStore(),
            writeGate: WriteGate(),
            acquireSyncLock: { try SyncProcessLock.acquire() },
            contactsAppRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.AddressBook").isEmpty },
            backupDirectory: BackupWriter.defaultDirectory,
            defaults: .standard,
            loginItem: SMAppServiceLoginItem(),
            notifications: UserNotificationDelivery.ifInstalledApp(),
            notificationsUnavailableReason: "Notifications need the installed Contact Bridge app, not a build run from the command line.",
            signIn: SignInController(),
            googleClient: { signIn in
                guard case .signedIn = signIn.status, let session = signIn.session else { return nil }
                return URLSessionGoogleContactsClient(auth: session)
            }
        )
    }

    /// Fakes seeded with sample data. Backups go to a temporary folder, the saved container choice to a separate defaults
    /// suite, the sync files stay in memory, and nothing real is read or written. The real sync engine runs against the fakes.
    @MainActor
    static func demo() -> AppDependencies {
        let demo = DemoData.make(forgottenLinks: demoForgetLinksRequested)
        let suite = "dev.dividedby.contactbridge.demo"
        // Never fall back to .standard: demo mode must not read or write the real saved container choice.
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("Cannot create the demo UserDefaults suite \(suite)") }
        defaults.removePersistentDomain(forName: suite)
        let backups = FileManager.default.temporaryDirectory.appendingPathComponent("ContactBridgeDemoBackups", isDirectory: true)
        return AppDependencies(
            isDemo: true,
            makeStore: { _ in demo.store },
            containerLister: DemoContainers(containers: demo.containers),
            notes: demo.notes,
            links: demo.links,
            dismissals: demo.dismissals,
            syncState: demo.syncState,
            reviews: demo.reviews,
            syncJournal: demo.journal,
            syncHistory: demo.history,
            writeGate: WriteGate(),
            acquireSyncLock: nil,
            contactsAppRunning: { false },
            backupDirectory: backups,
            defaults: defaults,
            loginItem: InMemoryLoginItem(),
            notifications: demoNotificationsRequested ? UserNotificationDelivery.ifInstalledApp() : nil,
            notificationsUnavailableReason: "Notifications are off in demo mode. Start with --demo-notifications to try them.",
            signIn: SignInController(demoEmail: demo.accountEmail),
            googleClient: { signIn in
                if case .signedIn = signIn.status { demo.google } else { nil }
            }
        )
    }
}

private struct DemoContainers: ContactContainerListing {
    var containers: [ContactContainer]
    func containers() async throws -> [ContactContainer] { containers }
}
