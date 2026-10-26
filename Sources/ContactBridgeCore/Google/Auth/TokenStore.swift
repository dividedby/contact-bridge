import Foundation
import Security

/// What is kept between launches. The email is the keychain account, not part of the stored JSON.
public struct StoredGoogleToken: Codable, Sendable, Equatable, CustomStringConvertible {
    public var refreshToken: String
    public var accessToken: String?
    public var expiry: Date?
    public var grantedScopes: [String]
    public var email: String?

    public init(refreshToken: String, accessToken: String? = nil, expiry: Date? = nil, grantedScopes: [String] = [], email: String? = nil) {
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.expiry = expiry
        self.grantedScopes = grantedScopes
        self.email = email
    }

    private enum CodingKeys: String, CodingKey {
        case refreshToken, accessToken, expiry, grantedScopes
    }

    public var description: String { "StoredGoogleToken(email: \(email ?? "nil"), tokens: <redacted>)" }
}

/// Persists the single signed-in account's credentials. Calls are synchronous (keychain access is local and fast).
public protocol TokenStore: Sendable {
    func load() throws -> StoredGoogleToken?
    /// Replaces whatever was stored; `token.email` names the account.
    func save(_ token: StoredGoogleToken) throws
    func delete() throws
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: StoredGoogleToken?

    public init(_ token: StoredGoogleToken? = nil) {
        self.token = token
    }

    public func load() throws -> StoredGoogleToken? { lock.withLock { token } }
    public func save(_ token: StoredGoogleToken) throws { lock.withLock { self.token = token } }
    public func delete() throws { lock.withLock { token = nil } }
}

public struct KeychainError: Error, LocalizedError, Sendable, Hashable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(message)"
    }
}

/// A legacy (file-based) keychain generic-password item: service `dev.dividedby.contactbridge.google`, account = the
/// signed-in email (or "default"), data = JSON. No access groups and no data-protection keychain, so the item is
/// bound to the app's code-signing identity.
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "dev.dividedby.contactbridge.google"
    static let defaultAccount = "default"

    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    /// The attributes that identify the item. `kSecAttrSynchronizable` is set to false explicitly: a query without it
    /// already skips synced items, but stating it guarantees the refresh token is never created in, or read from,
    /// iCloud Keychain on this or a future OS.
    func query(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: false,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    private var serviceQuery: [String: Any] { query(account: nil) }

    public func load() throws -> StoredGoogleToken? {
        var query = serviceQuery
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { return nil }
        var token = try Self.decoder.decode(StoredGoogleToken.self, from: data)
        let account = item[kSecAttrAccount as String] as? String
        token.email = account == Self.defaultAccount ? nil : account
        return token
    }

    public func save(_ token: StoredGoogleToken) throws {
        let account = token.email ?? Self.defaultAccount
        let data = try Self.encoder.encode(token)
        let match = query(account: account)
        var status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = match
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        try deleteOtherAccounts(keeping: account)
    }

    public func delete() throws {
        let status = SecItemDelete(serviceQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    /// Only one account is signed in at a time: signing in as someone else replaces the previous item.
    private func deleteOtherAccounts(keeping account: String) throws {
        var search = serviceQuery
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        for item in (result as? [[String: Any]]) ?? [] {
            guard let other = item[kSecAttrAccount as String] as? String, other != account else { continue }
            let remove = query(account: other)
            let removed = SecItemDelete(remove as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw KeychainError(status: removed) }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
