import Foundation

public enum GoogleAuthError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The refresh token (or authorization code) was rejected, typically `invalid_grant`: revoked, expired (Testing-mode
    /// refresh tokens last 7 days) or the password changed. The user has to sign in again.
    case needsReauthorization
    case notSignedIn
    /// The user declined consent in the browser; the payload is Google's `error` value.
    case authorizationDenied(String)
    case timedOut
    case cancelled
    /// The browser could not be opened.
    case browserUnavailable
    case listenerFailed(String)
    case secureRandomUnavailable
    /// The user unticked a scope Contact Bridge cannot work without.
    case missingScopes([String])
    /// The token endpoint answered with an error other than a revoked grant.
    case tokenEndpoint(status: Int, error: String, description: String?)
    case invalidResponse

    public var description: String {
        switch self {
        case .needsReauthorization: "Google sign-in expired or was revoked. Sign in again."
        case .notSignedIn: "Not signed in to Google."
        case .authorizationDenied(let reason): "Google sign-in was not approved (\(reason))."
        case .timedOut: "Sign-in timed out waiting for the browser."
        case .cancelled: "Sign-in was cancelled."
        case .browserUnavailable: "Could not open the browser for sign-in."
        case .listenerFailed(let reason): "Could not start the local sign-in listener: \(reason)"
        case .secureRandomUnavailable: "Could not generate secure random data for sign-in."
        case .missingScopes(let scopes): "Google did not grant the required access: \(scopes.joined(separator: ", "))."
        case .tokenEndpoint(let status, let error, let description):
            "Google token endpoint error \(status): \(error)" + (description.map { " (\($0))" } ?? "")
        case .invalidResponse: "Unexpected response from Google."
        }
    }
}

extension GoogleAuthError: LocalizedError {
    public var errorDescription: String? { description }
}
