import ContactBridgeCore
import ServiceManagement

/// `SMAppService.mainApp` behind the `LoginItemControlling` protocol, so the settings logic and demo mode never touch the real thing.
/// Needs no entitlement in the sandbox. Registering is only ever done from the "Open at login" switches.
@MainActor
final class SMAppServiceLoginItem: LoginItemControlling {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
