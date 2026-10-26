import Foundation
import Observation

/// Where the "open at login" registration stands, as macOS reports it.
public enum LoginItemStatus: Sendable, Hashable {
    case notRegistered
    case enabled
    /// Registered, but the user has to allow it in System Settings > General > Login Items.
    case requiresApproval
    /// macOS has no record of the app. Also what it reports for an app that was never registered, so it only means trouble
    /// once a register leaves it this way.
    case notFound
}

/// The system side of the login item (`SMAppService.mainApp` in the app), so the logic can be tested and demo mode can fake it.
@MainActor
public protocol LoginItemControlling: AnyObject {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// A login item that exists only in memory: demo mode, and tests.
@MainActor
public final class InMemoryLoginItem: LoginItemControlling {
    public var status: LoginItemStatus
    /// What `register()` leaves the status as (`.requiresApproval` to play the approval step).
    public var statusAfterRegister = LoginItemStatus.enabled
    public var registerError: (any Error)?
    public var unregisterError: (any Error)?
    public private(set) var registerCalls = 0
    public private(set) var unregisterCalls = 0
    public private(set) var settingsOpened = 0

    public init(status: LoginItemStatus = .notRegistered) {
        self.status = status
    }

    public func register() throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    public func unregister() throws {
        unregisterCalls += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    public func openSystemSettings() { settingsOpened += 1 }
}

/// The "Open at login" switch: what it shows, and what flipping it does. Off by default because nothing is registered until
/// the user turns it on.
@MainActor
@Observable
public final class LoginItemSettings {
    public private(set) var status: LoginItemStatus
    /// The last register or unregister failure, cleared by the next successful change or `refresh()`.
    public private(set) var errorMessage: String?
    /// A register went through but macOS still could not find the app. Cleared once the status is anything else.
    private var registerLeftNotFound = false

    @ObservationIgnored private let service: any LoginItemControlling

    public init(service: any LoginItemControlling) {
        self.service = service
        status = service.status
    }

    /// The switch is on once registered, even while macOS still waits for the user's approval.
    public var isOn: Bool { status == .enabled || status == .requiresApproval }
    public var needsApproval: Bool { status == .requiresApproval }

    /// A sentence under the switch, when the status needs explaining.
    public var explanation: String? {
        if let errorMessage { return errorMessage }
        switch status {
        case .requiresApproval:
            return "macOS needs your OK first: turn on Contact Bridge in System Settings > General > Login Items."
        case .notFound where registerLeftNotFound:
            return "macOS can't find Contact Bridge to register it. Open it from the Applications folder and try again."
        case .notFound, .notRegistered, .enabled:
            return nil
        }
    }

    /// Reads the status again; the user can change it in System Settings at any time.
    public func refresh() {
        status = service.status
        errorMessage = nil
        if status != .notFound { registerLeftNotFound = false }
    }

    /// Registers or unregisters. A switch that is already in the requested state is left alone.
    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        var registered = false
        do {
            if enabled {
                if !isOn {
                    try service.register()
                    registered = true
                }
            } else if isOn {
                try service.unregister()
            }
        } catch {
            errorMessage = "Could not \(enabled ? "turn on" : "turn off") open at login: \(error.localizedDescription)"
        }
        status = service.status
        if registered { registerLeftNotFound = status == .notFound } else if status != .notFound { registerLeftNotFound = false }
    }

    public func openSystemSettings() { service.openSystemSettings() }
}

/// "Start in menu bar", kept in `UserDefaults`.
@MainActor
@Observable
public final class ShellSettings {
    public static let startInMenuBarKey = "startInMenuBar"

    /// When Contact Bridge opens at login, stay in the menu bar and show no window. On by default.
    public var startInMenuBar: Bool {
        didSet { defaults.set(startInMenuBar, forKey: Self.startInMenuBarKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        startInMenuBar = defaults.object(forKey: Self.startInMenuBarKey) as? Bool ?? true
    }
}
