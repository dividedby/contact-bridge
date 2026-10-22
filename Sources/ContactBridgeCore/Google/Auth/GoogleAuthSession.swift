import Foundation

public struct GoogleAccount: Sendable, Equatable {
    public var email: String?
    public var grantedScopes: [String]

    public init(email: String?, grantedScopes: [String]) {
        self.email = email
        self.grantedScopes = grantedScopes
    }
}

/// What the People API client needs from authentication.
public protocol GoogleAccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
    /// Called after a 401: a token that is not `rejected` (already replaced by another caller) or a freshly refreshed one.
    func refreshedAccessToken(replacing rejected: String) async throws -> String
}

/// Owns the sign-in lifecycle and the access token: browser sign-in with PKCE, refresh (one at a time, however many
/// callers), persistence, and sign-out with revocation.
public actor GoogleAuthSession: GoogleAccessTokenProviding {
    /// Tokens are refreshed once they are this close to expiring.
    static let refreshWindow: TimeInterval = 60

    private let oauth: GoogleOAuthClient
    private let store: any TokenStore
    private let openURL: @Sendable (URL) async -> Bool
    private let now: @Sendable () -> Date
    private let scopes: [String]
    private let redirectTimeout: Duration

    private var cached: StoredGoogleToken?
    private var loaded = false
    private var refreshTask: Task<StoredGoogleToken, Error>?
    private var signingIn = false
    /// Bumped by sign-in and sign-out. A refresh that finishes under an older generation was started for credentials
    /// that are gone, so its result is discarded rather than written over the new state.
    private var generation = 0
    /// Set when a refresh failed with invalid_grant, so callers hear "needs reauthorization" rather than "not signed in".
    private var refreshTokenRevoked = false

    /// - Parameter openURL: opens the authorization URL in the user's default browser; false if it could not.
    public init(
        oauth: GoogleOAuthClient, store: any TokenStore, openURL: @escaping @Sendable (URL) async -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }, scopes: [String] = GoogleScopes.all,
        redirectTimeout: Duration = .seconds(300)
    ) {
        self.oauth = oauth
        self.store = store
        self.openURL = openURL
        self.now = now
        self.scopes = scopes
        self.redirectTimeout = redirectTimeout
    }

    /// The signed-in account from stored credentials, or nil. Makes no network call.
    public func currentAccount() throws -> GoogleAccount? {
        do {
            let token = try current()
            return GoogleAccount(email: token.email, grantedScopes: token.grantedScopes)
        } catch GoogleAuthError.notSignedIn {
            return nil
        } catch GoogleAuthError.needsReauthorization {
            return nil
        }
    }

    // MARK: access tokens

    public func validAccessToken() async throws -> String {
        let token = try current()
        if let access = token.accessToken, isFresh(token) { return access }
        return try await refreshedToken()
    }

    public func refreshedAccessToken(replacing rejected: String) async throws -> String {
        let token = try current()
        if let access = token.accessToken, access != rejected, isFresh(token) { return access }
        return try await refreshedToken()
    }

    private func isFresh(_ token: StoredGoogleToken) -> Bool {
        guard let expiry = token.expiry else { return false }
        return expiry.timeIntervalSince(now()) > Self.refreshWindow
    }

    private func current() throws -> StoredGoogleToken {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        guard let cached else { throw refreshTokenRevoked ? GoogleAuthError.needsReauthorization : GoogleAuthError.notSignedIn }
        return cached
    }

    /// All concurrent callers wait on one refresh.
    private func refreshedToken() async throws -> String {
        let task: Task<StoredGoogleToken, Error>
        if let running = refreshTask {
            task = running
        } else {
            let token = try current()
            task = Task { try await self.performRefresh(token) }
            refreshTask = task
        }
        defer { if refreshTask == task { refreshTask = nil } }
        let refreshed = try await task.value
        guard let access = refreshed.accessToken else { throw GoogleAuthError.invalidResponse }
        return access
    }

    private func performRefresh(_ token: StoredGoogleToken) async throws -> StoredGoogleToken {
        let started = generation
        let result: Result<GoogleTokenResponse, Error>
        do { result = .success(try await oauth.refresh(refreshToken: token.refreshToken)) } catch { result = .failure(error) }

        // The user signed out or in while this was in flight: whatever Google said is about credentials we dropped.
        guard started == generation else {
            if let cached { return cached }
            throw GoogleAuthError.notSignedIn
        }

        let response: GoogleTokenResponse
        switch result {
        case .success(let value):
            response = value
        case .failure(GoogleAuthError.needsReauthorization):
            // The refresh token is dead; keeping it would only repeat the failure.
            cached = nil
            loaded = true
            refreshTokenRevoked = true
            try? store.delete()
            throw GoogleAuthError.needsReauthorization
        case .failure(let error):
            throw error
        }
        var updated = token
        updated.accessToken = response.accessToken
        updated.expiry = now().addingTimeInterval(response.expiresIn)
        if let rotated = response.refreshToken { updated.refreshToken = rotated }
        if !response.scopes.isEmpty { updated.grantedScopes = response.scopes }
        cached = updated
        try store.save(updated)
        return updated
    }

    /// Invalidates any refresh in flight and lets the next caller start a fresh one.
    private func startNewGeneration() {
        generation += 1
        refreshTask = nil
    }

    // MARK: sign-in and sign-out

    /// Opens the browser for consent, waits for the loopback redirect, and stores the resulting credentials.
    public func signIn() async throws -> GoogleAccount {
        guard !signingIn else { throw GoogleAuthError.listenerFailed("sign-in is already in progress") }
        signingIn = true
        defer { signingIn = false }

        let pkce = try PKCE.generate()
        let state = try PKCE.randomState()
        let listener = LoopbackRedirectListener(expectedState: state, timeout: redirectTimeout)
        let redirectURI = try await listener.start()
        let code: String
        do {
            let url = oauth.authorizationURL(redirectURI: redirectURI, challenge: pkce.challenge, state: state, scopes: scopes)
            guard await openURL(url) else { throw GoogleAuthError.browserUnavailable }
            code = try await listener.waitForCode()
        } catch {
            await listener.cancel()
            throw error
        }

        let response = try await oauth.exchangeCode(code, verifier: pkce.verifier, redirectURI: redirectURI)
        guard let refreshToken = response.refreshToken else { throw GoogleAuthError.invalidResponse }
        // Granular consent lets the user untick scopes; without the contacts scope nothing here works.
        guard response.scopes.contains(GoogleScopes.contacts) else {
            try? await oauth.revoke(token: refreshToken)
            throw GoogleAuthError.missingScopes([GoogleScopes.contacts])
        }
        let email = await oauth.fetchAccountEmail(accessToken: response.accessToken)
        let token = StoredGoogleToken(
            refreshToken: refreshToken, accessToken: response.accessToken, expiry: now().addingTimeInterval(response.expiresIn),
            grantedScopes: response.scopes, email: email
        )
        startNewGeneration()
        refreshTokenRevoked = false
        cached = token
        loaded = true
        try store.save(token)
        return GoogleAccount(email: email, grantedScopes: token.grantedScopes)
    }

    /// Revokes the grant at Google (best effort) and always removes the local credentials.
    /// - Returns: whether Google confirmed the revocation. False means the grant may still exist at Google, including
    ///   when the stored token could not be read (so there was nothing to revoke with).
    @discardableResult
    public func signOut() async throws -> Bool {
        startNewGeneration()
        refreshTokenRevoked = false
        let stored = Result { try current() }
        // Drop the in-memory credentials before the revoke call suspends, so nothing can hand them out meanwhile.
        cached = nil
        loaded = true

        var revoked = true
        switch stored {
        case .success(let token):
            do { try await oauth.revoke(token: token.refreshToken) } catch { revoked = false }
        case .failure(GoogleAuthError.notSignedIn):
            break // nothing stored, nothing to revoke
        case .failure:
            revoked = false
        }
        try store.delete()
        return revoked
    }
}
