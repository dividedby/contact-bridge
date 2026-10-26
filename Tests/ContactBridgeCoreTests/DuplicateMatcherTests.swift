import Testing
@testable import ContactBridgeCore

struct DuplicateMatcherTests {
    private let matcher = DuplicateMatcher()

    private func person(
        _ id: String, _ given: String, _ family: String,
        phones: [String] = [], emails: [String] = [], org: String = ""
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: "ID-\(id)",
            givenName: given, familyName: family, organization: org,
            phones: phones.map { Labeled(label: "mobile", value: $0) },
            emails: emails.map { Labeled(label: "home", value: $0) }
        )
    }

    private func company(_ id: String, _ org: String, phones: [String] = [], emails: [String] = []) -> ContactRecord {
        person(id, "", "", phones: phones, emails: emails, org: org)
    }

    // MARK: strong evidence

    @Test("Same phone in different formats and same name is a high-confidence cluster")
    func samePhoneSameName() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["(415) 555-2671"]),
            person("b", "Ann", "Lee", phones: ["+1 415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].members.map(\.id) == ["a", "b"])
        #expect(clusters[0].confidence >= 0.85)
        #expect(clusters[0].level == .high)
        #expect(clusters[0].reasons.contains("same phone +14155552671"))
        #expect(clusters[0].reasons.contains("same name"))
        #expect(clusters[0].flags.isEmpty)
    }

    @Test("Same email is strong even when the other record has extra data")
    func sameEmail() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", emails: ["Ann@Example.com"]),
            person("b", "Ann", "Lee", phones: ["+14155552671"], emails: [" ann@example.com "]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].confidence >= 0.85)
        #expect(clusters[0].reasons.contains("same email ann@example.com"))
    }

    @Test("Shared phone with a nickname name variant stays high")
    func nicknameWithPhone() {
        let clusters = matcher.findClusters(in: [
            person("a", "Bob", "Smith", phones: ["415-555-2671"]),
            person("b", "Robert", "Smith", phones: ["+14155552671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .high)
    }

    @Test("Shared email with a family-name typo stays high and reports a similar name")
    func typoWithEmail() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Anderson", emails: ["aa@example.com"]),
            person("b", "Ann", "Andersen", emails: ["aa@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .high)
        #expect(clusters[0].reasons.contains("similar name"))
    }

    @Test("A given name that is an initial of the other still agrees", arguments: [("J", "John"), ("john", "J.")])
    func initialAgrees(a: String, b: String) {
        let clusters = matcher.findClusters(in: [
            person("a", a, "Smith", phones: ["415-555-2671"]),
            person("b", b, "Smith", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .high)
        #expect(clusters[0].flags.isEmpty)
    }

    @Test("Near-identical given names sharing a phone are different people, low and flagged", arguments: [
        ("Mark", "Mary"), ("Jane", "June"), ("Lee", "Leo"), ("Mike", "Mia"), ("Joan", "John"),
        ("Eric", "Erica"), ("Alex", "Alexa"), ("Ann", "Anna"), ("Sara", "Sarah"), ("Jon", "John"),
    ])
    func nearIdenticalGivenNamesPhone(a: String, b: String) {
        let clusters = matcher.findClusters(in: [
            person("a", a, "Smith", phones: ["415-555-2671"]),
            person("b", b, "Smith", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.sharedPhoneDifferentNames])
        #expect(!clusters[0].reasons.contains("same name") && !clusters[0].reasons.contains("similar name"))
    }

    @Test("Given-name spelling variants sharing an email join at medium with an informational flag", arguments: [
        ("Sara", "Sarah"), ("Jon", "John"), ("Allan", "Alan"), ("Eric", "Erica"), ("Alex", "Alexa"), ("Ann", "Anna"),
    ])
    func spellingVariantEmail(a: String, b: String) {
        let clusters = matcher.findClusters(in: [
            person("a", a, "Smith", emails: ["x@example.com"]),
            person("b", b, "Smith", emails: ["x@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .medium)
        #expect(abs(clusters[0].confidence - 0.7) < 1e-9)
        #expect(clusters[0].flags == [.nameSpellingVariant])
        #expect(clusters[0].reasons == ["same email x@example.com", "similar name"])
        #expect(clusters[0].edges.allSatisfy { $0.joinsCluster })
    }

    @Test("Less similar given names sharing an email stay low and flagged", arguments: [
        ("Mark", "Mary"), ("Jane", "June"), ("Lee", "Leo"), ("Mike", "Mia"), ("Joan", "John"),
    ])
    func differentGivenNamesEmail(a: String, b: String) {
        let clusters = matcher.findClusters(in: [
            person("a", a, "Smith", emails: ["x@example.com"]),
            person("b", b, "Smith", emails: ["x@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.sharedEmailDifferentNames])
    }

    @Test("Katherine nicknames sharing an email are the same name, not a spelling variant", arguments: [
        ("Kate", "Katie"), ("Katy", "Katie"), ("Kathryn", "Katherine"), ("Catherine", "Kate"),
    ])
    func katherineNicknames(a: String, b: String) {
        let clusters = matcher.findClusters(in: [
            person("a", a, "Smith", emails: ["x@example.com"]),
            person("b", b, "Smith", emails: ["x@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .high)
        #expect(clusters[0].flags.isEmpty)
        #expect(clusters[0].reasons.contains("same name"))
    }

    @Test("Katie and Kathy are not nicknames of each other: sharing a phone or email is low and flagged")
    func katieKathy() {
        let phone = matcher.findClusters(in: [
            person("a", "Katie", "Smith", phones: ["415-555-2671"]),
            person("b", "Kathy", "Smith", phones: ["415-555-2671"]),
        ])
        #expect(phone.count == 1)
        #expect(phone[0].level == .low)
        #expect(phone[0].flags == [.sharedPhoneDifferentNames])

        let email = matcher.findClusters(in: [
            person("a", "Katie", "Smith", emails: ["x@example.com"]),
            person("b", "Kathy", "Smith", emails: ["x@example.com"]),
        ])
        #expect(email[0].level == .low)
        #expect(email[0].flags == [.sharedEmailDifferentNames])
    }

    @Test("A spelling variant needs the same family name, and a shared phone keeps it strict")
    func spellingVariantStrictness() {
        let otherFamily = matcher.findClusters(in: [
            person("a", "Sara", "Smith", emails: ["x@example.com"]),
            person("b", "Sarah", "Jones", emails: ["x@example.com"]),
        ])
        #expect(otherFamily[0].level == .low)
        #expect(otherFamily[0].flags == [.sharedEmailDifferentNames])

        let phoneToo = matcher.findClusters(in: [
            person("a", "Sara", "Smith", phones: ["415-555-2671"], emails: ["x@example.com"]),
            person("b", "Sarah", "Smith", phones: ["415-555-2671"], emails: ["x@example.com"]),
        ])
        #expect(phoneToo[0].flags.contains(.sharedPhoneDifferentNames))
        #expect(!phoneToo[0].flags.contains(.nameSpellingVariant))
        #expect(phoneToo[0].level != .high)
    }

    // MARK: member-level name contradictions

    @Test("An org-only record holding two different people's phones cannot make them one cluster at medium")
    func orgBridgesTwoPeople() {
        let clusters = matcher.findClusters(in: [
            person("j", "John", "Smith", phones: ["415-555-2671"]),
            person("n", "Jane", "Doe", phones: ["212-555-3344"]),
            company("k", "Acme", phones: ["415-555-2671", "212-555-3344"]),
        ])
        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.members.map(\.id) == ["j", "k", "n"])
        #expect(cluster.level == .low)
        #expect(cluster.flags.contains(.memberNameConflict))
        let pair = cluster.edges.first { Set([$0.firstID, $0.secondID]) == ["j", "n"] }
        #expect(pair?.match.flags == [.memberNameConflict])
        #expect(pair?.joinsCluster == false)
    }

    @Test("A first-name-only record cannot bridge John Smith and John Doe")
    func firstNameBridgesTwoPeople() {
        let clusters = matcher.findClusters(in: [
            person("j", "John", "", phones: ["415-555-2671"], emails: ["john@example.com"]),
            person("k", "John", "Smith", phones: ["415-555-2671"]),
            person("n", "John", "Doe", emails: ["john@example.com"]),
        ])
        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.members.map(\.id) == ["j", "k", "n"])
        #expect(cluster.level == .low)
        #expect(cluster.flags == [.memberNameConflict])
        #expect(cluster.edges.contains { Set([$0.firstID, $0.secondID]) == ["k", "n"] && !$0.joinsCluster })
    }

    @Test("Compatible members get no member-name flag")
    func noFalseMemberConflict() {
        let clusters = matcher.findClusters(in: [
            person("a", "John", "Smith", phones: ["415-555-2671"]),
            person("b", "John", "", phones: ["415-555-2671"], emails: ["j@example.com"]),
            person("c", "J", "Smith", emails: ["j@example.com"]),
            company("d", "Acme", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(!clusters[0].flags.contains(.memberNameConflict))
    }

    // MARK: diagnostics

    @Test("Skipped oversized name blocks are reported")
    func diagnosticsNameBlocks() {
        let result = matcher.analyze((0..<2000).map { person("r\($0)", "John", "Smith") })
        #expect(result.clusters.isEmpty)
        #expect(result.diagnostics.oversizedNameBlocks == 1)
        #expect(result.diagnostics.skippedExactNameGroups == 1)
    }

    @Test("Dropped switchboard identifiers and unchecked large clusters are reported")
    func diagnosticsOthers() {
        var generator = SeededGenerator(seed: 11)
        let switchboard = (0..<150).map { person("s\($0)", randomWord(&generator), randomWord(&generator), phones: ["415-555-2671"]) }
        #expect(matcher.analyze(switchboard).diagnostics.droppedSwitchboardIdentifiers == 1)

        let big = (0..<60).map { person("b\($0)", "Ann", "Lee", emails: ["ann@example.com"]) }
        let result = matcher.analyze(big)
        #expect(result.clusters.count == 1)
        #expect(result.diagnostics.clustersSkippingMemberNameCheck == 1)
        #expect(matcher.analyze((0..<10).map { person("c\($0)", "Ann", "Lee", emails: ["ann@example.com"]) })
            .diagnostics == MatchDiagnostics())
    }

    @Test("A person and an unnamed record on one phone is capped below high and flagged", arguments: [
        "", "Acme Corp",
    ])
    func phoneWithUnnamedRecord(org: String) {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"]),
            company("b", org, phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .medium)
        #expect(clusters[0].confidence < 0.85)
        #expect(clusters[0].flags == [.sharedIdentifierUnnamedRecord])
    }

    @Test("Phone and email together still cannot lift a person/unnamed pair to high")
    func unnamedWithPhoneAndEmail() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"], emails: ["a@x.com"]),
            company("b", "Acme", phones: ["415-555-2671"], emails: ["a@x.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].confidence < 0.85)
        #expect(clusters[0].flags == [.sharedIdentifierUnnamedRecord])
    }

    @Test("Matches chain transitively into one cluster")
    func transitive() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"]),
            person("b", "Ann", "Lee", phones: ["415-555-2671"], emails: ["ann@example.com"]),
            person("c", "Ann", "Lee", emails: ["ann@example.com"]),
            person("d", "Zed", "Other", emails: ["zed@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].members.map(\.id) == ["a", "b", "c"])
    }

    // MARK: name-only

    @Test("Exact name alone is medium confidence")
    func nameOnly() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee"),
            person("b", "ann", "LEE"),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .medium)
        #expect(clusters[0].reasons == ["same name"])
    }

    @Test("Nickname match keys count as the same name")
    func nicknameNameOnly() {
        let clusters = matcher.findClusters(in: [
            person("a", "Bob", "Smith"),
            person("b", "Robert", "Smith"),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].reasons == ["same name"])
    }

    @Test("A fuzzy name alone is lower than an exact one")
    func fuzzyNameOnly() {
        let exact = matcher.findClusters(in: [person("a", "Ann", "Lee"), person("b", "Ann", "Lee")])
        let fuzzy = matcher.findClusters(in: [person("a", "Jon", "Smith"), person("b", "John", "Smith")])
        #expect(fuzzy.count == 1)
        #expect(fuzzy[0].reasons == ["similar name"])
        #expect(fuzzy[0].confidence == 0.4)
        #expect(fuzzy[0].level == .low)
        #expect(exact[0].confidence == 0.6)
        #expect(exact[0].level == .medium)
    }

    @Test("Different first names with the same surname do not match")
    func differentGivenNames() {
        let clusters = matcher.findClusters(in: [person("a", "John", "Smith"), person("b", "Jane", "Smith")])
        #expect(clusters.isEmpty)
    }

    @Test("Single-token names never match on name alone")
    func singleToken() {
        let clusters = matcher.findClusters(in: [person("a", "Mom", ""), person("b", "Mom", "")])
        #expect(clusters.isEmpty)
    }

    // MARK: false-positive guards

    @Test("A shared landline between different people is low confidence and flagged")
    func householdPhone() {
        let clusters = matcher.findClusters(in: [
            person("a", "Alice", "Jones", phones: ["415-555-2671"]),
            person("b", "Bob", "Smith", phones: ["+1 (415) 555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].confidence < 0.5)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.sharedPhoneDifferentNames])
        #expect(clusters[0].reasons.contains("same phone +14155552671"))
    }

    @Test("A shared household phone between spouses with the same surname is flagged")
    func spouses() {
        let clusters = matcher.findClusters(in: [
            person("a", "Alice", "Jones", phones: ["415-555-2671"]),
            person("b", "Carl", "Jones", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.sharedPhoneDifferentNames])
    }

    @Test("A shared email between different people is flagged and below high confidence")
    func sharedEmailDifferentNames() {
        let clusters = matcher.findClusters(in: [
            person("a", "Alice", "Jones", emails: ["family@example.com"]),
            person("b", "Bob", "Smith", emails: ["family@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level != .high)
        #expect(clusters[0].flags == [.sharedEmailDifferentNames])
    }

    @Test("Same name with different emails and phones is low confidence and flagged")
    func sameNameConflictingInfo() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"], emails: ["ann@one.com"]),
            person("b", "Ann", "Lee", phones: ["212-555-3344"], emails: ["ann@two.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].confidence < 0.5)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.conflictingContactInfo])
    }

    @Test("Same name where one record has no contact info is not penalised")
    func sameNameOneSideEmpty() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"]),
            person("b", "Ann", "Lee"),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].flags.isEmpty)
        #expect(clusters[0].level == .medium)
    }

    @Test("Company-only records do not match each other on organization alone")
    func companyOnly() {
        let clusters = matcher.findClusters(in: [
            company("a", "Acme Corp"),
            company("b", "Acme Corp"),
            person("c", "", "", org: "Acme Corp"),
        ])
        #expect(clusters.isEmpty)
    }

    @Test("Colleagues at the same organization do not match")
    func sameOrgDifferentPeople() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", org: "Acme"),
            person("b", "Bob", "Smith", org: "Acme"),
        ])
        #expect(clusters.isEmpty)
    }

    @Test("Company records can still match on a shared email")
    func companySharedEmail() {
        let clusters = matcher.findClusters(in: [
            company("a", "Acme", emails: ["info@acme.com"]),
            company("b", "Acme Corp", emails: ["INFO@acme.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].reasons == ["same email info@acme.com"])
    }

    @Test("Unnormalizable phones never match")
    func unnormalizablePhones() {
        let different = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["555-1234"]),
            person("b", "Bob", "Smith", phones: ["555-1234"]),
        ])
        #expect(different.isEmpty)

        let sameName = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["555-1234"]),
            person("b", "Ann", "Lee", phones: ["555-1234"]),
        ])
        #expect(sameName.count == 1)
        #expect(!sameName[0].reasons.contains { $0.contains("phone") })
        #expect(sameName[0].level == .medium)
    }

    @Test("Different extensions on one number are different people")
    func extensions() {
        let clusters = matcher.findClusters(in: [
            company("a", "Acme", phones: ["415-555-2671 x101"]),
            company("b", "Acme", phones: ["415-555-2671 x102"]),
        ])
        #expect(clusters.isEmpty)
    }

    @Test("A number shared by a huge number of records is treated as a switchboard")
    func switchboard() {
        var generator = SeededGenerator(seed: 7)
        let records = (0..<150).map { person("r\($0)", randomWord(&generator), randomWord(&generator), phones: ["415-555-2671"]) }
        #expect(matcher.findClusters(in: records).isEmpty)
    }

    @Test("A household link never merges into a strong cluster; it is attached as a related edge")
    func weakLinkNotUnioned() {
        let clusters = matcher.findClusters(in: [
            person("dad1", "Dan", "Jones", phones: ["415-555-2671"], emails: ["dan@example.com"]),
            person("dad2", "Dan", "Jones", emails: ["dan@example.com"]),
            person("mom", "Meg", "Jones", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.members.map(\.id) == ["dad1", "dad2"])
        #expect(cluster.level == .high)
        #expect(cluster.flags.isEmpty)
        #expect(cluster.edges.map { [$0.firstID, $0.secondID] } == [["dad1", "dad2"]])
        #expect(cluster.relatedEdges.count == 1)
        #expect(Set([cluster.relatedEdges[0].firstID, cluster.relatedEdges[0].secondID]) == ["dad1", "mom"])
        #expect(cluster.relatedEdges[0].match.flags == [.sharedPhoneDifferentNames])
    }

    @Test("A nameless record on a household phone cannot launder two different people into a high cluster")
    func householdWithFamilyRecord() {
        let clusters = matcher.findClusters(in: [
            person("dad", "Dan", "Jones", phones: ["415-555-2671"]),
            person("mom", "Meg", "Jones", phones: ["415-555-2671"]),
            company("fam", "Jones Family", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        let cluster = clusters[0]
        #expect(cluster.members.count == 3)
        #expect(cluster.level == .low)
        #expect(cluster.confidence <= 0.35)
        #expect(cluster.flags.contains(.sharedPhoneDifferentNames))
        #expect(cluster.edges.count == 3)
    }

    @Test("Weak-only pairs still surface as their own low-confidence cluster, with no related edges")
    func weakOnlyPair() {
        let clusters = matcher.findClusters(in: [
            person("a", "Alice", "Jones", phones: ["415-555-2671"]),
            person("b", "Bob", "Smith", phones: ["415-555-2671"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].edges.count == 1)
        #expect(clusters[0].relatedEdges.isEmpty)
    }

    @Test("A contradicting pair caps the cluster even when strong links connect it")
    func capAtContradictingPair() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"], emails: ["e1@example.com"]),
            person("b", "Ann", "Lee", emails: ["e1@example.com", "e2@example.com"]),
            person("c", "Ann", "Lee", phones: ["212-555-3344"], emails: ["e2@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].members.map(\.id) == ["a", "b", "c"])
        #expect(clusters[0].confidence < 0.5)
        #expect(clusters[0].level == .low)
        #expect(clusters[0].flags == [.conflictingContactInfo])
        #expect(clusters[0].edges.count == 3)
    }

    @Test("Chained strong links without any contradiction keep their strength")
    func chainKeepsStrength() {
        let clusters = matcher.findClusters(in: [
            person("a", "Ann", "Lee", phones: ["415-555-2671"]),
            person("b", "Ann", "Lee", phones: ["415-555-2671"], emails: ["e@example.com"]),
            person("c", "Ann", "Lee", emails: ["e@example.com"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters[0].level == .high)
    }

    @Test("No records or a single record produce no clusters")
    func trivial() {
        #expect(matcher.findClusters(in: []).isEmpty)
        #expect(matcher.findClusters(in: [person("a", "Ann", "Lee")]).isEmpty)
    }

    @Test("Output is independent of input order and sorted by confidence")
    func deterministic() {
        let records = [
            person("a", "Ann", "Lee", phones: ["415-555-2671"]),
            person("b", "Ann", "Lee", phones: ["415-555-2671"]),
            person("c", "Dan", "Roe"),
            person("d", "Dan", "Roe"),
            person("e", "Eve", "Poe", phones: ["212-555-3344"]),
            person("f", "Fay", "Moe", phones: ["212-555-3344"]),
        ]
        let baseline = matcher.findClusters(in: records)
        #expect(baseline.count == 3)
        #expect(baseline.map(\.confidence) == baseline.map(\.confidence).sorted(by: >))
        for seed in 0..<5 {
            var shuffled = records
            var generator = SeededGenerator(seed: UInt64(seed + 1))
            shuffled.shuffle(using: &generator)
            #expect(matcher.findClusters(in: shuffled) == baseline)
        }
        #expect(baseline[0].id == baseline[0].members[0].id)
    }

    @Test("Thousands of records cluster quickly and find the planted duplicates")
    func scale() {
        var generator = SeededGenerator(seed: 42)
        var records: [ContactRecord] = []
        for i in 0..<4000 {
            let phone = "+1415\(2_000_000 + i)"
            records.append(person("r\(i)", randomWord(&generator), randomWord(&generator), phones: [phone], emails: ["u\(i)@example.com"]))
        }
        let victim = records[10]
        records.append(person("dup1", victim.givenName, victim.familyName, emails: ["u10@example.com"]))
        records.append(person("dup2", "Zz", "Yy", phones: ["+1415\(2_000_077)"]))
        let clusters = matcher.findClusters(in: records)
        #expect(clusters.count == 2)
    }

    @Test("Members are sorted by id, and the cluster id is the first member's id")
    func memberOrder() {
        let clusters = matcher.findClusters(in: [
            person("z", "Ann", "Lee", emails: ["a@x.com"]),
            person("m", "Ann", "Lee", emails: ["a@x.com"]),
            person("b", "Ann", "Lee", emails: ["a@x.com"]),
        ])
        #expect(clusters[0].members.map(\.id) == ["b", "m", "z"])
        #expect(clusters[0].id == "b")
    }

    @Test("Thousands of identical names finish quickly: oversized name blocks are skipped")
    func oversizedNameBlock() {
        let records = (0..<2000).map { person("r\($0)", "John", "Smith") }
        let clock = ContinuousClock()
        var clusters: [DuplicateCluster] = []
        let elapsed = clock.measure { clusters = matcher.findClusters(in: records) }
        #expect(elapsed < .seconds(5))
        #expect(clusters.isEmpty)
    }

    @Test("An oversized name block still matches exact-name groups that fit under the cap")
    func oversizedNameBlockExactFallback() {
        var generator = SeededGenerator(seed: 3)
        var records = (0..<250).map { person("r\($0)", "J" + randomWord(&generator).lowercased(), "Smith") }
        records.append(person("x1", "Jonas", "Smith"))
        records.append(person("x2", "Jonas", "Smith"))
        let clusters = matcher.findClusters(in: records)
        #expect(clusters.contains { $0.members.map(\.id) == ["x1", "x2"] })
    }

    @Test("evaluate reports evidence for a single pair and nil for unrelated records")
    func pairEvaluation() {
        let a = person("a", "Ann", "Lee", emails: ["a@x.com"])
        let b = person("b", "Ann", "Lee", emails: ["a@x.com"])
        let c = person("c", "Zed", "Roe")
        #expect(matcher.evaluate(a, b) != nil)
        #expect(matcher.evaluate(a, c) == nil)
    }
}

/// Dissimilar synthetic names: sequential names like "Given1"/"Given2" are legitimately near-duplicates.
func randomWord(_ generator: inout SeededGenerator) -> String {
    String((0..<7).map { _ in Character(UnicodeScalar(UInt8.random(in: 97...122, using: &generator))) }).capitalized
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
