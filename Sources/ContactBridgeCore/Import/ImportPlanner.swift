import Foundation

/// Decides which Google contacts are worth copying into iCloud. Pure and deterministic: the same records in any order
/// give the same plan.
///
/// All records go through one `DuplicateMatcher.analyze` run and only pairs that cross sources are read from it. A
/// connection counts as "already in iCloud" when its best iCloud pair reaches medium confidence and carries no conflict
/// flag, the same bar the matcher uses to join a cluster. A pair that is medium by score but conflict-flagged (a shared
/// household phone and email with different first names, say) means probably different people, so it is only a possible
/// match and the connection stays importable. Every weaker pair, down to the matcher's `minimumConfidence`, is a
/// possible match too.
public struct ImportPlanner: Sendable {
    public var matcher: DuplicateMatcher

    public init(matcher: DuplicateMatcher = DuplicateMatcher()) {
        self.matcher = matcher
    }

    /// Same, from People API shapes. Deleted stubs and people without a resource name are dropped.
    public func plan(
        icloud: [ContactRecord], googleConnections: [GooglePerson], googleOtherContacts: [GooglePerson],
        knownLinks: [String: String] = [:]
    ) -> ImportPlan {
        plan(
            icloud: icloud,
            connections: googleConnections.compactMap { GooglePersonMapper.record(from: $0, source: .google) },
            otherContacts: googleOtherContacts.compactMap { GooglePersonMapper.record(from: $0, source: .googleOther) },
            knownLinks: knownLinks
        )
    }

    /// Record ids must be unique across the three inputs (CN identifiers and Google resource names never collide). Google
    /// records with no data at all are not offered.
    /// - Parameter knownLinks: Google resource name → iCloud id for contacts the app already imported. Those are linked
    ///   outright, whatever the matcher says, so a contact can never be imported twice.
    public func plan(
        icloud: [ContactRecord], connections: [ContactRecord], otherContacts: [ContactRecord], knownLinks: [String: String] = [:]
    ) -> ImportPlan {
        let icloudByID = Dictionary(icloud.map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var linked: [ImportLink] = []
        let connections = connections.filter { connection in
            guard let id = knownLinks[connection.sourceIdentifier], let saved = icloudByID[id] else { return true }
            linked.append(ImportLink(
                icloudID: id, googleResourceName: connection.sourceIdentifier, confidence: 1, reasons: ["imported by Contact Bridge"],
                icloudName: saved.displayName, googleName: connection.displayName, importAnywayCandidate: nil
            ))
            return false
        }

        enum Role { case icloud, connection, other }
        var records: [String: ContactRecord] = [:]
        var roles: [String: Role] = [:]
        func register(_ list: [ContactRecord], as role: Role, skippingEmpty: Bool) {
            for record in list where roles[record.id] == nil && !(skippingEmpty && record.isEmpty) {
                records[record.id] = record
                roles[record.id] = role
            }
        }
        register(icloud, as: .icloud, skippingEmpty: false)
        register(connections, as: .connection, skippingEmpty: true)
        register(otherContacts, as: .other, skippingEmpty: true)

        let analysis = matcher.analyze(Array(records.values))

        // Each pair can show up in two clusters' related edges; keep one copy.
        var seen = Set<String>()
        var iCloudEdges: [String: [(icloud: ContactRecord, edge: ClusterEdge)]] = [:]
        var otherMatchesConnection = Set<String>()
        for cluster in analysis.clusters {
            for edge in cluster.edges + cluster.relatedEdges {
                guard let first = records[edge.firstID], let second = records[edge.secondID],
                      let firstRole = roles[edge.firstID], let secondRole = roles[edge.secondID],
                      seen.insert(edge.firstID + "\u{0}" + edge.secondID).inserted
                else { continue }
                switch (firstRole, secondRole) {
                case (.icloud, .connection), (.icloud, .other):
                    iCloudEdges[second.id, default: []].append((first, edge))
                case (.connection, .icloud), (.other, .icloud):
                    iCloudEdges[first.id, default: []].append((second, edge))
                case (.connection, .other) where edge.joinsCluster:
                    otherMatchesConnection.insert(second.id)
                case (.other, .connection) where edge.joinsCluster:
                    otherMatchesConnection.insert(first.id)
                default:
                    break
                }
            }
        }

        let floor = matcher.options.minimumConfidence
        var plan = ImportPlan(diagnostics: analysis.diagnostics)
        plan.links = linked

        func possibleMatches(for google: ContactRecord, edges: [(icloud: ContactRecord, edge: ClusterEdge)]) -> [PossibleMatch] {
            edges.filter { !$0.edge.joinsCluster && $0.edge.match.confidence >= floor }.map {
                PossibleMatch(
                    icloudID: $0.icloud.sourceIdentifier, googleID: google.sourceIdentifier, googleSource: google.source,
                    confidence: $0.edge.match.confidence, reasons: $0.edge.match.reasons, flags: $0.edge.match.flags,
                    icloudName: $0.icloud.displayName, googleName: google.displayName
                )
            }
        }

        for connection in records.values where roles[connection.id] == .connection {
            let edges = iCloudEdges[connection.id] ?? []
            let strongest = edges.filter(\.edge.joinsCluster).min {
                ($1.edge.match.confidence, $0.icloud.sourceIdentifier) < ($0.edge.match.confidence, $1.icloud.sourceIdentifier)
            }
            if let strongest {
                // Reason texts start with "same phone" / "same email" when that identifier is shared (see DuplicateMatcher).
                let sharesIdentifier = strongest.edge.match.reasons.contains { $0.hasPrefix("same phone") || $0.hasPrefix("same email") }
                var anyway = connection
                anyway.source = .google
                plan.links.append(ImportLink(
                    icloudID: strongest.icloud.sourceIdentifier, googleResourceName: connection.sourceIdentifier,
                    confidence: strongest.edge.match.confidence, reasons: strongest.edge.match.reasons,
                    icloudName: strongest.icloud.displayName, googleName: connection.displayName,
                    importAnywayCandidate: sharesIdentifier ? nil : ImportCandidate(record: anyway, isSelected: false)
                ))
            } else {
                var candidate = connection
                candidate.source = .google
                let sender = candidate.isShortCodeSender
                plan.toImport.append(ImportCandidate(record: candidate, isSelected: !sender, isShortCodeSender: sender))
                plan.possibleMatches += possibleMatches(for: connection, edges: edges)
            }
        }

        for other in records.values where roles[other.id] == .other {
            let edges = iCloudEdges[other.id] ?? []
            guard !edges.contains(where: \.edge.joinsCluster), !otherMatchesConnection.contains(other.id) else { continue }
            var candidate = other
            candidate.source = .googleOther
            plan.otherContactCandidates.append(ImportCandidate(record: candidate, isSelected: false, isShortCodeSender: candidate.isShortCodeSender))
            plan.possibleMatches += possibleMatches(for: other, edges: edges)
        }

        plan.toImport.sort(by: Self.displayOrder)
        plan.otherContactCandidates.sort(by: Self.displayOrder)
        plan.links.sort { ($0.googleResourceName, $0.icloudID) < ($1.googleResourceName, $1.icloudID) }
        plan.possibleMatches.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return ($0.googleID, $0.icloudID) < ($1.googleID, $1.icloudID)
        }
        return plan
    }

    private static func displayOrder(_ a: ImportCandidate, _ b: ImportCandidate) -> Bool {
        sortKey(a.record).lexicographicallyPrecedes(sortKey(b.record))
    }

    private static func sortKey(_ record: ContactRecord) -> [String] {
        [record.familyName, record.givenName, record.organization, record.emails.first?.value ?? "", record.id]
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
    }
}
