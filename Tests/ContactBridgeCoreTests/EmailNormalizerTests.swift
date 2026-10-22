import Testing
@testable import ContactBridgeCore

struct EmailNormalizerTests {
    @Test("Lowercases and trims", arguments: [
        ("  Foo@Example.COM ", "foo@example.com"),
        ("foo@example.com", "foo@example.com"),
        ("\tFoo@Example.com\n", "foo@example.com"),
        ("mailto:Foo@Example.com", "foo@example.com"),
    ])
    func basic(raw: String, expected: String) {
        #expect(EmailNormalizer.normalize(raw) == expected)
    }

    @Test("Gmail dots and plus tags are preserved")
    func gmailQuirksKept() {
        #expect(EmailNormalizer.normalize("First.Last+Tag@Gmail.com") == "first.last+tag@gmail.com")
    }

    @Test("Unicode is lowercased but not ASCII-folded")
    func unicode() {
        #expect(EmailNormalizer.normalize("José@Exämple.com") == "josé@exämple.com")
    }

    @Test("Empty input yields nil", arguments: ["", "   ", "\n", "mailto:"])
    func empty(raw: String) {
        #expect(EmailNormalizer.normalize(raw) == nil)
    }

    @Test("Strings without an at-sign are still returned lowercased, not dropped")
    func malformedKept() {
        #expect(EmailNormalizer.normalize("Not An Email") == "not an email")
    }
}
