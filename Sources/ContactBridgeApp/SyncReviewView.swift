import ContactBridgeCore
import SwiftUI

/// One open review item, side by side: the iCloud contact, the Google contact, and what to do about it.
struct SyncReviewView: View {
    @Bindable var model: ReviewModel
    let app: AppModel

    var body: some View {
        Group {
            if let detail = model.detail {
                VStack(spacing: 0) {
                    header(detail)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let notice = model.notice {
                                Label(notice, systemImage: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            content(detail)
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider()
                    footer(detail)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .confirmationDialog(
                    model.confirming == .deleteFromICloud ? "Delete \(detail.name) from iCloud?" : "Delete \(detail.name) from Google too?",
                    isPresented: Binding(get: { model.confirming != nil }, set: { if !$0 { model.confirming = nil } }),
                    presenting: model.confirming
                ) { confirmation in
                    switch confirmation {
                    case .deleteFromICloud:
                        Button("Delete from iCloud", role: .destructive) { Task { await model.deleteFromICloud() } }
                    case .keepDeleted:
                        Button("Delete from Google", role: .destructive) { Task { await model.keepDeleted() } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { confirmation in
                    switch confirmation {
                    case .deleteFromICloud:
                        Text("\(detail.name) was deleted in Google. A backup with notes is taken first, then the contact is deleted here. You can get it back from that backup.")
                    case .keepDeleted:
                        Text("\(detail.name) was deleted here and edited in Google since. Deleting it from Google throws those edits away. A Google backup is taken first and the change is logged.")
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Reading both contacts…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: header and footer

    private func header(_ detail: ReviewDetail) -> some View {
        HStack(spacing: 12) {
            Button { model.close() } label: { Label("Back", systemImage: "chevron.left") }
                .disabled(model.isWorking)
            Text(detail.name).font(.title2).lineLimit(1)
            Text(detail.item.kind.title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.orange.opacity(0.2), in: Capsule())
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button("Read again") { Task { await model.reload() } }
                .disabled(model.isWorking || model.isLoading)
                .help("Read both contacts again, in case either changed")
        }
        .padding(12)
    }

    private func footer(_ detail: ReviewDetail) -> some View {
        let kind = detail.item.kind
        let busy = model.isWorking || model.isLoading
        return HStack(alignment: .center, spacing: 12) {
            // No fixedSize here: at the footer's minimum width it makes these captions wrap word by word, and the
            // resulting minimum height (~1600 pt) pushes the whole window's layout off screen.
            VStack(alignment: .leading, spacing: 2) {
                if let reason = blockReason(detail) {
                    Label(reason, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
                Label(Self.backupCaption(kind), systemImage: "externaldrive").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
            buttons(detail, disabled: busy)
        }
        .padding(12)
    }

    /// The first thing that stops the item's actions, if anything stops all of them.
    private func blockReason(_ detail: ReviewDetail) -> String? {
        switch detail.item.kind {
        case .googleEdited, .bothEdited: model.block(for: .save)
        case .newInGoogle: model.block(for: .importContact)
        case .deletedInGoogle: model.block(for: .deleteFromICloud)
        case .deletedInICloudEditedInGoogle: model.block(for: .restore)
        case .possibleLink: model.block(for: .link)
        }
    }

    @ViewBuilder private func buttons(_ detail: ReviewDetail, disabled: Bool) -> some View {
        switch detail.item.kind {
        case .googleEdited, .bothEdited:
            Button("Save to iCloud and Google") { Task { await model.save() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(disabled || model.block(for: .save) != nil || detail.draft == nil)
                .help("Save the choices to iCloud, then copy the result to Google")
        case .newInGoogle:
            Button("Ignore") { Task { await model.ignore() } }
                .disabled(disabled || model.blockReason != nil)
                .help("Never offer this contact again. Show ignored brings it back.")
            Button("Import to iCloud") { Task { await model.importContact() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(disabled || model.block(for: .importContact) != nil)
        case .deletedInGoogle:
            Button("Delete from iCloud…", role: .destructive) { model.confirming = .deleteFromICloud }
                .disabled(disabled || model.block(for: .deleteFromICloud) != nil)
            Button("Put back in Google") { Task { await model.putBack() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(disabled || model.block(for: .putBack) != nil)
        case .deletedInICloudEditedInGoogle:
            Button("Keep deleted…", role: .destructive) { model.confirming = .keepDeleted }
                .disabled(disabled || model.block(for: .keepDeleted) != nil)
                .help("Delete the Google contact too")
            Button("Restore to iCloud") { Task { await model.restore() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(disabled || model.block(for: .restore) != nil)
        case .possibleLink:
            Button("Keep separate") { Task { await model.keepSeparate() } }
                .disabled(disabled || model.block(for: .keepSeparate) != nil)
                .help("They are different people. The iCloud contact is created in Google.")
            Button("Link") { Task { await model.link() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(disabled || model.block(for: .link) != nil)
                .help("They are the same person")
        }
    }

    private static func backupCaption(_ kind: ReviewKind) -> String {
        switch kind {
        case .googleEdited, .bothEdited, .newInGoogle:
            "Before anything is written, a backup of iCloud and Google with notes is taken (one from the last hour is reused). Google changes are also logged."
        case .deletedInGoogle:
            "Delete takes a backup with notes first. Put back creates a new Google contact; a Google backup from the last day is reused."
        case .deletedInICloudEditedInGoogle:
            "Keep deleted takes a Google backup (a day old at most) and logs the change. Restore takes a backup with notes first."
        case .possibleLink:
            "Linking and keeping separate change nothing in your contacts."
        }
    }

    // MARK: content

    @ViewBuilder private func content(_ detail: ReviewDetail) -> some View {
        switch detail.item.kind {
        case .googleEdited, .bothEdited:
            if let draft = detail.draft {
                edits(detail, draft)
            } else {
                Label("One of the two contacts is not there any more. Go back and run Sync now.", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .newInGoogle:
            Text("This contact is in Google and not in iCloud. Import copies it (and its note) into iCloud and keeps the two in sync. Ignore leaves it out of iCloud and stops asking.")
                .foregroundStyle(.secondary)
            RecordComparison(left: nil, right: detail.google, leftTitle: "iCloud", rightTitle: "Google", leftNote: nil, rightNote: detail.googleNote)
        case .deletedInGoogle:
            Text("This contact was deleted in Google. Delete it from iCloud too, or put it back in Google as a new contact.")
                .foregroundStyle(.secondary)
            RecordComparison(left: detail.icloud, right: nil, leftTitle: "iCloud", rightTitle: "Google", leftNote: detail.icloudNote, rightNote: nil)
        case .deletedInICloudEditedInGoogle:
            Text("You deleted this contact from iCloud, but it was edited in Google since the last sync. Keep it deleted (the Google contact is deleted too), or restore it to iCloud from Google.")
                .foregroundStyle(.secondary)
            RecordComparison(
                left: detail.googleBefore, right: detail.google, leftTitle: "Before (last sync)", rightTitle: "Now in Google", leftNote: nil, rightNote: detail.googleNote
            )
        case .possibleLink:
            Text("These might be the same person. Link them to keep them in sync, or keep them separate and the iCloud contact is added to Google as its own.")
                .foregroundStyle(.secondary)
            RecordComparison(
                left: detail.icloud, right: detail.google, leftTitle: "iCloud", rightTitle: "Google", leftNote: detail.icloudNote, rightNote: detail.googleNote
            )
        }
    }

    @ViewBuilder private func edits(_ detail: ReviewDetail, _ draft: SyncReviewDraft) -> some View {
        Text(detail.item.kind == .googleEdited
            ? "This contact was edited in Google. Pick, field by field, what it should say. Your choices are saved to iCloud first, then copied back to Google."
            : "This contact differs between iCloud and Google. Pick, field by field, what it should say. Your choices are saved to iCloud first, then copied to Google.")
            .foregroundStyle(.secondary)
        if draft.isSettled {
            Label("The two sides agree now. Saving just records that.", systemImage: "checkmark.circle").foregroundStyle(.green)
        } else {
            Button("Use iCloud for everything") { model.chooseICloudEverywhere() }
                .help("iCloud's values win; entries only Google has stay in Google")
        }

        VStack(alignment: .leading, spacing: 10) {
            line(
                Text("Field"), Text("iCloud"), Text("Google"), Text("Use")
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            Divider()

            ForEach(draft.singleRows.filter { $0.differs || !$0.icloudText.isEmpty || !$0.googleText.isEmpty }) { row in
                line(
                    Text(row.field.label).font(.callout.weight(.medium)),
                    valueText(row.icloudText, highlighted: row.needsChoice),
                    valueText(row.googleText, highlighted: row.needsChoice),
                    singleChoice(row)
                )
            }

            ForEach(draft.lists) { group in
                Divider()
                Text(group.field.label).font(.callout.weight(.medium))
                ForEach(group.rows) { row in
                    line(
                        Text(row.status.title).font(.caption).foregroundStyle(row.status == .both ? .tertiary : .secondary),
                        valueText(row.icloudText ?? "—", highlighted: row.needsChoice),
                        valueText(row.googleText ?? "—", highlighted: row.needsChoice),
                        entryChoice(row)
                    )
                }
            }

            if let note = draft.noteRow {
                Divider()
                line(
                    Text("Note").font(.callout.weight(.medium)),
                    BoundedText(text: note.icloudText.isEmpty ? "—" : note.icloudText, maxHeight: 120),
                    BoundedText(text: note.googleText.isEmpty ? "—" : note.googleText, maxHeight: 120),
                    noteChoice(note)
                )
                if note.pick == .combine, let combined = note.combinedText {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("Both").font(.caption).foregroundStyle(.secondary).frame(width: Self.titleWidth, alignment: .leading)
                        BoundedText(text: combined, maxHeight: 140)
                    }
                }
            }
        }
        if draft.noteUnreadable {
            Label("The note changed, but it can't be read right now, so it is left as it is. Grant notes access in Setup.", systemImage: "note.text")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let titleWidth: CGFloat = 120
    private static let choiceWidth: CGFloat = 230

    /// One table row: a fixed-width heading, two flexible value columns and a fixed-width choice column.
    private func line(_ title: some View, _ icloud: some View, _ google: some View, _ choice: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            title.frame(width: Self.titleWidth, alignment: .leading)
            icloud.frame(maxWidth: .infinity, alignment: .leading)
            google.frame(maxWidth: .infinity, alignment: .leading)
            choice.frame(width: Self.choiceWidth, alignment: .leading)
        }
    }

    @ViewBuilder private func singleChoice(_ row: SyncReviewDraft.SingleRow) -> some View {
        if row.needsChoice {
            Picker("Use", selection: Binding(get: { row.pick }, set: { model.pick(row.field, $0) })) {
                Text("iCloud").tag(SyncReviewDraft.Side.icloud)
                Text("Google").tag(SyncReviewDraft.Side.google)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Text(row.differs ? "Next sync" : "Same").font(.caption).foregroundStyle(.tertiary)
                .help(row.differs ? "Not part of this decision: an edit in iCloud goes to Google on the next sync" : "")
        }
    }

    @ViewBuilder private func noteChoice(_ note: SyncReviewDraft.NoteRow) -> some View {
        if note.differs {
            Picker("Use", selection: Binding(get: { note.pick }, set: { model.pickNote($0) })) {
                Text("iCloud").tag(SyncReviewDraft.NotePick.icloud)
                Text("Google").tag(SyncReviewDraft.NotePick.google)
                Text("Both").tag(SyncReviewDraft.NotePick.combine)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } else {
            Text("Same").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func valueText(_ text: String, highlighted: Bool) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.callout)
            .foregroundStyle(text.isEmpty ? .tertiary : (highlighted ? .primary : .secondary))
            .textSelection(.enabled)
    }

    @ViewBuilder private func entryChoice(_ row: SyncReviewDraft.EntryRow) -> some View {
        if row.needsChoice {
            Picker("Use", selection: Binding(get: { row.action }, set: { model.setAction($0, forEntry: row.id) })) {
                ForEach(row.actions, id: \.self) { Text($0.title(for: row.status)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        } else if row.status == .addedInICloud {
            Text("Goes to Google").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("").font(.caption)
        }
    }
}

// MARK: - wording

private extension SyncField {
    /// The field group as a row heading.
    var label: String {
        switch self {
        case .name: "Name"
        case .nickname: "Nickname"
        case .organization: "Company"
        case .phones: "Phones"
        case .emails: "Emails"
        case .postalAddresses: "Addresses"
        case .urls: "Websites"
        case .birthday: "Birthday"
        case .note: "Note"
        }
    }
}

private extension SyncReviewDraft.EntryStatus {
    var title: String {
        switch self {
        case .both: "Same"
        case .addedInGoogle: "New in Google"
        case .removedInGoogle: "Removed in Google"
        case .changedInGoogle: "Changed in Google"
        case .changedInICloud: "Changed in iCloud"
        case .changedInBoth: "Different"
        case .googleOnly: "Only in Google"
        case .addedInICloud: "New in iCloud"
        case .removedInICloud: "Removed in iCloud"
        }
    }
}

private extension SyncReviewDraft.EntryAction {
    func title(for status: SyncReviewDraft.EntryStatus) -> String {
        switch self {
        case .keep: status == .addedInICloud ? "Add to Google" : "Keep"
        case .addToICloud: "Add to iCloud"
        case .keepInGoogleOnly: "Keep in Google only"
        case .removeFromGoogle: "Remove from Google"
        case .removeFromICloud: "Remove from iCloud"
        case .keepInICloud: "Keep, and put back in Google"
        case .useICloud: "Use iCloud's"
        case .useGoogle: "Use Google's"
        }
    }
}

// MARK: - read-only comparison

/// Two contacts (or the same contact at two times) in two columns, with the rows that differ marked.
private struct RecordComparison: View {
    let left: ContactRecord?
    let right: ContactRecord?
    let leftTitle: String
    let rightTitle: String
    let leftNote: String?
    let rightNote: String?

    var body: some View {
        let rows = Self.rows(left, right, leftNote: leftNote, rightNote: rightNote)
        VStack(alignment: .leading, spacing: 10) {
            line(Text("Field"), Text(leftTitle), Text(rightTitle))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            if rows.isEmpty { Text("Nothing to show.").foregroundStyle(.secondary) }
            ForEach(rows, id: \.title) { row in
                line(Text(row.title).font(.callout.weight(.medium)), cell(row.left, differs: row.differs), cell(row.right, differs: row.differs))
            }
        }
    }

    private func line(_ title: some View, _ left: some View, _ right: some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            title.frame(width: 120, alignment: .leading)
            left.frame(maxWidth: .infinity, alignment: .leading)
            right.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cell(_ text: String, differs: Bool) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.callout)
            .foregroundStyle(text.isEmpty ? .tertiary : (differs ? .primary : .secondary))
            .textSelection(.enabled)
    }

    private struct Row {
        var title: String
        var left: String
        var right: String
        var differs: Bool { left != right }
    }

    private static func rows(_ left: ContactRecord?, _ right: ContactRecord?, leftNote: String?, rightNote: String?) -> [Row] {
        func texts(_ record: ContactRecord?, _ note: String?) -> [(String, String)] {
            guard let record else { return [] }
            return [
                ("Name", [record.givenName, record.middleName, record.familyName].filter { !$0.isBlank }.joined(separator: " ")),
                ("Nickname", record.nickname),
                ("Company", [record.organization, record.jobTitle].filter { !$0.isBlank }.joined(separator: " · ")),
                ("Phones", ContactText.phonesOrEmails(record.phones)),
                ("Emails", ContactText.phonesOrEmails(record.emails)),
                ("Addresses", ContactText.addresses(record.postalAddresses)),
                ("Websites", ContactText.phonesOrEmails(record.urls)),
                ("Birthday", ContactText.birthday(record.birthday)),
                ("Note", note ?? ""),
            ]
        }
        let a = texts(left, leftNote), b = texts(right, rightNote)
        let titles = ["Name", "Nickname", "Company", "Phones", "Emails", "Addresses", "Websites", "Birthday", "Note"]
        return titles.compactMap { title in
            let l = a.first { $0.0 == title }?.1 ?? "", r = b.first { $0.0 == title }?.1 ?? ""
            return l.isEmpty && r.isEmpty ? nil : Row(title: title, left: l, right: r)
        }
    }
}

// MARK: - keep iCloud for all

/// One confirmation listing the first-link conflicts, then what happened to each.
struct KeepICloudSheet: View {
    @Bindable var model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isBulkWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Keeping iCloud's values…")
                }
            } else if let report = model.bulkReport {
                summary(report)
            } else {
                confirmation
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var confirmation: some View {
        let items = model.firstLinkItems
        return VStack(alignment: .leading, spacing: 12) {
            Text("Keep iCloud for \(ContactText.count(items.count, "contact"))?").font(.title2)
            Text("These contacts exist in iCloud and Google and disagree. For all of them, iCloud's values are sent to Google. Phones, emails and other entries that only Google has stay in Google. Nothing in iCloud changes.")
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        Label {
                            HStack {
                                Text(item.name)
                                Text(item.fields.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(items.count) * 28 + 8, 260))
            Text("A backup of iCloud and Google is taken first if the last one is old, and each Google change is logged.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.showingBulk = false }
                Button("Keep iCloud for all") { Task { await model.keepICloudForAll() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.block(for: .save) != nil || items.isEmpty)
            }
        }
    }

    private func summary(_ report: BulkKeepReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Done").font(.title2)
            Label("Kept iCloud's values for \(ContactText.count(report.applied.count, "contact")).", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if !report.skipped.isEmpty || !report.changedSinceShown.isEmpty {
                Label("\(ContactText.count(report.skipped.count + report.changedSinceShown.count, "item")) left in the list: they changed since you looked, or are gone. Look at them one by one.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.failed, id: \.itemID) { failure in
                Label("\(failure.name): \(failure.reason)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { model.showingBulk = false }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

// MARK: - ignored contacts

/// Google contacts the user chose not to import, with a way to bring each back.
struct IgnoredSheet: View {
    @Bindable var model: ReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ignored contacts").font(.title2)
            Text("These Google contacts are not offered for import, even if they change. Show again offers one on the next sync.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.isLoadingIgnored {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading them from Google…")
                }
            } else if model.ignored.isEmpty {
                Text("You have not ignored any contacts.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.ignored) { contact in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(contact.name)
                                    if let detail = contact.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Button("Show again") { Task { await model.unignore(contact) } }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(model.ignored.count) * 44 + 8, 300))
            }
            HStack {
                Spacer()
                Button("Done") { model.showingIgnored = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
