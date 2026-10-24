import AppKit
import ContactBridgeCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                if model.deps.isDemo {
                    Label("Demo data. Nothing here is real.", systemImage: "testtube.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                }
            }
        } detail: {
            switch model.selection {
            case .setup: SetupView(model: model)
            case .backup: BackupView(model: model.backup, setup: model.setup)
            case .importContacts: ImportView(model: model.importing, app: model)
            case .dedupe: DedupeView(model: model.dedupe, app: model)
            case .cleanUp: CleanupView(model: model.cleanup, app: model)
            case .sync: SyncView(model: model.sync, app: model)
            }
        }
        // The window can always hand over its own opener, so reopening never depends on the menu-bar label.
        .task { ActivationPolicyController.shared.openMainWindow = { openWindow(id: MainWindow.id) } }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }
}

@main
struct ContactBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let model = AppModel.make()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        // A single window, presented at every launch. A launch at login with "Start in menu bar" hides it again (see
        // AppDelegate). The sync engine belongs to the model, not to this window.
        Window("Contact Bridge", id: MainWindow.id) {
            RootView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1200, height: 800)
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Launch and window lifecycle: the app lives on in the menu bar after its window closes, so sync keeps going.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `ContactBridgeApp` before the app finishes launching.
    static var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model = Self.model else { return }
        let policy = ActivationPolicyController.shared
        policy.start()
        let atLogin = LaunchContext.launchedAtLogin()
        if !ActivationRules.showsWindowAtLaunch(launchedAtLogin: atLogin, startInMenuBar: model.shell.startInMenuBar) {
            policy.suppressLaunchWindow()
        }
        Task { await model.start() }
    }

    /// Closing the window must not quit: sync runs from the menu bar. Quit is in the menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon (or opening the app again) with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.model?.showWindow() }
        return true
    }
}
