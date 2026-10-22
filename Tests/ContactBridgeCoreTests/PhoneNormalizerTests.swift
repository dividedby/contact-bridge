import Testing
@testable import ContactBridgeCore

struct PhoneNormalizerTests {
    @Test("US numbers in common formats normalize to E.164", arguments: [
        "(415) 555-2671",
        "415.555.2671",
        "415 555 2671",
        "4155552671",
        "1-415-555-2671",
        "1 (415) 555-2671",
        "+1 (415) 555-2671",
        "+14155552671",
        "415\u{00A0}555\u{2011}2671",
        "\u{202D}+1 (415) 555-2671\u{202C}",
        "  (415) 555-2671  ",
    ])
    func usFormats(raw: String) {
        let result = PhoneNormalizer.normalize(raw)
        #expect(result.value == "+14155552671")
        #expect(result.isNormalizable)
        #expect(result.extensionDigits == nil)
    }

    @Test("International numbers keep their country code", arguments: [
        ("+44 20 7946 0958", "+442079460958"),
        ("+44 (0)20 7946 0958", "+442079460958"),
        ("0044 20 7946 0958", "+442079460958"),
        ("011 44 20 7946 0958", "+442079460958"),
        ("+49 30 901820", "+4930901820"),
        ("+81-3-1234-5678", "+81312345678"),
        ("+442079460958", "+442079460958"),
    ])
    func international(raw: String, expected: String) {
        let result = PhoneNormalizer.normalize(raw)
        #expect(result.value == expected)
        #expect(result.isNormalizable)
    }

    @Test("Extensions are split out in several spellings", arguments: [
        "415-555-2671 x123",
        "415-555-2671 ext. 123",
        "415-555-2671 Ext 123",
        "415-555-2671 extension 123",
        "415-555-2671,123",
        "415-555-2671,,123",
        "415-555-2671;123",
        "(415) 555-2671 x 123",
        "+1 415 555 2671 X123",
    ])
    func extensions(raw: String) {
        let result = PhoneNormalizer.normalize(raw)
        #expect(result.value == "+14155552671")
        #expect(result.extensionDigits == "123")
        #expect(result.isNormalizable)
    }

    @Test("Garbage and short codes are kept as-is and flagged", arguments: [
        "911",
        "12345",
        "555-1234",
        "1-800-FLOWERS",
        "abc",
        "+1",
        "123-456-7890",
        "000-000-0000",
        "+1234567890123456",
        "415-555-2671 x",
    ])
    func unnormalizable(raw: String) {
        let result = PhoneNormalizer.normalize(raw)
        #expect(!result.isNormalizable)
        #expect(result.value == raw.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(result.extensionDigits == nil)
    }

    @Test("Empty and whitespace-only input is unnormalizable and empty", arguments: ["", "   ", "\n"])
    func empty(raw: String) {
        let result = PhoneNormalizer.normalize(raw)
        #expect(result.value.isEmpty)
        #expect(!result.isNormalizable)
    }

    @Test("Normalizing is idempotent")
    func idempotent() {
        let once = PhoneNormalizer.normalize("(415) 555-2671 x9")
        let twice = PhoneNormalizer.normalize(once.value + " x" + (once.extensionDigits ?? ""))
        #expect(once == twice)
    }
}
