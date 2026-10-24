import AppKit
import ContactBridgeCore
import OSLog

/// Keeps the app's presence in step with its windows. With a window it is a regular app (Dock icon, switcher); when the
/// last one closes it becomes a menu-bar app, and sync carries on. Opening the window brings the Dock icon back.
///
/// The window scene is presented by SwiftUI at every launch, so a window never depends on anything here to appear. The one
/// exception is a launch at login with "Start in menu bar" on: `suppressLaunchWindow()` hides it again as it appears.
@MainActor
final class ActivationPolicyController {
    static let shared = ActivationPolicyController()

    /// Opens the main window scene when it has been closed. Handed over by SwiftUI views (the window itself, the menu-bar
    /// label and the menu), because only SwiftUI can create the window. Any of them is enough.
    var openMainWindow: (() -> Void)? {
        didSet {
            guard pendingOpen, let open = openMainWindow else { return }
            pendingOpen = false
            open()
        }
    }

    private var pendingOpen = false
    private var observers: [any NSObjectProtocol] = []
    /// Windows the user closed or this controller hid. Hiding the whole app (Cmd-H) must not make such a window count again.
    private var closed: Set<ObjectIdentifier> = []
    private var suppressingLaunchWindow = false
    private weak var launchHiddenWindow: NSWindow?

    /// Starts watching windows. Closing needs one more turn of the run loop before the window counts as gone.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                // Delivered on the main queue (see `queue`), so reading the window there is safe.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated {
                    guard let window = note.object as? NSWindow, Self.isAppWindowKind(window) else { return }
                    ActivationPolicyController.shared.windowEvent(note.name, window)
                }
            })
        }
    }

    private func windowEvent(_ name: Notification.Name, _ window: NSWindow) {
        if name == NSWindow.willCloseNotification {
            closed.insert(ObjectIdentifier(window))
        } else if name != NSWindow.didMiniaturizeNotification {
            closed.remove(ObjectIdentifier(window))
            if suppressingLaunchWindow { hideForLaunch(window) }
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ActivationPolicyController.shared.refresh() }
        }
    }

    /// Dock icon with a window, menu bar only without.
    func refresh() {
        let traits = NSApp.windows.map(traits)
        let target: NSApplication.ActivationPolicy = ActivationRules.presence(for: traits) == .regular ? .regular : .accessory
        if NSApp.activationPolicy() != target { NSApp.setActivationPolicy(target) }
    }

    /// For a launch at login that should start in the menu bar: keeps the window SwiftUI presents off the screen. Stops
    /// after a few seconds, or as soon as the window is asked for.
    func suppressLaunchWindow() {
        suppressingLaunchWindow = true
        NSApp.setActivationPolicy(.accessory)
        for window in NSApp.windows where Self.isAppWindowKind(window) { hideForLaunch(window) }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            suppressingLaunchWindow = false
        }
    }

    private func hideForLaunch(_ window: NSWindow) {
        launchHiddenWindow = window
        closed.insert(ObjectIdentifier(window))
        window.orderOut(nil)
    }

    /// Brings the main window to the front, creating it if it was closed.
    func showMainWindow() {
        suppressingLaunchWindow = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { ActivationRules.countsAsAppWindow(traits($0)) }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let window = launchHiddenWindow {
            launchHiddenWindow = nil
            closed.remove(ObjectIdentifier(window))
            window.makeKeyAndOrderFront(nil)
        } else if let open = openMainWindow {
            open()
        } else if let window = NSApp.windows.first(where: Self.isAppWindowKind) {
            // Nobody has handed over the opener: show the closed window itself rather than nothing.
            closed.remove(ObjectIdentifier(window))
            window.makeKeyAndOrderFront(nil)
        } else {
            pendingOpen = true
        }
    }

    private static func isAppWindowKind(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    private func traits(_ window: NSWindow) -> WindowTraits {
        WindowTraits(
            isTitled: window.styleMask.contains(.titled), isPanel: window is NSPanel,
            isShownOrParked: !closed.contains(ObjectIdentifier(window)) && (window.isVisible || window.isMiniaturized || NSApp.isHidden)
        )
    }
}

enum LaunchContext {
    private static let log = Logger(subsystem: "dev.dividedby.contactbridge", category: "launch")

    /// Whether macOS started this process because the user logged in. macOS tells a login item it was launched as one in the
    /// open-application Apple event ("launched as login item" property). Read from the event, so it is only valid while
    /// the app is finishing launching. If the event does not say so (not verified on every macOS release), this is false and
    /// the window simply opens as for any launch.
    static func launchedAtLogin() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let flag = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let atLogin = event?.eventID == AEEventID(kAEOpenApplication) && flag == OSType(keyAELaunchedAsLogInItem)
        log.info("launch event \(event?.eventID ?? 0, privacy: .public), property \(flag ?? 0, privacy: .public), launched at login: \(atLogin, privacy: .public)")
        return atLogin
    }
}
