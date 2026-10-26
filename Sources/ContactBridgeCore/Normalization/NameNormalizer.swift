import Foundation

/// Produces comparison keys only; display values are never rewritten.
public enum NameNormalizer {
    /// Case-, diacritic-, width- and whitespace-folded; punctuation dropped, hyphens become spaces.
    public static func foldedKey(_ raw: String) -> String {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        // Latin-ASCII handles letters folding leaves alone (Ł, ø, ß, æ) and curly quotes; other scripts pass through.
        let latin = folded.applyingTransform(StringTransform("Latin-ASCII"), reverse: false) ?? folded

        var out = ""
        for ch in latin.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if ch.isWhitespace || ch.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .dashPunctuation }) {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    public static func givenNameMatchKey(_ raw: String) -> String {
        let key = foldedKey(raw)
        return NicknameTable.canonical[key] ?? key
    }

    public static func familyNameMatchKey(_ raw: String) -> String {
        foldedKey(raw)
    }
}

/// Deliberately modest; ambiguous short forms (sam, chris, alex, pat) are left out to avoid false matches.
enum NicknameTable {
    private static let groups: [String: [String]] = [
        "robert": ["bob", "bobby", "rob", "robbie"],
        "william": ["bill", "billy", "will", "willy"],
        "elizabeth": ["liz", "lizzie", "beth", "betty", "eliza"],
        "michael": ["mike", "mikey"],
        "james": ["jim", "jimmy"],
        "john": ["jack", "johnny"],
        "joseph": ["joe", "joey"],
        "thomas": ["tom", "tommy"],
        "richard": ["rick", "ricky", "dick"],
        "david": ["dave"],
        "steven": ["steve", "stephen"],
        "daniel": ["dan", "danny"],
        "matthew": ["matt"],
        "andrew": ["andy", "drew"],
        "anthony": ["tony"],
        "benjamin": ["ben", "benny"],
        "nicholas": ["nick"],
        "edward": ["ed", "eddie", "ted"],
        "henry": ["hank"],
        "katherine": ["kate", "katy", "katie", "katharine", "catherine", "kathryn"],
        "margaret": ["maggie", "peggy"],
        "susan": ["sue", "susie"],
        "jennifer": ["jen", "jenny"],
        "rebecca": ["becky", "becca"],
    ]

    /// nickname -> canonical formal name
    static let canonical: [String: String] = {
        var table: [String: String] = [:]
        for (formal, nicknames) in groups {
            for nickname in nicknames { table[nickname] = formal }
        }
        return table
    }()
}
