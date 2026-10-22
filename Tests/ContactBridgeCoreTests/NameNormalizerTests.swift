import Testing
@testable import ContactBridgeCore

struct NameNormalizerTests {
    @Test("Folded keys ignore case, diacritics, width and whitespace", arguments: [
        ("  José   García ", "jose garcia"),
        ("JOSÉ", "jose"),
        ("Jose\u{301}", "jose"),
        ("Müller", "muller"),
        ("Łukasz", "lukasz"),
        ("Straße", "strasse"),
        ("Zoë", "zoe"),
        ("Ｊｏｈｎ", "john"),
        ("John\u{00A0}Smith", "john smith"),
        ("O'Brien", "obrien"),
        ("O\u{2019}Brien", "obrien"),
        ("Mary-Jane", "mary jane"),
        ("St. John", "st john"),
        ("", ""),
        ("   ", ""),
    ])
    func folding(raw: String, expected: String) {
        #expect(NameNormalizer.foldedKey(raw) == expected)
    }

    @Test("Non-Latin scripts survive folding")
    func nonLatin() {
        #expect(NameNormalizer.foldedKey("李雷") == "李雷")
        #expect(NameNormalizer.foldedKey("Иван") == "иван")
    }

    @Test("Nicknames collapse to one canonical given-name key", arguments: [
        ("Bob", "robert"), ("Bobby", "robert"), ("Robert", "robert"), ("ROB", "robert"),
        ("Bill", "william"), ("Will", "william"),
        ("Liz", "elizabeth"), ("Lizzie", "elizabeth"), ("Elizabeth", "elizabeth"),
        ("Mike", "michael"), ("Jim", "james"), ("Steve", "steven"), ("Stephen", "steven"),
        ("Katy", "katherine"), ("Katie", "katherine"), ("Kate", "katherine"),
        ("Catherine", "katherine"), ("Kathryn", "katherine"), ("Katherine", "katherine"),
        ("Kathy", "kathy"), ("Cathy", "cathy"), ("Zed", "zed"), ("Zoë", "zoe"), ("", ""),
    ])
    func nicknames(raw: String, expected: String) {
        #expect(NameNormalizer.givenNameMatchKey(raw) == expected)
    }

    @Test("Family-name keys fold but never apply nicknames")
    func familyKey() {
        #expect(NameNormalizer.familyNameMatchKey(" Bill ") == "bill")
        #expect(NameNormalizer.familyNameMatchKey("García") == "garcia")
    }

    @Test("Match keys never mutate display values")
    func displayUntouched() {
        let record = ContactRecord(
            id: "1", source: .icloud, sourceIdentifier: "A",
            givenName: "Bob", familyName: "García"
        )
        _ = record.givenNameMatchKey
        #expect(record.givenName == "Bob")
        #expect(record.givenNameMatchKey == "robert")
        #expect(record.familyNameMatchKey == "garcia")
    }
}
