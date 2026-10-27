import Foundation

/// The user's working copy of one pair that needs a decision (`googleEdited` or `bothEdited`): for every field group the
/// iCloud and the Google side by side, and what the pair becomes once they choose. Pure value logic; nothing here reads or
/// writes a contact.
///
/// - A single-value group (name, nickname, company, birthday) is one pick: iCloud or Google. The default is Google where
///   only Google edited it, iCloud where both did or where the pair was only just linked, and always the side that has
///   something where the other has nothing.
/// - A list group (phones, emails, addresses, websites) has one row per entry, paired by its normalized key and judged
///   against both halves of the baseline. Every row says what happened (`EntryStatus`) and offers the actions that make
///   sense for it. A removal in Google is a row the user confirms, never silently undone, and an entry only Google has
///   stays Google-only unless the user adds it to iCloud.
/// - The note is a pick between iCloud, Google or both combined (`NotesMerge.combine`).
///
/// `resolve()` yields the iCloud record and note to save and the Google projection to send afterwards. Groups that are
/// not under review keep what the next sync would have done with them: iCloud's edits still flow to Google.
public struct SyncReviewDraft: Sendable, Hashable {
    public enum Side: Sendable, Hashable {
        case icloud, google
    }

    public enum NotePick: Sendable, Hashable {
        case icloud, google
        /// iCloud's note, then Google's if it adds anything.
        case combine
    }

    /// What happened to one list entry, from the pair's point of view.
    public enum EntryStatus: Sendable, Hashable {
        /// The same on both sides; nothing to decide.
        case both
        case addedInGoogle
        case removedInGoogle
        case changedInGoogle
        case changedInICloud
        /// Different on both sides, and both sides moved (or the pair was only just linked).
        case changedInBoth
        /// Google had it at the last sync and iCloud never did.
        case googleOnly
        /// New in iCloud: it will be added to Google.
        case addedInICloud
        case removedInICloud
    }

    public enum EntryAction: Sendable, Hashable {
        /// Nothing to choose: the entry stays (and, if only iCloud has it, goes to Google).
        case keep
        case addToICloud
        case keepInGoogleOnly
        case removeFromGoogle
        case removeFromICloud
        /// Google removed it: keep it in iCloud and put it back in Google.
        case keepInICloud
        case useICloud
        case useGoogle
        /// Drop the entry on both sides.
        case removeFromBoth
    }

    /// One single-value group on screen.
    public struct SingleRow: Sendable, Hashable, Identifiable {
        public var id: SyncField { field }
        public var field: SyncField
        public var icloudText: String
        public var googleText: String
        /// The two sides say different things.
        public var differs: Bool
        /// The group is one the pair needs a decision about.
        public var isReview: Bool
        public var pick: Side
        /// `chooseICloudEverywhere` found iCloud blank here and Google not: Google's value stays in Google and iCloud stays
        /// blank, rather than iCloud's nothing erasing it. Picking explicitly clears this.
        public var keepsGoogleOnly = false

        /// There is something to choose.
        public var needsChoice: Bool { isReview && differs }
    }

    /// One list entry on screen.
    public struct EntryRow: Sendable, Hashable, Identifiable {
        /// `"<group>|<normalized key>"`.
        public var id: String
        public var field: SyncField
        public var status: EntryStatus
        public var icloudText: String?
        public var googleText: String?
        /// The choices, the first being the one that follows Google's edit where there is one.
        public var actions: [EntryAction]
        public var action: EntryAction
        fileprivate var key: String
        fileprivate var inICloud: Bool
        fileprivate var inGoogle: Bool

        public var needsChoice: Bool { actions.count > 1 }

        /// `actions`, plus removing the entry where none of them does: any entry can be dropped while the pair is reviewed.
        public var choices: [EntryAction] {
            switch status {
            case .both, .changedInGoogle, .changedInICloud, .changedInBoth: actions + [.removeFromBoth]
            case .addedInICloud: actions + [.removeFromICloud]
            case .addedInGoogle, .removedInGoogle, .removedInICloud, .googleOnly: actions
            }
        }
    }

    public struct ListGroup: Sendable, Hashable, Identifiable {
        public var id: SyncField { field }
        public var field: SyncField
        public var rows: [EntryRow]
    }

    public struct NoteRow: Sendable, Hashable {
        public var icloudText: String
        public var googleText: String
        /// What combining would give; nil when both are blank.
        public var combinedText: String?
        public var pick: NotePick
        public var differs: Bool
        /// As `SingleRow.keepsGoogleOnly`, for the note.
        public var keepsGoogleOnly = false
    }

    /// The pair as it becomes.
    public struct Resolution: Sendable, Hashable {
        /// The iCloud contact to save.
        public var icloud: ContactRecord
        /// The Google contact to send: Google's current values with the decisions (and iCloud's other edits) applied.
        public var google: ContactRecord
        /// The note both sides end up with; nil when the note is left alone (not under review, or unreadable).
        public var note: String?
        public var changesICloud: Bool
        public var changesGoogle: Bool
    }

    public private(set) var singleRows: [SingleRow]
    /// The list groups under review, in `SyncField` order.
    public private(set) var lists: [ListGroup]
    public private(set) var noteRow: NoteRow?
    /// The note is under review but one side's text is unknown, so it is left alone.
    public let noteUnreadable: Bool
    /// Every group the pair needs a decision about, in `SyncField` order.
    public let reviewFields: [SyncField]

    private let icloud: ContactRecord
    private let google: ContactRecord
    private let pushed: ContactRecord
    private let icloudNote: String?
    private let googleNote: String?
    private let notePushes: Bool

    /// - Parameters:
    ///   - reviewFields: the groups the review item names. Groups the three-way diff itself finds in conflict are added.
    ///   - icloudNote, googleNote: the note texts; nil when a side's note could not be read.
    public init(
        icloud: ContactRecord, google: ContactRecord, base: SyncBaseline, reviewFields: [SyncField] = [],
        icloudNote: String? = nil, googleNote: String? = nil
    ) {
        self.icloud = icloud
        self.google = google
        self.icloudNote = icloudNote
        self.googleNote = googleNote

        let diff = ThreeWayDiff.diff(
            icloud: icloud, google: google, base: base, icloudNoteHash: icloudNote.map(NoteHash.hash),
            googleNoteHash: googleNote.map(NoteHash.hash)
        )
        pushed = diff.desiredGoogle
        let review = Set(reviewFields).union(diff.reviewFields)
        self.reviewFields = SyncField.allCases.filter(review.contains)
        notePushes = diff.changes[.note] == .pushToGoogle && icloudNote != nil

        // A side with nothing never wins by default: saving would erase what the other side has.
        func defaultSide(_ field: SyncField, icloudText: String, googleText: String) -> Side {
            if icloudText.isBlank != googleText.isBlank { return icloudText.isBlank ? .google : .icloud }
            return diff.changes[field] == .googleEdited ? .google : .icloud
        }
        singleRows = Self.singleFields.map { field in
            let i = Self.text(field, icloud), g = Self.text(field, google)
            return SingleRow(
                field: field, icloudText: i, googleText: g, differs: Self.exact(field, icloud) != Self.exact(field, google),
                isReview: review.contains(field), pick: defaultSide(field, icloudText: i, googleText: g)
            )
        }

        var groups: [ListGroup] = []
        for field in SyncField.recordFields where review.contains(field) {
            let rows: [EntryRow]
            switch field {
            case .phones: rows = Self.rows(Specs.phones, icloud: icloud, google: google, base: base)
            case .emails: rows = Self.rows(Specs.emails, icloud: icloud, google: google, base: base)
            case .postalAddresses: rows = Self.rows(Specs.addresses, icloud: icloud, google: google, base: base)
            case .urls: rows = Self.rows(Specs.urls, icloud: icloud, google: google, base: base)
            default: continue
            }
            groups.append(ListGroup(field: field, rows: rows))
        }
        lists = groups

        if review.contains(.note) {
            if let icloudNote, let googleNote {
                noteRow = NoteRow(
                    icloudText: icloudNote, googleText: googleNote,
                    combinedText: NotesMerge.combine(survivor: icloudNote, others: [(id: google.id, note: googleNote)]),
                    pick: icloudNote.isBlank != googleNote.isBlank ? (icloudNote.isBlank ? .google : .icloud)
                        : diff.changes[.note] == .googleEdited ? .google : .icloud,
                    differs: NoteHash.hash(icloudNote) != NoteHash.hash(googleNote)
                )
                noteUnreadable = false
            } else {
                noteRow = nil
                noteUnreadable = true
            }
        } else {
            noteRow = nil
            noteUnreadable = false
        }
    }

    // MARK: choosing

    /// Nothing differs in any group under review: the pair already agrees.
    public var isSettled: Bool {
        !singleRows.contains(where: \.needsChoice) && !lists.contains { $0.rows.contains { $0.status != .both } }
            && noteRow?.differs != true
    }

    /// There is at least one thing the user has to choose.
    public var hasChoices: Bool {
        singleRows.contains(where: \.needsChoice) || lists.contains { $0.rows.contains(where: \.needsChoice) } || noteRow?.differs == true
    }

    public mutating func pick(_ field: SyncField, _ side: Side) {
        guard let index = singleRows.firstIndex(where: { $0.field == field && $0.needsChoice }) else { return }
        singleRows[index].pick = side
        singleRows[index].keepsGoogleOnly = false
    }

    /// Ignored unless `action` is one of the row's choices.
    public mutating func setAction(_ action: EntryAction, forEntry id: String) {
        for g in lists.indices {
            guard let r = lists[g].rows.firstIndex(where: { $0.id == id }), lists[g].rows[r].choices.contains(action) else { continue }
            lists[g].rows[r].action = action
        }
    }

    public mutating func pickNote(_ pick: NotePick) {
        noteRow?.pick = pick
        noteRow?.keepsGoogleOnly = false
    }

    /// iCloud's values win everywhere: they are what Google gets, and entries only Google has stay Google-only. This is
    /// what "Keep iCloud for all" does to a pair that was only just linked.
    public mutating func chooseICloudEverywhere() {
        for index in singleRows.indices where singleRows[index].needsChoice {
            singleRows[index].pick = .icloud
            // iCloud having nothing is not a decision to erase what Google has.
            singleRows[index].keepsGoogleOnly = singleRows[index].icloudText.isBlank && !singleRows[index].googleText.isBlank
        }
        for g in lists.indices {
            for r in lists[g].rows.indices {
                let preferred: EntryAction? = switch lists[g].rows[r].status {
                case .changedInGoogle, .changedInICloud, .changedInBoth: .useICloud
                case .removedInGoogle: .keepInICloud
                case .removedInICloud: .removeFromGoogle
                case .addedInGoogle, .googleOnly: .keepInGoogleOnly
                case .both, .addedInICloud: nil
                }
                if let preferred, lists[g].rows[r].actions.contains(preferred) { lists[g].rows[r].action = preferred }
            }
        }
        if let row = noteRow {
            noteRow?.pick = .icloud
            noteRow?.keepsGoogleOnly = row.differs && row.icloudText.isBlank && !row.googleText.isBlank
        }
    }

    /// The groups `chooseICloudEverywhere` left as Google has them because iCloud has nothing there.
    public var keptFromGoogle: [SyncField] {
        singleRows.filter { $0.needsChoice && $0.keepsGoogleOnly }.map(\.field) + (noteRow?.keepsGoogleOnly == true ? [.note] : [])
    }

    // MARK: result

    public func resolve() -> Resolution {
        var resolvedICloud = icloud
        var resolvedGoogle = pushed

        for row in singleRows where row.needsChoice && !row.keepsGoogleOnly {
            let source = row.pick == .icloud ? icloud : google
            resolvedICloud.copy(row.field, from: source)
            resolvedGoogle.copy(row.field, from: source)
        }
        for group in lists {
            switch group.field {
            case .phones: Self.apply(Specs.phones, group.rows, icloud: icloud, google: google, to: &resolvedICloud, and: &resolvedGoogle)
            case .emails: Self.apply(Specs.emails, group.rows, icloud: icloud, google: google, to: &resolvedICloud, and: &resolvedGoogle)
            case .postalAddresses:
                Self.apply(Specs.addresses, group.rows, icloud: icloud, google: google, to: &resolvedICloud, and: &resolvedGoogle)
            case .urls: Self.apply(Specs.urls, group.rows, icloud: icloud, google: google, to: &resolvedICloud, and: &resolvedGoogle)
            default: break
            }
        }

        var note: String?
        if let noteRow, noteRow.keepsGoogleOnly {
            note = nil
        } else if let noteRow {
            switch noteRow.pick {
            case .icloud: note = noteRow.icloudText
            case .google: note = noteRow.googleText
            case .combine: note = noteRow.combinedText ?? ""
            }
        } else if notePushes {
            note = icloudNote
        }

        return Resolution(
            icloud: resolvedICloud, google: resolvedGoogle, note: note,
            changesICloud: Self.projection(resolvedICloud) != Self.projection(icloud),
            changesGoogle: Self.projection(resolvedGoogle) != Self.projection(google)
        )
    }

    private static func projection(_ record: ContactRecord) -> String {
        SyncJournalEntry.projectionHash(of: record, fields: Set(SyncField.recordFields), noteHash: "")
    }

    // MARK: single-value groups

    private static let singleFields: [SyncField] = [.name, .nickname, .organization, .birthday]

    private static func text(_ field: SyncField, _ record: ContactRecord) -> String {
        switch field {
        case .name: [record.givenName, record.middleName, record.familyName].filter { !$0.isBlank }.joined(separator: " ")
        case .nickname: record.nickname
        case .organization: [record.organization, record.jobTitle].filter { !$0.isBlank }.joined(separator: " · ")
        case .birthday: birthdayText(record.birthday)
        default: ""
        }
    }

    /// As spelled, so a case or spacing edit still counts as a difference (surrounding whitespace aside).
    private static func exact(_ field: SyncField, _ record: ContactRecord) -> String {
        let trim = { (text: String) in text.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch field {
        case .name: return [record.givenName, record.middleName, record.familyName].map(trim).joined(separator: "\u{1F}")
        case .nickname: return trim(record.nickname)
        case .organization: return [record.organization, record.jobTitle].map(trim).joined(separator: "\u{1F}")
        case .birthday: return birthdayText(record.birthday)
        default: return ""
        }
    }

    private static func birthdayText(_ birthday: DateComponents?) -> String {
        guard let birthday, let month = birthday.month, let day = birthday.day else { return "" }
        let year = birthday.year.map { String(format: "%04d-", $0) } ?? "--"
        return year + String(format: "%02d-%02d", month, day)
    }

    // MARK: list groups

    /// How one list group reads its entries.
    private struct ListSpec<Value: Sendable & Hashable & Codable> {
        var path: WritableKeyPath<ContactRecord, [Labeled<Value>]>
        var key: (Value) -> String?
        var text: (Value) -> String
        var field: SyncField

        /// Label and value as spelled.
        func exact(_ entry: Labeled<Value>) -> String {
            (entry.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\u{1F}" + text(entry.value)
        }

        /// The label without case or surrounding whitespace.
        func label(_ entry: Labeled<Value>) -> String {
            (entry.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        /// "value (label)".
        func display(_ entry: Labeled<Value>) -> String {
            let label = (entry.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? text(entry.value) : "\(text(entry.value)) (\(label))"
        }

        /// Entries by key (the first wins), and the keys in list order.
        func index(_ list: [Labeled<Value>]) -> (order: [String], entries: [String: Labeled<Value>]) {
            var order: [String] = []
            var entries: [String: Labeled<Value>] = [:]
            for entry in list {
                guard let k = key(entry.value), entries[k] == nil else { continue }
                order.append(k)
                entries[k] = entry
            }
            return (order, entries)
        }
    }

    private enum Specs {
        static var phones: ListSpec<String> {
            ListSpec(path: \.phones, key: MergePlan.phoneKey, text: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, field: .phones)
        }

        static var emails: ListSpec<String> {
            ListSpec(path: \.emails, key: EmailNormalizer.normalize, text: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, field: .emails)
        }

        static var urls: ListSpec<String> {
            ListSpec(path: \.urls, key: MergePlan.urlKey, text: { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, field: .urls)
        }

        static var addresses: ListSpec<PostalAddress> {
            ListSpec(path: \.postalAddresses, key: MergePlan.addressKey, text: SyncReviewDraft.addressText, field: .postalAddresses)
        }
    }

    private static func addressText(_ address: PostalAddress) -> String {
        [address.street, address.city, address.state, address.postalCode, address.country]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func rows<Value>(_ spec: ListSpec<Value>, icloud: ContactRecord, google: ContactRecord, base: SyncBaseline) -> [EntryRow] {
        let i = spec.index(icloud[keyPath: spec.path]), g = spec.index(google[keyPath: spec.path])
        let bi = spec.index(base.icloud[keyPath: spec.path]).entries, bg = spec.index(base.google[keyPath: spec.path]).entries
        let keys = i.order + g.order.filter { i.entries[$0] == nil }

        return keys.map { k in
            let mine = i.entries[k], theirs = g.entries[k]
            func moved(_ entry: Labeled<Value>?, since base: Labeled<Value>?) -> Bool {
                guard let entry else { return true }
                return base.map { spec.exact($0) != spec.exact(entry) } ?? true
            }

            let status: EntryStatus
            let actions: [EntryAction]
            let chosen: EntryAction
            switch (mine, theirs) {
            case (let mine?, let theirs?):
                let iMoved = moved(mine, since: bi[k]), gMoved = moved(theirs, since: bg[k])
                // Same label and the same value up to spelling (Google reformats phone numbers), or neither side moved since
                // they were last made equal: nothing to decide.
                if spec.exact(mine) == spec.exact(theirs) || spec.label(mine) == spec.label(theirs) || (!iMoved && !gMoved) {
                    (status, actions, chosen) = (.both, [.keep], .keep)
                } else {
                    if gMoved && !iMoved {
                        (status, actions, chosen) = (.changedInGoogle, [.useGoogle, .useICloud], .useGoogle)
                    } else if iMoved && !gMoved {
                        (status, actions, chosen) = (.changedInICloud, [.useICloud, .useGoogle], .useICloud)
                    } else {
                        (status, actions, chosen) = (.changedInBoth, [.useICloud, .useGoogle], .useICloud)
                    }
                }
            case (let mine?, nil):
                if bg[k] != nil {
                    // Google took it away. If iCloud also edited it, keeping it is the safe default.
                    (status, actions) = (.removedInGoogle, [.removeFromICloud, .keepInICloud])
                    chosen = moved(mine, since: bi[k]) ? .keepInICloud : .removeFromICloud
                } else {
                    (status, actions, chosen) = (.addedInICloud, [.keep], .keep)
                }
            case (nil, let theirs?):
                if bi[k] != nil {
                    (status, actions) = (.removedInICloud, [.removeFromGoogle, .addToICloud])
                    chosen = moved(theirs, since: bg[k]) ? .addToICloud : .removeFromGoogle
                } else if bg[k] != nil {
                    (status, actions, chosen) = (.googleOnly, [.keepInGoogleOnly, .addToICloud, .removeFromGoogle], .keepInGoogleOnly)
                } else {
                    (status, actions, chosen) = (.addedInGoogle, [.addToICloud, .keepInGoogleOnly, .removeFromGoogle], .addToICloud)
                }
            case (nil, nil):
                preconditionFailure("a key comes from one of the two lists")
            }
            return EntryRow(
                id: "\(spec.field.rawValue)|\(k)", field: spec.field, status: status, icloudText: mine.map(spec.display),
                googleText: theirs.map(spec.display), actions: actions, action: chosen, key: k, inICloud: mine != nil, inGoogle: theirs != nil
            )
        }
    }

    /// Rebuilds one list group on both sides from the user's actions. Entries without a key (blank values) stay where they are.
    private static func apply<Value>(
        _ spec: ListSpec<Value>, _ rows: [EntryRow], icloud: ContactRecord, google: ContactRecord,
        to resolvedICloud: inout ContactRecord, and resolvedGoogle: inout ContactRecord
    ) {
        let action = Dictionary(rows.map { ($0.key, $0.action) }, uniquingKeysWith: { first, _ in first })
        let i = spec.index(icloud[keyPath: spec.path]), g = spec.index(google[keyPath: spec.path])

        var forICloud: [Labeled<Value>] = []
        var replaced = Set<String>()
        for entry in icloud[keyPath: spec.path] {
            guard let k = spec.key(entry.value), let chosen = action[k] else {
                forICloud.append(entry)
                continue
            }
            switch chosen {
            case .removeFromICloud, .removeFromBoth: continue
            case .useGoogle:
                if replaced.insert(k).inserted, let theirs = g.entries[k] { forICloud.append(theirs) }
            default: forICloud.append(entry)
            }
        }
        for k in g.order where i.entries[k] == nil && action[k] == .addToICloud {
            if let theirs = g.entries[k] { forICloud.append(theirs) }
        }

        var forGoogle: [Labeled<Value>] = []
        replaced = []
        for entry in google[keyPath: spec.path] {
            guard let k = spec.key(entry.value), let chosen = action[k] else {
                forGoogle.append(entry)
                continue
            }
            switch chosen {
            case .removeFromGoogle, .removeFromBoth: continue
            case .useICloud:
                if replaced.insert(k).inserted, let mine = i.entries[k] { forGoogle.append(mine) }
            default: forGoogle.append(entry)
            }
        }
        for k in i.order where g.entries[k] == nil && (action[k] == .keep || action[k] == .keepInICloud) {
            if let mine = i.entries[k] { forGoogle.append(mine) }
        }

        resolvedICloud[keyPath: spec.path] = forICloud
        resolvedGoogle[keyPath: spec.path] = forGoogle
    }
}
