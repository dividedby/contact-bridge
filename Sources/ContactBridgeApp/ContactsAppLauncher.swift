import AppKit
import ContactBridgeCore

/// Opens the Contacts app hidden in the background for photo writes that need it (`ContactsAppPhotoWriter`).
struct ContactsAppLauncher: ContactsAppLaunching {
    private static let bundleID = "com.apple.AddressBook"

    func isRunning() async -> Bool {
        await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty }
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
        await MainActor.run {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) where app.isHidden {
                app.terminate()
            }
        }
    }
}
