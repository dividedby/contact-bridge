import Foundation
import Testing
@testable import ContactBridgeCore

@MainActor
struct LoginItemTests {
    private struct Failure: LocalizedError {
        var errorDescription: String? { "denied" }
    }

    @Test("Off by default, and building the settings registers nothing")
    func offByDefault() {
        let service = InMemoryLoginItem()
        let settings = LoginItemSettings(service: service)
        #expect(!settings.isOn && !settings.needsApproval && settings.explanation == nil)
        #expect(service.registerCalls == 0 && service.unregisterCalls == 0)
    }

    @Test("Turning it on registers, turning it off unregisters")
    func toggle() {
        let service = InMemoryLoginItem()
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        #expect(settings.isOn && settings.status == .enabled && service.registerCalls == 1)
        settings.setEnabled(false)
        #expect(!settings.isOn && settings.status == .notRegistered && service.unregisterCalls == 1)
    }

    @Test("Switching to the state it is already in does nothing")
    func idempotent() {
        let on = InMemoryLoginItem(status: .enabled)
        let settings = LoginItemSettings(service: on)
        settings.setEnabled(true)
        #expect(on.registerCalls == 0)

        let off = InMemoryLoginItem()
        let other = LoginItemSettings(service: off)
        other.setEnabled(false)
        #expect(off.unregisterCalls == 0)
    }

    @Test("Waiting for approval shows as on, explains, and can open System Settings")
    func requiresApproval() {
        let service = InMemoryLoginItem()
        service.statusAfterRegister = .requiresApproval
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        #expect(settings.isOn && settings.needsApproval)
        #expect(settings.explanation?.contains("Login Items") == true)
        settings.openSystemSettings()
        #expect(service.settingsOpened == 1)
        // Already registered: asking again must not register twice (macOS would throw).
        settings.setEnabled(true)
        #expect(service.registerCalls == 1)
        settings.setEnabled(false)
        #expect(!settings.isOn && service.unregisterCalls == 1)
    }

    @Test("The status follows System Settings when refreshed")
    func refresh() {
        let service = InMemoryLoginItem(status: .requiresApproval)
        let settings = LoginItemSettings(service: service)
        #expect(settings.needsApproval)
        service.status = .enabled
        settings.refresh()
        #expect(settings.isOn && !settings.needsApproval && settings.explanation == nil)
        service.status = .notRegistered
        settings.refresh()
        #expect(!settings.isOn)
    }

    @Test("A failure is shown, keeps the real status, and clears on the next change")
    func failures() {
        let service = InMemoryLoginItem()
        service.registerError = Failure()
        let settings = LoginItemSettings(service: service)
        settings.setEnabled(true)
        #expect(!settings.isOn && settings.explanation == "Could not turn on open at login: denied")

        service.registerError = nil
        settings.setEnabled(true)
        #expect(settings.isOn && settings.explanation == nil)

        service.unregisterError = Failure()
        settings.setEnabled(false)
        #expect(settings.isOn && settings.explanation == "Could not turn off open at login: denied")
    }

    @Test("A missing app is explained")
    func notFound() {
        let settings = LoginItemSettings(service: InMemoryLoginItem(status: .notFound))
        #expect(!settings.isOn && settings.explanation?.contains("Applications") == true)
    }

    @Test("Start in menu bar is on by default and remembered")
    func startInMenuBar() {
        let name = "LoginItemTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        let settings = ShellSettings(defaults: suite)
        #expect(settings.startInMenuBar)
        settings.startInMenuBar = false
        #expect(!ShellSettings(defaults: suite).startInMenuBar)
        settings.startInMenuBar = true
        #expect(ShellSettings(defaults: suite).startInMenuBar)
    }
}
