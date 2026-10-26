import Testing
@testable import ContactBridgeCore

/// SMS short-code senders, organization-only twins and website twins: shapes seen when a Google import ran twice.
struct ShortCodeMatchingTests {
    private let matcher = DuplicateMatcher()

    private func record(
        _ id: String, given: String = "", family: String = "", nickname: String = "", org: String = "",
        phones: [String] = [], emails: [String] = [], urls: [String] = []
    ) -> ContactRecord {
        ContactRecord(
            id: id, source: .icloud, sourceIdentifier: "ID-\(id)",
            givenName: given, familyName: family, nickname: nickname, organization: org,
            phones: phones.map { Labeled(label: "other", value: $0) },
            emails: emails.map { Labeled(label: "home", value: $0) },
            urls: urls.map { Labeled(label: "homepage", value: $0) }
        )
    }

    // MARK: short codes

    @Test("The same company and the same short code, twice, is a high-confidence cluster")
    func companyShortCodeTwice() throws {
        let clusters = matcher.findClusters(in: [
            record("a", org: "Acme Bank", phones: ["72727"]),
            record("b", org: "Acme Bank", phones: ["72727"]),
        ])
        let cluster = try #require(clusters.first)
        #expect(clusters.count == 1)
        #expect(cluster.members.map(\.id) == ["a", "b"])
        #expect(cluster.level == .high)
        #expect(abs(cluster.confidence - 0.9) < 1e-9)
        #expect(cluster.reasons == ["same company and short code 72727"])
        #expect(cluster.flags.isEmpty)
    }

    @Test("Company names compare folded: case, diacritics and whitespace do not matter")
    func companyFolded() {
        let clusters = matcher.findClusters(in: [
            record("a", org: "Acme Bank", phones: ["72727"]),
            record("b", org: "  ACMÉ   bank ", phones: ["727-27"]),
        ])
        #expect(clusters.count == 1)
        #expect(clusters.first?.level == .high)
    }

    @Test("A shared short code with different companies creates no edge at all")
    func differentCompanies() {
        let a = record("a", org: "Acme Bank", phones: ["72727"])
        let b = record("b", org: "Other Co", phones: ["72727"])
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
        #expect(matcher.evaluate(a, b) == nil)
        let result = matcher.analyze([a, b])
        #expect(result.clusters.isEmpty)
    }

    @Test("A shared short code where a side has no company creates no edge", arguments: [
        ("Acme Bank", ""), ("", "Acme Bank"), ("", ""),
    ])
    func missingCompany(orgA: String, orgB: String) {
        let a = record("a", org: orgA, phones: ["72727"])
        let b = record("b", org: orgB, phones: ["72727"])
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
        #expect(matcher.evaluate(a, b) == nil)
    }

    @Test("A 7- or 8-digit local number is not a short code and creates no edge", arguments: ["555-0199", "5550199", "12345678"])
    func localNumbersAreNotShortCodes(number: String) {
        let a = record("a", org: "Acme Bank", phones: [number])
        let b = record("b", org: "Acme Bank", phones: [number])
        #expect(matcher.evaluate(a, b) == nil)
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
    }

    @Test("The same company with different short codes is not a match")
    func differentShortCodes() {
        #expect(matcher.findClusters(in: [
            record("a", org: "Acme Bank", phones: ["72727"]),
            record("b", org: "Acme Bank", phones: ["72728"]),
        ]).isEmpty)
    }

    @Test("People with conflicting names at the same company and short code do not match")
    func conflictingPersonNames() {
        let a = record("a", given: "Ann", family: "Lee", org: "Acme Bank", phones: ["72727"])
        let b = record("b", given: "Bob", family: "Stone", org: "Acme Bank", phones: ["72727"])
        #expect(matcher.evaluate(a, b) == nil)
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
    }

    @Test("A short code is no evidence for different given names that are merely close (Mark/Mary)")
    func closeGivenNamesDoNotMatch() {
        let a = record("a", given: "Mark", family: "Smith", org: "Acme Bank", phones: ["72727"])
        let b = record("b", given: "Mary", family: "Smith", org: "Acme Bank", phones: ["72727"])
        // Close names may still match by name alone, but never through the short code.
        #expect(matcher.evaluate(a, b)?.reasons.contains { $0.contains("short code") } != true)
    }

    @Test("A person at the company and a nameless record sharing the short code never reach high")
    func personAndUnnamed() throws {
        let clusters = matcher.findClusters(in: [
            record("a", given: "Ann", family: "Lee", org: "Acme Bank", phones: ["72727"]),
            record("b", org: "Acme Bank", phones: ["72727"]),
        ])
        let cluster = try #require(clusters.first)
        #expect(cluster.level == .medium)
        #expect(cluster.flags == [.sharedIdentifierUnnamedRecord])
    }

    @Test("A short code held by more than the switchboard cap is ignored and counted")
    func shortCodeSwitchboard() {
        var options = DuplicateMatcher.Options()
        options.maxIdentifierBlockSize = 5
        let capped = DuplicateMatcher(options: options)
        let same = (0..<6).map { record("r\($0)", org: "Acme Bank", phones: ["72727"]) }
        let result = capped.analyze(same)
        #expect(result.clusters.isEmpty)
        #expect(result.diagnostics.droppedSwitchboardIdentifiers == 1)

        let atCap = capped.analyze(Array(same.prefix(5)))
        #expect(atCap.clusters.count == 1)
        #expect(atCap.clusters.first?.members.count == 5)
    }

    @Test("Twelve companies imported twice give twelve clusters, one per company")
    func twelveCompaniesTwice() {
        var records: [ContactRecord] = []
        for n in 0..<12 {
            for copy in ["a", "b"] {
                records.append(record("\(copy)\(n)", org: "Company \(n)", phones: ["\(70000 + n)"]))
            }
        }
        let clusters = matcher.findClusters(in: records)
        #expect(clusters.count == 12)
        #expect(clusters.allSatisfy { $0.members.count == 2 && $0.level == .high })
    }

    @Test("A short code does not join records through a company name alone: org alone never matches")
    func orgAloneNeverMatches() {
        #expect(matcher.findClusters(in: [
            record("a", org: "Acme Bank", phones: ["72727"]),
            record("b", org: "Acme Bank"),
        ]).isEmpty)
    }

    // MARK: organization-only twins via a regular phone

    @Test("Two organization-only records with the same org and the same 10-digit phone cluster")
    func orgOnlyTwinsRegularPhone() throws {
        let clusters = matcher.findClusters(in: [
            record("a", org: "Acme Dental", phones: ["(512) 555-0199"]),
            record("b", org: "Acme Dental", phones: ["512-555-0199"]),
        ])
        let cluster = try #require(clusters.first)
        #expect(cluster.level >= .medium)
        #expect(cluster.reasons.contains("same phone +15125550199"))
    }

    // MARK: the person imported twice

    @Test("A person imported twice (name, 10-digit phone, email, nickname) is high via the phone")
    func personTwice() throws {
        let clusters = matcher.findClusters(in: [
            record("a", given: "Ann", family: "Lee", nickname: "Annie", phones: ["415-555-2671"], emails: ["ann@example.com"]),
            record("b", given: "Ann", family: "Lee", nickname: "Annie", phones: ["415-555-2671"], emails: ["ann@example.com"]),
        ])
        let cluster = try #require(clusters.first)
        #expect(cluster.level == .high)
        #expect(cluster.reasons.contains("same phone +14155552671"))
    }

    // MARK: websites

    @Test("Two Sams sharing a website (scheme and www folded) are a medium cluster")
    func websiteTwins() throws {
        let clusters = matcher.findClusters(in: [
            record("a", given: "Sam", urls: ["https://sam.example.com/"]),
            record("b", given: "Sam", urls: ["http://www.sam.example.com"]),
        ])
        let cluster = try #require(clusters.first)
        #expect(clusters.count == 1)
        #expect(cluster.level == .medium)
        #expect(abs(cluster.confidence - 0.7) < 1e-9)
        #expect(cluster.reasons == ["same website sam.example.com"])
        #expect(cluster.flags.isEmpty)
    }

    @Test("A website keeps its path: different pages on one host are different websites")
    func websitePathKept() {
        #expect(matcher.findClusters(in: [
            record("a", given: "Sam", urls: ["https://example.com/sam"]),
            record("b", given: "Sam", urls: ["https://example.com/pat"]),
        ]).isEmpty)
    }

    @Test("Different people sharing a website get no edge")
    func websiteDifferentNames() {
        let a = record("a", given: "Sam", urls: ["https://example.com/"])
        let b = record("b", given: "Pat", urls: ["https://example.com/"])
        #expect(matcher.evaluate(a, b) == nil)
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
    }

    @Test("A shared website with a family-name conflict gets no edge")
    func websiteFamilyConflict() {
        let a = record("a", given: "Sam", family: "Lee", urls: ["https://example.com/"])
        let b = record("b", given: "Sam", family: "Stone", urls: ["https://example.com/"])
        #expect(matcher.evaluate(a, b) == nil)
    }

    @Test("A shared website with a full name on one side and only the given name on the other is compatible")
    func websiteGivenOnlyAgainstFull() {
        let a = record("a", given: "Sam", family: "Lee", urls: ["https://example.com/"])
        let b = record("b", given: "Sam", urls: ["https://example.com/"])
        let match = matcher.evaluate(a, b)
        #expect(match.map { abs($0.confidence - 0.7) < 1e-9 } == true)
    }

    @Test("A shared website with an unnamed record gets no edge")
    func websiteUnnamed() {
        #expect(matcher.evaluate(
            record("a", org: "Acme", urls: ["https://example.com/"]),
            record("b", org: "Acme", urls: ["https://example.com/"])
        ) == nil)
    }

    @Test("A bare root on a shared host never creates an edge", arguments: [
        ("https://facebook.com", "https://www.facebook.com/"),
        ("https://instagram.com/", "http://instagram.com"),
        ("https://x.com", "https://x.com/"),
        ("https://www.linkedin.com/", "https://linkedin.com"),
        ("https://github.com", "https://github.com/"),
        ("https://google.com/", "https://www.google.com"),
        ("https://youtube.com", "https://youtube.com/?hl=en"),
    ])
    func sharedHostRoots(first: String, second: String) {
        let a = record("a", given: "Mike", urls: [first])
        let b = record("b", given: "Mike", family: "Smith", urls: [second])
        #expect(matcher.evaluate(a, b) == nil)
        #expect(matcher.findClusters(in: [a, b]).isEmpty)
    }

    @Test("A single generic path segment on a shared host never creates an edge", arguments: [
        "https://facebook.com/home", "https://www.twitter.com/home/", "https://linkedin.com/login", "https://github.com/about",
    ])
    func sharedHostGenericPath(url: String) {
        let a = record("a", given: "Mike", urls: [url])
        let b = record("b", given: "Mike", family: "Smith", urls: [url])
        #expect(matcher.evaluate(a, b) == nil)
    }

    @Test("A profile path on a shared host still counts")
    func sharedHostProfile() throws {
        let a = record("a", given: "Mike", urls: ["https://facebook.com/mike.smith"])
        let b = record("b", given: "Mike", family: "Smith", urls: ["https://www.facebook.com/mike.smith/"])
        let match = try #require(matcher.evaluate(a, b))
        #expect(match.reasons == ["same website facebook.com/mike.smith"])
        #expect(match.level == .medium)
    }

    @Test("A personal subdomain root on a blog host still counts")
    func blogSubdomainRoot() {
        let a = record("a", given: "Sam", urls: ["https://sam.blogspot.com"])
        let b = record("b", given: "Sam", urls: ["http://sam.blogspot.com/"])
        #expect(matcher.evaluate(a, b) != nil)
    }

    @Test("A website held by more than the switchboard cap is ignored and counted")
    func websiteSwitchboard() {
        var options = DuplicateMatcher.Options()
        options.maxIdentifierBlockSize = 5
        let capped = DuplicateMatcher(options: options)
        let result = capped.analyze((0..<6).map { record("r\($0)", given: "Sam", urls: ["https://example.com/"]) })
        #expect(result.clusters.isEmpty)
        #expect(result.diagnostics.droppedSwitchboardIdentifiers == 1)
    }
}
