import AppKit
import ContactBridgeCore
import SwiftUI

enum MainWindow {
    static let id = "main"
}

/// The menu-bar icon. Also hands the window opener to `ActivationPolicyController` (as the window itself and the menu do),
/// so the opener is known even when the window was hidden at a launch at login.
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = MenuBarState(model.sync.snapshot)
        Group {
            if model.deps.isDemo {
                HStack(spacing: 4) {
                    Image(systemName: state.icon.systemImage)
                    Text("Demo")
                }
            } else {
                Image(systemName: state.icon.systemImage)
            }
        }
        .accessibilityLabel("Contact Bridge: \(state.statusLine)")
        .task {
            ActivationPolicyController.shared.openMainWindow = { openWindow(id: MainWindow.id) }
        }
    }
}

extension MenuBarIcon {
    var systemImage: String {
        switch self {
        case .normal: "arrow.triangle.2.circlepath"
        case .syncing: "arrow.triangle.2.circlepath.circle.fill"
        case .paused: "pause.circle"
        case .needsAttention: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}

/// The menu. It reads the same `AppModel` as the window, so there is one engine and one source of truth.
struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = MenuBarState(model.sync.snapshot)
        if model.deps.isDemo {
            Text("Demo mode: sample data, nothing real")
        }
        Text(state.statusLine)
        if let line = state.reviewLine {
            Button(line) { show(.sync) }
        }
        if state.needsConfirmation {
            Button("Review and confirm…") { show(.sync) }
        }
        Divider()
        Button("Sync now") { Task { await model.sync.syncNow() } }
            .disabled(!state.canSyncNow)
        switch state.pauseControl {
        case .pause: Button("Pause syncing") { Task { await model.sync.pause() } }
        case .resume: Button("Resume syncing") { Task { await model.sync.resume() } }
        case .none: EmptyView()
        }
        Divider()
        Toggle("Open at login", isOn: Binding(get: { model.loginItem.isOn }, set: { model.loginItem.setEnabled($0) }))
        if model.loginItem.needsApproval {
            Button("Allow in Login Items settings…") { model.loginItem.openSystemSettings() }
        }
        Divider()
        Button("Open Contact Bridge") { show(nil) }
        Button("Quit Contact Bridge") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ section: SidebarSection?) {
        // The menu has the window opener at hand even if the label has not handed it over.
        ActivationPolicyController.shared.openMainWindow = { openWindow(id: MainWindow.id) }
        model.showWindow(section)
    }
}
