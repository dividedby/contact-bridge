import Foundation
import Testing
@testable import ContactBridgeCore

actor SleepRecorder {
    private(set) var delays: [TimeInterval] = []
    func record(_ delay: TimeInterval) { delays.append(delay) }
}

struct StaticTokenProvider: GoogleAccessTokenProviding {
    func validAccessToken() async throws -> String { "tok-1" }
    func refreshedAccessToken(replacing rejected: String) async throws -> String { "tok-2" }
}

let base = "https://people.googleapis.com/v1/"
let personFields = "names,nicknames,organizations,phoneNumbers,emailAddresses,addresses,urls,birthdays,metadata,clientData,memberships"

struct URLSessionGoogleContactsClientTests {
    private func makeClient(
        _ transport: FakeHTTPTransport, auth: any GoogleAccessTokenProviding = StaticTokenProvider(),
        sleeps: SleepRecorder = SleepRecorder()
    ) -> URLSessionGoogleContactsClient {
        URLSessionGoogleContactsClient(
            transport: transport, auth: auth,
            sleep: { await sleeps.record($0) }, jitter: { 0 }
        )
    }

    private func person(_ given: String) -> GooglePerson {
        GooglePerson(names: [GoogleName(givenName: given, familyName: "Test")])
    }

    // MARK: reads

    @Test("The first connections page asks for every modeled field plus metadata, clientData and memberships, with a sync token")
    func listConnectionsFirstPage() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/me/connections", [try .fixture(200, "connections_page1")])
        let page = try await makeClient(transport).listConnections(syncToken: nil, pageToken: nil)

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString.hasPrefix(base + "people/me/connections?"))
        #expect(request.query == ["personFields": personFields, "pageSize": "1000", "requestSyncToken": "true"])
        #expect(request.headers["Authorization"] == "Bearer tok-1")
        #expect(page.people.count == 2 && page.nextPageToken == "CgwI_9a7pAYQ4LuHtwM" && page.nextSyncToken == nil)
    }

    @Test("Later pages and incremental syncs repeat the same parameters plus pageToken / syncToken")
    func listConnectionsTokens() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/me/connections", [try .fixture(200, "connections_page2")])
        let client = makeClient(transport)
        let page = try await client.listConnections(syncToken: "SYNC/1+x", pageToken: "PAGE 2")

        let request = try #require(await transport.requests.first)
        #expect(request.query == [
            "personFields": personFields, "pageSize": "1000", "requestSyncToken": "true",
            "pageToken": "PAGE 2", "syncToken": "SYNC/1+x",
        ])
        #expect(request.url.absoluteString.contains("syncToken=SYNC%2F1%2Bx"))
        #expect(page.nextSyncToken == "CMjZ0uDYo7oDEMjZ0uDYo7oD" && page.nextPageToken == nil)
        #expect(page.people.count == 1)
    }

    @Test("Sync stubs for deleted people survive decoding")
    func deletedStubs() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/me/connections", [try .fixture(200, "connections_sync_deleted")])
        let page = try await makeClient(transport).listConnections(syncToken: "S", pageToken: nil)
        #expect(page.people.map(\.isDeleted) == [true, false])
    }

    @Test("Other contacts use readMask, not personFields")
    func listOtherContacts() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "otherContacts", [try .fixture(200, "other_contacts_page")])
        let page = try await makeClient(transport).listOtherContacts(pageToken: "P2")
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString.hasPrefix(base + "otherContacts?"))
        #expect(request.query == ["readMask": "names,emailAddresses,phoneNumbers,metadata", "pageSize": "1000", "pageToken": "P2"])
        #expect(page.nextPageToken == "CgwIsecondPage" && !page.people.isEmpty)
    }

    @Test("getPerson fetches by resource name and keeps unmodeled keys")
    func getPerson() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c2468013579246801357", [try .fixture(200, "person_full")])
        let person = try await makeClient(transport).getPerson(resourceName: "people/c2468013579246801357")
        let request = try #require(await transport.requests.first)
        #expect(request.url.path == "/v1/people/c2468013579246801357")
        #expect(request.query == ["personFields": personFields])
        #expect(person == (try GoogleFixtures.decode(GooglePerson.self, "person_full")))
    }

    // MARK: single writes

    @Test("createContact posts the person to people:createContact")
    func create() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:createContact", [.json(200, #"{"resourceName": "people/c9", "etag": "E1", "names": [{"givenName": "Zed", "familyName": "Test"}]}"#)])
        let created = try await makeClient(transport).createContact(person("Zed"))
        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        // The colon must stay literal: a %3A would address a different (nonexistent) method.
        #expect(request.url.absoluteString.hasPrefix(base + "people:createContact?"))
        #expect(request.query == ["personFields": personFields])
        #expect(request.headers["Content-Type"] == "application/json")
        let names = try #require(request.bodyJSON?["names"] as? [[String: Any]])
        #expect(names.first?["givenName"] as? String == "Zed")
        #expect(created.resourceName == "people/c9" && created.etag == "E1")
    }

    @Test("updateContact patches with updatePersonFields and puts the etag in the body")
    func update() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("PATCH", ":updateContact", [.json(200, #"{"resourceName": "people/c1", "etag": "E2"}"#)])
        var changed = person("New")
        changed.etag = "stale-or-missing"
        let updated = try await makeClient(transport).updateContact(
            resourceName: "people/c1", etag: "E1", person: changed, updatePersonFields: "names,emailAddresses"
        )
        let request = try #require(await transport.requests.first)
        #expect(request.method == "PATCH" && request.url.path == "/v1/people/c1:updateContact")
        #expect(request.query == ["updatePersonFields": "names,emailAddresses", "personFields": personFields])
        #expect(request.bodyJSON?["etag"] as? String == "E1")
        #expect(request.bodyJSON?["resourceName"] as? String == "people/c1")
        #expect(updated.etag == "E2")
    }

    @Test("deleteContact issues DELETE people/...:deleteContact")
    func delete() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("DELETE", ":deleteContact", [.json(200, "{}")])
        try await makeClient(transport).deleteContact(resourceName: "people/c1")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "DELETE" && request.url.path == "/v1/people/c1:deleteContact")
        #expect(request.body.isEmpty)
    }

    // MARK: batches

    private func tagged(_ index: Int) -> GooglePerson {
        var tagged = person("P\(index)")
        GoogleOwnership.setSourceID("tag-\(index)", on: &tagged)
        return tagged
    }

    /// A createdPeople response for inputs `range`; failing indices come back as bare error items.
    private func createdResponse(_ range: Range<Int>, failing: Set<Int> = []) -> HTTPResult {
        let items = range.map { index in
            failing.contains(index)
                ? #"{"httpStatusCode": 400, "status": {"code": 3, "message": "bad"}}"#
                : #"{"httpStatusCode": 200, "person": {"resourceName": "people/n\#(index)", "etag": "e", "clientData": [{"key": "contactBridge.sourceID", "value": "tag-\#(index)"}]}}"#
        }
        return .json(200, #"{"createdPeople": [\#(items.joined(separator: ","))]}"#)
    }

    @Test("batchCreate chunks at 200, wraps each person in contactPerson, and reports item failures")
    func batchCreate() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchCreateContacts", [createdResponse(0..<200), createdResponse(200..<400, failing: [201]), createdResponse(400..<450)])
        let results = try await makeClient(transport).batchCreate((0..<450).map(tagged))

        let requests = await transport.requests
        #expect(requests.count == 3)
        for (request, expected) in zip(requests, [200, 200, 50]) {
            let contacts = try #require(request.bodyJSON?["contacts"] as? [[String: Any]])
            #expect(contacts.count == expected)
            #expect((contacts.first?["contactPerson"] as? [String: Any])?["names"] != nil)
            #expect(request.bodyJSON?["readMask"] as? String == personFields)
            #expect(request.url.path == "/v1/people:batchCreateContacts")
        }
        #expect(results.count == 450)
        #expect(results[0].isSuccess && results[0].resourceName == "people/n0")
        #expect(results[201].error == .other(status: 400, message: "bad"))
        #expect(results.filter { !$0.isSuccess }.count == 1)
    }

    private func update(_ name: String, mask: String) -> GoogleContactUpdate {
        GoogleContactUpdate(resourceName: name, etag: "etag-\(name)", person: person(name), updatePersonFields: mask)
    }

    private func updateResponse(_ names: [String], failing: [String: String] = [:]) -> HTTPResult {
        let items = names.map { name in
            if let message = failing[name] {
                return #""\#(name)": {"httpStatusCode": 400, "status": {"code": 9, "message": "\#(message)"}}"#
            }
            return #""\#(name)": {"httpStatusCode": 200, "person": {"resourceName": "\#(name)", "etag": "new-\#(name)"}}"#
        }
        return .json(200, #"{"updateResult": {\#(items.joined(separator: ","))}}"#)
    }

    @Test("batchUpdate sends updates with different masks in separate calls and returns results in input order")
    func batchUpdateMixedMasks() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchUpdateContacts", [
            updateResponse(["people/c1", "people/c3"], failing: ["people/c3": "Request person.etag is different than the current person.etag."]),
            updateResponse(["people/c2"]),
        ])
        let updates = [update("people/c1", mask: "names"), update("people/c2", mask: "names,birthdays"), update("people/c3", mask: "names")]
        let results = try await makeClient(transport).batchUpdate(updates)

        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.map { $0.bodyJSON?["updateMask"] as? String } == ["names", "names,birthdays"])
        let firstContacts = try #require(requests[0].bodyJSON?["contacts"] as? [String: [String: Any]])
        #expect(Set(firstContacts.keys) == ["people/c1", "people/c3"])
        #expect(firstContacts["people/c1"]?["etag"] as? String == "etag-people/c1")
        #expect(firstContacts["people/c1"]?["names"] != nil)
        #expect(requests[0].bodyJSON?["readMask"] as? String == personFields)

        #expect(results.map(\.resourceName) == ["people/c1", "people/c2", "people/c3"])
        #expect(results[0].person?.etag == "new-people/c1" && results[1].isSuccess)
        #expect(results[2].error == .etagMismatch)
    }

    @Test("batchUpdate chunks a mask group at 200")
    func batchUpdateChunks() async throws {
        let transport = FakeHTTPTransport()
        let names = (0..<201).map { "people/c\($0)" }
        await transport.route("POST", "people:batchUpdateContacts", [updateResponse(Array(names[0..<200])), updateResponse([names[200]])])
        let results = try await makeClient(transport).batchUpdate(names.map { update($0, mask: "names") })
        let sizes = try await transport.requests.map { try #require($0.bodyJSON?["contacts"] as? [String: Any]).count }
        #expect(sizes == [200, 1])
        #expect(results.count == 201 && results.allSatisfy { $0.isSuccess })
    }

    @Test("batchUpdate never puts the same person twice in one call")
    func batchUpdateDuplicates() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchUpdateContacts", [updateResponse(["people/c1"])])
        let results = try await makeClient(transport).batchUpdate([update("people/c1", mask: "names"), update("people/c1", mask: "names")])
        #expect(await transport.requests.count == 2)
        #expect(results.count == 2)
    }

    @Test("A result missing from the response is reported as a failure, not dropped")
    func batchUpdateMissingResult() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchUpdateContacts", [updateResponse(["people/c1"])])
        let results = try await makeClient(transport).batchUpdate([update("people/c1", mask: "names"), update("people/c2", mask: "names")])
        #expect(results.count == 2 && results[0].isSuccess && results[1].isAmbiguous)
    }

    @Test("batchDelete chunks resource names at 200")
    func batchDelete() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchDeleteContacts", [.json(200, "{}")])
        let results = try await makeClient(transport).batchDelete((0..<201).map { "people/c\($0)" })
        #expect(results.count == 201 && results.allSatisfy { $0.isSuccess } && results[5].resourceName == "people/c5")
        let requests = await transport.requests
        #expect(try requests.map { try #require($0.bodyJSON?["resourceNames"] as? [String]).count } == [200, 1])
        #expect(requests[0].url.path == "/v1/people:batchDeleteContacts")
        #expect(try await makeClient(transport).batchDelete([]).isEmpty)
        #expect(await transport.requests.count == 2)
    }

    @Test("A failed batchDelete reports the classified error on the item")
    func batchDeleteFails() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:batchDeleteContacts", [try .fixture(404, "error_404")])
        let results = try await makeClient(transport).batchDelete(["people/c1"])
        #expect(results.map(\.error) == [.notFound])
    }

    // MARK: groups

    @Test("ensureGroup finds an existing user group across pages without creating")
    func ensureGroupExisting() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "v1/contactGroups", [
            .json(200, #"{"contactGroups": [{"resourceName": "contactGroups/myContacts", "name": "myContacts", "groupType": "SYSTEM_CONTACT_GROUP"}], "nextPageToken": "G2"}"#),
            .json(200, #"{"contactGroups": [{"resourceName": "contactGroups/6a2", "name": "Contact Bridge", "groupType": "USER_CONTACT_GROUP"}]}"#),
        ])
        let name = try await makeClient(transport).ensureGroup(named: "Contact Bridge")
        #expect(name == "contactGroups/6a2")
        let requests = await transport.requests
        #expect(requests.count == 2 && requests.allSatisfy { $0.method == "GET" })
        #expect(requests[0].query == ["pageSize": "1000"] && requests[1].query == ["pageSize": "1000", "pageToken": "G2"])
    }

    @Test("ensureGroup creates the group when only a system group shares its name")
    func ensureGroupCreates() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "v1/contactGroups", [.json(200, #"{"contactGroups": [{"resourceName": "contactGroups/starred", "name": "Contact Bridge", "groupType": "SYSTEM_CONTACT_GROUP"}]}"#)])
        await transport.route("POST", "v1/contactGroups", [.json(200, #"{"resourceName": "contactGroups/77", "name": "Contact Bridge", "groupType": "USER_CONTACT_GROUP"}"#)])
        let name = try await makeClient(transport).ensureGroup(named: "Contact Bridge")
        #expect(name == "contactGroups/77")
        let create = try #require(await transport.requests.last)
        #expect(create.method == "POST" && create.url.path == "/v1/contactGroups")
        #expect((create.bodyJSON?["contactGroup"] as? [String: Any])?["name"] as? String == "Contact Bridge")
    }

    @Test("addMembers posts resourceNamesToAdd to members:modify, in chunks of 1000")
    func addMembers() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "members:modify", [.json(200, "{}")])
        try await makeClient(transport).addMembers(groupResourceName: "contactGroups/77", memberResourceNames: (0..<1001).map { "people/c\($0)" })
        let requests = await transport.requests
        #expect(requests.allSatisfy { $0.url.path == "/v1/contactGroups/77/members:modify" })
        #expect(try requests.map { try #require($0.bodyJSON?["resourceNamesToAdd"] as? [String]).count } == [1000, 1])
    }

    @Test("addMembers fails with notFound when Google reports unknown members")
    func addMembersNotFound() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "members:modify", [.json(200, #"{"notFoundResourceNames": ["people/c9"]}"#)])
        await #expect(throws: GoogleAPIError.notFound) {
            try await makeClient(transport).addMembers(groupResourceName: "contactGroups/77", memberResourceNames: ["people/c9"])
        }
    }

    // MARK: errors, retries, refresh

    @Test("Non-2xx responses are classified with GoogleAPIError.parse")
    func classification() async throws {
        let cases: [(Int, String, GoogleAPIError)] = [
            (404, "error_404", .notFound),
            (410, "error_410", .syncTokenExpired),
            (400, "error_400_expired_sync_token", .syncTokenExpired),
            (400, "error_400_etag", .etagMismatch),
        ]
        for (status, fixture, expected) in cases {
            let transport = FakeHTTPTransport()
            await transport.route("GET", "people/", [try .fixture(status, fixture)])
            await #expect(throws: expected) { _ = try await makeClient(transport).getPerson(resourceName: "people/c1") }
        }
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/", [try .fixture(403, "error_403_forbidden")])
        do {
            _ = try await makeClient(transport).getPerson(resourceName: "people/c1")
            Issue.record("expected a throw")
        } catch let error as GoogleAPIError {
            if case .other(let status, _) = error { #expect(status == 403) } else { Issue.record("expected .other, got \(error)") }
        }
    }

    @Test("Rate limits back off exponentially with injected sleeps, then succeed")
    func backoff() async throws {
        let transport = FakeHTTPTransport()
        let limited = try HTTPResult.fixture(429, "error_429")
        await transport.route("GET", "people/c1", [limited, limited, limited, .json(200, #"{"resourceName": "people/c1"}"#)])
        let sleeps = SleepRecorder()
        let person = try await makeClient(transport, sleeps: sleeps).getPerson(resourceName: "people/c1")
        #expect(person.resourceName == "people/c1")
        #expect(await sleeps.delays == [1, 2, 4])
        #expect(await transport.requests.count == 4)
    }

    @Test("Jitter stretches the delay by up to half")
    func jitter() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(429, "error_429"), .json(200, "{}")])
        let sleeps = SleepRecorder()
        let client = URLSessionGoogleContactsClient(transport: transport, auth: StaticTokenProvider(), sleep: { await sleeps.record($0) }, jitter: { 1 })
        _ = try await client.getPerson(resourceName: "people/c1")
        #expect(await sleeps.delays == [1.5])
    }

    @Test("Retry-After overrides the computed backoff")
    func retryAfter() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(429, "error_429", headers: ["retry-after": "7"]), .json(200, "{}")])
        let sleeps = SleepRecorder()
        _ = try await makeClient(transport, sleeps: sleeps).getPerson(resourceName: "people/c1")
        #expect(await sleeps.delays == [7])
    }

    @Test("A 403 rateLimitExceeded is retried like a 429")
    func rateLimit403() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(403, "error_403_rate_limit"), .json(200, "{}")])
        let sleeps = SleepRecorder()
        _ = try await makeClient(transport, sleeps: sleeps).getPerson(resourceName: "people/c1")
        #expect(await sleeps.delays == [1])
    }

    @Test("Gives up after 5 attempts with the rate-limit error")
    func giveUp() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(429, "error_429", headers: ["Retry-After": "3"])])
        let sleeps = SleepRecorder()
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: 3)) {
            _ = try await makeClient(transport, sleeps: sleeps).getPerson(resourceName: "people/c1")
        }
        #expect(await transport.requests.count == 5)
        #expect(await sleeps.delays == [3, 3, 3, 3])
    }

    private func sessionClient(_ transport: FakeHTTPTransport, expiringIn seconds: TimeInterval = 3600) -> URLSessionGoogleContactsClient {
        let session = GoogleAuthSession(
            oauth: GoogleOAuthClient(config: OAuthConfig(clientID: "id", clientSecret: "secret"), transport: transport),
            store: InMemoryTokenStore(StoredGoogleToken(refreshToken: "r1", accessToken: "tok-old", expiry: Date().addingTimeInterval(seconds), grantedScopes: GoogleScopes.all)),
            openURL: { _ in false }
        )
        return URLSessionGoogleContactsClient(transport: transport, auth: session, sleep: { _ in }, jitter: { 0 })
    }

    @Test("A 401 refreshes the token once and retries with the new one")
    func unauthorizedRefreshes() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(401, "error_401"), .json(200, #"{"resourceName": "people/c1"}"#)])
        await transport.route("POST", "/token", [.json(200, #"{"access_token": "tok-new", "expires_in": 3600, "scope": "x"}"#)])
        let person = try await sessionClient(transport).getPerson(resourceName: "people/c1")
        #expect(person.resourceName == "people/c1")
        let gets = await transport.requests("GET", containing: "people/c1")
        #expect(gets.map { $0.headers["Authorization"] } == ["Bearer tok-old", "Bearer tok-new"])
        #expect(await transport.requests(containing: "/token").count == 1)
    }

    @Test("A second 401 is not retried again")
    func unauthorizedTwice() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(401, "error_401")])
        await transport.route("POST", "/token", [.json(200, #"{"access_token": "tok-new", "expires_in": 3600}"#)])
        await #expect(throws: GoogleAPIError.unauthorized) { _ = try await sessionClient(transport).getPerson(resourceName: "people/c1") }
        #expect(await transport.requests("GET", containing: "people/c1").count == 2)
        #expect(await transport.requests(containing: "/token").count == 1)
    }

    @Test("A revoked refresh token during a 401 retry surfaces as needsReauthorization")
    func unauthorizedRevoked() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [try .fixture(401, "error_401")])
        await transport.route("POST", "/token", [.json(400, #"{"error": "invalid_grant"}"#)])
        await #expect(throws: GoogleAuthError.needsReauthorization) { _ = try await sessionClient(transport).getPerson(resourceName: "people/c1") }
    }

    @Test("Transport failures and unreadable bodies propagate")
    func failures() async throws {
        let empty = FakeHTTPTransport()
        await #expect(throws: URLError.self) { _ = try await makeClient(empty).getPerson(resourceName: "people/c1") }
        let garbage = FakeHTTPTransport()
        await garbage.route("GET", "people/c1", [.json(200, "<html>")])
        await #expect(throws: GoogleAPIError.self) { _ = try await makeClient(garbage).getPerson(resourceName: "people/c1") }
    }
}
