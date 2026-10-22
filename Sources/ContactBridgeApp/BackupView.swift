import AppKit
import ContactBridgeCore
import SwiftUI

struct BackupView: View {
    let model: BackupModel
    let setup: SetupModel
    @State private var pendingTrash: BackupEntry?

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Back up now") { Task { await model.backUpNow() } }
                        .disabled(model.isRunning)
                        .buttonStyle(.borderedProminent)
                    if model.isRunning { ProgressView().controlSize(.small) }
                }
                if let message = model.lastMessage { Text(message).foregroundStyle(.secondary) }
                Text("A backup is a read-only snapshot: a .vcf, JSON copies of every record, and notes when access is granted. Nothing is changed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Existing backups") {
                if model.entries.isEmpty {
                    Text("No backups yet.").foregroundStyle(.secondary)
                }
                ForEach(model.entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                            Text(counts(entry)).font(.caption).foregroundStyle(.secondary)
                            Label(entry.notesIncluded ? "Notes included" : "Notes not included", systemImage: entry.notesIncluded ? "note.text" : "note.text.badge.plus")
                                .font(.caption).foregroundStyle(entry.notesIncluded ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.folderURL]) }
                        Button("Move to Trash…", systemImage: "trash", role: .destructive) { pendingTrash = entry }
                            .labelStyle(.iconOnly)
                            .help("Move this backup to the Trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Backup")
        .confirmationDialog(
            "Move this backup to the Trash?",
            isPresented: Binding(get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }),
            presenting: pendingTrash
        ) { entry in
            Button("Move to Trash", role: .destructive) { Task { await model.moveToTrash(entry) } }
            Button("Cancel", role: .cancel) {}
        } message: { entry in
            Text("The backup from \(entry.createdAt.formatted(date: .abbreviated, time: .standard)) goes to the Trash. You can put it back from there until you empty the Trash. The next import or merge takes a fresh backup first.")
        }
        .task { await model.refresh() }
    }

    private func counts(_ entry: BackupEntry) -> String {
        var parts = ["\(entry.counts.icloud ?? 0) iCloud"]
        if let connections = entry.counts.googleConnections { parts.append("\(connections) Google") }
        if let others = entry.counts.googleOther { parts.append("\(others) other contacts") }
        return parts.joined(separator: " · ")
    }
}
