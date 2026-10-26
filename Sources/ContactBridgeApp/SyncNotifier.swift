import AppKit
import ContactBridgeCore
import UserNotifications

/// `UNUserNotificationCenter` behind `NotificationDelivering`. The center is not touched until something needs it: building
/// this object, and the app running with "Notify me" off, never reach it. Permission is asked for only in
/// `requestPermission()`, which the "Notify me" switch calls.
@MainActor
final class UserNotificationDelivery: NSObject, NotificationDelivering, @preconcurrency UNUserNotificationCenterDelegate {
    private static let destinationKey = "destination"

    var onOpen: (@MainActor (SyncNotice.Destination) -> Void)?

    /// Nil when this process is not an app bundle (`swift run`): the center cannot work there, and asking for it crashes.
    static func ifInstalledApp() -> UserNotificationDelivery? {
        Bundle.main.bundleURL.pathExtension == "app" ? UserNotificationDelivery() : nil
    }

    private var center: UNUserNotificationCenter { .current() }

    func prepare() {
        center.delegate = self
    }

    func permission() async -> NotificationPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ notice: SyncNotice) async {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = "dev.dividedby.contactbridge.sync"
        content.userInfo = [Self.destinationKey: notice.destination.rawValue]
        // The same identifier replaces a notice of that kind that is still on screen.
        try? await center.add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
    }

    func retract(_ kinds: [SyncNotice.Kind]) async {
        let identifiers = kinds.map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A click on a notification. Notifications are not shown while the app is frontmost (no `willPresent`), so the user
    /// who is already looking at the window is not told twice.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo[Self.destinationKey] as? String,
              let destination = SyncNotice.Destination(rawValue: raw)
        else { return }
        onOpen?(destination)
    }
}
