import Foundation
import Security
import Testing
@testable import ContactBridgeCore

private let testConfig = OAuthConfig(clientID: "test-client.apps.googleusercontent.com", clientSecret: "test-secret-value")
private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func tokenJSON(access: String = "access-1", refresh: String? = "refresh-1", expiresIn: Int = 3599, scope: String? = nil) -> String {
    let scope = scope ?? GoogleScopes.all.joined(separator: " ")
    let refreshPart = refresh.map { #""refresh_token": "\#($0)","# } ?? ""
    return #"{"access_token": "\#(access)", \#(refreshPart) "expires_in": \#(expiresIn), "scope": "\#(scope)", "token_type": "Bearer"}"#
}

private let invalidGrant = HTTPResult.json(400, #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#)

private func storedToken(access: String? = "access-old", expiry: Date? = now.addingTimeInterval(3600), email: String? = "me@example.com") -> StoredGoogleToken {
    StoredGoogleToken(refreshToken: "refresh-1", accessToken: access, expiry: expiry, grantedScopes: GoogleScopes.all, email: email)
}

struct GoogleOAuthClientTests {
    @Test("The authorization URL carries every required parameter and never the secret")
    func authorizationURL() throws {
        let client = GoogleOAuthClient(config: testConfig, transport: FakeHTTPTransport())
        let url = client.authorizationURL(redirectURI: try #require(URL(string: "http://127.0.0.1:54321")), challenge: "CHALLENGE", state: "STATE", scopes: GoogleScopes.all)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "accounts.google.com" && components.path == "/o/oauth2/v2/auth")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["response_type"] == "code")
        #expect(query["client_id"] == testConfig.clientID)
        #expect(query["redirect_uri"] == "http://127.0.0.1:54321")
        #expect(query["scope"] == "https://www.googleapis.com/auth/contacts https://www.googleapis.com/auth/contacts.other.readonly")
        #expect(query["code_challenge"] == "CHALLENGE" && query["code_challenge_method"] == "S256")
        #expect(query["state"] == "STATE")
        #expect(query["access_type"] == "offline" && query["prompt"] == "consent")
        #expect(query.count == 9)
        #expect(!url.absoluteString.contains("test-secret-value"))
        // Colons and slashes inside values are percent-encoded so the redirect URI cannot be misparsed.
        #expect(url.absoluteString.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A54321"))
    }

    @Test("Code exchange posts a form with verifier, redirect URI and client credentials")
    func exchange() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "oauth2.googleapis.com/token", [.json(200, tokenJSON())])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        let response = try await client.exchangeCode("auth/code+1", verifier: "VERIFIER", redirectURI: try #require(URL(string: "http://127.0.0.1:54321")))

        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST" && request.url.absoluteString == "https://oauth2.googleapis.com/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(request.form == [
            "grant_type": "authorization_code", "code": "auth/code+1", "code_verifier": "VERIFIER",
            "redirect_uri": "http://127.0.0.1:54321", "client_id": testConfig.clientID, "client_secret": "test-secret-value",
        ])
        // Reserved characters in values must be escaped, not sent raw.
        #expect(request.bodyString.contains("code=auth%2Fcode%2B1"))
        #expect(response.accessToken == "access-1" && response.refreshToken == "refresh-1" && response.expiresIn == 3599)
        #expect(response.scopes == GoogleScopes.all)
    }

    @Test("Refresh posts grant_type=refresh_token and tolerates a response without a new refresh token")
    func refresh() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "access-2", refresh: nil))])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        let response = try await client.refresh(refreshToken: "refresh-1")
        let request = try #require(await transport.requests.first)
        #expect(request.form == [
            "grant_type": "refresh_token", "refresh_token": "refresh-1",
            "client_id": testConfig.clientID, "client_secret": "test-secret-value",
        ])
        #expect(response.accessToken == "access-2" && response.refreshToken == nil)
    }

    @Test("invalid_grant maps to needsReauthorization for refresh and for exchange")
    func invalidGrantMapping() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [invalidGrant])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        await #expect(throws: GoogleAuthError.needsReauthorization) { _ = try await client.refresh(refreshToken: "r") }
        await #expect(throws: GoogleAuthError.needsReauthorization) {
            _ = try await client.exchangeCode("c", verifier: "v", redirectURI: URL(string: "http://127.0.0.1:1")!)
        }
    }

    @Test("Other token errors stay typed and their text never includes credentials")
    func otherTokenError() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(401, #"{"error": "invalid_client", "error_description": "Unauthorized"}"#)])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        do {
            _ = try await client.refresh(refreshToken: "refresh-secret-token")
            Issue.record("expected a throw")
        } catch let error as GoogleAuthError {
            #expect(error == .tokenEndpoint(status: 401, error: "invalid_client", description: "Unauthorized"))
            #expect(!"\(error)".contains("test-secret-value") && !"\(error)".contains("refresh-secret-token"))
        }
    }

    @Test("A malformed 200 response is invalidResponse")
    func malformedSuccess() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, #"{"nope": true}"#)])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        await #expect(throws: GoogleAuthError.invalidResponse) { _ = try await client.refresh(refreshToken: "r") }
    }

    @Test("Revoke posts the token; an already-invalid token counts as revoked")
    func revoke() async throws {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "oauth2.googleapis.com/revoke", [.json(200), .json(400, #"{"error": "invalid_token"}"#), .json(500, "{}")])
        let client = GoogleOAuthClient(config: testConfig, transport: transport)
        try await client.revoke(token: "refresh-1")
        let request = try #require(await transport.requests.first)
        #expect(request.form == ["token": "refresh-1"])
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        try await client.revoke(token: "refresh-1")
        await #expect(throws: GoogleAuthError.self) { try await client.revoke(token: "refresh-1") }
    }

    @Test("The account email prefers the ACCOUNT-sourced address, then primary, then the first")
    func emailSelection() throws {
        func person(_ json: String) throws -> GooglePerson { try JSONDecoder().decode(GooglePerson.self, from: Data(json.utf8)) }
        let account = try person(#"{"emailAddresses": [{"value": "other@x.com", "metadata": {"primary": true, "source": {"type": "CONTACT"}}}, {"value": "me@x.com", "metadata": {"source": {"type": "ACCOUNT"}}}]}"#)
        #expect(GoogleOAuthClient.accountEmail(from: account) == "me@x.com")
        let primary = try person(#"{"emailAddresses": [{"value": "a@x.com"}, {"value": "b@x.com", "metadata": {"primary": true}}]}"#)
        #expect(GoogleOAuthClient.accountEmail(from: primary) == "b@x.com")
        let first = try person(#"{"emailAddresses": [{"value": "a@x.com"}]}"#)
        #expect(GoogleOAuthClient.accountEmail(from: first) == "a@x.com")
        #expect(GoogleOAuthClient.accountEmail(from: try person("{}")) == nil)
    }
}

struct GoogleAuthSessionTests {
    private func makeSession(
        store: InMemoryTokenStore, transport: FakeHTTPTransport,
        openURL: @escaping @Sendable (URL) async -> Bool = { _ in false }, timeout: Duration = .seconds(10)
    ) -> GoogleAuthSession {
        GoogleAuthSession(
            oauth: GoogleOAuthClient(config: testConfig, transport: transport), store: store, openURL: openURL,
            now: { now }, redirectTimeout: timeout
        )
    }

    @Test("A token with plenty of life is returned without any network call")
    func freshToken() async throws {
        let store = InMemoryTokenStore(storedToken())
        let transport = FakeHTTPTransport()
        let session = makeSession(store: store, transport: transport)
        #expect(try await session.validAccessToken() == "access-old")
        #expect(await transport.requests.isEmpty)
    }

    @Test("Within 60 seconds of expiry the token is refreshed and the new one persisted, keeping the refresh token")
    func refreshesNearExpiry() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(59)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "access-new", refresh: nil, expiresIn: 3600))])
        let session = makeSession(store: store, transport: transport)
        #expect(try await session.validAccessToken() == "access-new")
        let saved = try #require(try store.load())
        #expect(saved.accessToken == "access-new" && saved.refreshToken == "refresh-1")
        #expect(saved.expiry == now.addingTimeInterval(3600))
        #expect(saved.email == "me@example.com")
        // Outside the window, no further refresh.
        #expect(try await session.validAccessToken() == "access-new")
        #expect(await transport.requests.count == 1)
    }

    @Test("A stored token without an access token refreshes; a rotated refresh token replaces the old one")
    func missingAccessToken() async throws {
        let store = InMemoryTokenStore(storedToken(access: nil, expiry: nil))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "a2", refresh: "refresh-2"))])
        let session = makeSession(store: store, transport: transport)
        #expect(try await session.validAccessToken() == "a2")
        #expect(try store.load()?.refreshToken == "refresh-2")
    }

    @Test("Concurrent callers share a single refresh")
    func coalescing() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "shared"))], delay: .milliseconds(50))
        let session = makeSession(store: store, transport: transport)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 { group.addTask { try await session.validAccessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "shared", count: 8))
        #expect(await transport.requests(containing: "/token").count == 1)
    }

    @Test("A rejected token is replaced once; a caller holding an already-replaced token does not refresh again")
    func refreshedReplacing() async throws {
        let store = InMemoryTokenStore(storedToken())
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "access-A")), .json(200, tokenJSON(access: "access-B"))])
        let session = makeSession(store: store, transport: transport)
        #expect(try await session.refreshedAccessToken(replacing: "access-old") == "access-A")
        #expect(try await session.refreshedAccessToken(replacing: "access-old") == "access-A")
        #expect(await transport.requests.count == 1)
        #expect(try await session.refreshedAccessToken(replacing: "access-A") == "access-B")
    }

    @Test("invalid_grant surfaces as needsReauthorization and clears the dead credentials")
    func revokedRefreshToken() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [invalidGrant])
        let session = makeSession(store: store, transport: transport)
        await #expect(throws: GoogleAuthError.needsReauthorization) { _ = try await session.validAccessToken() }
        #expect(try store.load() == nil)
        // Later callers keep hearing "needs reauthorization", not "not signed in", until a new sign-in.
        await #expect(throws: GoogleAuthError.needsReauthorization) { _ = try await session.validAccessToken() }
        #expect(await transport.requests.count == 1)
        #expect(try await session.currentAccount() == nil)
    }

    @Test("Signing in again clears the remembered revocation")
    func signInClearsRevocation() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [invalidGrant], bodyContains: "grant_type=refresh_token")
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "fresh-access", refresh: "fresh-refresh"))], bodyContains: "grant_type=authorization_code")
        await transport.route("GET", "people/me", [.json(200, #"{"emailAddresses": [{"value": "me@example.com"}]}"#)])
        let session = makeSession(store: store, transport: transport, openURL: browser())
        await #expect(throws: GoogleAuthError.needsReauthorization) { _ = try await session.validAccessToken() }
        _ = try await session.signIn()
        #expect(try await session.validAccessToken() == "fresh-access")
    }

    @Test("A sign-out during an in-flight refresh is not overwritten by the refresh result")
    func signOutDuringRefresh() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "late"))], delay: .milliseconds(250))
        await transport.route("POST", "/revoke", [.json(200)])
        let session = makeSession(store: store, transport: transport)
        let refresh = Task { try await session.validAccessToken() }
        try await Task.sleep(for: .milliseconds(60))
        _ = try await session.signOut()
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await refresh.value }
        #expect(try store.load() == nil)
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await session.validAccessToken() }
    }

    @Test("A sign-out that lands after the refresh task is created but before it starts still discards the refresh")
    func signOutBeforeRefreshTaskStarts() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "late"))])
        await transport.route("POST", "/revoke", [.json(200)])
        let session = makeSession(store: store, transport: transport)

        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let (released, releasedContinuation) = AsyncStream<Void>.makeStream()
        await session.setBeforeRefreshStarts {
            enteredContinuation.yield()
            for await _ in released { return }
        }
        let refresh = Task { try await session.validAccessToken() }
        for await _ in entered { break }
        // The refresh task exists but has not begun: sign out now, then let it run.
        _ = try await session.signOut()
        releasedContinuation.yield()

        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await refresh.value }
        #expect(try store.load() == nil)
        #expect(await transport.requests(containing: "/token").isEmpty)
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await session.validAccessToken() }
    }

    @Test("A sign-in that completes while sign-out awaits the revocation keeps its fresh credentials")
    func signInDuringSignOut() async throws {
        let store = InMemoryTokenStore(storedToken())
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/revoke", [.json(200)], delay: .milliseconds(500))
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "fresh-access", refresh: "fresh-refresh"))], bodyContains: "grant_type=authorization_code")
        await transport.route("GET", "people/me", [.json(200, #"{"emailAddresses": [{"value": "new@example.com"}]}"#)])
        let session = makeSession(store: store, transport: transport, openURL: browser())

        let signOut = Task { try await session.signOut() }
        try await Task.sleep(for: .milliseconds(100))
        _ = try await session.signIn()
        _ = try await signOut.value

        let saved = try #require(try store.load())
        #expect(saved.refreshToken == "fresh-refresh" && saved.email == "new@example.com")
        #expect(try await session.validAccessToken() == "fresh-access")
    }

    @Test("A sign-in during an in-flight refresh keeps the new credentials; the stale refresh hands out the new token")
    func signInDuringRefresh() async throws {
        let store = InMemoryTokenStore(storedToken(expiry: now.addingTimeInterval(-10)))
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "fresh-access", refresh: "fresh-refresh"))], bodyContains: "grant_type=authorization_code")
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "stale-access", refresh: "stale-refresh"))], bodyContains: "grant_type=refresh_token", delay: .milliseconds(400))
        await transport.route("GET", "people/me", [.json(200, #"{"emailAddresses": [{"value": "new@example.com"}]}"#)])
        let session = makeSession(store: store, transport: transport, openURL: browser())
        let refresh = Task { try await session.validAccessToken() }
        try await Task.sleep(for: .milliseconds(60))
        _ = try await session.signIn()
        #expect(try await refresh.value == "fresh-access")
        let saved = try #require(try store.load())
        #expect(saved.refreshToken == "fresh-refresh" && saved.accessToken == "fresh-access" && saved.email == "new@example.com")
        #expect(try await session.validAccessToken() == "fresh-access")
    }

    @Test("signOut reports an unconfirmed revocation when the stored token cannot be loaded")
    func signOutLoadFailure() async throws {
        struct BrokenStore: TokenStore {
            func load() throws -> StoredGoogleToken? { throw KeychainError(status: -25293) }
            func save(_ token: StoredGoogleToken) throws {}
            func delete() throws {}
        }
        let transport = FakeHTTPTransport()
        let session = GoogleAuthSession(oauth: GoogleOAuthClient(config: testConfig, transport: transport), store: BrokenStore(), openURL: { _ in false }, now: { now })
        #expect(try await session.signOut() == false)
        #expect(await transport.requests.isEmpty)
    }

    @Test("Token responses never print their tokens")
    func tokenResponseRedaction() {
        let response = GoogleTokenResponse(accessToken: "AT-secret", refreshToken: "RT-secret", expiresIn: 60, scopes: ["s"])
        for text in ["\(response)", String(reflecting: response)] {
            #expect(!text.contains("AT-secret") && !text.contains("RT-secret"))
        }
    }

    @Test("Without stored credentials the session is not signed in")
    func notSignedIn() async throws {
        let session = makeSession(store: InMemoryTokenStore(), transport: FakeHTTPTransport())
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await session.validAccessToken() }
        #expect(try await session.currentAccount() == nil)
    }

    @Test("currentAccount reports the stored email and scopes")
    func currentAccount() async throws {
        let session = makeSession(store: InMemoryTokenStore(storedToken()), transport: FakeHTTPTransport())
        let account = try await session.currentAccount()
        #expect(account == GoogleAccount(email: "me@example.com", grantedScopes: GoogleScopes.all))
    }

    // MARK: sign-in

    /// Plays the browser: reads the authorization URL and calls the loopback redirect, as Google's page would.
    private func browser(
        tamperState: Bool = false, error: String? = nil, captured: Capture? = nil
    ) -> @Sendable (URL) async -> Bool {
        { url in
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            await captured?.set(query)
            guard let redirect = query["redirect_uri"] else { return false }
            let state = tamperState ? "forged" : (query["state"] ?? "")
            let tail = error.map { "error=\($0)&state=\(state)" } ?? "code=the-code&state=\(state)"
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            Task { _ = try? await URLSession(configuration: configuration).data(from: URL(string: "\(redirect)/?\(tail)")!) }
            return true
        }
    }

    actor Capture {
        var query: [String: String] = [:]
        func set(_ query: [String: String]) { self.query = query }
    }

    private func signInTransport(scope: String? = nil) async -> FakeHTTPTransport {
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON(access: "fresh-access", refresh: "fresh-refresh", scope: scope))])
        await transport.route("GET", "people.googleapis.com/v1/people/me", [.json(200, #"{"resourceName": "people/me", "emailAddresses": [{"value": "me@example.com", "metadata": {"primary": true, "source": {"type": "ACCOUNT"}}}]}"#)])
        return transport
    }

    @Test("Sign-in opens the browser, exchanges the code with the matching verifier, and stores token and email")
    func signIn() async throws {
        let store = InMemoryTokenStore()
        let transport = await signInTransport()
        let capture = Capture()
        let session = makeSession(store: store, transport: transport, openURL: browser(captured: capture))
        let account = try await session.signIn()

        #expect(account == GoogleAccount(email: "me@example.com", grantedScopes: GoogleScopes.all))
        let saved = try #require(try store.load())
        #expect(saved.refreshToken == "fresh-refresh" && saved.accessToken == "fresh-access")
        #expect(saved.email == "me@example.com" && saved.grantedScopes == GoogleScopes.all)
        #expect(saved.expiry == now.addingTimeInterval(3599))

        let exchange = try #require(await transport.requests(containing: "/token").first)
        #expect(exchange.form["code"] == "the-code")
        let challenge = await capture.query["code_challenge"]
        #expect(PKCE.challenge(forVerifier: try #require(exchange.form["code_verifier"])) == challenge)
        #expect(exchange.form["redirect_uri"] == (await capture.query["redirect_uri"]))
        let profile = try #require(await transport.requests(containing: "people/me").first)
        #expect(profile.headers["Authorization"] == "Bearer fresh-access")
        #expect(profile.query["personFields"] == "emailAddresses")
        // Now signed in without further network calls.
        #expect(try await session.validAccessToken() == "fresh-access")
    }

    @Test("If the email lookup fails, sign-in still succeeds with no email")
    func signInWithoutEmail() async throws {
        let store = InMemoryTokenStore()
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/token", [.json(200, tokenJSON())])
        await transport.route("GET", "people/me", [.json(403, #"{"error": {"code": 403, "message": "no"}}"#)])
        let session = makeSession(store: store, transport: transport, openURL: browser())
        let account = try await session.signIn()
        #expect(account.email == nil)
        #expect(try store.load()?.refreshToken == "refresh-1")
    }

    @Test("A forged state is ignored, so sign-in waits (and times out) without any token exchange")
    func signInStateMismatch() async throws {
        let store = InMemoryTokenStore()
        let transport = await signInTransport()
        let session = makeSession(store: store, transport: transport, openURL: browser(tamperState: true), timeout: .milliseconds(300))
        await #expect(throws: GoogleAuthError.timedOut) { _ = try await session.signIn() }
        #expect(await transport.requests.isEmpty)
        #expect(try store.load() == nil)
    }

    @Test("Declining consent aborts sign-in")
    func signInDenied() async throws {
        let session = makeSession(store: InMemoryTokenStore(), transport: await signInTransport(), openURL: browser(error: "access_denied"))
        await #expect(throws: GoogleAuthError.authorizationDenied("access_denied")) { _ = try await session.signIn() }
    }

    @Test("A browser that cannot be opened aborts sign-in")
    func browserFails() async throws {
        let session = makeSession(store: InMemoryTokenStore(), transport: await signInTransport(), openURL: { _ in false })
        await #expect(throws: GoogleAuthError.browserUnavailable) { _ = try await session.signIn() }
    }

    @Test("Sign-in times out if the browser never calls back")
    func signInTimeout() async throws {
        let session = makeSession(store: InMemoryTokenStore(), transport: await signInTransport(), openURL: { _ in true }, timeout: .milliseconds(150))
        await #expect(throws: GoogleAuthError.timedOut) { _ = try await session.signIn() }
    }

    @Test("Cancelling the task cancels sign-in")
    func signInCancelled() async throws {
        let session = makeSession(store: InMemoryTokenStore(), transport: await signInTransport(), openURL: { _ in true })
        let task = Task { try await session.signIn() }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: GoogleAuthError.cancelled) { _ = try await task.value }
    }

    @Test("Sign-in requires the main contacts scope")
    func missingScope() async throws {
        let store = InMemoryTokenStore()
        let transport = await signInTransport(scope: GoogleScopes.otherContactsReadonly)
        let session = makeSession(store: store, transport: transport, openURL: browser())
        await #expect(throws: GoogleAuthError.missingScopes([GoogleScopes.contacts])) { _ = try await session.signIn() }
        #expect(try store.load() == nil)
    }

    // MARK: sign-out

    @Test("Sign-out revokes the refresh token and clears the store")
    func signOut() async throws {
        let store = InMemoryTokenStore(storedToken())
        let transport = FakeHTTPTransport()
        await transport.route("POST", "/revoke", [.json(200)])
        let session = makeSession(store: store, transport: transport)
        #expect(try await session.signOut() == true)
        #expect(await transport.requests(containing: "/revoke").first?.form == ["token": "refresh-1"])
        #expect(try store.load() == nil)
        await #expect(throws: GoogleAuthError.notSignedIn) { _ = try await session.validAccessToken() }
    }

    @Test("If revocation fails (offline), the local credentials are still removed and the result says so")
    func signOutOffline() async throws {
        let store = InMemoryTokenStore(storedToken())
        let session = makeSession(store: store, transport: FakeHTTPTransport())
        #expect(try await session.signOut() == false)
        #expect(try store.load() == nil)
    }
}

struct KeychainTokenStoreTests {
    @Test("Queries are for a local, non-synced, generic-password item with no access group")
    func queryShape() {
        let query = KeychainTokenStore(service: "svc.test").query(account: "me@example.com")
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "svc.test")
        #expect(query[kSecAttrAccount as String] as? String == "me@example.com")
        // Explicit, so an item is never created in (or matched from) iCloud Keychain.
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccessGroup as String] == nil)
        #expect(query[kSecUseDataProtectionKeychain as String] == nil)
        #expect(KeychainTokenStore(service: "svc.test").query(account: nil)[kSecAttrAccount as String] == nil)
        #expect(KeychainTokenStore.defaultService == "dev.dividedby.contactbridge.google")
    }
}
