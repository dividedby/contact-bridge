import Foundation
import Testing
@testable import ContactBridgeCore

struct OAuthConfigTests {
    private func plist(_ entries: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .xml, options: 0)
    }

    @Test("Loads the client ID and secret from plist data")
    func loads() throws {
        let config = try OAuthConfig(plistData: plist(["ClientID": "abc.apps.googleusercontent.com", "ClientSecret": "s3cret-value"]))
        #expect(config.clientID == "abc.apps.googleusercontent.com")
        #expect(config.clientSecret == "s3cret-value")
    }

    @Test("The example plist's placeholder values are rejected")
    func placeholders() throws {
        let data = try plist(["ClientID": "YOUR_CLIENT_ID.apps.googleusercontent.com", "ClientSecret": "YOUR_CLIENT_SECRET"])
        #expect(throws: OAuthConfigError.placeholderValues) { try OAuthConfig(plistData: data) }
    }

    @Test("Missing or empty keys and garbage data are malformed")
    func malformed() throws {
        #expect(throws: OAuthConfigError.malformed) { try OAuthConfig(plistData: plist(["ClientID": "x.apps.googleusercontent.com"])) }
        #expect(throws: OAuthConfigError.malformed) { try OAuthConfig(plistData: plist(["ClientID": "", "ClientSecret": " "])) }
        #expect(throws: OAuthConfigError.malformed) { try OAuthConfig(plistData: Data("not a plist".utf8)) }
    }

    @Test("A bundle without GoogleOAuth.plist reports it missing, with guidance")
    func missingFromBundle() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = try #require(Bundle(url: empty))
        #expect(throws: OAuthConfigError.missing) { try OAuthConfig.load(from: bundle) }
        #expect(OAuthConfigError.missing.description.contains("GoogleOAuth.local.plist"))
    }

    @Test("Descriptions never contain the secret")
    func redaction() throws {
        let config = try OAuthConfig(plistData: plist(["ClientID": "abc.apps.googleusercontent.com", "ClientSecret": "s3cret-value"]))
        #expect(!"\(config)".contains("s3cret-value"))
        #expect(!String(reflecting: config).contains("s3cret-value"))
    }
}
