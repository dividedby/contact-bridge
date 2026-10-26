import Foundation

/// What happened to one field group since the last sync, from the pair's point of view.
public enum FieldChange: Sendable, Hashable {
    case unchanged
    /// Edited in iCloud only: send it to Google.
    case pushToGoogle
    /// Edited in Google only: needs the user's decision (review item), nothing is written.
    case googleEdited
    /// Edited on both sides to the same result: only the baselines move.
    case bothEditedEqual
    /// Edited on both sides to different results: review item.
    case bothEditedDifferent
    /// Edited in Google, but only entries iCloud never had: only `baseline.google` moves.
    case googleOnlyChange

    public var needsReview: Bool { self == .googleEdited || self == .bothEditedDifferent }
}

public struct LinkDiff: Sendable, Hashable {
    public var changes: [SyncField: FieldChange]
    /// Groups to write to Google, review groups excluded. Empty when nothing needs sending.
    public var pushFields: Set<SyncField>
    /// Groups held back for the user, in `SyncField` order.
    public var reviewFields: [SyncField]
    /// The Google record to send: Google's current values with the iCloud edits of `pushFields` applied. Feed it to
    /// `GooglePersonMapper.updatePayload(for:existing:restrictedTo:)`. It carries no note; the note text is supplied
    /// separately when `pushFields` contains `.note`.
    public var desiredGoogle: ContactRecord
    /// The baseline once the pushes are confirmed. Groups under review keep their old values on both sides, so the
    /// review is derived again next run. `google` holds `desiredGoogle` (replace it with what Google returns), and
    /// `googleEtag` is only current if the caller passed the etag it listed, and stays the old one while any group is
    /// held for review.
    public var updatedBaseline: SyncBaseline

    public var needsPush: Bool { !pushFields.isEmpty }
    public var needsReview: Bool { !reviewFields.isEmpty }
}

/// Compares each side of a linked pair against the baseline, one field group at a time.
///
/// "Changed since the baseline" is judged on the exact values (surrounding whitespace aside), so a case or accent edit in
/// iCloud is copied to Google. The normalized keys (phone E.164, lowercase email, host-folded URL, folded address,
/// folded text) only pair up list entries and decide whether two edits agree.
public enum ThreeWayDiff {
    /// - Parameters:
    ///   - icloudNoteHash, googleNoteHash: `NoteHash.hash` of each side's current note, nil only when that side's note was
    ///     not read. A note that was read and is empty is known: pass `NoteHash.hash("")`. Google's biographies are
    ///     always known after a fetch, so a Google contact without a note is `NoteHash.hash("")`, never nil.
    ///
    ///     The note is only compared when all four hashes (both current, both in the baseline) are known; otherwise it is
    ///     `unchanged`, is never pushed, and the baseline hashes stay as they are.
    ///   - googleEtag: the etag of `google`, recorded in `updatedBaseline` when given and nothing is held
    ///     for review.
    ///   - labelsMatter: whether two edited list entries with the same key but different labels disagree. They do in an
    ///     ongoing sync (a relabel is an edit to carry over). Linking two existing contacts passes false: each side keeps
    ///     its own labels, and only entries one side lacks are a difference.
    public static func diff(
        icloud: ContactRecord, google: ContactRecord, base: SyncBaseline,
        icloudNoteHash: String? = nil, googleNoteHash: String? = nil, googleEtag: String? = nil, labelsMatter: Bool = true,
        at now: Date = Date()
    ) -> LinkDiff {
        var changes: [SyncField: FieldChange] = [:]
        var pushFields = Set<SyncField>()
        var desired = google

        for field in SyncField.recordFields {
            let change = classify(field, icloud: icloud, google: google, base: base, labelsMatter: labelsMatter)
            changes[field] = change
            // Two edits that agree after normalizing still send iCloud's exact form when it differs from Google's.
            guard change == .pushToGoogle || change == .bothEditedEqual else { continue }
            var candidate = desired
            if isList(field) {
                applyDesiredList(field, icloud: icloud, base: base.icloud, to: &candidate)
            } else {
                candidate.copy(field, from: icloud)
            }
            if exact(field, candidate) != exact(field, google) || orderedEntries(field, candidate) != orderedEntries(field, google) {
                desired = candidate
                pushFields.insert(field)
            }
        }

        let noteChange = classifyNote(
            icloud: icloudNoteHash, google: googleNoteHash, baseIcloud: base.icloudNoteHash, baseGoogle: base.googleNoteHash
        )
        changes[.note] = noteChange
        let pushesNote = noteChange == .pushToGoogle && googleNoteHash != icloudNoteHash
        if pushesNote { pushFields.insert(.note) }

        let reviewFields = SyncField.allCases.filter { changes[$0]?.needsReview == true }
        let held = Set(reviewFields)

        var baseline = base
        baseline.syncedAt = now
        // While a group is held for review the baseline still lacks Google's edit of it. The etag must stay behind too:
        // the planner reads "same etag as the baseline" as "Google changed nothing" and would never see the edit again.
        if let googleEtag, held.isEmpty { baseline.googleEtag = googleEtag }
        for field in SyncField.recordFields where !held.contains(field) {
            baseline.icloud.copy(field, from: icloud)
            baseline.google.copy(field, from: desired)
        }
        if !held.contains(.note), let icloudNoteHash, let googleNoteHash, base.icloudNoteHash != nil, base.googleNoteHash != nil {
            baseline.icloudNoteHash = icloudNoteHash
            baseline.googleNoteHash = pushesNote ? icloudNoteHash : googleNoteHash
        }

        return LinkDiff(
            changes: changes, pushFields: pushFields, reviewFields: reviewFields, desiredGoogle: desired,
            updatedBaseline: baseline
        )
    }

    /// Whether Google moved the contact on since the baseline: a different etag AND a different projection (etags churn
    /// without edits). iCloud is held at the baseline, so only Google's side counts. Used before deleting a Google contact
    /// because its iCloud one is gone.
    static func googleChanged(_ person: GooglePerson, since baseline: SyncBaseline, at now: Date) -> Bool {
        guard person.etag != baseline.googleEtag, let record = GooglePersonMapper.record(from: person, source: .google) else { return false }
        let diff = diff(
            icloud: baseline.icloud, google: record, base: baseline,
            icloudNoteHash: baseline.icloudNoteHash, googleNoteHash: GooglePersonMapper.noteHash(of: person), at: now
        )
        return diff.changes.values.contains { $0 != .unchanged }
    }

    // MARK: classification

    private static func classify(
        _ field: SyncField, icloud: ContactRecord, google: ContactRecord, base: SyncBaseline, labelsMatter: Bool
    ) -> FieldChange {
        guard isList(field) else {
            let iChanged = exact(field, icloud) != exact(field, base.icloud)
            let gChanged = exact(field, google) != exact(field, base.google)
            return resolve(iChanged: iChanged, gChanged: gChanged, equal: normalized(field, icloud) == normalized(field, google))
        }

        let baseICloud = exactMap(field, base.icloud)
        let baseGoogle = exactMap(field, base.google)
        let currentICloud = exactMap(field, icloud)
        let currentGoogle = exactMap(field, google)
        // Entries Google had that iCloud did not: they are never compared, only carried along.
        let googleOnly = Set(baseGoogle.keys).subtracting(baseICloud.keys)
        let iChanged = currentICloud != baseICloud
        let gChanged = currentGoogle.filter { !googleOnly.contains($0.key) } != baseGoogle.filter { !googleOnly.contains($0.key) }
        // An iCloud edit that adopts a Google-only entry makes it shared again.
        let stillGoogleOnly = googleOnly.subtracting(currentICloud.keys)
        let theirs = normalizedMap(field, google).filter { !stillGoogleOnly.contains($0.key) }
        let equal = labelsMatter ? normalizedMap(field, icloud) == theirs : Set(normalizedMap(field, icloud).keys) == Set(theirs.keys)
        let change = resolve(iChanged: iChanged, gChanged: gChanged, equal: equal)
        return change == .unchanged && currentGoogle != baseGoogle ? .googleOnlyChange : change
    }

    private static func resolve(iChanged: Bool, gChanged: Bool, equal: Bool) -> FieldChange {
        switch (iChanged, gChanged) {
        case (false, false): .unchanged
        case (true, false): .pushToGoogle
        case (false, true): .googleEdited
        case (true, true): equal ? .bothEditedEqual : .bothEditedDifferent
        }
    }

    private static func classifyNote(icloud: String?, google: String?, baseIcloud: String?, baseGoogle: String?) -> FieldChange {
        guard let icloud, let google, let baseIcloud, let baseGoogle else { return .unchanged }
        return resolve(iChanged: icloud != baseIcloud, gChanged: google != baseGoogle, equal: icloud == google)
    }

    // MARK: comparison keys

    private enum Snapshot: Equatable {
        case text(String)
    }

    private struct Entry: Equatable {
        var key: String
        /// Normalized label.
        var label: String
        /// Trimmed label and value as spelled.
        var exact: String
    }

    private static func isList(_ field: SyncField) -> Bool {
        switch field {
        case .phones, .emails, .postalAddresses, .urls: true
        default: false
        }
    }

    private static let separator = "\u{1F}"

    /// What a single-value group says, as spelled (surrounding whitespace aside).
    private static func exact(_ field: SyncField, _ record: ContactRecord) -> Snapshot {
        func text(_ parts: String...) -> Snapshot { .text(parts.map(trimmed).joined(separator: separator)) }
        switch field {
        case .name: return text(record.givenName, record.middleName, record.familyName)
        case .nickname: return text(record.nickname)
        case .organization: return text(record.organization, record.jobTitle)
        case .birthday: return text(birthdayText(record.birthday))
        case .phones, .emails, .postalAddresses, .urls: return .text(orderedEntries(field, record).map(\.exact).joined(separator: "\n"))
        case .note: return .text("")
        }
    }

    /// What a single-value group says after folding case, accents and spacing.
    private static func normalized(_ field: SyncField, _ record: ContactRecord) -> Snapshot {
        func text(_ parts: String...) -> Snapshot { .text(parts.map(MergePlan.comparisonKey).joined(separator: separator)) }
        switch field {
        case .name: return text(record.givenName, record.middleName, record.familyName)
        case .nickname: return text(record.nickname)
        case .organization: return text(record.organization, record.jobTitle)
        case .birthday: return text(birthdayText(record.birthday))
        case .phones, .emails, .postalAddresses, .urls, .note: return .text("")
        }
    }

    private static func birthdayText(_ birthday: DateComponents?) -> String {
        guard let birthday else { return "" }
        return "\(birthday.year.map(String.init) ?? "-")/\(birthday.month ?? 0)/\(birthday.day ?? 0)"
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Entry key to exact label and value.
    private static func exactMap(_ field: SyncField, _ record: ContactRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: orderedEntries(field, record).map { ($0.key, $0.exact) })
    }

    /// Entry key to normalized label.
    private static func normalizedMap(_ field: SyncField, _ record: ContactRecord) -> [String: String] {
        Dictionary(uniqueKeysWithValues: orderedEntries(field, record).map { ($0.key, $0.label) })
    }

    /// Non-blank entries in record order, one per key (the first wins).
    private static func orderedEntries(_ field: SyncField, _ record: ContactRecord) -> [Entry] {
        switch field {
        case .phones: entries(record.phones, key: MergePlan.phoneKey, text: trimmed)
        case .emails: entries(record.emails, key: EmailNormalizer.normalize, text: trimmed)
        case .urls: entries(record.urls, key: MergePlan.urlKey, text: trimmed)
        case .postalAddresses: entries(record.postalAddresses, key: MergePlan.addressKey, text: addressText)
        default: []
        }
    }

    private static func addressText(_ address: PostalAddress) -> String {
        [address.street, address.city, address.state, address.postalCode, address.country].map(trimmed).joined(separator: separator)
    }

    private static func entries<Value>(_ list: [Labeled<Value>], key: (Value) -> String?, text: (Value) -> String) -> [Entry] {
        var seen = Set<String>()
        return list.compactMap { entry in
            guard let key = key(entry.value), seen.insert(key).inserted else { return nil }
            return Entry(
                key: key, label: normalizedLabel(entry.label),
                exact: trimmed(entry.label ?? "") + separator + text(entry.value)
            )
        }
    }

    private static func normalizedLabel(_ label: String?) -> String {
        label?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    // MARK: desired Google lists

    private static func applyDesiredList(_ field: SyncField, icloud: ContactRecord, base: ContactRecord, to desired: inout ContactRecord) {
        switch field {
        case .phones:
            desired.phones = desiredList(icloud: icloud.phones, google: desired.phones, base: base.phones, key: MergePlan.phoneKey, text: trimmed)
        case .emails:
            desired.emails = desiredList(
                icloud: icloud.emails, google: desired.emails, base: base.emails, key: EmailNormalizer.normalize, text: trimmed
            )
        case .urls:
            desired.urls = desiredList(icloud: icloud.urls, google: desired.urls, base: base.urls, key: MergePlan.urlKey, text: trimmed)
        case .postalAddresses:
            desired.postalAddresses = desiredList(
                icloud: icloud.postalAddresses, google: desired.postalAddresses, base: base.postalAddresses,
                key: MergePlan.addressKey, text: addressText
            )
        default: break
        }
    }

    /// Google's current list, minus entries iCloud removed since the baseline, plus entries iCloud added that Google
    /// lacks (appended in iCloud order). An entry iCloud added or edited (value or label, as spelled) takes iCloud's
    /// spelling in place. Google-only entries, entries without a key, untouched entries in Google's spelling, and
    /// Google's order are kept. If iCloud removed every entry and Google has no Google-only ones, the list is empty.
    private static func desiredList<Value>(
        icloud: [Labeled<Value>], google: [Labeled<Value>], base: [Labeled<Value>], key: (Value) -> String?, text: (Value) -> String
    ) -> [Labeled<Value>] {
        func exactText(_ entry: Labeled<Value>) -> String { trimmed(entry.label ?? "") + separator + text(entry.value) }
        var current: [String: Labeled<Value>] = [:]
        var currentOrder: [String] = []
        for entry in icloud {
            guard let k = key(entry.value), current[k] == nil else { continue }
            current[k] = entry
            currentOrder.append(k)
        }
        var baseExact: [String: String] = [:]
        for entry in base {
            guard let k = key(entry.value), baseExact[k] == nil else { continue }
            baseExact[k] = exactText(entry)
        }

        var result: [Labeled<Value>] = []
        var present = Set<String>()
        for entry in google {
            guard let k = key(entry.value) else {
                result.append(entry)
                continue
            }
            present.insert(k)
            guard let mine = current[k] else {
                if baseExact[k] == nil { result.append(entry) }  // removed in iCloud when the baseline had it
                continue
            }
            result.append(baseExact[k] == exactText(mine) ? entry : mine)
        }
        for k in currentOrder where !present.contains(k) && baseExact[k] == nil {
            result.append(current[k]!)
        }
        return result
    }
}
