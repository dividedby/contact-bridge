import Foundation
import Testing
@testable import ContactBridgeCore

struct PKCETests {
    @Test("S256 challenge matches the RFC 7636 appendix B vector")
    func rfcVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(PKCE.challenge(forVerifier: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("Generated verifiers are 43-128 unreserved characters and differ every time")
    func generatedVerifier() throws {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var seen = Set<String>()
        for _ in 0..<20 {
            let pkce = try PKCE.generate()
            #expect((43...128).contains(pkce.verifier.count))
            #expect(pkce.verifier.allSatisfy(unreserved.contains))
            #expect(pkce.challenge == PKCE.challenge(forVerifier: pkce.verifier))
            #expect(!pkce.challenge.contains("=") && !pkce.challenge.contains("+") && !pkce.challenge.contains("/"))
            seen.insert(pkce.verifier)
        }
        #expect(seen.count == 20)
    }

    @Test("State values are URL-safe, long enough, and unique")
    func state() throws {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let first = try PKCE.randomState()
        let second = try PKCE.randomState()
        #expect(first.count >= 22 && first.allSatisfy(unreserved.contains))
        #expect(first != second)
    }
}
