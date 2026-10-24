import ContactBridgeCore
import SwiftUI

struct CleanupView: View {
    @Bindable var model: CleanupModel
    let app: AppModel

    var body: some View {
        Group {
            if let reason = model.blockReason {
                ContentUnavailableView {
                    Label("Not ready yet", systemImage: "exclamationmark.circle")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Open Setup") { app.selection = .setup }
                }
            } else if model.hasLoaded {
                content
            } else if model.isLoading {
                ProgressView("Loading contacts…")
            } else {
                ContentUnavailableView {
                    Label("Nothing loaded", systemImage: "trash")
                } actions: {
                    Button("Load contacts") { Task { await model.load() } }
                }
            }
        }
        .navigationTitle("Clean up")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading || model.blockReason != nil)
                    .help("Read your contacts again")
            }
        }
        .task(id: model.blockReason) { await model.loadIfNeeded() }
        .sheet(isPresented: $model.showingConfirmation, onDismiss: { model.run = nil }) {
            CleanupSheet(model: model, containerName: app.setup.selectedContainer?.name ?? "iCloud")
                .interactiveDismissDisabled(model.isDeleting)
        }
    }

    @ViewBuilder private var content: some View {
        if model.rows.isEmpty {
            ContentUnavailableView("Your address book is empty", systemImage: "person.crop.circle.badge.questionmark", description: Text("There is nothing to clean up in this account."))
        } else {
            VStack(spacing: 0) {
                CleanupBar(model: model)
                Divider()
                if model.shownRows.isEmpty {
                    ContentUnavailableView("No contacts match", systemImage: "line.3.horizontal.decrease.circle", description: Text("Turn off an option or change the search. Contacts you ticked stay ticked."))
                } else {
                    List(model.shownRows) { row in
                        CleanupRowView(row: row, isSelected: Binding(get: { model.isSelected(row.id) }, set: { model.setSelected(row.id, $0) }))
                    }
                }
            }
            .searchable(text: $model.filter.search, prompt: "Search name, phone or email")
        }
    }
}

/// The four filters, the selection controls and the delete button.
struct CleanupBar: View {
    @Bindable var model: CleanupModel

    var body: some View {
        let selected = model.selection.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Text-message senders", isOn: $model.filter.textMessageSenders)
                    .help("Automated senders: short-code phone numbers with no person name or email")
                Toggle("No name", isOn: $model.filter.noName)
                    .help("No first, middle, last or nick name, and no organization")
                Toggle("No phone or email", isOn: $model.filter.noPhoneOrEmail)
                    .help("Neither a phone number nor an email address")
                Toggle("Imported by Contact Bridge", isOn: $model.filter.importedByContactBridge)
                    .help("Contacts this app created from your Google contacts")
                Spacer()
                Text("\(model.shownRows.count) of \(ContactText.count(model.rows.count, "contact"))").foregroundStyle(.secondary)
            }
            .toggleStyle(.button)
            HStack {
                Button("Select all shown (\(model.shownRows.count))") { model.selectAllShown() }
                    .disabled(model.shownRows.isEmpty)
                Button("Select none") { model.selectNone() }.disabled(selected == 0)
                Text(selected == 0 ? "None selected" : "\(selected) selected").foregroundStyle(.secondary)
                Spacer()
                if selected > 0 {
                    Button("Delete \(ContactText.count(selected, "contact"))…", role: .destructive) { model.showingConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(model.deleteBlockReason != nil)
                }
            }
            if model.filter.hasActiveOptions {
                Text("Options combine: a contact has to match every one that is on.").font(.caption).foregroundStyle(.secondary)
            }
            if selected > 0, let reason = model.deleteBlockReason { Text(reason).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct CleanupRowView: View {
    let row: CleanupRow
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("Select \(row.displayName)", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).lineLimit(1)
                if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if row.isTextMessageSender { badge("Text-message sender", .blue) }
            if row.hasNoName { badge("No name", .orange) }
            if row.hasNoPhoneOrEmail { badge("No phone/email", .orange) }
            if row.isImported { badge("Imported", .green) }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { isSelected.toggle() }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.25), in: Capsule())
    }
}

/// Confirm (listing every selected contact), then progress, then the result.
struct CleanupSheet: View {
    @Bindable var model: CleanupModel
    let containerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isDeleting {
                progressView
            } else if let run = model.run {
                result(run)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// A plain stack up to 8 rows; beyond that a scroller with an explicit height (a ScrollView has no intrinsic height in a
    /// sheet). Lazy, because a clean-up can be thousands of contacts.
    @ViewBuilder private func doomedList(_ doomed: [CleanupRow]) -> some View {
        let rows = LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(doomed) { row in
                Label("\(row.displayName) · \(row.detail.isEmpty ? "no phone or email" : row.detail) · \(containerName)", systemImage: "trash")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if doomed.count <= 8 {
            rows
        } else {
            ScrollView { rows }.frame(height: 240)
        }
    }

    private var confirmation: some View {
        let doomed = model.selectedRows
        return VStack(alignment: .leading, spacing: 12) {
            Text("Delete \(ContactText.count(doomed.count, "contact"))?").font(.title2)
            Text(doomed.count == 1 ? "This contact will be deleted:" : "These \(doomed.count) contacts will be deleted:").font(.headline)
            doomedList(doomed)
            Text("A new backup, including notes, is taken first, so you can get these contacts back from it. Deleted contacts are also removed from the import links Contact Bridge keeps.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showingConfirmation = false }
                Button("Delete \(ContactText.count(doomed.count, "contact"))", role: .destructive) { Task { await model.deleteSelected() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(doomed.isEmpty || model.deleteBlockReason != nil)
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.phase == .deleting ? "Deleting contacts…" : "Taking a backup first…").font(.title2)
            ProgressView()
            Text("Keep this window open until it finishes.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func result(_ run: CleanupRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deleted \(ContactText.count(run.deletedCount, "contact"))").font(.title2)
            Text("A backup with notes was taken first (\(ContactText.count(run.receipt.manifest.counts.icloud ?? 0, "contact"))).")
            if run.linksRemoved > 0 {
                Text("\(ContactText.count(run.linksRemoved, "import link")) removed.").foregroundStyle(.secondary)
            }
            ForEach(run.followUpWarnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { model.showingConfirmation = false }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
