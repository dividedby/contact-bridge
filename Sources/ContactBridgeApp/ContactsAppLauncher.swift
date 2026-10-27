import AppKit
import ContactBridgeCore

/// Opens the Contacts app hidden in the background for photo writes that need it (`ContactsAppPhotoWriter`).
struct ContactsAppLauncher: ContactsAppLaunching {
    private static let bundleID = "com.apple.AddressBook"

    /// The running Contacts processes. Launch Services can keep listing one that is gone (pid -1, not terminated, seen
    /// after Contacts was killed); it does not count.
    static func running() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0.processIdentifier > 0 && !$0.isTerminated }
    }

    func isRunning() async -> Bool {
        !Self.running().isEmpty
    }

    func openHidden() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    func quitIfStillHidden() async {
        for app in Self.running() where app.isHidden {
            app.terminate()
        }
    }
}
