import AppKit
import ContactBridgeCore
import SwiftUI

struct SetupView: View {
    let model: AppModel

    var body: some View {
        let setup: SetupModel = model.setup
        Form {
            Section("Contacts") {
                LabeledContent("Permission") {
                    Text(permissionText(setup.contactsStatus)).foregroundStyle(setup.contactsStatus == .authorized ? Color.secondary : Color.orange)
                }
                switch setup.contactsStatus {
                case .notDetermined:
                    Button("Request access") { Task { await setup.requestContactsAccess() } }
                case .denied, .restricted:
                    Text("Turn on Contact Bridge in System Settings > Privacy & Security > Contacts, then come back.")
                        .foregroundStyle(.secondary)
                    Button("Open Contacts privacy settings") { SettingsLinks.open(.contacts) }
                    Button("Check again") { Task { await setup.refresh() } }
                case .authorized:
                    EmptyView()
                }
            }

            Section("iCloud account") {
                containerContent(setup)
            }

            Section("Notes") {
                LabeledContent("Access") { Text(notesText(setup.notesStatus)).foregroundStyle(notesColor(setup.notesStatus)) }
                if case .notAuthorized = setup.notesStatus {
                    Text("Grant in System Settings > Privacy & Security > Automation: turn on Contacts under Contact Bridge.")
                    Button("Open Automation settings") { SettingsLinks.open(.automation) }
                }
                if case .unavailable(let message) = setup.notesStatus {
                    Text(message).foregroundStyle(.secondary)
                }
                HStack {
                    Button(setup.notesStatus == .unknown ? "Check notes access" : "Check again") { Task { await setup.checkNotes() } }
                        .disabled(setup.isCheckingNotes)
                    if setup.isCheckingNotes { ProgressView().controlSize(.small) }
                }
                if setup.notesStatus == .unknown {
                    Text("Notes are read through the Contacts app. Checking may show a macOS permission prompt.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Google") {
                googleContent(model.signIn)
            }

            Section("Menu bar and notifications") {
                backgroundContent()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .task {
            model.loginItem.refresh()
            await model.notifier.refresh()
            await setup.refresh()
        }
        // The user may have changed Login Items or Notifications in System Settings and come back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.loginItem.refresh()
            Task { await model.notifier.refresh() }
        }
    }

    /// Contact Bridge keeps syncing from the menu bar after its window closes; these decide how it starts and what it says.
    @ViewBuilder private func backgroundContent() -> some View {
        let loginItem = model.loginItem
        let notifier = model.notifier
        Toggle("Open at login", isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) }))
        if let explanation = loginItem.explanation {
            Text(explanation).font(.caption).foregroundStyle(loginItem.needsApproval ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.deps.isDemo {
            Text("Demo mode: nothing is registered with macOS.").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("Starts Contact Bridge when you log in, so syncing carries on without you opening it.").font(.caption).foregroundStyle(.secondary)
        }
        if loginItem.needsApproval {
            Button("Open Login Items settings") { loginItem.openSystemSettings() }
        }

        Toggle("Start in menu bar", isOn: Binding(get: { model.shell.startInMenuBar }, set: { model.shell.startInMenuBar = $0 }))
        Text("When Contact Bridge opens at login, keep the window closed and run from the menu bar. Opening it yourself always shows the window.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

        Toggle("Notify me", isOn: Binding(get: { notifier.isOn }, set: { on in Task { await notifier.setEnabled(on) } }))
            .disabled(notifier.unavailableReason != nil)
        if let reason = notifier.unavailableReason {
            Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else if let message = notifier.message {
            Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            Button("Open Notification settings") { notifier.openSystemSettings() }
        } else {
            Text("Tell me when contacts need my review or syncing stops and needs me. macOS asks for permission when you turn this on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func containerContent(_ setup: SetupModel) -> some View {
        if setup.contactsStatus != .authorized {
            Text("Allow access to Contacts first.").foregroundStyle(.secondary)
        } else {
            LabeledContent("Using") {
                Text(setup.selectedContainer?.name ?? "None selected")
                    .foregroundStyle(setup.selectedContainer == nil ? Color.orange : Color.primary)
            }
            switch setup.resolution {
            case .needsUserChoice?:
                Text("More than one account could hold your iCloud contacts. Choose the one to work on. Contact Bridge never changes any other account.")
                    .foregroundStyle(.secondary)
            case .savedChoiceUnavailable?:
                Label("Your saved account is no longer available. Pick one below. Nothing is read or changed until you do.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .some(.none):
                Text("No iCloud contacts account was found. Turn on Contacts for iCloud in System Settings, then check again.")
                    .foregroundStyle(.orange)
                Button("Check again") { Task { await setup.loadContainers() } }
            case .selected(_, let saved)?:
                Text(saved ? "Your saved choice." : "Chosen automatically: the account named iCloud.").font(.caption).foregroundStyle(.secondary)
            case nil:
                EmptyView()
            }
            if setup.choosableContainers.count > 1 || setup.selectedContainer == nil && !setup.choosableContainers.isEmpty {
                Picker("Account", selection: Binding(
                    get: { setup.selectedContainer?.id },
                    set: { if let id = $0 { setup.choose(containerID: id) } }
                )) {
                    if setup.selectedContainer == nil { Text("Choose…").tag(String?.none) }
                    ForEach(setup.choosableContainers) { container in
                        Text(container.name).tag(Optional(container.id))
                    }
                }
            }
        }
    }

    @ViewBuilder private func googleContent(_ signIn: SignInController) -> some View {
        switch signIn.status {
        case .signedOut:
            LabeledContent("Status", value: "Not signed in")
            Button("Sign in with Google") { signIn.signIn() }
        case .signingIn:
            HStack { ProgressView().controlSize(.small); Text("Finish signing in in your browser…") }
            Button("Cancel") { signIn.cancelSignIn() }
        case .signedIn(let email):
            LabeledContent("Signed in as", value: email ?? "your Google account")
            Button("Sign out") { signIn.signOut() }
        case .needsReauthorization:
            Text("Google access expired or was revoked. Sign in again.").foregroundStyle(.orange)
            Button("Sign in with Google") { signIn.signIn() }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Try again") { signIn.signIn() }
        }
        if let notice = signIn.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
    }

    private func permissionText(_ status: ContactAuthorization) -> String {
        switch status {
        case .notDetermined: "Not requested yet"
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        }
    }

    private func notesText(_ status: NotesAccessStatus) -> String {
        switch status {
        case .unknown: "Not checked"
        case .authorized: "Allowed"
        case .notAuthorized: "Not allowed"
        case .unavailable: "Unavailable"
        }
    }

    private func notesColor(_ status: NotesAccessStatus) -> Color {
        switch status {
        case .authorized: .secondary
        case .unknown: .secondary
        default: .orange
        }
    }
}

enum SettingsLinks {
    enum Pane: String {
        case contacts = "Privacy_Contacts"
        case automation = "Privacy_Automation"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
