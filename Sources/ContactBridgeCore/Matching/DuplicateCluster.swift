/// Something that makes a pair or cluster less trustworthy than its raw score suggests; surfaced so the UI can warn.
public enum MatchFlag: String, Sendable, Hashable, Codable, CaseIterable {
    /// A phone is shared but the names disagree: likely a household or office line.
    case sharedPhoneDifferentNames
    /// An email is shared but the names disagree: likely a family or role address.
    case sharedEmailDifferentNames
    /// Names match but both records carry phones (or emails) and none overlap.
    case conflictingContactInfo
    /// A person and a record with no person name (organization-only or blank) share a phone or email.
    case sharedIdentifierUnnamedRecord
    /// Two members of a cluster have clearly different person names although no scored pair says so (they were joined
    /// through a third record, such as an organization-only one).
    case memberNameConflict
    /// Given names differ only slightly in spelling (Sara/Sarah) but share an email and a family name. Informational.
    case nameSpellingVariant

    /// Conflict flags mean the two records are probably different people, so the pair never joins a cluster.
    public var isConflict: Bool {
        switch self {
        case .sharedPhoneDifferentNames, .sharedEmailDifferentNames, .conflictingContactInfo, .memberNameConflict: true
        case .sharedIdentifierUnnamedRecord, .nameSpellingVariant: false
        }
    }
}

public enum ConfidenceLevel: String, Sendable, Hashable, Codable, Comparable {
    case low
    case medium
    case high

    public static let mediumThreshold = 0.6
    public static let highThreshold = 0.85

    public init(confidence: Double) {
        if confidence >= Self.highThreshold {
            self = .high
        } else if confidence >= Self.mediumThreshold {
            self = .medium
        } else {
            self = .low
        }
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Evidence that two records are the same person.
public struct PairMatch: Sendable, Hashable {
    /// 0...1.
    public var confidence: Double
    /// Human-readable, e.g. "same phone +15551234567", "same email a@b.com", "same name", "similar name".
    public var reasons: [String]
    public var flags: [MatchFlag]

    public var level: ConfidenceLevel { ConfidenceLevel(confidence: confidence) }
}

/// Scored evidence between two specific records, identified by id (`firstID` sorts before `secondID`).
public struct ClusterEdge: Sendable, Hashable {
    public var firstID: String
    public var secondID: String
    public var match: PairMatch

    /// Strong enough to join a cluster: medium confidence or better and no conflict flag.
    public var joinsCluster: Bool {
        match.confidence >= ConfidenceLevel.mediumThreshold && !match.flags.contains(where: \.isConflict)
    }
}

/// A set of records believed to be one person.
public struct DuplicateCluster: Sendable, Hashable, Identifiable {
    /// The first member's id (members are sorted by id, so this is stable across runs).
    public var id: String
    /// Sorted by id, then source identifier. Always at least two.
    public var members: [ContactRecord]
    /// 0...1: the weakest joining link, further capped by the weakest contradicting pair (a scored pair of members
    /// that is flagged as a conflict or below medium confidence), even if it was not needed to connect the cluster.
    public var confidence: Double
    /// Deduplicated across all scored pairs of members, strongest evidence first.
    public var reasons: [String]
    /// Union of the flags on all scored pairs of members.
    public var flags: [MatchFlag]
    /// Every scored pair whose records are both members (including contradicting ones), strongest first. Lets a UI split
    /// the cluster along its weak pairs.
    public var edges: [ClusterEdge]
    /// Weaker or conflict-flagged links from a member to a record outside the cluster ("possibly related"). Clusters are
    /// never joined through these.
    public var relatedEdges: [ClusterEdge]

    public var level: ConfidenceLevel { ConfidenceLevel(confidence: confidence) }
}

/// What the matcher skipped or limited, so a silent skip is visible.
public struct MatchDiagnostics: Sendable, Hashable {
    /// Name blocks larger than `Options.maxNameBlockSize`; they fell back to exact-name groups.
    public var oversizedNameBlocks = 0
    /// Exact-name groups that were still too large and were not compared at all.
    public var skippedExactNameGroups = 0
    /// Phones/emails held by more than `Options.maxIdentifierBlockSize` records and ignored.
    public var droppedSwitchboardIdentifiers = 0
    /// Clusters larger than `Options.maxMemberNameCheckSize`, whose member names were not cross-checked.
    public var clustersSkippingMemberNameCheck = 0

    public init() {}
}

public struct MatchResult: Sendable, Hashable {
    public var clusters: [DuplicateCluster]
    public var diagnostics: MatchDiagnostics
}
