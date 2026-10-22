import Foundation

/// The real People API v1 client. Every call carries a bearer token from `auth`; non-2xx responses are classified with
/// `GoogleAPIError.parse`; rate limits are retried with exponential backoff; a 401 refreshes the token once and retries.
public struct URLSessionGoogleContactsClient: GoogleContactsClient {
    static let baseURL = "https://people.googleapis.com/v1/"
    static let maxAttempts = 5
    static let maxBackoff: TimeInterval = 120
    static let retryableServerStatuses: Set<Int> = [500, 502, 503, 504]
    /// `members:modify` accepts at most this many resource names per call.
    static let maxMembersPerCall = 1000
    static let pageSize = 1000

    /// Every modeled field plus the bookkeeping the sync needs. `modeledFields` stays the single source of truth.
    static let personFields = (GooglePersonMapper.modeledFields + ["metadata", "clientData", "memberships"]).joined(separator: ",")
    /// The only fields `otherContacts.list` accepts that this app uses.
    static let otherContactsReadMask = "names,emailAddresses,phoneNumbers,metadata"

    /// `urlPathAllowed` escapes a colon in the first segment, which would break `people:createContact`.
    private static let pathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.insert(":")
        return allowed
    }()

    private let transport: any HTTPTransport
    private let auth: any GoogleAccessTokenProviding
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let jitter: @Sendable () -> Double

    /// - Parameters:
    ///   - sleep: waits the given seconds between rate-limit retries (injectable so tests do not wait).
    ///   - jitter: a value in 0..<1 that stretches each computed backoff by up to 50%.
    public init(
        transport: any HTTPTransport = URLSessionTransport(), auth: any GoogleAccessTokenProviding,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.transport = transport
        self.auth = auth
        self.sleep = sleep
        self.jitter = jitter
    }

    // MARK: reads

    public func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
        // A sync token is only valid with the same parameters as the call that issued it, so they never vary.
        var query = [("personFields", Self.personFields), ("pageSize", "\(Self.pageSize)"), ("requestSyncToken", "true")]
        if let pageToken { query.append(("pageToken", pageToken)) }
        if let syncToken { query.append(("syncToken", syncToken)) }
        let data = try await perform("GET", "people/me/connections", query: query, idempotent: true)
        return GooglePeoplePage(try decode(GoogleConnectionsResponse.self, data))
    }

    public func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage {
        var query = [("readMask", Self.otherContactsReadMask), ("pageSize", "\(Self.pageSize)")]
        if let pageToken { query.append(("pageToken", pageToken)) }
        let data = try await perform("GET", "otherContacts", query: query, idempotent: true)
        return GooglePeoplePage(try decode(GoogleOtherContactsResponse.self, data))
    }

    public func getPerson(resourceName: String) async throws -> GooglePerson {
        try decode(GooglePerson.self, try await perform("GET", resourceName, query: [("personFields", Self.personFields)], idempotent: true))
    }

    // MARK: single writes

    public func createContact(_ person: GooglePerson) async throws -> GooglePerson {
        let data = try await perform("POST", "people:createContact", query: [("personFields", Self.personFields)], body: encode(person))
        return try decode(GooglePerson.self, data)
    }

    public func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson {
        var body = person
        body.resourceName = resourceName
        body.etag = etag
        let data = try await perform(
            "PATCH", "\(resourceName):updateContact",
            query: [("updatePersonFields", updatePersonFields), ("personFields", Self.personFields)], body: encode(body)
        )
        return try decode(GooglePerson.self, data)
    }

    public func deleteContact(resourceName: String) async throws {
        _ = try await perform("DELETE", "\(resourceName):deleteContact", idempotent: true)
    }

    // MARK: batches

    public func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult] {
        // Google may answer in any order, so created people are matched to inputs by their ownership tag.
        let tags = try GoogleOwnership.requireDistinctTags(people)

        var run = GoogleBatchRun()
        var results: [GoogleBatchResult] = []
        for chunk in zip(people, tags).map({ (person: $0, tag: $1) }).chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            results += await run.run(chunk, resourceName: { _ in nil }) { chunk in
                let body = BatchCreateBody(contacts: chunk.map { .init(contactPerson: $0.person) }, readMask: Self.personFields)
                let data = try await self.perform("POST", "people:batchCreateContacts", body: self.encode(body))
                let created = try self.decode(BatchCreateResponse.self, data).createdPeople ?? []
                return Self.matchCreated(tags: chunk.map(\.tag), response: created)
            }
        }
        return results
    }

    /// Pairs created people with inputs by tag. An input with no match is a failure only if the response's failure
    /// items account for exactly the unmatched inputs; otherwise it may have been created, so it is ambiguous.
    private static func matchCreated(tags: [String], response: [PersonResponse]) -> [GoogleBatchResult] {
        var byTag: [String: GoogleBatchResult] = [:]
        var failures: [GoogleBatchResult] = []
        var unexplained = 0
        for item in response {
            let result = item.result()
            if !result.isSuccess {
                failures.append(result)
            } else if let person = result.person, let tag = GoogleOwnership.sourceID(of: person), tags.contains(tag), byTag[tag] == nil {
                byTag[tag] = result
            } else {
                unexplained += 1
            }
        }
        let unmatched = tags.filter { byTag[$0] == nil }.count
        var remainingFailures = failures[...]
        return tags.map { tag in
            if let result = byTag[tag] { return result }
            if unexplained == 0, failures.count == unmatched, let failure = remainingFailures.popFirst() {
                return GoogleBatchResult(resourceName: nil, outcome: failure.outcome)
            }
            return GoogleBatchResult(resourceName: nil, outcome: .ambiguous(reason: "the response did not include this contact"))
        }
    }

    public func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] {
        var results = [GoogleBatchResult?](repeating: nil, count: updates.count)
        var run = GoogleBatchRun()
        for group in updates.maskGroupedChunks() {
            for call in Self.uniquelyNamed(group) {
                let outcomes = await run.run(call, resourceName: { $0.update.resourceName }) { call in
                    var contacts: [String: GooglePerson] = [:]
                    for (_, update) in call {
                        var person = update.person
                        person.resourceName = update.resourceName
                        person.etag = update.etag
                        contacts[update.resourceName] = person
                    }
                    let body = BatchUpdateBody(contacts: contacts, updateMask: call[0].update.updatePersonFields, readMask: Self.personFields)
                    let data = try await self.perform("POST", "people:batchUpdateContacts", body: self.encode(body))
                    let answered = try self.decode(BatchUpdateResponse.self, data).updateResult ?? [:]
                    return call.map { _, update in
                        answered[update.resourceName]?.result(resourceName: update.resourceName) ?? Self.missingResult(for: update.resourceName)
                    }
                }
                for (position, result) in outcomes.enumerated() { results[call[position].index] = result }
            }
        }
        return results.compactMap { $0 }
    }

    public func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult] {
        var run = GoogleBatchRun()
        var results: [GoogleBatchResult] = []
        for chunk in resourceNames.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            var chunkResults = await run.run(chunk, resourceName: { $0 }) { names in
                _ = try await self.perform("POST", "people:batchDeleteContacts", body: self.encode(BatchDeleteBody(resourceNames: names)), idempotent: true)
                return names.map { GoogleBatchResult(resourceName: $0) }
            }
            // Google rejects the whole chunk if any contact is already gone, which would leave the rest undeleted.
            if chunk.count > 1, chunkResults.allSatisfy({ $0.error == .notFound }) {
                chunkResults = []
                for name in chunk {
                    chunkResults += await run.run([name], resourceName: { $0 }) { _ in
                        _ = try await self.perform("DELETE", "\(name):deleteContact", idempotent: true)
                        return [GoogleBatchResult(resourceName: name)]
                    }
                }
            }
            results += chunkResults
        }
        return results
    }

    /// The map in a batch update body is keyed by resource name, so one call cannot carry the same person twice.
    private static func uniquelyNamed(_ group: [(index: Int, update: GoogleContactUpdate)]) -> [[(index: Int, update: GoogleContactUpdate)]] {
        var calls: [[(index: Int, update: GoogleContactUpdate)]] = []
        for item in group {
            if let open = calls.firstIndex(where: { call in !call.contains { $0.update.resourceName == item.update.resourceName } }) {
                calls[open].append(item)
            } else {
                calls.append([item])
            }
        }
        return calls
    }

    private static func missingResult(for resourceName: String?) -> GoogleBatchResult {
        GoogleBatchResult(resourceName: resourceName, outcome: .ambiguous(reason: "the batch response did not include this contact"))
    }

    // MARK: groups

    public func ensureGroup(named name: String) async throws -> String {
        var pageToken: String?
        repeat {
            var query = [("pageSize", "\(Self.pageSize)")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page = try decode(ContactGroupsResponse.self, try await perform("GET", "contactGroups", query: query, idempotent: true))
            // System groups (myContacts, starred, ...) can share a name with a user's; only user groups count.
            if let match = page.contactGroups?.first(where: { $0.name == name && ($0.groupType ?? "USER_CONTACT_GROUP") == "USER_CONTACT_GROUP" }),
               let resourceName = match.resourceName {
                return resourceName
            }
            pageToken = page.nextPageToken
        } while pageToken != nil

        let created = try decode(GoogleContactGroup.self, try await perform("POST", "contactGroups", body: encode(CreateGroupBody(contactGroup: .init(name: name)))))
        guard let resourceName = created.resourceName else {
            throw GoogleAPIError.other(status: 200, message: "Google created the group but returned no resource name")
        }
        return resourceName
    }

    public func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
        for chunk in memberResourceNames.chunked(into: Self.maxMembersPerCall) {
            let data = try await perform("POST", "\(groupResourceName)/members:modify", body: encode(ModifyMembersBody(resourceNamesToAdd: chunk)))
            let response = try decode(ModifyMembersResponse.self, data)
            if !(response.notFoundResourceNames ?? []).isEmpty { throw GoogleAPIError.notFound }
        }
    }

    // MARK: transport

    /// - Parameter idempotent: repeating the call is harmless (reads, deletes), so server errors (500/502/503/504) are
    ///   retried like rate limits. For everything else a 5xx is thrown as is: the change may have been applied.
    private func perform(_ method: String, _ path: String, query: [(String, String)] = [], body: Data? = nil, idempotent: Bool = false) async throws -> Data {
        var token = try await auth.validAccessToken()
        var refreshedAfter401 = false
        var attempt = 1
        while true {
            let result = try await transport.send(try request(method, path, query: query, body: body, token: token))
            if result.isSuccess { return result.body }

            let retryAfter = GoogleAPIError.retryAfter(fromHeader: result.header("Retry-After"))
            let error = GoogleAPIError.parse(status: result.status, body: result.body, retryAfter: retryAfter)
            switch error {
            case .unauthorized where !refreshedAfter401:
                refreshedAfter401 = true
                token = try await auth.refreshedAccessToken(replacing: token)
            case .rateLimited(let hint) where attempt < Self.maxAttempts:
                try await sleep(delay(afterAttempt: attempt, hint: hint))
                attempt += 1
            case .other(let status, _) where idempotent && Self.retryableServerStatuses.contains(status) && attempt < Self.maxAttempts:
                try await sleep(delay(afterAttempt: attempt, hint: retryAfter))
                attempt += 1
            default:
                throw error
            }
        }
    }

    private func delay(afterAttempt attempt: Int, hint: TimeInterval?) -> TimeInterval {
        if let hint { return min(max(hint, 0), Self.maxBackoff) }
        let exponential = min(pow(2, Double(attempt - 1)), 32)
        return exponential * (1 + 0.5 * jitter())
    }

    private func request(_ method: String, _ path: String, query: [(String, String)], body: Data?, token: String) throws -> URLRequest {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? path
        let queryString = query.isEmpty ? "" : "?" + FormEncoding.encode(query)
        guard let url = URL(string: Self.baseURL + encodedPath + queryString) else {
            throw GoogleAPIError.other(status: 0, message: "Could not form a request URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        // Empty 2xx bodies (deletes) are valid for types whose fields are all optional.
        let payload = data.isEmpty ? Data("{}".utf8) : data
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw GoogleAPIError.other(status: 200, message: "Unreadable response from Google")
        }
    }
}

// MARK: wire shapes

private struct BatchCreateBody: Encodable {
    struct Contact: Encodable { var contactPerson: GooglePerson }
    var contacts: [Contact]
    var readMask: String
}

private struct BatchUpdateBody: Encodable {
    var contacts: [String: GooglePerson]
    var updateMask: String
    var readMask: String
}

private struct BatchDeleteBody: Encodable {
    var resourceNames: [String]
}

private struct CreateGroupBody: Encodable {
    struct Group: Encodable { var name: String }
    var contactGroup: Group
}

private struct ModifyMembersBody: Encodable {
    var resourceNamesToAdd: [String]
}

private struct ModifyMembersResponse: Decodable {
    var notFoundResourceNames: [String]?
}

private struct ContactGroupsResponse: Decodable {
    var contactGroups: [GoogleContactGroup]?
    var nextPageToken: String?
}

private struct BatchCreateResponse: Decodable {
    var createdPeople: [PersonResponse]?
}

private struct BatchUpdateResponse: Decodable {
    /// Keyed by the resource name sent in the request.
    var updateResult: [String: PersonResponse]?
}

/// One item of a batch response. A failed item carries a google.rpc.Status (and the deprecated `httpStatusCode`).
private struct PersonResponse: Decodable {
    struct RPCStatus: Decodable {
        var code: Int?
        var message: String?
    }

    var person: GooglePerson?
    var requestedResourceName: String?
    var httpStatusCode: Int?
    var status: RPCStatus?

    func result(resourceName: String? = nil) -> GoogleBatchResult {
        let name = person?.resourceName ?? resourceName ?? requestedResourceName
        if let error { return GoogleBatchResult(resourceName: name, error: error) }
        guard let person else {
            return GoogleBatchResult(resourceName: name, outcome: .ambiguous(reason: "the batch response did not include this contact"))
        }
        return GoogleBatchResult(resourceName: name, person: person)
    }

    /// Per-item failures are routed through `GoogleAPIError.parse` so they classify exactly like whole-call failures.
    private var error: GoogleAPIError? {
        let rpcCode = status?.code ?? 0
        let http = httpStatusCode.flatMap { (200..<300).contains($0) ? nil : $0 }
        guard rpcCode != 0 || http != nil else { return nil }
        let httpStatus = http ?? Self.httpStatus(forRPCCode: rpcCode)
        let envelope: [String: Any] = ["error": [
            "code": httpStatus, "message": status?.message ?? "Request failed", "status": Self.rpcName(rpcCode),
        ]]
        let body = (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
        return GoogleAPIError.parse(status: httpStatus, body: body)
    }

    private static func httpStatus(forRPCCode code: Int) -> Int {
        switch code {
        case 3, 9, 11: 400
        case 5: 404
        case 6, 10: 409
        case 7: 403
        case 8: 429
        case 16: 401
        case 14: 503
        default: 500
        }
    }

    private static func rpcName(_ code: Int) -> String {
        switch code {
        case 3: "INVALID_ARGUMENT"
        case 5: "NOT_FOUND"
        case 8: "RESOURCE_EXHAUSTED"
        case 9: "FAILED_PRECONDITION"
        case 16: "UNAUTHENTICATED"
        default: "UNKNOWN"
        }
    }
}
