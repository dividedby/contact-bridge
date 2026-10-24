import Foundation
import Observation

public enum NotificationPermission: Sendable, Hashable {
    case notDetermined
    case denied
    case allowed
}

/// The system side of notifications (`UNUserNotificationCenter` in the app).
@MainActor
public protocol NotificationDelivering: AnyObject {
    /// Called when the user clicks a notification.
    var onOpen: (@MainActor (SyncNotice.Destination) -> Void)? { get set }
    /// Starts listening for clicks on notifications. Does not ask for permission.
    func prepare()
    func permission() async -> NotificationPermission
    /// Shows the macOS permission prompt. True when the user allowed.
    func requestPermission() async -> Bool
    func post(_ notice: SyncNotice) async
    func retract(_ kinds: [SyncNotice.Kind]) async
    func openSystemSettings()
}

/// Notifications that stay in memory: tests, and anywhere the real ones must not run.
@MainActor
public final class InMemoryNotificationDelivery: NotificationDelivering {
    public var onOpen: (@MainActor (SyncNotice.Destination) -> Void)?
    public var currentPermission: NotificationPermission
    /// What the permission prompt ends as.
    public var promptAnswer = true
    public private(set) var posted: [SyncNotice] = []
    public private(set) var retracted: [SyncNotice.Kind] = []
    public private(set) var prompts = 0
    public private(set) var prepared = 0
    public private(set) var settingsOpened = 0

    public init(permission: NotificationPermission = .notDetermined) {
        currentPermission = permission
    }

    public func prepare() { prepared += 1 }
    public func permission() async -> NotificationPermission { currentPermission }

    public func requestPermission() async -> Bool {
        prompts += 1
        currentPermission = promptAnswer ? .allowed : .denied
        return promptAnswer
    }

    public func post(_ notice: SyncNotice) async { posted.append(notice) }
    public func retract(_ kinds: [SyncNotice.Kind]) async { retracted.append(contentsOf: kinds) }
    public func openSystemSettings() { settingsOpened += 1 }

    public func click(_ destination: SyncNotice.Destination) { onOpen?(destination) }
}

/// "Notify me": the switch, the permission it depends on, and the notices the engine's snapshots call for. Off by default;
/// macOS is asked for permission only when the user turns the switch on.
@MainActor
@Observable
public final class SyncNotifier {
    public static let defaultsKey = "notifyMe"

    /// The user wants notifications and macOS allowed them.
    public private(set) var isOn: Bool
    /// Said under the switch when it could not be turned on.
    public private(set) var message: String?
    /// Why the switch cannot work in this run at all (demo mode, not an installed app); nil when it can.
    public let unavailableReason: String?
    public var onOpen: (@MainActor (SyncNotice.Destination) -> Void)?

    @ObservationIgnored private let delivery: (any NotificationDelivering)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var tracker: SyncNoticeTracker
    @ObservationIgnored private var delivering: Task<Void, Never>?

    /// - Parameters:
    ///   - delivery: nil when notifications must not run here; then `unavailableReason` says why.
    ///   - knownReviewIDs: the review items already stored, so a launch does not announce them again.
    public init(delivery: (any NotificationDelivering)?, unavailableReason: String? = nil, defaults: UserDefaults, knownReviewIDs: Set<String> = []) {
        self.delivery = delivery
        self.unavailableReason = delivery == nil ? (unavailableReason ?? "Notifications are not available here.") : nil
        self.defaults = defaults
        tracker = SyncNoticeTracker(knownReviewIDs: knownReviewIDs)
        isOn = delivery != nil && defaults.bool(forKey: Self.defaultsKey)
        delivery?.onOpen = { [weak self] destination in self?.onOpen?(destination) }
    }

    /// At launch: if the switch was left on, listens for clicks and checks that macOS still allows it.
    public func start() async {
        guard isOn else { return }
        delivery?.prepare()
        await refresh()
    }

    /// Reads the permission again (the user can change it in System Settings). A switch left on after macOS blocked
    /// notifications turns itself off and says so.
    public func refresh() async {
        guard let delivery, isOn else { return }
        if await delivery.permission() == .denied {
            setRequested(false)
            message = Self.blockedMessage
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        message = nil
        guard enabled else {
            setRequested(false)
            return
        }
        guard let delivery else {
            setRequested(false)
            message = unavailableReason
            return
        }
        var permission = await delivery.permission()
        if permission == .notDetermined { permission = await delivery.requestPermission() ? .allowed : .denied }
        if permission == .allowed {
            delivery.prepare()
            setRequested(true)
        } else {
            setRequested(false)
            message = Self.blockedMessage
        }
    }

    public func openSystemSettings() { delivery?.openSystemSettings() }

    /// Feeds one engine snapshot. The tracker follows the snapshots whether or not the switch is on, so turning it on
    /// later does not announce what was already there.
    public func observe(_ snapshot: SyncSnapshot) {
        let update = tracker.observe(snapshot)
        // Off means the app stays out of Notification Center altogether, including taking notices back.
        guard let delivery, isOn, !update.isEmpty else { return }
        let previous = delivering
        delivering = Task {
            await previous?.value
            if !update.retract.isEmpty { await delivery.retract(update.retract) }
            for notice in update.post { await delivery.post(notice) }
        }
    }

    /// Waits for the notices handed to the system so far (tests).
    public func waitUntilDelivered() async {
        await delivering?.value
    }

    private func setRequested(_ on: Bool) {
        isOn = on
        defaults.set(on, forKey: Self.defaultsKey)
    }

    static let blockedMessage = "macOS is not letting Contact Bridge show notifications. Allow them in System Settings > Notifications, then turn this on again."
}
