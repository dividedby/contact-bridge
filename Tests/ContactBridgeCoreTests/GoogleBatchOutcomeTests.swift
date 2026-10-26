import Foundation
import Testing
@testable import ContactBridgeCore

private struct ThrowingTokenProvider: GoogleAccessTokenProviding {
    func validAccessToken() async throws -> String { throw GoogleAuthError.needsReauthorization }
    func refreshedAccessToken(replacing rejected: String) async throws -> String { throw GoogleAuthError.needsReauthorization }
}

private let badRequest = HTTPResult.json(400, #"{"error": {"code": 400, "message": "bad", "status": "INVALID_ARGUMENT"}}"#)
private let unauthorized = HTTPResult.json(401, #"{"error": {"code": 401, "message": "expired", "status": "UNAUTHENTICATED"}}"#)
private let unavailable = HTTPResult.json(503, #"{"error": {"code": 503, "message": "try later", "status": "UNAVAILABLE"}}"#)

/// What each batch operation promises when part of the work fails: a result for every input, never a thrown error that
/// hides what already happened.
struct GoogleBatchOutcomeTests {
    private let sleeps = SleepRecorder()

    private func makeClient(_ transport: FakeHTTPTransport, auth: any GoogleAccessTokenProviding = StaticTokenProvider()) -> URLSessionGoogleContactsClient {
        URLSessionGoogleContactsClient(transport: transport, auth: auth, sleep: { [sleeps] in await sleeps.record($0) }, jitter: { 0 })
    }

    private func tagged(_ index: Int) -> GooglePerson {
        var person = GooglePerson(names: [GoogleName(givenName: "P\(index)")])
        GoogleOwnership.setSourceID("tag-\(index)", on: &person)
        return person
    }

    private func created(_ indices: [Int]) -> HTTPResult {
        let items = indices.map { index in
            #"{"httpStatusCode": 200, "person": {"resourceName": "people/n\#(index)", "etag": "e", "clientData": [{"key": "contactBridge.sourceID", "value": "tag-\#(index)"}]}}"#
        }
        return .json(200, #"{"createdPeople": [\#(items.joined(separator: ","))]}"#)
    }

    private func outcomes(_ results: [GoogleBatchResult], _ range: Range<Int>) -> [String] {
        results[range].map { result in
            switch result.outcome {
            case .applied: "applied"
            case .failed: "failed"
            case .notAttempted: "notAttempted"
            case .ambiguous: "ambiguous"
            }
        }
    }

    private func allSame(_ results: [GoogleBatchResult], _ range: Range<Int>, _ expected: String) -> Bool {
        outcomes(results, range).allSatisfy { $0 == expected }
    }

    // MARK: batchCreate

    @Test("batchCreate: a failed middle chunk fails only its own items")
    func createMidBatchFailure() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [created(Array(0..<200)), badRequest, created(Array(400..<450))])
        let results = try await makeClient(transport).batchCreate((0..<450).map(tagged))
        #expect(results.count == 450)
        #expect(allSame(results, 0..<200, "applied") && allSame(results, 400..<450, "applied"))
        #expect(allSame(results, 200..<400, "failed"))
        #expect(results[250].error == .other(status: 400, message: "bad"))
        #expect(await transport.requests.count == 3)
    }

    @Test("batchCreate: a fatal error (unauthorized after the one refresh) marks later chunks notAttempted")
    func createFatalStops() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [created(Array(0..<200)), unauthorized])
        let results = try await makeClient(transport).batchCreate((0..<450).map(tagged))
        #expect(allSame(results, 0..<200, "applied"))
        #expect(allSame(results, 200..<400, "failed") && results[200].error == .unauthorized)
        #expect(allSame(results, 400..<450, "notAttempted"))
        #expect(await transport.requests.count == 3) // chunk 1, chunk 2, chunk 2 again after the refresh
    }

    @Test("batchCreate: a transport error makes the chunk ambiguous (not retried) and stops later chunks")
    func createTransportError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [created(Array(0..<200)), .networkDown])
        let results = try await makeClient(transport).batchCreate((0..<450).map(tagged))
        #expect(allSame(results, 0..<200, "applied"))
        #expect(allSame(results, 200..<400, "ambiguous"))
        #expect(allSame(results, 400..<450, "notAttempted"))
        #expect(await transport.requests.count == 2)
        #expect(results[250].error == nil && !results[250].isSuccess)
    }

    @Test("batchCreate: a 5xx is ambiguous, never retried")
    func createServerError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [unavailable])
        let results = try await makeClient(transport).batchCreate((0..<3).map(tagged))
        #expect(allSame(results, 0..<3, "ambiguous"))
        #expect(await transport.requests.count == 1)
        #expect(await sleeps.delays == [])
    }

    @Test("batchCreate: a 408 request timeout is ambiguous, never retried")
    func createRequestTimeout() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [.json(408, #"{"error": {"code": 408, "message": "timeout", "status": "DEADLINE_EXCEEDED"}}"#)])
        let results = try await makeClient(transport).batchCreate((0..<3).map(tagged))
        #expect(allSame(results, 0..<3, "ambiguous"))
        #expect(await transport.requests.count == 1)
    }

    @Test("batchCreate: a 2xx whose body cannot be read is ambiguous")
    func createUnreadable() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [.json(200, "<html>")])
        let results = try await makeClient(transport).batchCreate((0..<2).map(tagged))
        #expect(allSame(results, 0..<2, "ambiguous"))
    }

    @Test("batchCreate: a rate limit that outlasts the retries fails the chunk and stops")
    func createRateLimited() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [try .fixture(429, "error_429")])
        let results = try await makeClient(transport).batchCreate((0..<250).map(tagged))
        #expect(allSame(results, 0..<200, "failed") && allSame(results, 200..<250, "notAttempted"))
        #expect(await transport.requests.count == 5)
    }

    @Test("batchCreate: sign-in problems mean nothing was sent, so everything is notAttempted")
    func createAuthFailure() async throws {
        let transport = FakeHTTPTransport()
        let results = try await makeClient(transport, auth: ThrowingTokenProvider()).batchCreate((0..<3).map(tagged))
        #expect(allSame(results, 0..<3, "notAttempted"))
        #expect(await transport.requests.isEmpty)
    }

    @Test("batchCreate pairs created people to inputs by ownership tag, whatever order Google answers in")
    func createShuffled() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [created([4, 2, 0, 3, 1])])
        let results = try await makeClient(transport).batchCreate((0..<5).map(tagged))
        #expect(results.map(\.resourceName) == (0..<5).map { "people/n\($0)" })
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(results.map { $0.person.flatMap(GoogleOwnership.sourceID) } == (0..<5).map { "tag-\($0)" })
    }

    @Test("batchCreate: an input with no matching result is ambiguous when it cannot be explained as a failure")
    func createUnmatched() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchCreateContacts", [created([3, 0, 4])])
        let results = try await makeClient(transport).batchCreate((0..<5).map(tagged))
        #expect(outcomes(results, 0..<5) == ["applied", "ambiguous", "ambiguous", "applied", "applied"])
    }

    @Test("batchCreate: unexplained failures are attributed by elimination")
    func createFailureByElimination() async throws {
        let transport = FakeHTTPTransport()
        let failure = #"{"httpStatusCode": 400, "status": {"code": 3, "message": "bad"}}"#
        let ok = #"{"httpStatusCode": 200, "person": {"resourceName": "people/n0", "clientData": [{"key": "contactBridge.sourceID", "value": "tag-0"}]}}"#
        await transport.route("POST", "batchCreateContacts", [.json(200, #"{"createdPeople": [\#(failure), \#(ok)]}"#)])
        let results = try await makeClient(transport).batchCreate((0..<2).map(tagged))
        #expect(results[0].isSuccess && results[1].error == .other(status: 400, message: "bad"))
    }

    @Test("batchCreate requires an ownership tag on every person, and distinct tags, before sending anything")
    func createRequiresTags() async throws {
        let transport = FakeHTTPTransport()
        let client = makeClient(transport)
        await #expect(throws: GoogleBatchError.missingOwnershipTag(index: 1)) {
            _ = try await client.batchCreate([tagged(0), GooglePerson(names: [GoogleName(givenName: "No tag")])])
        }
        await #expect(throws: GoogleBatchError.duplicateOwnershipTag("tag-0")) {
            _ = try await client.batchCreate([tagged(0), tagged(0)])
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: batchUpdate

    private func update(_ name: String, mask: String) -> GoogleContactUpdate {
        GoogleContactUpdate(resourceName: name, etag: "etag", person: GooglePerson(names: [GoogleName(givenName: name)]), updatePersonFields: mask)
    }

    private func updated(_ names: [String]) -> HTTPResult {
        let items = names.map { #""\#($0)": {"httpStatusCode": 200, "person": {"resourceName": "\#($0)", "etag": "new"}}"# }
        return .json(200, #"{"updateResult": {\#(items.joined(separator: ","))}}"#)
    }

    private var threeUpdates: [GoogleContactUpdate] {
        [update("people/c1", mask: "names"), update("people/c2", mask: "nicknames"), update("people/c3", mask: "urls")]
    }

    @Test("batchUpdate: a failed mask group fails its items; other groups still run")
    func updateMidBatchFailure() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchUpdateContacts", [updated(["people/c1"]), badRequest, updated(["people/c3"])])
        let results = try await makeClient(transport).batchUpdate(threeUpdates)
        #expect(outcomes(results, 0..<3) == ["applied", "failed", "applied"])
    }

    @Test("batchUpdate: a fatal error marks later groups notAttempted")
    func updateFatalStops() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchUpdateContacts", [updated(["people/c1"]), HTTPResult.json(403, #"{"error": {"code": 403, "message": "scope", "status": "PERMISSION_DENIED"}}"#)])
        let results = try await makeClient(transport).batchUpdate(threeUpdates)
        #expect(outcomes(results, 0..<3) == ["applied", "failed", "notAttempted"])
    }

    @Test("batchUpdate: a transport error is ambiguous for that group and stops the rest")
    func updateTransportError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchUpdateContacts", [updated(["people/c1"]), .networkDown])
        let results = try await makeClient(transport).batchUpdate(threeUpdates)
        #expect(outcomes(results, 0..<3) == ["applied", "ambiguous", "notAttempted"])
    }

    @Test("batchUpdate: a 5xx is ambiguous and not retried")
    func updateServerError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchUpdateContacts", [unavailable])
        let results = try await makeClient(transport).batchUpdate([update("people/c1", mask: "names")])
        #expect(outcomes(results, 0..<1) == ["ambiguous"])
        #expect(await transport.requests.count == 1)
    }

    @Test("batchUpdate: a 408 request timeout is ambiguous and stops the rest")
    func updateRequestTimeout() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchUpdateContacts", [updated(["people/c1"]), .json(408, "{}")])
        let results = try await makeClient(transport).batchUpdate(threeUpdates)
        #expect(outcomes(results, 0..<3) == ["applied", "ambiguous", "notAttempted"])
    }

    // MARK: batchDelete

    @Test("batchDelete: a failed middle chunk fails only its own items")
    func deleteMidBatchFailure() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchDeleteContacts", [.json(200), badRequest, .json(200)])
        let results = try await makeClient(transport).batchDelete((0..<450).map { "people/c\($0)" })
        #expect(allSame(results, 0..<200, "applied") && allSame(results, 200..<400, "failed") && allSame(results, 400..<450, "applied"))
        #expect(results.map(\.resourceName) == (0..<450).map { "people/c\($0)" })
    }

    @Test("batchDelete: fatal errors and transport errors stop later chunks")
    func deleteStops() async throws {
        let fatal = FakeHTTPTransport()
        await fatal.route("POST", "batchDeleteContacts", [.json(200), unauthorized])
        let a = try await makeClient(fatal).batchDelete((0..<450).map { "people/c\($0)" })
        #expect(allSame(a, 0..<200, "applied") && allSame(a, 200..<400, "failed") && allSame(a, 400..<450, "notAttempted"))

        let down = FakeHTTPTransport()
        await down.route("POST", "batchDeleteContacts", [.json(200), .networkDown])
        let b = try await makeClient(down).batchDelete((0..<450).map { "people/c\($0)" })
        #expect(allSame(b, 200..<400, "ambiguous") && allSame(b, 400..<450, "notAttempted"))
    }

    @Test("batchDelete: when a chunk is rejected because some contacts are already gone, items are deleted one by one")
    func deleteNotFoundFallback() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchDeleteContacts", [try .fixture(404, "error_404")])
        await transport.route("DELETE", ":deleteContact", [.json(200), try .fixture(404, "error_404"), .json(200)])
        let results = try await makeClient(transport).batchDelete(["people/c1", "people/c2", "people/c3"])
        #expect(outcomes(results, 0..<3) == ["applied", "failed", "applied"])
        #expect(results[1].error == .notFound)
        let deletes = await transport.requests("DELETE", containing: "people/c")
        #expect(deletes.map(\.url.path) == ["/v1/people/c1:deleteContact", "/v1/people/c2:deleteContact", "/v1/people/c3:deleteContact"])
    }

    @Test("batchDelete: a fatal error during the one-by-one fallback stops it and the later chunks")
    func deleteFallbackFatal() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchDeleteContacts", [try .fixture(404, "error_404")])
        await transport.route("DELETE", ":deleteContact", [.json(200), unauthorized])
        let results = try await makeClient(transport).batchDelete((0..<202).map { "people/c\($0)" })
        #expect(results[0].isSuccess && results[1].error == .unauthorized)
        #expect(allSame(results, 2..<202, "notAttempted"))
    }

    @Test("batchDelete retries a 5xx, since deleting twice is harmless")
    func deleteRetriesServerError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "batchDeleteContacts", [HTTPResult.json(504), .json(200)])
        let results = try await makeClient(transport).batchDelete(["people/c1"])
        #expect(results.allSatisfy { $0.isSuccess })
        #expect(await sleeps.delays == [1])
    }

    // MARK: 5xx retries for idempotent calls only

    @Test("GET and DELETE retry 500/502/503/504 with the same backoff as rate limits")
    func idempotentRetries() async throws {
        for status in [500, 502, 503, 504] {
            let transport = FakeHTTPTransport()
            await transport.route("GET", "people/c1", [HTTPResult.json(status), HTTPResult.json(status), .json(200, #"{"resourceName": "people/c1"}"#)])
            let recorder = SleepRecorder()
            let client = URLSessionGoogleContactsClient(transport: transport, auth: StaticTokenProvider(), sleep: { await recorder.record($0) }, jitter: { 0 })
            #expect(try await client.getPerson(resourceName: "people/c1").resourceName == "people/c1")
            #expect(await recorder.delays == [1, 2])
        }
        let transport = FakeHTTPTransport()
        await transport.route("DELETE", ":deleteContact", [HTTPResult.json(503), .json(200)])
        try await makeClient(transport).deleteContact(resourceName: "people/c1")
        #expect(await transport.requests.count == 2)
    }

    @Test("A persistent 5xx on a GET is thrown after 5 attempts; Retry-After is honored")
    func idempotentGiveUp() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("GET", "people/c1", [HTTPResult.json(503, "{}", headers: ["Retry-After": "2"])])
        await #expect(throws: GoogleAPIError.other(status: 503, message: "{}")) { _ = try await makeClient(transport).getPerson(resourceName: "people/c1") }
        #expect(await transport.requests.count == 5)
        #expect(await sleeps.delays == [2, 2, 2, 2])
    }

    @Test("createContact and updateContact do not retry a 5xx")
    func mutationsDoNotRetry() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "people:createContact", [unavailable])
        await transport.route("PATCH", ":updateContact", [unavailable])
        let client = makeClient(transport)
        await #expect(throws: GoogleAPIError.self) { _ = try await client.createContact(GooglePerson()) }
        await #expect(throws: GoogleAPIError.self) { _ = try await client.updateContact(resourceName: "people/c1", etag: "e", person: GooglePerson(), updatePersonFields: "names") }
        #expect(await transport.requests.count == 2)
        #expect(await sleeps.delays == [])
    }
}
