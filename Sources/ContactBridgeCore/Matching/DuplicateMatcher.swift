import Foundation

/// Finds likely duplicates. Pure and deterministic: the same records in any order give identical output.
///
/// Pairs are only compared when they share a blocking key (normalized phone, normalized email, company + SMS short code,
/// website, or surname prefix + given-name initial), so a few thousand contacts never need all n² comparisons.
///
/// Records join a cluster only through links of medium confidence or better with no conflict flag (union-find, strongest
/// first). Weaker or flagged links are never unioned through: they are attached to clusters as `relatedEdges`. Records
/// left unclustered after that are grouped by their weak links into low-confidence clusters of their own.
public struct DuplicateMatcher: Sendable {
    public struct Options: Sendable, Hashable {
        /// Pairs scoring below this are dropped. Default keeps flagged low-confidence pairs for review.
        public var minimumConfidence = 0.3
        /// A phone, email, short code or website shared by more than this many records is a switchboard/placeholder and is ignored.
        public var maxIdentifierBlockSize = 100
        /// Name-only matches (no shared phone/email) need at least this name similarity.
        public var nameOnlyMinimumSimilarity = 0.92
        /// A name block bigger than this is not compared pairwise; only its exact-name groups (up to this size) are.
        public var maxNameBlockSize = 200
        /// Member names are cross-checked for contradictions only in clusters up to this size.
        public var maxMemberNameCheckSize = 50

        public init() {}
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: scoring constants

    fileprivate enum Score {
        static let phone = 0.85
        static let email = 0.9
        /// Shared identifier but conflicting names.
        static let phoneConflictingNames = 0.35
        static let emailConflictingNames = 0.55
        /// How much agreeing names add on top of a shared identifier (scaled by name similarity).
        static let nameSupport = 0.6
        static let nameOnlyExact = 0.6
        static let nameOnlyFuzzy = 0.4
        static let conflictingContactInfoFactor = 0.6
        /// A person and an unnamed record sharing an identifier never reach `ConfidenceLevel.highThreshold`.
        static let unnamedCap = 0.84
        /// Same company (non-empty, folded) and same SMS short code, with no person-name conflict.
        static let shortCode = 0.9
        /// Same website and compatible person names, nothing else shared.
        static let website = 0.7
        /// Shared email, same family name, given names a close spelling variant (Sara/Sarah).
        static let emailSpellingVariant = 0.7
        /// Given names at least this similar (Jaro-Winkler) count as a spelling variant.
        static let spellingVariantSimilarity = 0.9
        /// Synthetic confidence for two cluster members whose names contradict; the cluster is capped here.
        static let memberNameConflict = 0.35
    }

    // MARK: public API

    public func findClusters(in records: [ContactRecord]) -> [DuplicateCluster] {
        analyze(records).clusters
    }

    /// Like `findClusters`, plus counts of what was skipped or limited.
    public func analyze(_ records: [ContactRecord]) -> MatchResult {
        var diagnostics = MatchDiagnostics()
        let sorted = records.sorted(by: Self.recordOrder)
        let profiles = withoutSwitchboards(sorted.map(Profile.init), diagnostics: &diagnostics)

        var edges: [Edge] = []
        var seen = Set<PairKey>()
        for (_, indices) in blocks(of: profiles, diagnostics: &diagnostics) where indices.count > 1 {
            for x in 0..<indices.count {
                for y in (x + 1)..<indices.count {
                    let key = PairKey(indices[x], indices[y])
                    guard seen.insert(key).inserted else { continue }
                    guard let match = evaluate(profiles[key.low], profiles[key.high]) else { continue }
                    edges.append(Edge(low: key.low, high: key.high, match: match))
                }
            }
        }

        // Sub-threshold edges are kept: they cannot link or relate records but still cap a cluster they sit inside.
        let clusters = buildClusters(from: edges, records: sorted, profiles: profiles, diagnostics: &diagnostics)
        return MatchResult(clusters: clusters, diagnostics: diagnostics)
    }

    /// Evidence that two records are the same person, or nil if there is none. Not filtered by `minimumConfidence`.
    public func evaluate(_ a: ContactRecord, _ b: ContactRecord) -> PairMatch? {
        evaluate(Profile(a), Profile(b))
    }

    // MARK: pair scoring

    private func evaluate(_ a: Profile, _ b: Profile) -> PairMatch? {
        let sharedPhones = a.phones.keys.filter { b.phones[$0] != nil }.sorted()
        let sharedEmails = a.emails.intersection(b.emails).sorted()
        let relation = NameRelation(a.name, b.name)
        let sharedShortCodes = sharedShortCodes(a, b, relation: relation)

        if !sharedPhones.isEmpty || !sharedEmails.isEmpty || !sharedShortCodes.isEmpty {
            return identifierMatch(
                a, b, sharedPhones: sharedPhones, sharedEmails: sharedEmails, sharedShortCodes: sharedShortCodes, relation: relation
            )
        }
        let byName = nameOnlyMatch(a, b, relation: relation)
        guard let byWebsite = websiteMatch(a, b) else { return byName }
        return (byName?.confidence ?? 0) > byWebsite.confidence ? byName : byWebsite
    }

    /// A short code is only meaningful inside one sender: it is evidence only when both records name the same company and
    /// their person names (if any) do not contradict.
    private func sharedShortCodes(_ a: Profile, _ b: Profile, relation: NameRelation) -> [String] {
        guard !a.organization.isEmpty, a.organization == b.organization, !relation.conflictsOnIdentifier else { return [] }
        return a.shortCodes.intersection(b.shortCodes).sorted()
    }

    /// A shared website, medium only: the given names must be equal (single names allowed) with no family-name conflict.
    private func websiteMatch(_ a: Profile, _ b: Profile) -> PairMatch? {
        let shared = a.websites.intersection(b.websites).sorted()
        guard !shared.isEmpty, !a.name.given.isEmpty, a.name.given == b.name.given else { return nil }
        if !a.name.family.isEmpty, !b.name.family.isEmpty, a.name.family != b.name.family,
           StringSimilarity.jaroWinkler(a.name.family, b.name.family) < Score.spellingVariantSimilarity {
            return nil
        }
        return PairMatch(confidence: Score.website, reasons: shared.map { "same website \($0)" }, flags: [])
    }

    private func identifierMatch(
        _ a: Profile, _ b: Profile, sharedPhones: [String], sharedEmails: [String], sharedShortCodes: [String],
        relation: NameRelation
    ) -> PairMatch {
        // A near-identical given name is tolerated only on a shared email, never a shared phone.
        let spellingVariant = relation.isSpellingVariant && sharedPhones.isEmpty
        let conflicts = relation.conflictsOnIdentifier && !spellingVariant
        var miss = 1.0
        var reasons: [String] = []
        var flags: [MatchFlag] = []

        if !sharedPhones.isEmpty {
            miss *= 1 - (conflicts ? Score.phoneConflictingNames : Score.phone)
            reasons += sharedPhones.map { "same phone \(a.phones[$0] ?? $0)" }
            if conflicts { flags.append(.sharedPhoneDifferentNames) }
        }
        if !sharedEmails.isEmpty {
            let strength = conflicts ? Score.emailConflictingNames : (spellingVariant ? Score.emailSpellingVariant : Score.email)
            miss *= 1 - strength
            reasons += sharedEmails.map { "same email \($0)" }
            if conflicts { flags.append(.sharedEmailDifferentNames) }
            if spellingVariant {
                reasons.append("similar name")
                flags.append(.nameSpellingVariant)
            }
        }
        if !sharedShortCodes.isEmpty {
            miss *= 1 - Score.shortCode
            reasons += sharedShortCodes.map { "same company and short code \($0)" }
        }
        if let score = relation.identifierSupport {
            miss *= 1 - Score.nameSupport * score
            reasons.append(score >= 0.999 ? "same name" : "similar name")
        }
        var confidence = 1 - miss
        if case .unknown = relation, a.name.isEmpty != b.name.isEmpty {
            confidence = min(confidence, Score.unnamedCap)
            flags.append(.sharedIdentifierUnnamedRecord)
        }
        return PairMatch(confidence: confidence, reasons: reasons, flags: flags)
    }

    private func nameOnlyMatch(_ a: Profile, _ b: Profile, relation: NameRelation) -> PairMatch? {
        guard case .similar(let score, let full, _, _) = relation, full, score >= options.nameOnlyMinimumSimilarity else {
            return nil
        }
        let exact = score >= 0.999
        var confidence = exact ? Score.nameOnlyExact : Score.nameOnlyFuzzy
        var flags: [MatchFlag] = []
        // No identifier is shared, so any channel both records have is, by construction, in disagreement.
        if (!a.phones.isEmpty && !b.phones.isEmpty) || (!a.emails.isEmpty && !b.emails.isEmpty) {
            confidence *= Score.conflictingContactInfoFactor
            flags.append(.conflictingContactInfo)
        }
        return PairMatch(confidence: confidence, reasons: [exact ? "same name" : "similar name"], flags: flags)
    }

    // MARK: blocking

    private func blocks(of profiles: [Profile], diagnostics: inout MatchDiagnostics) -> [String: [Int]] {
        var blocks: [String: [Int]] = [:]
        for (index, profile) in profiles.enumerated() {
            for key in profile.phones.keys { blocks["p|" + key, default: []].append(index) }
            for email in profile.emails { blocks["e|" + email, default: []].append(index) }
            if !profile.organization.isEmpty {
                for code in profile.shortCodes { blocks["s|" + profile.organization + "|" + code, default: []].append(index) }
            }
            if !profile.name.given.isEmpty {
                for site in profile.websites { blocks["u|" + site, default: []].append(index) }
            }
            if let nameKey = profile.name.blockKey { blocks["n|" + nameKey, default: []].append(index) }
        }
        // Oversized name blocks degrade to exact-name groups, which are skipped in turn if still oversized.
        for (key, indices) in blocks where key.hasPrefix("n|") && indices.count > options.maxNameBlockSize {
            blocks[key] = nil
            diagnostics.oversizedNameBlocks += 1
            var exact: [String: [Int]] = [:]
            for index in indices { exact["x|" + profiles[index].name.exactKey, default: []].append(index) }
            for (exactKey, group) in exact where group.count > 1 {
                if group.count <= options.maxNameBlockSize {
                    blocks[exactKey] = group
                } else {
                    diagnostics.skippedExactNameGroups += 1
                }
            }
        }
        return blocks
    }

    /// Drops phones, emails, short codes and websites held by more than `maxIdentifierBlockSize` records, so they neither
    /// block nor score.
    private func withoutSwitchboards(_ profiles: [Profile], diagnostics: inout MatchDiagnostics) -> [Profile] {
        var phoneCounts: [String: Int] = [:]
        var emailCounts: [String: Int] = [:]
        var shortCodeCounts: [String: Int] = [:]
        var websiteCounts: [String: Int] = [:]
        for profile in profiles {
            for key in profile.phones.keys { phoneCounts[key, default: 0] += 1 }
            for email in profile.emails { emailCounts[email, default: 0] += 1 }
            for code in profile.shortCodes { shortCodeCounts[code, default: 0] += 1 }
            for site in profile.websites { websiteCounts[site, default: 0] += 1 }
        }
        let limit = options.maxIdentifierBlockSize
        let counts = [phoneCounts, emailCounts, shortCodeCounts, websiteCounts]
        diagnostics.droppedSwitchboardIdentifiers = counts.reduce(0) { $0 + $1.values.filter { $0 > limit }.count }
        guard counts.contains(where: { $0.values.contains(where: { $0 > limit }) }) else { return profiles }
        return profiles.map { profile in
            var copy = profile
            copy.phones = profile.phones.filter { phoneCounts[$0.key, default: 0] <= limit }
            copy.emails = profile.emails.filter { emailCounts[$0, default: 0] <= limit }
            copy.shortCodes = profile.shortCodes.filter { shortCodeCounts[$0, default: 0] <= limit }
            copy.websites = profile.websites.filter { websiteCounts[$0, default: 0] <= limit }
            return copy
        }
    }

    // MARK: clustering

    private func buildClusters(
        from edges: [Edge], records: [ContactRecord], profiles: [Profile], diagnostics: inout MatchDiagnostics
    ) -> [DuplicateCluster] {
        let candidates = edges.filter { $0.match.confidence >= options.minimumConfidence }
        let joining = candidates.filter { $0.joinsCluster }
        let weak = candidates.filter { !$0.joinsCluster }

        var sets = UnionFind(count: records.count)
        // Per root: the weakest edge used to join it (1 for a lone record).
        var weakest = [Double](repeating: 1, count: records.count)
        func join(_ edges: [Edge]) {
            // Strongest first, so each union uses the best edge available and `weakest` is the bottleneck.
            for edge in edges.sorted(by: Self.strongerFirst) {
                let a = sets.find(edge.low)
                let b = sets.find(edge.high)
                guard a != b else { continue }
                weakest[sets.union(a, b)] = min(weakest[a], weakest[b], edge.match.confidence)
            }
        }

        join(joining)
        // Only records no strong link touched may form weak-only clusters, so no record lands in two clusters.
        var clustered = Set<Int>()
        for edge in joining {
            clustered.insert(edge.low)
            clustered.insert(edge.high)
        }
        join(weak.filter { !clustered.contains($0.low) && !clustered.contains($0.high) })

        var members: [Int: [Int]] = [:]
        for index in records.indices { members[sets.find(index), default: []].append(index) }

        var internalEdges: [Int: [Edge]] = [:]
        var relatedEdges: [Int: [Edge]] = [:]
        for edge in edges.sorted(by: Self.strongerFirst) {
            let a = sets.find(edge.low)
            let b = sets.find(edge.high)
            if a == b {
                internalEdges[a, default: []].append(edge)
            } else if edge.match.confidence >= options.minimumConfidence {
                relatedEdges[a, default: []].append(edge)
                relatedEdges[b, default: []].append(edge)
            }
        }

        func clusterEdge(_ edge: Edge) -> ClusterEdge {
            ClusterEdge(firstID: records[edge.low].id, secondID: records[edge.high].id, match: edge.match)
        }

        // Members joined through a third record may still contradict each other without any scored pair saying so.
        var skippedChecks = 0
        for (root, indices) in members where indices.count > 1 {
            guard indices.count <= options.maxMemberNameCheckSize else {
                skippedChecks += 1
                continue
            }
            let scored = Set((internalEdges[root] ?? []).map { PairKey($0.low, $0.high) })
            for x in 0..<indices.count {
                for y in (x + 1)..<indices.count {
                    let key = PairKey(indices[x], indices[y])
                    guard !scored.contains(key), case .conflict = NameRelation(profiles[key.low].name, profiles[key.high].name)
                    else { continue }
                    let match = PairMatch(
                        confidence: Score.memberNameConflict, reasons: ["different names"], flags: [.memberNameConflict]
                    )
                    internalEdges[root, default: []].append(Edge(low: key.low, high: key.high, match: match))
                }
            }
            internalEdges[root]?.sort(by: Self.strongerFirst)
        }
        diagnostics.clustersSkippingMemberNameCheck = skippedChecks

        let clusters = members.compactMap { root, indices -> DuplicateCluster? in
            guard indices.count > 1 else { return nil }
            let inside = internalEdges[root] ?? []
            var reasons: [String] = []
            for reason in inside.flatMap(\.match.reasons) where !reasons.contains(reason) { reasons.append(reason) }
            let flagSet = Set(inside.flatMap(\.match.flags))
            let contradictions = inside.filter { !$0.joinsCluster }.map(\.match.confidence)
            let clusterMembers = indices.map { records[$0] }
            return DuplicateCluster(
                id: clusterMembers[0].id,
                members: clusterMembers,
                confidence: min(weakest[root], contradictions.min() ?? 1),
                reasons: reasons,
                flags: MatchFlag.allCases.filter(flagSet.contains),
                edges: inside.map(clusterEdge),
                relatedEdges: (relatedEdges[root] ?? []).map(clusterEdge)
            )
        }
        return clusters.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.members.count != $1.members.count { return $0.members.count > $1.members.count }
            return $0.id < $1.id
        }
    }

    private static func strongerFirst(_ a: Edge, _ b: Edge) -> Bool {
        (b.match.confidence, a.low, a.high) < (a.match.confidence, b.low, b.high)
    }

    private static func recordOrder(_ a: ContactRecord, _ b: ContactRecord) -> Bool {
        (a.id, a.sourceIdentifier, a.source.rawValue) < (b.id, b.sourceIdentifier, b.source.rawValue)
    }
}

// MARK: - supporting types

private struct Edge {
    var low: Int
    var high: Int
    var match: PairMatch

    var joinsCluster: Bool {
        match.confidence >= ConfidenceLevel.mediumThreshold && !match.flags.contains(where: \.isConflict)
    }
}

private struct PairKey: Hashable {
    let low: Int
    let high: Int
    init(_ a: Int, _ b: Int) {
        low = min(a, b)
        high = max(a, b)
    }
}

private struct Profile {
    /// Normalizable phones only: comparison key -> display text. The key includes any extension.
    var phones: [String: String]
    var emails: Set<String>
    /// SMS short codes (digits only). Evidence only between records of the same `organization`.
    var shortCodes: Set<String>
    /// Normalized website keys (scheme and host folded, path kept).
    var websites: Set<String>
    /// Folded organization; empty when the record has none.
    let organization: String
    let name: PersonName

    init(_ record: ContactRecord) {
        var phones: [String: String] = [:]
        let normalizedPhones = record.normalizedPhones
        for phone in normalizedPhones where phone.isNormalizable {
            let suffix = phone.extensionDigits.map { " x\($0)" } ?? ""
            phones[phone.value + suffix] = phone.value + suffix
        }
        self.phones = phones
        self.emails = Set(record.normalizedEmails)
        self.shortCodes = Set(normalizedPhones.compactMap(\.shortCodeDigits))
        self.websites = Set(record.urls.compactMap { Profile.websiteKey($0.value) })
        self.organization = NameNormalizer.foldedKey(record.organization)
        self.name = PersonName(given: record.givenNameMatchKey, family: record.familyNameMatchKey)
    }
}

extension Profile {
    /// Hosts that serve millions of people: a bare root or generic page on one says nothing about who owns the link.
    private static let sharedHosts: Set<String> = [
        "facebook.com", "instagram.com", "linkedin.com", "twitter.com", "x.com", "tiktok.com", "youtube.com", "google.com",
        "gmail.com", "apple.com", "icloud.com", "github.com", "medium.com", "wordpress.com", "blogspot.com",
    ]
    private static let genericPaths: Set<String> = [
        "home", "index", "index.html", "index.php", "login", "signin", "signup", "about", "explore", "help", "search", "feed",
        "discover", "welcome", "main",
    ]

    /// The merge URL key, or nil when it is a root (or a single generic page) on a shared host.
    static func websiteKey(_ raw: String) -> String? {
        guard let key = MergePlan.urlKey(raw) else { return nil }
        let hostEnd = key.firstIndex(where: { "/?#".contains($0) }) ?? key.endIndex
        guard sharedHosts.contains(String(key[..<hostEnd])) else { return key }
        let path = key[hostEnd...].prefix { $0 != "?" && $0 != "#" }.split(separator: "/", omittingEmptySubsequences: true)
        if path.isEmpty { return nil }
        if path.count == 1, genericPaths.contains(path[0].lowercased()) { return nil }
        return key
    }
}

/// Person-name keys only. Organization is deliberately absent: a company name is never evidence of identity.
private struct PersonName {
    let given: String
    let family: String

    var isEmpty: Bool { given.isEmpty && family.isEmpty }
    var isFull: Bool { !given.isEmpty && !family.isEmpty }
    var exactKey: String { given + "|" + family }

    /// Surname prefix + given initial; nil unless both parts exist (name-only matching needs full names).
    var blockKey: String? {
        isFull ? family.prefix(3) + "|" + given.prefix(1) : nil
    }
}

private enum NameRelation {
    /// At least one side has no person name, so names say nothing either way.
    case unknown
    /// `full` is true only when both sides have given and family names. `givenAgrees` means the given names match
    /// exactly (folded or nickname key) or one is an initial of the other, which is what a shared identifier requires.
    /// `spellingVariant`: not `givenAgrees`, but the family names are equal and the given names very close (Sara/Sarah).
    case similar(score: Double, full: Bool, givenAgrees: Bool, spellingVariant: Bool)
    case conflict

    /// With a shared phone or email, near-identical but different given names (Mark/Mary) are different people.
    var conflictsOnIdentifier: Bool {
        switch self {
        case .unknown: false
        case .similar(_, _, let givenAgrees, _): !givenAgrees
        case .conflict: true
        }
    }

    /// Name similarity that may lift an identifier match, or nil when names are silent or disagree.
    var identifierSupport: Double? {
        if case .similar(let score, _, true, _) = self { return score }
        return nil
    }

    var isSpellingVariant: Bool {
        if case .similar(_, _, _, true) = self { return true }
        return false
    }

    init(_ a: PersonName, _ b: PersonName) {
        guard !a.isEmpty, !b.isEmpty else {
            self = .unknown
            return
        }
        if a.isFull, b.isFull {
            let givenAgrees = a.given == b.given || Self.isInitial(a.given, of: b.given) || Self.isInitial(b.given, of: a.given)
            let g = a.given == b.given ? 1 : (givenAgrees ? 0.9 : StringSimilarity.jaroWinkler(a.given, b.given))
            let f = StringSimilarity.jaroWinkler(a.family, b.family)
            // One badly-off part (John/Jane Smith) must not be averaged away by the other.
            let score = (g >= 0.85 && f >= 0.9) ? (g + f) / 2 : min(g, f)
            let variant = !givenAgrees && a.family == b.family && g >= DuplicateMatcher.Score.spellingVariantSimilarity
            self = score >= 0.8
                ? .similar(score: score, full: true, givenAgrees: givenAgrees, spellingVariant: variant)
                : .conflict
            return
        }
        // At least one side has a single name part: agree only if some part is shared.
        let tokensA = Set([a.given, a.family].filter { !$0.isEmpty })
        let tokensB = Set([b.given, b.family].filter { !$0.isEmpty })
        self = tokensA.isDisjoint(with: tokensB) ? .conflict : .similar(score: 0.85, full: false, givenAgrees: true, spellingVariant: false)
    }

    private static func isInitial(_ initial: String, of name: String) -> Bool {
        initial.count == 1 && name.count > 1 && name.hasPrefix(initial)
    }
}

private struct UnionFind {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        size = [Int](repeating: 1, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root {
            (node, parent[node]) = (parent[node], root)
        }
        return root
    }

    /// Joins the sets rooted at `a` and `b` (both must be roots) and returns the new root.
    @discardableResult
    mutating func union(_ a: Int, _ b: Int) -> Int {
        let (big, small) = size[a] >= size[b] ? (a, b) : (b, a)
        parent[small] = big
        size[big] += size[small]
        return big
    }
}
