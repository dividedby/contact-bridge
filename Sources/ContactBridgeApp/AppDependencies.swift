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
    var backupDirectory: URL
    var defaults: UserDefaults
    var signIn: SignInController
    /// The People API client for the current sign-in, or nil when signed out.
    var googleClient: @MainActor (SignInController) -> (any GoogleContactsClient)?

    /// `--demo` on the command line, or CONTACT_BRIDGE_DEMO set to anything but "" and "0".
    static var demoRequested: Bool {
        if CommandLine.arguments.contains("--demo") { return true }
        let value = ProcessInfo.processInfo.environment["CONTACT_BRIDGE_DEMO"] ?? ""
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
            backupDirectory: BackupWriter.defaultDirectory,
            defaults: .standard,
            signIn: SignInController(),
            googleClient: { signIn in
                guard case .signedIn = signIn.status, let session = signIn.session else { return nil }
                return URLSessionGoogleContactsClient(auth: session)
            }
        )
    }

    /// Fakes seeded with sample data. Backups go to a temporary folder, the saved container choice to a separate defaults
    /// suite, and nothing real is read or written.
    @MainActor
    static func demo() -> AppDependencies {
        let demo = DemoData.make()
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
            backupDirectory: backups,
            defaults: defaults,
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
