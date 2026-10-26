import Foundation

/// A Google record the user may copy into iCloud.
public struct ImportCandidate: Sendable, Hashable, Identifiable {
    /// The Google resource name (also the record's id).
    public var id: String { record.id }
    /// `.google` for a connection, `.googleOther` for an "Other contact".
    public var record: ContactRecord
    /// Connections start selected; other contacts and short-code senders do not.
    public var isSelected: Bool
    /// Only SMS short-code phones, no person name, no email: an automated text-message sender, rarely worth a contact.
    public var isShortCodeSender: Bool

    public init(record: ContactRecord, isSelected: Bool, isShortCodeSender: Bool = false) {
        self.record = record
        self.isSelected = isSelected
        self.isShortCodeSender = isShortCodeSender
    }

    public var googleResourceName: String { record.sourceIdentifier }

    /// Has a given or family name. A business (organization only), a nickname alone and a nameless card are not people.
    public var isPerson: Bool { !record.givenName.isBlank || !record.familyName.isBlank }
}

/// Selection shortcuts for a list of import candidates. Pure: take the current ticks, return the new ones.
public enum ImportSelection {
    /// Only the candidates that are people; every other tick is dropped.
    public static func peopleOnly(_ candidates: [ImportCandidate]) -> Set<String> {
        Set(candidates.filter(\.isPerson).map(\.id))
    }

    /// `selected` without the automated text-message senders among `candidates`; every other tick stays.
    public static func excludingTextMessageSenders(_ selected: Set<String>, from candidates: [ImportCandidate]) -> Set<String> {
        selected.subtracting(candidates.filter(\.isShortCodeSender).map(\.id))
    }
}

/// A Google connection that is already in iCloud (medium confidence or better, no conflict flag).
public struct ImportLink: Sendable, Hashable {
    public var icloudID: String
    public var googleResourceName: String
    public var confidence: Double
    public var reasons: [String]
    /// Display names, for showing the pair.
    public var icloudName: String
    public var googleName: String
    /// Set only when the match rests on the name alone (no shared phone or email): common names can hide a different
    /// person, so the UI offers "Import anyway" with this candidate (never selected by default).
    public var importAnywayCandidate: ImportCandidate?

    public var isNameOnly: Bool { importAnywayCandidate != nil }

    public init(
        icloudID: String, googleResourceName: String, confidence: Double, reasons: [String], icloudName: String = "", googleName: String = "",
        importAnywayCandidate: ImportCandidate? = nil
    ) {
        self.importAnywayCandidate = importAnywayCandidate
        self.icloudID = icloudID
        self.googleResourceName = googleResourceName
        self.confidence = confidence
        self.reasons = reasons
        self.icloudName = icloudName
        self.googleName = googleName
    }

    public var level: ConfidenceLevel { ConfidenceLevel(confidence: confidence) }
}

/// A Google record and an iCloud contact that might be the same person, but not convincingly enough to treat as one. The
/// Google record stays importable; this is for the user to look at.
public struct PossibleMatch: Sendable, Hashable, Identifiable {
    public var id: String { icloudID + "|" + googleID }
    public var icloudID: String
    /// Resource name of the Google connection or other contact.
    public var googleID: String
    public var googleSource: ContactSource
    public var confidence: Double
    public var reasons: [String]
    public var flags: [MatchFlag]
    public var icloudName: String
    public var googleName: String

    public init(
        icloudID: String, googleID: String, googleSource: ContactSource, confidence: Double, reasons: [String], flags: [MatchFlag],
        icloudName: String = "", googleName: String = ""
    ) {
        self.icloudName = icloudName
        self.googleName = googleName
        self.icloudID = icloudID
        self.googleID = googleID
        self.googleSource = googleSource
        self.confidence = confidence
        self.reasons = reasons
        self.flags = flags
    }

    public var level: ConfidenceLevel { ConfidenceLevel(confidence: confidence) }
}

/// What importing Google contacts into iCloud would do. Pure data; building one changes nothing.
public struct ImportPlan: Sendable, Hashable {
    /// Google connections with no iCloud match, selected by default.
    public var toImport: [ImportCandidate]
    /// Google "Other contacts" with no match, NOT selected by default.
    public var otherContactCandidates: [ImportCandidate]
    /// Connections that are already in iCloud, one per connection (its best iCloud match). Candidates only: nothing is
    /// persisted from them by the planner.
    public var links: [ImportLink]
    /// Low-confidence (or conflict-flagged) pairs worth a look.
    public var possibleMatches: [PossibleMatch]
    public var diagnostics: MatchDiagnostics

    public init(
        toImport: [ImportCandidate] = [], otherContactCandidates: [ImportCandidate] = [], links: [ImportLink] = [],
        possibleMatches: [PossibleMatch] = [], diagnostics: MatchDiagnostics = MatchDiagnostics()
    ) {
        self.toImport = toImport
        self.otherContactCandidates = otherContactCandidates
        self.links = links
        self.possibleMatches = possibleMatches
        self.diagnostics = diagnostics
    }

    public var isEmpty: Bool { toImport.isEmpty && otherContactCandidates.isEmpty && links.isEmpty && possibleMatches.isEmpty }

    /// Possible matches that involve this Google record.
    public func possibleMatches(forGoogleID id: String) -> [PossibleMatch] {
        possibleMatches.filter { $0.googleID == id }
    }
}
