import Foundation
import Testing
@testable import ContactBridgeCore

@MainActor
struct SyncNotifierTests {
    private func defaults() -> UserDefaults {
        let name = "SyncNotifierTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private func snapshot(reviews: [String], run: Double = 1) -> SyncSnapshot {
        var snapshot = SyncSnapshot()
        snapshot.status = .idle
        snapshot.firstSyncApproved = true
        snapshot.lastRunAt = Date(timeIntervalSince1970: 1_800_000_000 + run * 60)
        snapshot.reviewItems = reviews.map { SyncReviewSummary(id: $0, kind: .googleEdited, name: $0, detail: nil, fields: []) }
        return snapshot
    }

    @Test("Off by default: building it, starting it and feeding it snapshots touches nothing in the system")
    func offByDefault() async {
        let delivery = InMemoryNotificationDelivery()
        let notifier = SyncNotifier(delivery: delivery, defaults: defaults())
        await notifier.start()
        notifier.observe(snapshot(reviews: ["a"]))
        await notifier.waitUntilDelivered()
        #expect(!notifier.isOn && delivery.prompts == 0 && delivery.prepared == 0 && delivery.posted.isEmpty)
    }

    @Test("Turning it on asks macOS once, and then notices are posted")
    func turnOn() async {
        let delivery = InMemoryNotificationDelivery()
        let store = defaults()
        let notifier = SyncNotifier(delivery: delivery, defaults: store)
        await notifier.setEnabled(true)
        #expect(notifier.isOn && delivery.prompts == 1 && delivery.prepared == 1 && notifier.message == nil)
        #expect(store.bool(forKey: SyncNotifier.defaultsKey))

        notifier.observe(snapshot(reviews: ["a", "b"]))
        await notifier.waitUntilDelivered()
        #expect(delivery.posted.map(\.body) == ["2 contacts need your review"])

        await notifier.setEnabled(false)
        #expect(!notifier.isOn && !store.bool(forKey: SyncNotifier.defaultsKey))
        notifier.observe(snapshot(reviews: ["a", "b", "c"], run: 2))
        await notifier.waitUntilDelivered()
        #expect(delivery.posted.count == 1)
    }

    @Test("A refusal at the prompt leaves it off and explains; an earlier refusal is not asked about again")
    func refused() async {
        let delivery = InMemoryNotificationDelivery()
        delivery.promptAnswer = false
        let notifier = SyncNotifier(delivery: delivery, defaults: defaults())
        await notifier.setEnabled(true)
        #expect(!notifier.isOn && notifier.message?.contains("System Settings") == true && delivery.prompts == 1)

        await notifier.setEnabled(true)
        #expect(!notifier.isOn && delivery.prompts == 1)
        notifier.openSystemSettings()
        #expect(delivery.settingsOpened == 1)
    }

    @Test("Notices are not posted while it is off, but turning it on later does not announce what was already waiting")
    func trackingWhileOff() async {
        let delivery = InMemoryNotificationDelivery(permission: .allowed)
        let notifier = SyncNotifier(delivery: delivery, defaults: defaults())
        notifier.observe(snapshot(reviews: ["a"]))
        await notifier.setEnabled(true)
        notifier.observe(snapshot(reviews: ["a"], run: 2))
        await notifier.waitUntilDelivered()
        #expect(delivery.posted.isEmpty && delivery.prompts == 0)

        notifier.observe(snapshot(reviews: ["a", "b"], run: 3))
        await notifier.waitUntilDelivered()
        #expect(delivery.posted.count == 1)
    }

    @Test("A switch left on starts listening at launch; one that macOS has since blocked turns itself off")
    func launch() async {
        let store = defaults()
        store.set(true, forKey: SyncNotifier.defaultsKey)

        let allowed = InMemoryNotificationDelivery(permission: .allowed)
        let on = SyncNotifier(delivery: allowed, defaults: store)
        await on.start()
        #expect(on.isOn && allowed.prepared == 1 && allowed.prompts == 0)

        let blocked = InMemoryNotificationDelivery(permission: .denied)
        let off = SyncNotifier(delivery: blocked, defaults: store)
        await off.start()
        #expect(!off.isOn && off.message != nil && !store.bool(forKey: SyncNotifier.defaultsKey))
    }

    @Test("Clicking a notification reports where it leads")
    func click() {
        let delivery = InMemoryNotificationDelivery()
        let notifier = SyncNotifier(delivery: delivery, defaults: defaults())
        var opened: [SyncNotice.Destination] = []
        notifier.onOpen = { opened.append($0) }
        delivery.click(.reviewList)
        delivery.click(.confirmation)
        #expect(opened == [.reviewList, .confirmation])
    }

    @Test("Without a delivery (demo mode) it cannot be turned on, never prompts and never posts")
    func unavailable() async {
        let store = defaults()
        store.set(true, forKey: SyncNotifier.defaultsKey)
        let notifier = SyncNotifier(delivery: nil, unavailableReason: "Not in demo mode.", defaults: store)
        #expect(!notifier.isOn && notifier.unavailableReason == "Not in demo mode.")
        await notifier.setEnabled(true)
        #expect(!notifier.isOn && notifier.message == "Not in demo mode.")
        notifier.observe(snapshot(reviews: ["a"]))
        await notifier.waitUntilDelivered()
    }

    @Test("A cleared condition retracts the notice while the switch is on, and does nothing once it is off")
    func retract() async {
        let delivery = InMemoryNotificationDelivery()
        let notifier = SyncNotifier(delivery: delivery, defaults: defaults())
        await notifier.setEnabled(true)
        notifier.observe(snapshot(reviews: ["a"]))
        notifier.observe(snapshot(reviews: [], run: 2))
        await notifier.waitUntilDelivered()
        #expect(delivery.retracted == [.reviews])

        notifier.observe(snapshot(reviews: ["b"], run: 3))
        await notifier.setEnabled(false)
        notifier.observe(snapshot(reviews: [], run: 4))
        await notifier.waitUntilDelivered()
        #expect(delivery.retracted == [.reviews] && delivery.posted.count == 2)
    }
}
