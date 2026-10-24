import ContactBridgeCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: ImportModel
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
            } else if let plan = model.plan {
                planList(plan)
            } else if model.isLoading {
                ProgressView("Reading your Google contacts…")
            } else {
                ContentUnavailableView {
                    Label("Nothing loaded", systemImage: "square.and.arrow.down")
                } actions: {
                    Button("Load Google contacts") { Task { await model.load() } }
                }
            }
        }
        .navigationTitle("Import")
        .toolbar {
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading || model.blockReason != nil)
            }
        }
        .task(id: model.blockReason) { await model.loadIfNeeded() }
        .sheet(isPresented: $model.showingConfirmation, onDismiss: { model.result = nil }) {
            ImportConfirmationSheet(model: model, containerName: app.setup.selectedContainer?.name ?? "iCloud")
        }
    }

    @ViewBuilder private func planList(_ plan: ImportPlan) -> some View {
        List {
            Section {
                Text(summary(plan)).foregroundStyle(.secondary)
            }
            Section {
                if plan.toImport.isEmpty {
                    Text("Every Google contact is already in iCloud.").foregroundStyle(.secondary)
                }
                ForEach(plan.toImport) { candidate in
                    Toggle(isOn: binding($model.selectedConnections, candidate.id)) {
                        candidateRow(candidate, plan: plan)
                    }
                }
            } header: {
                HStack {
                    Text("Not in iCloud yet (\(plan.toImport.count))")
                    Spacer()
                    Button("Select all") { model.selectedConnections = Set(plan.toImport.map(\.id)) }.buttonStyle(.link)
                    Button("Select none") { model.selectedConnections = [] }.buttonStyle(.link)
                    Button("People only") { model.selectedConnections = ImportSelection.peopleOnly(plan.toImport) }.buttonStyle(.link)
                    Button("Exclude text-message senders") {
                        model.selectedConnections = ImportSelection.excludingTextMessageSenders(model.selectedConnections, from: plan.toImport)
                    }.buttonStyle(.link)
                }
            }
            if !plan.otherContactCandidates.isEmpty {
                Section {
                    DisclosureGroup("Other contacts (\(plan.otherContactCandidates.count)), not selected by default") {
                        Text("Addresses Google saved from your email. They are not part of your own Google contacts.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.otherContactCandidates) { candidate in
                            Toggle(isOn: binding($model.selectedOthers, candidate.id)) {
                                candidateRow(candidate, plan: plan)
                            }
                        }
                    }
                }
            }
            if !plan.possibleMatches.isEmpty {
                Section {
                    DisclosureGroup("Possible matches to look at (\(plan.possibleMatches.count))") {
                        Text("These pairs might be the same person, but not convincingly. Both stay as they are; read-only.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.possibleMatches) { match in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text("Google \(match.googleName) ↔ iCloud \(match.icloudName)")
                                    ConfidenceBadge(confidence: match.confidence)
                                }
                                Text(match.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                ForEach(match.flags, id: \.self) { FlagLabel(flag: $0).font(.caption) }
                            }
                        }
                    }
                }
            }
            if !plan.links.isEmpty {
                Section {
                    DisclosureGroup("Already in iCloud (\(plan.links.count))") {
                        Text("Nothing here is imported unless you tick “Import anyway”. Matches by name alone are the ones worth a look: a common name can hide a different person.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(plan.links, id: \.googleResourceName) { link in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text("\(link.googleName) ↔ \(link.icloudName)")
                                        ConfidenceBadge(confidence: link.confidence)
                                    }
                                    if link.isNameOnly {
                                        Text("Matched by name only: no shared phone or email.").font(.caption).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if link.isNameOnly {
                                    Toggle("Import anyway", isOn: binding($model.importAnyway, link.googleResourceName))
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(selectionSummary).foregroundStyle(.secondary)
                Spacer()
                Button("Import selected…") { model.showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedCandidates.isEmpty)
            }
            .padding()
            .background(.bar)
        }
    }

    private func candidateRow(_ candidate: ImportCandidate, plan: ImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(candidate.record.displayName)
            let line = ContactText.contactLine(candidate.record)
            if !line.isEmpty { Text(line).font(.caption).foregroundStyle(.secondary) }
            if candidate.isShortCodeSender {
                Text("Automated text-message sender").font(.caption).foregroundStyle(.secondary)
            }
            if !plan.possibleMatches(forGoogleID: candidate.id).isEmpty {
                Label("Might already be in iCloud (see possible matches)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func binding(_ set: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { if $0 { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) } }
        )
    }

    private func summary(_ plan: ImportPlan) -> String {
        "\(plan.toImport.count) Google contacts are not in iCloud. \(plan.links.count) already are. "
            + "\(plan.otherContactCandidates.count) other contacts could be added."
    }

    private var selectionSummary: String {
        "\(model.selectedConnectionCount) contacts and \(model.selectedOtherCount) other contacts selected"
    }
}

struct ImportConfirmationSheet: View {
    @Bindable var model: ImportModel
    let containerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = model.result {
                resultView(result)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import into iCloud?").font(.title2)
            Text("This will create \(ContactText.count(model.selectedConnectionCount, "contact")) from your Google contacts and \(ContactText.count(model.selectedOtherCount, "contact")) from Other contacts in “\(containerName)”.")
            Text("Nothing is deleted or changed in Google. If the last backup is older than an hour, a new one is taken first.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                if model.isImporting { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { model.showingConfirmation = false }.disabled(model.isImporting)
                Button("Import \(ContactText.count(model.selectedCandidates.count, "contact"))") { Task { await model.runImport() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isImporting || model.selectedCandidates.isEmpty)
            }
        }
    }

    @ViewBuilder private func resultView(_ result: ImportResult) -> some View {
        Text(result.isComplete ? "Import finished" : "Import stopped").font(.title2)
        Text("Created \(ContactText.count(result.created.count, "contact")) in “\(containerName)”.")
        if case .failed(let id, let reason) = result.stopped {
            Label("Stopped at \(id): \(reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(result.notAttempted.count) more were not attempted. Fix the problem and import again; contacts already created will show as already in iCloud.")
                .foregroundStyle(.secondary)
        }
        if case .cancelled = result.stopped {
            Text("Cancelled. \(result.notAttempted.count) were not attempted.").foregroundStyle(.secondary)
        }
        if let error = result.linkSaveError {
            Label("The contacts were created, but the link file could not be saved: \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        HStack {
            Spacer()
            Button("Done") { model.showingConfirmation = false }.keyboardShortcut(.defaultAction)
        }
    }
}
