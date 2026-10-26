import AppKit
import ContactBridgeCore
import SwiftUI

struct DedupeView: View {
    @Bindable var model: DedupeModel
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
            } else if let scan = model.scan {
                content(scan)
            } else if model.isLoading {
                ProgressView("Looking for duplicates…")
            } else {
                ContentUnavailableView {
                    Label("Nothing loaded", systemImage: "person.2.crop.square.stack")
                } actions: {
                    Button("Look for duplicates") { Task { await model.load() } }
                }
            }
        }
        .navigationTitle(model.draft == nil ? "Dedupe" : "Review group")
        .toolbar {
            if model.draft != nil {
                ToolbarItem(placement: .navigation) {
                    Button("All groups", systemImage: "chevron.backward") { model.selectedClusterID = nil }
                        .help("Back to the list of groups")
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .disabled(model.isLoading || model.blockReason != nil)
                    .help("Look for duplicates again")
                if (model.scan?.hiddenCount ?? 0) > 0 {
                    Button("Show hidden", systemImage: "eye") { Task { await model.restoreDismissed() } }
                        .help("Bring back the \(model.scan?.hiddenCount ?? 0) groups you marked as not duplicates")
                }
            }
        }
        .task(id: model.blockReason) { await model.loadIfNeeded() }
        .sheet(isPresented: $model.showingConfirmation, onDismiss: { model.mergeRun = nil }) {
            MergeConfirmationSheet(model: model, containerName: app.setup.selectedContainer?.name ?? "iCloud")
        }
        .sheet(isPresented: $model.showingBulkSheet, onDismiss: { model.bulkReport = nil }) {
            BulkMergeSheet(model: model, containerName: app.setup.selectedContainer?.name ?? "iCloud")
                .interactiveDismissDisabled(model.isBulkMerging)
        }
    }

    @ViewBuilder private func content(_ scan: DuplicateScan) -> some View {
        if scan.records.isEmpty {
            ContentUnavailableView("Your address book is empty", systemImage: "person.crop.circle.badge.questionmark", description: Text("There is nothing to compare in this account."))
        } else if scan.clusters.isEmpty {
            ContentUnavailableView(
                "No duplicates found", systemImage: "checkmark.circle",
                description: Text(scan.hiddenCount > 0 ? "\(scan.hiddenCount) groups are hidden because you marked them as not duplicates." : "Checked \(scan.records.count) contacts.")
            )
        } else {
            if model.draft != nil {
                ClusterDetail(model: model, containerName: app.setup.selectedContainer?.name ?? "iCloud")
            } else {
                VStack(spacing: 0) {
                    BulkBar(model: model)
                    Divider()
                    List(selection: $model.selectedClusterID) {
                        Section {
                            ForEach(scan.clusters) { cluster in
                                let eligibility = model.eligibility[cluster.id] ?? .eligible
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("Include in bulk actions", isOn: Binding(
                                        get: { model.isChecked(cluster.id) }, set: { model.setChecked(cluster.id, $0) }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .disabled(eligibility == .needsReview)
                                    .help(eligibility == .needsReview ? "Open this group to review it. It can't be merged in bulk." : "Include in bulk actions")
                                    ClusterRow(cluster: cluster, eligibility: eligibility)
                                }
                                .tag(cluster.id)
                            }
                        } header: {
                            Text("\(ContactText.count(scan.clusters.count, "possible duplicate group")). Select one to review; nothing merges until you confirm.")
                        }
                    }
                }
            }
        }
    }
}

/// Select-all-safe / none, the count, and the actions on the ticked groups.
struct BulkBar: View {
    @Bindable var model: DedupeModel

    var body: some View {
        let checked = model.checkedClusterIDs.count
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Select all safe groups (\(model.safeClusterIDs.count))") { model.selectAllSafe() }
                    .disabled(model.safeClusterIDs.isEmpty)
                    .help("Tick every high-confidence group with no warnings and no fields that disagree")
                Button("Select none") { model.selectNone() }.disabled(checked == 0)
                Text(checked == 0 ? "None selected" : "\(checked) selected").foregroundStyle(.secondary)
                Spacer()
                if checked > 0 {
                    Button("Not duplicates (\(checked))") { Task { await model.dismissChecked() } }
                        .help("Hide the selected groups from now on. You can bring hidden groups back from the toolbar.")
                    Button("Merge \(ContactText.count(checked, "group"))…") { model.showingBulkSheet = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.bulkMergeBlockReason != nil)
                }
            }
            if checked > 0, let reason = model.bulkMergeBlockReason { Text(reason).font(.caption).foregroundStyle(.orange) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct ClusterRow: View {
    let cluster: DuplicateCluster
    var eligibility: BulkEligibility = .eligible

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(cluster.members.map(\.displayName).joined(separator: " · ")).lineLimit(2)
                Spacer()
                if eligibility == .needsReview {
                    Text("Needs review").font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.25), in: Capsule())
                }
                ConfidenceBadge(confidence: cluster.confidence)
            }
            Text("\(cluster.members.count) contacts · \(cluster.reasons.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ForEach(cluster.flags, id: \.self) { FlagLabel(flag: $0).font(.caption) }
        }
        .padding(.vertical, 2)
    }
}

struct ClusterDetail: View {
    @Bindable var model: DedupeModel
    let containerName: String

    var body: some View {
        if let draft = model.draft {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(draft)
                    comparison(draft)
                    survivorPicker(draft)
                    conflictPickers(draft)
                    linkSections(draft)
                    preview(draft)
                    actions(draft)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: sections

    private func header(_ draft: MergeDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(draft.members.count) contacts").font(.title2)
                ConfidenceBadge(confidence: draft.confidence)
            }
            if !draft.reasons.isEmpty { Text("Why: " + draft.reasons.joined(separator: ", ")).foregroundStyle(.secondary) }
            ForEach(draft.flags, id: \.self) { FlagLabel(flag: $0) }
            if draft.isSplit {
                Label("Nothing strong links all of these contacts to each other.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let note = model.notesIssue { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func comparison(_ draft: MergeDraft) -> some View {
        let members = draft.members
        let rows: [(String, (ContactRecord) -> String)] = [
            ("Given name", { $0.givenName }), ("Middle name", { $0.middleName }), ("Family name", { $0.familyName }),
            ("Nickname", { $0.nickname }), ("Organization", { $0.organization }), ("Job title", { $0.jobTitle }),
            ("Phones", { ContactText.phonesOrEmails($0.phones) }), ("Emails", { ContactText.phonesOrEmails($0.emails) }),
            ("Addresses", { ContactText.addresses($0.postalAddresses) }), ("Websites", { ContactText.phonesOrEmails($0.urls) }),
            ("Birthday", { ContactText.birthday($0.birthday) }), ("Note", { model.notes[$0.sourceIdentifier] ?? "" }),
        ]
        let cellWidth: CGFloat = 190
        return VStack(alignment: .leading, spacing: 8) {
            GroupBox("Side by side") {
                // Its own horizontal scroller: many members never push the window's content off-screen.
                ScrollView(.horizontal) {
                    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("").frame(width: 90)
                            ForEach(members) { member in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.displayName).bold()
                                    Text(containerName).font(.caption).foregroundStyle(.secondary)
                                    if draft.survivorID == member.id {
                                        Label("Kept", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                    }
                                    if members.count > 2 {
                                        Button("Remove from group") { model.removeMember(member.id) }
                                            .buttonStyle(.link).font(.caption)
                                            .help("Leave this contact out of the merge. It will not be touched.")
                                    }
                                }
                                .frame(width: cellWidth, alignment: .leading)
                            }
                        }
                        Divider().gridCellColumns(members.count + 1)
                        ForEach(rows.filter { row in members.contains { !row.1($0).isBlank } }, id: \.0) { row in
                            GridRow {
                                Text(row.0).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                ForEach(members) { member in
                                    Text(row.1(member))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(width: cellWidth, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
            ForEach(draft.removedMembers) { removed in
                HStack {
                    Text("Left out: \(removed.displayName)").foregroundStyle(.secondary)
                    Button("Put back") { model.restoreMember(removed.id) }.buttonStyle(.link)
                }
            }
        }
    }

    private func survivorPicker(_ draft: MergeDraft) -> some View {
        GroupBox("Keep which contact?") {
            Picker("Keep", selection: Binding(get: { draft.survivorID }, set: { model.chooseSurvivor($0) })) {
                ForEach(draft.members) { member in
                    Text(summary(member)).tag(member.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    @ViewBuilder private func conflictPickers(_ draft: MergeDraft) -> some View {
        let conflicts = draft.conflicts
        if !conflicts.isEmpty {
            GroupBox("These fields disagree. Pick the value to keep.") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(conflicts, id: \.field) { conflict in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(conflict.field)).font(.headline)
                            Picker(title(conflict.field), selection: Binding(
                                get: { draft.selectedRecordID(for: conflict.field) ?? conflict.proposedRecordID },
                                set: { model.pick(conflict.field, recordID: $0) }
                            )) {
                                ForEach(conflict.candidates, id: \.recordID) { candidate in
                                    Text("\(candidate.value)  (from \(draft.members.first { $0.id == candidate.recordID }?.displayName ?? "?"))").tag(candidate.recordID)
                                }
                            }
                            .pickerStyle(.radioGroup)
                            .labelsHidden()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    @ViewBuilder private func linkSections(_ draft: MergeDraft) -> some View {
        if !draft.weakEdges.isEmpty {
            GroupBox("Weak or conflicting links inside this group") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If these are different people, remove one from the group above.").font(.caption).foregroundStyle(.secondary)
                    ForEach(draft.weakEdges, id: \.firstID) { edge in edgeRow(edge) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
        if !draft.relatedEdges.isEmpty {
            GroupBox("Possibly related, not in this group") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.relatedEdges, id: \.firstID) { edge in edgeRow(edge) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func edgeRow(_ edge: ClusterEdge) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(name(edge.firstID)) ↔ \(name(edge.secondID))")
                ConfidenceBadge(confidence: edge.match.confidence)
            }
            Text(edge.match.reasons.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            ForEach(edge.match.flags, id: \.self) { FlagLabel(flag: $0).font(.caption) }
        }
    }

    private func preview(_ draft: MergeDraft) -> some View {
        let plan = draft.plan
        let merged = plan.merged
        return GroupBox("Merged contact preview") {
            VStack(alignment: .leading, spacing: 8) {
                Text(merged.displayName).font(.headline)
                let fields: [(String, String)] = [
                    ("Organization", merged.organization), ("Job title", merged.jobTitle),
                    ("Phones", ContactText.phonesOrEmails(merged.phones)), ("Emails", ContactText.phonesOrEmails(merged.emails)),
                    ("Addresses", ContactText.addresses(merged.postalAddresses)), ("Websites", ContactText.phonesOrEmails(merged.urls)),
                    ("Birthday", ContactText.birthday(merged.birthday)),
                ]
                ForEach(fields.filter { !$0.1.isBlank }, id: \.0) { field in
                    HStack(alignment: .top) {
                        Text(field.0).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(field.1)
                    }
                }
                if !plan.droppedLabels.isEmpty {
                    Divider()
                    Text("Labels that will be dropped").font(.subheadline.bold())
                    ForEach(Array(plan.droppedLabels.enumerated()), id: \.offset) { _, dropped in
                        Text("\(dropped.value): keeping “\(dropped.keptLabel)”, dropping “\(dropped.droppedLabel)”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("Combined note").font(.subheadline.bold())
                if let note = draft.combinedNote(notes: model.notes) {
                    Text(note).textSelection(.enabled)
                } else {
                    Text(model.notesIssue ?? "No notes on these contacts.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }

    private func actions(_ draft: MergeDraft) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Merge…") { model.showingConfirmation = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.mergeBlockReason != nil)
                Button("Not duplicates") { Task { await model.dismissSelected() } }
                    .help("Hide this group from now on. You can bring hidden groups back from the toolbar.")
            }
            if let reason = model.mergeBlockReason { Text(reason).font(.caption).foregroundStyle(.orange) }
            Text("Nothing changes until you confirm. A backup is taken first.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: helpers

    private func name(_ id: String) -> String { model.recordsByID[id]?.displayName ?? id }

    private func summary(_ member: ContactRecord) -> String {
        let line = ContactText.contactLine(member)
        return line.isEmpty ? member.displayName : "\(member.displayName)  (\(line))"
    }

    private func title(_ field: MergeField) -> String {
        switch field {
        case .givenName: "Given name"
        case .middleName: "Middle name"
        case .familyName: "Family name"
        case .nickname: "Nickname"
        case .organization: "Organization"
        case .jobTitle: "Job title"
        case .birthday: "Birthday"
        }
    }
}

struct MergeConfirmationSheet: View {
    @Bindable var model: DedupeModel
    let containerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let run = model.mergeRun {
                resultView(run)
            } else if let draft = model.draft {
                confirmation(draft)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// Every row fully visible: a plain stack up to 8 rows; only beyond that a scroller, with an explicit height because a
    /// ScrollView has no intrinsic height inside a sheet.
    @ViewBuilder private func doomedList(_ doomed: [ContactRecord]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 4) {
            ForEach(doomed) { other in
                Label("\(other.displayName) · \(ContactText.distinguishing(other)) · \(containerName)", systemImage: "trash")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if doomed.count <= 8 {
            rows
        } else {
            ScrollView { rows }.frame(height: min(CGFloat(doomed.count) * 24, 240))
        }
    }

    private func confirmation(_ draft: MergeDraft) -> some View {
        let note = draft.combinedNote(notes: model.notes)
        let doomed = draft.others
        return VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(draft.members.count) contacts into one?").font(.title2)
            Text("Kept: **\(draft.survivor.displayName)** (\(ContactText.distinguishing(draft.survivor))) in “\(containerName)”")
            Text(doomed.count == 1 ? "This contact will be deleted:" : "These \(doomed.count) contacts will be deleted:").font(.headline)
            doomedList(doomed)
            if let note {
                Text("The kept contact's note becomes:").font(.headline)
                BoundedText(text: note, maxHeight: 120)
            }
            Text("If the last backup is older than an hour, a new one is taken first. Phone, email and address entries from the deleted \(doomed.count == 1 ? "contact are" : "contacts are") folded into the kept one.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if model.isMerging { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { model.showingConfirmation = false }.disabled(model.isMerging)
                Button("Merge and delete \(ContactText.count(doomed.count, "contact"))") { Task { await model.merge() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isMerging || model.mergeBlockReason != nil)
            }
        }
    }

    @ViewBuilder private func resultView(_ run: MergeRun) -> some View {
        Text("Merged").font(.title2)
        Text("Kept \(run.survivor.displayName) and deleted \(run.deleted.count == 1 ? "1 duplicate contact" : "\(run.deleted.count) duplicate contacts"). A backup was taken first (\(ContactText.count(run.receipt.manifest.counts.icloud ?? 0, "contact"))).")
        switch run.outcome.notes {
        case .written: Label("The combined note was saved.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unchanged: Text("The note did not need to change.").foregroundStyle(.secondary)
        case .skipped: Text("Notes were not merged.").foregroundStyle(.secondary)
        case .writeFailed(let combined, let reason):
            Label("The contacts were merged, but the combined note could not be saved: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Copy it and paste it into the contact's note yourself. It is also in the backup.").font(.caption).foregroundStyle(.secondary)
            BoundedText(text: combined, maxHeight: 140)
            Button("Copy combined note") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(combined, forType: .string)
            }
        }
        MergeLinkNotes(links: run.links)
        HStack {
            Spacer()
            Button("Done") { model.showingConfirmation = false }.keyboardShortcut(.defaultAction)
        }
    }
}

/// What a merge did about the Google links of the contacts it deleted.
struct MergeLinkNotes: View {
    let links: MergeLinkOutcome

    var body: some View {
        if links.linksMoved > 0 {
            Label("Google link moved to the kept contact.", systemImage: "link").foregroundStyle(.secondary)
        }
        if links.googleCopiesLeft > 0 {
            Label(
                "Google still has \(links.googleCopiesLeft == 1 ? "1 other copy" : "\(links.googleCopiesLeft) other copies") of this person. Contact Bridge leaves \(links.googleCopiesLeft == 1 ? "it" : "them") alone.",
                systemImage: "info.circle"
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if links.googleRemovalsPending > 0 {
            Label("Also removed from Google on the next sync (\(ContactText.count(links.googleRemovalsPending, "contact"))).", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
        }
        ForEach(links.followUpWarnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Confirm, then progress, then the per-group summary of a bulk merge.
struct BulkMergeSheet: View {
    @Bindable var model: DedupeModel
    let containerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isBulkMerging {
                progressView
            } else if let report = model.bulkReport {
                summary(report)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// A plain stack for a few rows; a scroller of a definite height beyond that (a ScrollView has no intrinsic height in a sheet).
    @ViewBuilder private func rows(_ content: some View, count: Int) -> some View {
        if count <= 6 {
            content
        } else {
            ScrollView { content }.frame(height: min(CGFloat(count) * 40, 280))
        }
    }

    private var confirmation: some View {
        let drafts = model.checkedDrafts
        let deleting = model.checkedDeleteCount
        return VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(ContactText.count(drafts.count, "group"))?").font(.title2)
            rows(
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(drafts, id: \.cluster.id) { draft in
                        Label("Keep **\(draft.survivor.displayName)** · delete \(draft.others.map(\.displayName).joined(separator: ", "))", systemImage: "person.2")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading),
                count: drafts.count
            )
            Text("\(ContactText.count(drafts.count, "group")) merged in “\(containerName)”, \(ContactText.count(deleting, "contact")) deleted in total.").font(.headline)
            Text("A new backup, including notes, is taken first. Phone, email and address entries from the deleted contacts are folded into the kept ones. If a group fails, the run stops and the rest are left untouched.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showingBulkSheet = false }
                Button("Merge \(ContactText.count(drafts.count, "group")) (delete \(ContactText.count(deleting, "contact")))", role: .destructive) {
                    Task { await model.bulkMerge() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(drafts.isEmpty || model.bulkMergeBlockReason != nil)
            }
        }
    }

    private var progressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            let progress = model.bulkProgress
            switch progress?.phase {
            case .merging:
                let total = progress?.total ?? 0
                Text("Merging \(min((progress?.completed ?? 0) + 1, total)) of \(total)").font(.title2)
                ProgressView(value: Double(progress?.completed ?? 0), total: Double(max(total, 1)))
            default:
                Text("Taking a backup first…").font(.title2)
                ProgressView()
            }
            Text(model.isStopRequested ? "Stopping after this group…" : "Stop finishes the group being merged, then leaves the rest untouched.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Stop") { model.stopBulkMerge() }.disabled(model.isStopRequested)
            }
        }
    }

    private func summary(_ report: BulkMergeReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch report.stop {
            case .completed:
                Text("Merged \(ContactText.count(report.mergedCount, "group"))").font(.title2)
            case .stoppedByUser:
                Text("Stopped after \(ContactText.count(report.mergedCount, "group"))").font(.title2)
            case .stoppedOnProblem:
                Text("Stopped at a problem").font(.title2)
            case .backupFailed(let reason):
                Text("Nothing was merged").font(.title2)
                Label("The backup could not be taken: \(reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if report.mergedCount > 0 {
                Text("\(ContactText.count(report.deletedCount, "duplicate contact")) deleted.\(report.receipt.map { " A backup was taken first (\(ContactText.count($0.manifest.counts.icloud ?? 0, "contact")))." } ?? "")")
            }
            if report.notRunCount > 0, report.receipt != nil { // no receipt: the backup failed and the title says so
                Text("\(ContactText.count(report.notRunCount, "group")) not run.").foregroundStyle(.secondary)
            }
            rows(
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.entries.enumerated()), id: \.offset) { _, entry in entryRow(entry) }
                }
                .frame(maxWidth: .infinity, alignment: .leading),
                count: report.entries.count
            )
            HStack {
                Spacer()
                Button("Done") { model.showingBulkSheet = false }.keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func entryRow(_ entry: BulkMergeReport.Entry) -> some View {
        let draft = entry.draft
        switch entry.outcome {
        case .merged(let survivor, let deleted, let notes, let links):
            VStack(alignment: .leading, spacing: 4) {
                mergedRow(survivor: survivor, deleted: deleted, notes: notes)
                MergeLinkNotes(links: links).font(.caption)
            }
        case .failed(let reason):
            Label("Failed: \(draft.survivor.displayName) and \(draft.others.map(\.displayName).joined(separator: ", ")). \(reason)", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .notRun:
            Label("Not run: \(draft.members.map(\.displayName).joined(separator: ", "))", systemImage: "minus.circle")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func mergedRow(survivor: ContactRecord, deleted: [ContactRecord], notes: MergeExecutor.NotesOutcome) -> some View {
        if case .writeFailed(let combined, let reason) = notes {
            VStack(alignment: .leading, spacing: 4) {
                Label("Merged: kept \(survivor.displayName), deleted \(deleted.map(\.displayName).joined(separator: ", ")). The combined note was not saved: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                BoundedText(text: combined, maxHeight: 100)
                Button("Copy combined note") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(combined, forType: .string)
                }
                Text("Paste it into the contact's note yourself. It is also in the backup.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Label("Merged: kept \(survivor.displayName), deleted \(deleted.map(\.displayName).joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Long text in a scroller of a definite height (short text takes only the room it needs).
struct BoundedText: View {
    let text: String
    let maxHeight: CGFloat

    var body: some View {
        let estimatedLines = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { $0 + max(1, $1.count / 60 + 1) }
        let height = min(max(CGFloat(estimatedLines) * 18 + 8, 30), maxHeight)
        ScrollView {
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
    }
}
