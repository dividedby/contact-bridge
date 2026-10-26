import Foundation

public enum OAuthConfigError: Error, Sendable, Hashable, CustomStringConvertible {
    case missing
    case malformed
    case placeholderValues

    public var description: String {
        switch self {
        case .missing:
            "GoogleOAuth.plist is not in the app bundle. Copy Config/GoogleOAuth.example.plist to Config/GoogleOAuth.local.plist, fill in the OAuth client ID and secret, and rebuild with scripts/build-app.sh."
        case .malformed:
            "GoogleOAuth.plist must contain non-empty ClientID and ClientSecret strings."
        case .placeholderValues:
            "GoogleOAuth.plist still has the example placeholder values. Put the real OAuth client ID and secret in Config/GoogleOAuth.local.plist and rebuild with scripts/build-app.sh."
        }
    }
}

extension OAuthConfigError: LocalizedError {
    public var errorDescription: String? { description }
}

/// The Google "Desktop app" OAuth client. Google requires the secret even for installed apps; it is not confidential in
/// that setting, but is still kept out of logs and descriptions.
public struct OAuthConfig: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let resourceName = "GoogleOAuth"

    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public init(plistData: Data) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let id = (plist["ClientID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = (plist["ClientSecret"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty, !secret.isEmpty
        else { throw OAuthConfigError.malformed }
        guard !id.hasPrefix("YOUR_"), !secret.hasPrefix("YOUR_") else { throw OAuthConfigError.placeholderValues }
        self.init(clientID: id, clientSecret: secret)
    }

    public static func load(from bundle: Bundle = .main) throws -> OAuthConfig {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist"),
              let data = try? Data(contentsOf: url)
        else { throw OAuthConfigError.missing }
        return try OAuthConfig(plistData: data)
    }

    public var description: String { "OAuthConfig(clientID: \(clientID), clientSecret: <redacted>)" }
    public var debugDescription: String { description }
}
