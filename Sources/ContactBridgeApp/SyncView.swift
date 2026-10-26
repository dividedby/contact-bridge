import ContactBridgeCore
import SwiftUI

struct SyncView: View {
    let model: SyncModel
    let app: AppModel

    var body: some View {
        let snapshot = model.snapshot
        Group {
            if snapshot.status == .notStarted {
                ProgressView("Starting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case .disabled(let message) = snapshot.status {
                ContentUnavailableView {
                    Label("Syncing is off", systemImage: "lock.fill")
                } description: {
                    Text(message)
                }
            } else if !snapshot.firstSyncApproved {
                FirstSyncView(model: model, app: app)
            } else if app.review.isOpen {
                SyncReviewView(model: app.review, app: app)
            } else {
                SyncStatusView(model: model, app: app)
            }
        }
        .navigationTitle("Sync")
        .task(id: model.readyKey) { await model.screenAppeared() }
    }
}

// MARK: - first sync

/// What the first sync would do, before it does anything.
private struct FirstSyncView: View {
    let model: SyncModel
    let app: AppModel

    var body: some View {
        let snapshot = model.snapshot
        if case .notReady(let reason) = snapshot.status {
            notReady(reason)
        } else if let preview = snapshot.preview {
            preview.view(model: model, app: app, snapshot: snapshot)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(snapshot.isRunning ? "Looking at your contacts…" : "Preparing the preview…").foregroundStyle(.secondary)
                if case .failed(let message) = snapshot.status {
                    Text(message).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
                    Button("Try again") { Task { await model.refreshPreview() } }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notReady(_ reason: String) -> some View {
        ContentUnavailableView {
            Label("Not ready yet", systemImage: "exclamationmark.circle")
        } description: {
            Text(reason)
        } actions: {
            Button("Open Setup") { app.selection = .setup }
        }
    }
}

private extension SyncPreview {
    /// How many names a list shows before it says "and N more".
    static let listLimit = 200

    @MainActor @ViewBuilder
    func view(model: SyncModel, app: AppModel, snapshot: SyncSnapshot) -> some View {
        let blocked = pause.map { if case .needsConfirmation = $0 { false } else { true } } ?? false
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("First sync preview").font(.title2)
                    if case .failed(let message) = snapshot.status {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("The preview could not be refreshed: \(message)", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("What is shown is from \(generatedAt.formatted(date: .omitted, time: .shortened)) and may be out of date. Press Refresh preview to try again.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("Nothing has been changed yet. This is what Contact Bridge would do the first time it syncs. Nothing starts until you press Start syncing.")
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        CountTile(title: "Link", count: counts.link, systemImage: "link")
                        CountTile(title: "Create", count: counts.create, systemImage: "plus.circle")
                        CountTile(title: "Update", count: counts.update, systemImage: "pencil.circle")
                        CountTile(title: "Delete", count: counts.delete, systemImage: "trash.circle")
                        CountTile(title: "Review", count: counts.review, systemImage: "questionmark.circle")
                    }

                    if let pause {
                        Label(pause.explanation, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    warnings(app: app)

                    PreviewList(
                        title: "Link \(ContactText.count(links.count, "contact"))",
                        explanation: "These already exist in iCloud and Google. They are tied together; neither side is changed by linking.",
                        items: links
                    )
                    PreviewList(
                        title: "Create \(ContactText.count(creates.count, "contact")) in Google",
                        explanation: "These are in iCloud only. A copy is added to Google.",
                        items: creates
                    )
                    PreviewList(title: "Update \(ContactText.count(updates.count, "Google contact"))", explanation: "Changed in iCloud since they were linked.", items: updates)
                    PreviewList(
                        title: "Delete \(ContactText.count(deletes.count, "Google contact"))",
                        explanation: "Their iCloud contact is gone.",
                        items: deletes
                    )
                    PreviewList(
                        title: "Forget \(ContactText.count(forgottenLinks.count, "old link"))",
                        explanation: ForgottenLinks.explanation,
                        items: forgottenLinks
                    )
                    ReviewListView(
                        title: "Review \(ContactText.count(reviews.count, "item"))",
                        explanation: "These need your decision. Nothing is changed for them until you decide.",
                        items: reviews
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Backups").font(.headline)
                        ForEach(backups, id: \.self) { line in
                            Label(line, systemImage: "externaldrive").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle").foregroundStyle(.orange).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Preview from \(generatedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if snapshot.isRunning || model.isApproving { ProgressView().controlSize(.small) }
                Button("Refresh preview") { Task { await model.refreshPreview() } }
                    .disabled(snapshot.isRunning || model.isApproving)
                Button("Start syncing") { Task { await model.approve() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(snapshot.isRunning || model.isApproving || blocked)
                    .help(blocked ? "Fix the problem above first" : "Link, create and update contacts as listed, and keep both sides in sync from now on")
            }
            .padding(12)
        }
    }

    @MainActor @ViewBuilder
    private func warnings(app: AppModel) -> some View {
        if waitingForNotes > 0 || notesUnavailable {
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    waitingForNotes > 0
                        ? "\(ContactText.count(waitingForNotes, "contact")) can't be linked or created yet: their notes can't be read. Notes access is needed so no note is lost."
                        : "Notes can't be read, so notes will not sync.",
                    systemImage: "note.text"
                )
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                Button("Open Setup") { app.selection = .setup }
            }
        }
        if unlinkedWaitingForFullListing > 0 {
            Label("\(ContactText.count(unlinkedWaitingForFullListing, "contact")) wait for a full read of your Google contacts.", systemImage: "hourglass")
                .foregroundStyle(.orange)
        }
    }
}

private struct CountTile: View {
    let title: String
    let count: Int
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text("\(count)").font(.title.monospacedDigit().weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

private enum ForgottenLinks {
    static let explanation = "Their contact is gone from iCloud, so the saved link to Google is dropped. Nothing is deleted in Google for these."
}

/// An expandable list of contact names. Long lists show their first names and a count of the rest.
private struct PreviewList: View {
    let title: String
    let explanation: String
    let items: [SyncPreview.Item]

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(items.prefix(SyncPreview.listLimit)) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.name).lineLimit(1)
                            if let detail = item.detail, !detail.isEmpty {
                                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    if items.count > SyncPreview.listLimit {
                        Text("and \(items.count - SyncPreview.listLimit) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}

// MARK: - review list

extension ReviewKind {
    var title: String {
        switch self {
        case .googleEdited: "Edited in Google"
        case .bothEdited: "Edited in both places"
        case .newInGoogle: "New in Google"
        case .deletedInGoogle: "Deleted in Google"
        case .deletedInICloudEditedInGoogle: "Deleted here, edited in Google"
        case .possibleLink: "Possible match"
        case .photoConflict: "Photo differs"
        }
    }
}

/// One review item: what kind it is, who it is about, and what differs.
struct ReviewRow: View {
    let item: SyncReviewSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.kind.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.orange.opacity(0.2), in: Capsule())
            Text(item.name).lineLimit(1)
            if let detail = item.detail {
                Text("may be \(detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if !item.fields.isEmpty {
                Text(item.fields.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// The review items of the first-sync preview, kind and name. Nothing can be decided before syncing is approved.
private struct ReviewListView: View {
    let title: String
    let explanation: String
    let items: [SyncReviewSummary]

    var body: some View {
        if !items.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(explanation).font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
                    ForEach(items.prefix(SyncPreview.listLimit)) { item in ReviewRow(item: item) }
                    if items.count > SyncPreview.listLimit {
                        Text("and \(items.count - SyncPreview.listLimit) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Text(title).font(.headline)
            }
        }
    }
}

// MARK: - running

private struct SyncStatusView: View {
    let model: SyncModel
    let app: AppModel
    @Bindable private var review: ReviewModel

    init(model: SyncModel, app: AppModel) {
        self.model = model
        self.app = app
        review = app.review
    }

    var body: some View {
        let snapshot = model.snapshot
        Form {
            Section {
                HStack(spacing: 8) {
                    statusIcon(snapshot)
                    Text(statusText(snapshot)).font(.headline)
                    Spacer()
                }
                if let summary = snapshot.lastRun {
                    // Next to a status other than "Synced", the last run's result must not read like the current state.
                    Text(snapshot.status == .idle ? summary.text : "Last sync at \(Self.time(summary.finishedAt)): \(summary.text)")
                        .foregroundStyle(.secondary)
                    if let halted = summary.halted {
                        Label(haltedText(halted, retryAt: snapshot.nextAttemptAt), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if case .failed = snapshot.status, let retry = snapshot.nextAttemptAt {
                    Text("Trying again after \(retry.formatted(date: .omitted, time: .shortened)).").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Sync now") { Task { await model.syncNow() } }
                        .disabled(snapshot.isRunning || snapshot.isUserPaused || snapshot.confirmationSummary != nil)
                    if snapshot.isUserPaused {
                        Button("Resume") { Task { await model.resume() } }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Pause") { Task { await model.pause() } }
                            .help("Stop syncing until you resume. Nothing is read or written while paused.")
                    }
                    if snapshot.isRunning { ProgressView().controlSize(.small) }
                }
            }

            if let summary = snapshot.confirmationSummary {
                Section {
                    Label("Waiting for your OK", systemImage: "hand.raised.fill").font(.headline).foregroundStyle(.orange)
                    Text(summary).fixedSize(horizontal: false, vertical: true)
                    PreviewList(title: "Contacts whose links would be forgotten", explanation: ForgottenLinks.explanation, items: snapshot.pauseDetails)
                    Text("Nothing has been changed. Confirm if this is what you expect; otherwise keep syncing paused and look at your contacts first.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Confirm and continue") { Task { await model.confirm() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(snapshot.isRunning)
                        Button("Keep paused") { Task { await model.keepPaused() } }
                            .disabled(snapshot.isRunning)
                    }
                }
            }

            warningsSection(snapshot)

            reviewSection(snapshot)
        }
        .formStyle(.grouped)
        .sheet(isPresented: $review.showingBulk) { KeepICloudSheet(model: review) }
        .sheet(isPresented: $review.showingIgnored) { IgnoredSheet(model: review) }
    }

    // MARK: review list

    @ViewBuilder private func reviewSection(_ snapshot: SyncSnapshot) -> some View {
        let items = review.items
        let firstLink = review.firstLinkItems
        Section("Needs your review") {
            if let message = review.resultMessage {
                Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            if items.isEmpty {
                Text("Nothing to review.").foregroundStyle(.secondary)
            } else {
                Text("\(ContactText.count(items.count, "item")) waiting. Open one to decide. Nothing is changed for them until you do.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(items.prefix(SyncPreview.listLimit)) { item in
                    Button { Task { await review.open(item.id) } } label: {
                        HStack {
                            ReviewRow(item: item)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if items.count > SyncPreview.listLimit {
                    Text("and \(items.count - SyncPreview.listLimit) more").font(.caption).foregroundStyle(.secondary)
                }
                if firstLink.count > 1 {
                    Button("Keep iCloud for all \(firstLink.count) first-link conflicts…") { review.startBulk() }
                        .help("Two contacts that were linked for the first time disagree. Keep iCloud's values, send them to Google, and keep what only Google has.")
                }
            }
            Button("Show ignored contacts…") { Task { await review.showIgnored() } }
                .help("Google contacts you chose not to import, with a way to bring them back")
        }
    }

    // MARK: status

    private func statusText(_ snapshot: SyncSnapshot) -> String {
        switch snapshot.status {
        case .notStarted: return "Starting…"
        case .disabled(let message): return message
        case .notReady(let reason): return "Not ready: \(reason)"
        case .idle:
            guard let at = snapshot.lastRunAt else { return "Waiting for the first sync" }
            return "Synced at \(Self.time(at))"
        case .running(let phase): return "Syncing… \(phase.title)"
        case .paused(.user): return "Paused"
        case .paused(let reason): return "Paused: \(reason.explanation)"
        case .failed(let message): return "The last sync failed: \(message)"
        }
    }

    @ViewBuilder private func statusIcon(_ snapshot: SyncSnapshot) -> some View {
        switch snapshot.status {
        case .running: ProgressView().controlSize(.small)
        case .paused: Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        case .failed, .notReady, .disabled: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .idle:
            if snapshot.lastRun?.halted != nil {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .notStarted: ProgressView().controlSize(.small)
        }
    }

    private func haltedText(_ reason: String, retryAt: Date?) -> String {
        let retry = retryAt.map { " Trying again after \(Self.time($0))." } ?? ""
        return "Stopped early: \(reason)\(retry)"
    }

    /// Today's times as "3:41 PM", other days with the date.
    private static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: warnings

    @ViewBuilder private func warningsSection(_ snapshot: SyncSnapshot) -> some View {
        let leftBehind = snapshot.lastRun?.leftForNextRun ?? 0
        let conflicts = snapshot.lastRun?.conflictsFound ?? 0
        let blocked = snapshot.lastRun?.blockedByReview ?? 0
        let warnings = snapshot.lastRun?.warnings ?? []
        if snapshot.notesUnavailable || snapshot.waitingForNotes > 0 || snapshot.unlinkedWaitingForFullListing > 0
            || snapshot.unconfirmedCreates > 0 || leftBehind > 0 || conflicts > 0 || blocked > 0 || !warnings.isEmpty
            || snapshot.pauseSaveWarning != nil {
            Section("Heads up") {
                if let saveWarning = snapshot.pauseSaveWarning {
                    Label(saveWarning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if snapshot.notesUnavailable || snapshot.waitingForNotes > 0 {
                    Label(notesText(snapshot), systemImage: "note.text").foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Setup") { app.selection = .setup }
                }
                if snapshot.unlinkedWaitingForFullListing > 0 {
                    Label(
                        "\(ContactText.count(snapshot.unlinkedWaitingForFullListing, "contact")) wait for a full read of your Google contacts. This resolves on the next run.",
                        systemImage: "hourglass"
                    )
                    .foregroundStyle(.orange)
                }
                if snapshot.unconfirmedCreates > 0 {
                    Label(
                        "\(ContactText.count(snapshot.unconfirmedCreates, "new contact")) sent to Google but not confirmed yet. They are checked again in about 10 minutes; nothing is created twice.",
                        systemImage: "clock"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if conflicts > 0 {
                    Label("\(ContactText.count(conflicts, "contact")) changed in Google while syncing. They are in the review list.", systemImage: "arrow.left.arrow.right")
                        .foregroundStyle(.orange)
                }
                if blocked > 0 {
                    Label("\(ContactText.count(blocked, "delete")) held back because the contact is waiting for review.", systemImage: "hand.raised")
                        .foregroundStyle(.secondary)
                }
                if leftBehind > 0 {
                    Label("\(ContactText.count(leftBehind, "change")) will be tried again on the next run.", systemImage: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func notesText(_ snapshot: SyncSnapshot) -> String {
        if snapshot.waitingForNotes > 0 {
            return "\(ContactText.count(snapshot.waitingForNotes, "new contact")) can't sync yet: their notes can't be read. Grant notes access in Setup so no note is lost."
        }
        return "Notes can't be read, so notes are not syncing. Grant notes access in Setup."
    }
}
