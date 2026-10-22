import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case backup = "Backup"
    case importContacts = "Import"
    case dedupe = "Dedupe"
    case sync = "Sync"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .backup: "externaldrive"
        case .importContacts: "square.and.arrow.down"
        case .dedupe: "person.2.crop.square.stack"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

struct RootView: View {
    @State private var selection: SidebarSection? = .backup
    @State private var signIn = SignInController()

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if selection == .sync {
                SyncPlaceholderView(signIn: signIn)
            } else if let selection {
                ContentUnavailableView(
                    selection.rawValue,
                    systemImage: selection.systemImage,
                    description: Text("Coming soon.")
                )
            } else {
                Text("Select a section")
            }
        }
    }
}

@main
struct ContactBridgeApp: App {
    var body: some Scene {
        WindowGroup("Contact Bridge") {
            RootView()
                .frame(minWidth: 720, minHeight: 440)
        }
    }
}
