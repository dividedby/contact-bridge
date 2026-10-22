import Foundation

public struct GoogleTokenResponse: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    /// Absent on refresh responses: keep the refresh token you already have.
    public var refreshToken: String?
    public var expiresIn: TimeInterval
    public var scopes: [String]

    public var description: String { "GoogleTokenResponse(tokens: <redacted>, expiresIn: \(Int(expiresIn)), scopes: \(scopes.count))" }
    public var debugDescription: String { description }
}

/// Google's OAuth 2.0 endpoints for an installed (Desktop) client: authorization URL, token exchange, refresh, revoke.
public struct GoogleOAuthClient: Sendable {
    public static let authorizationEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")!
    static let profileEndpoint = URL(string: "https://people.googleapis.com/v1/people/me?personFields=emailAddresses")!

    public let config: OAuthConfig
    let transport: any HTTPTransport

    public init(config: OAuthConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func authorizationURL(redirectURI: URL, challenge: String, state: String, scopes: [String]) -> URL {
        let query: [(String, String)] = [
            ("client_id", config.clientID),
            ("redirect_uri", redirectURI.absoluteString),
            ("response_type", "code"),
            ("scope", scopes.joined(separator: " ")),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ]
        // Built from the pre-encoded string: URLComponents would leave ':' and '/' raw inside values.
        return URL(string: "\(Self.authorizationEndpoint)?\(FormEncoding.encode(query))")!
    }

    public func exchangeCode(_ code: String, verifier: String, redirectURI: URL) async throws -> GoogleTokenResponse {
        try await tokenRequest([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI.absoluteString),
        ])
    }

    public func refresh(refreshToken: String) async throws -> GoogleTokenResponse {
        try await tokenRequest([("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
    }

    /// Revokes the grant (pass the refresh token). A token Google already considers invalid counts as revoked.
    public func revoke(token: String) async throws {
        var request = formRequest(Self.revokeEndpoint, [("token", token)])
        request.timeoutInterval = 30
        let result = try await transport.send(request)
        guard !result.isSuccess else { return }
        let failure = Self.tokenError(result)
        if case .tokenEndpoint(_, "invalid_token", _) = failure { return }
        throw failure
    }

    /// Best effort: the signed-in account's email for display. Nil on any failure.
    public func fetchAccountEmail(accessToken: String) async -> String? {
        var request = URLRequest(url: Self.profileEndpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let result = try? await transport.send(request), result.isSuccess,
              let person = try? JSONDecoder().decode(GooglePerson.self, from: result.body)
        else { return nil }
        return Self.accountEmail(from: person)
    }

    /// The Google account address: the ACCOUNT-sourced one, else the primary, else the first.
    static func accountEmail(from person: GooglePerson) -> String? {
        let emails = (person.emailAddresses ?? []).filter { !($0.value ?? "").isEmpty }
        let chosen = emails.first { $0.metadata?.source?.type == "ACCOUNT" } ?? emails.first { $0.metadata?.primary == true } ?? emails.first
        return chosen?.value
    }

    // MARK: internals

    private func formRequest(_ url: URL, _ pairs: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(FormEncoding.encode(pairs).utf8)
        return request
    }

    private func tokenRequest(_ grant: [(String, String)]) async throws -> GoogleTokenResponse {
        var request = formRequest(Self.tokenEndpoint, grant + [("client_id", config.clientID), ("client_secret", config.clientSecret)])
        request.timeoutInterval = 30
        let result = try await transport.send(request)
        guard result.isSuccess else { throw Self.tokenError(result) }
        guard let body = try? JSONDecoder().decode(TokenBody.self, from: result.body), !body.access_token.isEmpty else {
            throw GoogleAuthError.invalidResponse
        }
        return GoogleTokenResponse(
            accessToken: body.access_token, refreshToken: body.refresh_token, expiresIn: body.expires_in ?? 3600,
            scopes: (body.scope ?? "").split(separator: " ").map(String.init)
        )
    }

    private static func tokenError(_ result: HTTPResult) -> GoogleAuthError {
        let body = try? JSONDecoder().decode(ErrorBody.self, from: result.body)
        if body?.error == "invalid_grant" { return .needsReauthorization }
        return .tokenEndpoint(status: result.status, error: body?.error ?? "unknown_error", description: body?.error_description)
    }

    private struct TokenBody: Decodable {
        var access_token: String
        var refresh_token: String?
        var expires_in: TimeInterval?
        var scope: String?
    }

    private struct ErrorBody: Decodable {
        var error: String
        var error_description: String?
    }
}
