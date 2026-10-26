import Foundation

/// Single-value fields where members can disagree and the user has to choose.
public enum MergeField: String, Sendable, Hashable, Codable, CaseIterable {
    case givenName
    case middleName
    case familyName
    case nickname
    case organization
    case jobTitle
    case birthday
}

public struct MergeCandidate: Sendable, Hashable {
    /// The record that holds exactly this value; picking it yields this value. For birthdays that agree up to a missing
    /// year, this is the record that has the year.
    public var recordID: String
    /// Display text; birthdays render as `YYYY-MM-DD`, or `--MM-DD` without a year.
    public var value: String
}

/// Members disagree on a single-value field and no pick was supplied.
public struct MergeConflict: Sendable, Hashable {
    public var field: MergeField
    /// One per distinct value, survivor's first.
    public var candidates: [MergeCandidate]
    /// The first candidate: used in `MergePlan.merged`. That is the survivor's value, or the first non-blank one if the
    /// survivor has none (or, for birthdays, the first value that completes the survivor's year-less one).
    public var proposedRecordID: String
}

public enum MergeListField: String, Sendable, Hashable, Codable, CaseIterable {
    case phones
    case emails
    case postalAddresses
    case urls
}

/// A label that lost a collision: the same value appeared under a different label than the one kept.
public struct DroppedLabel: Sendable, Hashable {
    public var field: MergeListField
    /// The kept entry's value as stored in `MergePlan.merged`.
    public var value: String
    public var keptLabel: String
    public var droppedLabel: String
}

/// A description of a merge. Building one has no side effects; executing it is the caller's job, behind a backup gate.
public struct MergePlan: Sendable, Hashable {
    /// The record to update with `merged`.
    public var survivorID: String
    /// Records the merge implies deleting: `others` minus the survivor, deduplicated, in the order given.
    public var deleteIDs: [String]
    /// Survivor identity (id, source, sourceIdentifier) with the merged field values. Never contains unresolved guesses
    /// silently: where `conflicts` has an entry, this holds the proposed default.
    public var merged: ContactRecord
    /// Ordered as `MergeField.allCases`.
    public var conflicts: [MergeConflict]
    /// Picks that named a record that is not a member, or one with no value for the field. They were ignored.
    public var invalidPicks: [MergeField]
    /// Labels discarded when duplicate multi-value entries collapsed (survivor's label is kept), for the UI to show.
    public var droppedLabels: [DroppedLabel]

    public var hasUnresolvedConflicts: Bool { !conflicts.isEmpty }

    /// True when applying the plan would change nothing: no deletions and the survivor already equals the merged result.
    public func isNoOp(for survivor: ContactRecord) -> Bool {
        deleteIDs.isEmpty && merged == survivor
    }

    /// - Parameter picks: for each field, the id of the member whose value to take.
    public static func build(
        survivor: ContactRecord,
        others: [ContactRecord],
        picks: [MergeField: String] = [:]
    ) -> MergePlan {
        var seenIDs: Set<String> = [survivor.id]
        let distinctOthers = others.filter { seenIDs.insert($0.id).inserted }
        let members = [survivor] + distinctOthers

        var merged = survivor
        var conflicts: [MergeConflict] = []
        var invalidPicks: [MergeField] = []

        for field in MergeField.allCases {
            switch field {
            case .birthday:
                let outcome = resolve(
                    field, members: members, picks: picks,
                    value: { $0.birthday },
                    isSame: Self.birthdaysAgree,
                    prefersNew: { current, new in current.year == nil && new.year != nil },
                    display: Self.display
                )
                merged.birthday = outcome.value
                outcome.apply(&conflicts, &invalidPicks)
            default:
                let path = Self.textPath(for: field)
                let outcome = resolve(
                    field, members: members, picks: picks,
                    value: { $0[keyPath: path].isBlank ? nil : $0[keyPath: path] },
                    isSame: { Self.comparisonKey($0) == Self.comparisonKey($1) },
                    prefersNew: { _, _ in false },
                    display: { $0 }
                )
                merged[keyPath: path] = outcome.value ?? ""
                outcome.apply(&conflicts, &invalidPicks)
            }
        }

        var droppedLabels: [DroppedLabel] = []
        merged.phones = unionLabeled(.phones, members.map(\.phones), key: Self.phoneKey, describe: { $0 }, dropped: &droppedLabels)
        merged.emails = unionLabeled(
            .emails, members.map(\.emails), key: { EmailNormalizer.normalize($0) }, describe: { $0 }, dropped: &droppedLabels
        )
        merged.urls = unionLabeled(.urls, members.map(\.urls), key: Self.urlKey, describe: { $0 }, dropped: &droppedLabels)
        merged.postalAddresses = unionLabeled(
            .postalAddresses, members.map(\.postalAddresses), key: Self.addressKey, describe: Self.describe, dropped: &droppedLabels
        )

        return MergePlan(
            survivorID: survivor.id,
            deleteIDs: distinctOthers.map(\.id),
            merged: merged,
            conflicts: conflicts,
            invalidPicks: invalidPicks,
            droppedLabels: droppedLabels
        )
    }

    // MARK: single-value resolution

    private struct Outcome<Value> {
        var value: Value?
        var conflict: MergeConflict?
        var invalidPick: MergeField?

        func apply(_ conflicts: inout [MergeConflict], _ invalid: inout [MergeField]) {
            if let conflict { conflicts.append(conflict) }
            if let invalidPick { invalid.append(invalidPick) }
        }
    }

    private static func resolve<Value>(
        _ field: MergeField,
        members: [ContactRecord],
        picks: [MergeField: String],
        value: (ContactRecord) -> Value?,
        isSame: (Value, Value) -> Bool,
        prefersNew: (_ current: Value, _ new: Value) -> Bool,
        display: (Value) -> String
    ) -> Outcome<Value> {
        let entries = members.compactMap { record in value(record).map { (id: record.id, value: $0) } }

        var invalidPick: MergeField?
        if let pickID = picks[field] {
            if let chosen = entries.first(where: { $0.id == pickID }) {
                return Outcome(value: chosen.value, conflict: nil, invalidPick: nil)
            }
            invalidPick = field
        }

        var groups: [(id: String, value: Value)] = []
        for entry in entries {
            if let index = groups.firstIndex(where: { isSame($0.value, entry.value) }) {
                // The group keeps the id of the record that holds its displayed value.
                if prefersNew(groups[index].value, entry.value) { groups[index] = entry }
            } else {
                groups.append(entry)
            }
        }

        guard let first = groups.first else { return Outcome(value: nil, conflict: nil, invalidPick: invalidPick) }
        guard groups.count > 1 else { return Outcome(value: first.value, conflict: nil, invalidPick: invalidPick) }
        let conflict = MergeConflict(
            field: field,
            candidates: groups.map { MergeCandidate(recordID: $0.id, value: display($0.value)) },
            proposedRecordID: first.id
        )
        return Outcome(value: first.value, conflict: conflict, invalidPick: invalidPick)
    }

    private static func textPath(for field: MergeField) -> WritableKeyPath<ContactRecord, String> {
        switch field {
        case .givenName: \.givenName
        case .middleName: \.middleName
        case .familyName: \.familyName
        case .nickname: \.nickname
        case .organization: \.organization
        case .jobTitle: \.jobTitle
        case .birthday: preconditionFailure("birthday is not a text field")
        }
    }

    /// Folds case, diacritics, width and whitespace only. Punctuation and symbols count, so "Acme \u{1F680}" differs from "Acme".
    static func comparisonKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Same month and day, and the years agree or at least one is unknown.
    private static func birthdaysAgree(_ a: DateComponents, _ b: DateComponents) -> Bool {
        guard a.month == b.month, a.day == b.day else { return false }
        return a.year == nil || b.year == nil || a.year == b.year
    }

    private static func display(_ birthday: DateComponents) -> String {
        func part(_ value: Int?, width: Int) -> String {
            value.map { String(format: "%0\(width)d", $0) } ?? String(repeating: "?", count: width)
        }
        let year = birthday.year.map { part($0, width: 4) } ?? "-"
        return "\(year)-\(part(birthday.month, width: 2))-\(part(birthday.day, width: 2))"
    }
}
