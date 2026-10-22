import CryptoKit
import Foundation
import Security

/// PKCE (RFC 7636) code verifier and S256 challenge, plus the anti-CSRF `state` value.
public struct PKCE: Sendable, Hashable {
    public let verifier: String
    public let challenge: String

    /// 32 random bytes give a 43-character verifier, the minimum length RFC 7636 allows.
    public static func generate() throws -> PKCE {
        let verifier = try randomURLSafeString(byteCount: 32)
        return PKCE(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }

    public static func challenge(forVerifier verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func randomState() throws -> String {
        try randomURLSafeString(byteCount: 24)
    }

    static func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) == errSecSuccess else {
            throw GoogleAuthError.secureRandomUnavailable
        }
        return base64URL(Data(bytes))
    }

    /// Base64url without padding: its alphabet is a subset of the RFC 7636 unreserved set.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
