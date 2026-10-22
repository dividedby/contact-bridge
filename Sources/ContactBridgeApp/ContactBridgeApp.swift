import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

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
            case .sync: SyncPlaceholderView(app: model)
            }
        }
        .task { await model.start() }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }
}

@main
struct ContactBridgeApp: App {
    @State private var model = AppModel.make()

    var body: some Scene {
        WindowGroup("Contact Bridge") {
            RootView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1200, height: 800)
    }
}
