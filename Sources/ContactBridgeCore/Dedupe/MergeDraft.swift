import Foundation

/// The user's working copy of one duplicate cluster: who stays, who is left out, and which value wins each conflict.
/// Pure value logic; nothing here touches a store.
///
/// Removing a member re-scopes the cluster: its links to the remaining members become "possibly related" edges, and
/// confidence, reasons and flags are recomputed from the pairs that are left (an untouched draft reports the matcher's own
/// numbers). Conflict rows come from the plan *without* picks, so a row stays on screen after the user picks in it.
public struct MergeDraft: Sendable, Hashable {
    public let cluster: DuplicateCluster
    public private(set) var removedIDs: Set<String> = []
    public private(set) var survivorID: String
    /// Per field, the id of the member whose value wins. Only candidates of a current conflict are kept.
    public private(set) var picks: [MergeField: String] = [:]

    public init(cluster: DuplicateCluster) {
        self.cluster = cluster
        self.survivorID = Self.suggestedSurvivor(in: cluster.members).id
    }

    /// The member with the most filled-in data; ties go to the lowest id.
    public static func suggestedSurvivor(in members: [ContactRecord]) -> ContactRecord {
        func richness(_ record: ContactRecord) -> Int {
            [record.givenName, record.middleName, record.familyName, record.nickname, record.organization, record.jobTitle]
                .filter { !$0.isBlank }.count
                + record.phones.filter { !$0.value.isBlank }.count
                + record.emails.filter { !$0.value.isBlank }.count
                + record.postalAddresses.filter { !$0.value.isEmpty }.count
                + record.urls.filter { !$0.value.isBlank }.count
                + (record.birthday == nil ? 0 : 1)
        }
        // Precondition of the type: clusters always have at least two members.
        return members.min { (-richness($0), $0.id) < (-richness($1), $1.id) } ?? members[0]
    }

    // MARK: members

    public var members: [ContactRecord] { cluster.members.filter { !removedIDs.contains($0.id) } }
    public var removedMembers: [ContactRecord] { cluster.members.filter { removedIDs.contains($0.id) } }
    public var survivor: ContactRecord { members.first { $0.id == survivorID } ?? members[0] }
    /// The members that would be deleted.
    public var others: [ContactRecord] { members.filter { $0.id != survivor.id } }
    /// The ids the store knows them by.
    public var deleteSourceIdentifiers: [String] { others.map(\.sourceIdentifier) }
    public var canMerge: Bool { members.count >= 2 }

    public mutating func chooseSurvivor(_ id: String) {
        guard id != survivorID, members.contains(where: { $0.id == id }) else { return }
        survivorID = id
        picks = [:] // the proposed defaults were relative to the old survivor
    }

    /// False (and no change) for an unknown member, one already removed, or when only two members remain.
    @discardableResult
    public mutating func remove(memberID: String) -> Bool {
        guard members.count > 2, members.contains(where: { $0.id == memberID }) else { return false }
        removedIDs.insert(memberID)
        if survivorID == memberID {
            survivorID = Self.suggestedSurvivor(in: members).id
            picks = [:]
        }
        normalizePicks()
        return true
    }

    public mutating func restore(memberID: String) {
        guard removedIDs.remove(memberID) != nil else { return }
        normalizePicks()
    }

    // MARK: conflicts and preview

    /// Fields where the remaining members disagree, ignoring picks.
    public var conflicts: [MergeConflict] {
        MergePlan.build(survivor: survivor, others: others, picks: [:]).conflicts
    }

    /// The member currently chosen for a conflicting field: the user's pick, else the proposed default. Nil if the field
    /// does not conflict.
    public func selectedRecordID(for field: MergeField) -> String? {
        guard let conflict = conflicts.first(where: { $0.field == field }) else { return nil }
        if let pick = picks[field], conflict.candidates.contains(where: { $0.recordID == pick }) { return pick }
        return conflict.proposedRecordID
    }

    /// Ignored unless `recordID` is one of the field's candidates.
    public mutating func pick(_ field: MergeField, recordID: String) {
        guard let conflict = conflicts.first(where: { $0.field == field }),
              conflict.candidates.contains(where: { $0.recordID == recordID })
        else { return }
        picks[field] = recordID
    }

    private mutating func normalizePicks() {
        let current = conflicts
        picks = picks.filter { field, recordID in
            current.first { $0.field == field }?.candidates.contains { $0.recordID == recordID } ?? false
        }
    }

    /// The merge as it would be applied. Requires `canMerge`.
    public var plan: MergePlan {
        MergePlan.build(survivor: survivor, others: others, picks: picks)
    }

    /// The note the merged contact would carry, given the notes of the members keyed by contact id.
    public func combinedNote(notes: [String: String]) -> String? {
        NotesMerge.combine(
            survivor: notes[survivor.sourceIdentifier],
            others: others.map { (id: $0.sourceIdentifier, note: notes[$0.sourceIdentifier]) }
        )
    }

    // MARK: how the cluster holds together

    /// Scored pairs among the remaining members, strongest first.
    public var edges: [ClusterEdge] {
        cluster.edges.filter { !removedIDs.contains($0.firstID) && !removedIDs.contains($0.secondID) }
    }

    /// Links to records outside the draft: the matcher's own, plus every link to a removed member.
    public var relatedEdges: [ClusterEdge] {
        let ids = Set(members.map(\.id))
        let removedLinks = cluster.edges.filter { ids.contains($0.firstID) != ids.contains($0.secondID) }
        let outside = cluster.relatedEdges.filter { ids.contains($0.firstID) || ids.contains($0.secondID) }
        return (removedLinks + outside).sorted {
            if $0.match.confidence != $1.match.confidence { return $0.match.confidence > $1.match.confidence }
            return ($0.firstID, $0.secondID) < ($1.firstID, $1.secondID)
        }
    }

    /// Pairs among the remaining members that are conflict-flagged or below medium confidence: the places to split.
    public var weakEdges: [ClusterEdge] { edges.filter { !$0.joinsCluster } }

    /// Nil when no scored pair is left among the remaining members.
    public var confidence: Double? {
        if removedIDs.isEmpty { return cluster.confidence }
        return edges.map(\.match.confidence).min()
    }

    public var level: ConfidenceLevel? { confidence.map(ConfidenceLevel.init(confidence:)) }

    public var reasons: [String] {
        if removedIDs.isEmpty { return cluster.reasons }
        var seen: [String] = []
        for reason in edges.flatMap(\.match.reasons) where !seen.contains(reason) { seen.append(reason) }
        return seen
    }

    public var flags: [MatchFlag] {
        if removedIDs.isEmpty { return cluster.flags }
        let present = Set(edges.flatMap(\.match.flags))
        return MatchFlag.allCases.filter(present.contains)
    }

    /// Remaining members grouped by strong links (medium or better, no conflict). More than one group means the draft
    /// holds people nothing strong connects.
    public var components: [[String]] {
        let ids = members.map(\.id)
        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func root(_ id: String) -> String {
            var current = id
            while let next = parent[current], next != current { current = next }
            return current
        }
        for edge in edges where edge.joinsCluster {
            let a = root(edge.firstID), b = root(edge.secondID)
            if a != b { parent[b] = a }
        }
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for id in ids {
            let key = root(id)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(id)
        }
        return order.compactMap { groups[$0] }
    }

    public var isSplit: Bool { components.count > 1 }
}
