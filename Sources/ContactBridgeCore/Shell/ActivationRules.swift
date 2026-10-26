import Foundation

/// Whether the app shows in the Dock and the app switcher.
public enum AppPresence: Sendable, Hashable {
    /// A normal app: Dock icon, menu bar, switcher.
    case regular
    /// Menu-bar only. Sync keeps running.
    case menuBarOnly
}

/// The facts about one window that decide whether it keeps the app in the Dock.
public struct WindowTraits: Sendable, Hashable {
    /// Has a title bar (the status item's window, menus and popovers do not).
    public var isTitled: Bool
    /// Open panels, alerts and inspectors come and go with the window that asked for them.
    public var isPanel: Bool
    /// On screen, minimized to the Dock, or hidden along with the whole app.
    public var isShownOrParked: Bool

    public init(isTitled: Bool, isPanel: Bool, isShownOrParked: Bool) {
        self.isTitled = isTitled
        self.isPanel = isPanel
        self.isShownOrParked = isShownOrParked
    }
}

public enum ActivationRules {
    /// A window the user would call "the app's window".
    public static func countsAsAppWindow(_ window: WindowTraits) -> Bool {
        window.isTitled && !window.isPanel && window.isShownOrParked
    }

    /// While a launch at login keeps the window away, any app window that is on screen is put away again.
    public static func shouldHideForLaunch(_ window: WindowTraits, isOnScreen: Bool, suppressing: Bool) -> Bool {
        suppressing && isOnScreen && window.isTitled && !window.isPanel
    }

    /// With a window the app is a regular app; with none it drops to the menu bar and keeps syncing.
    public static func presence(for windows: [WindowTraits]) -> AppPresence {
        windows.contains(where: countsAsAppWindow) ? .regular : .menuBarOnly
    }

    /// Whether the main window is shown right after launch. Only a launch at login can start without it, and only when the
    /// user asked for that.
    public static func showsWindowAtLaunch(launchedAtLogin: Bool, startInMenuBar: Bool) -> Bool {
        !(launchedAtLogin && startInMenuBar)
    }
}
