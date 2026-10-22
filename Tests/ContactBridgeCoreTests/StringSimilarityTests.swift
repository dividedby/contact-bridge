import Testing
@testable import ContactBridgeCore

struct StringSimilarityTests {
    @Test("Identical strings score 1, disjoint strings score 0")
    func extremes() {
        #expect(StringSimilarity.jaroWinkler("smith", "smith") == 1)
        #expect(StringSimilarity.jaroWinkler("abc", "xyz") == 0)
    }

    @Test("Empty input never counts as similar")
    func empty() {
        #expect(StringSimilarity.jaroWinkler("", "") == 0)
        #expect(StringSimilarity.jaroWinkler("a", "") == 0)
    }

    @Test("Known reference values", arguments: [
        ("martha", "marhta", 0.961),
        ("dixon", "dicksonx", 0.813),
        ("jellyfish", "smellyfish", 0.896),
    ])
    func reference(a: String, b: String, expected: Double) {
        #expect(abs(StringSimilarity.jaroWinkler(a, b) - expected) < 0.001)
    }

    @Test("Symmetric")
    func symmetric() {
        #expect(StringSimilarity.jaroWinkler("jon", "john") == StringSimilarity.jaroWinkler("john", "jon"))
    }

    @Test("Works on non-Latin text")
    func nonLatin() {
        #expect(StringSimilarity.jaroWinkler("李雷", "李雷") == 1)
        #expect(StringSimilarity.jaroWinkler("李雷", "韩梅") == 0)
    }
}
