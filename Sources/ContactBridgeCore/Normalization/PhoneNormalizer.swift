import Foundation

public enum PhoneRegion: Sendable {
    case us
}

public struct NormalizedPhone: Sendable, Hashable {
    /// E.164 (`+14155552671`) when normalizable; otherwise the input, trimmed, unchanged.
    public var value: String
    /// Digits only, from "x123", "ext. 123", ",123" and similar. Never part of `value`.
    public var extensionDigits: String?
    public var isNormalizable: Bool

    /// Digits of an SMS short code: after stripping formatting, 3-6 digits with no leading "+" that did not normalize to
    /// E.164 (verification-code senders such as 72727). Nil for anything else.
    public var shortCodeDigits: String? {
        guard !isNormalizable, extensionDigits == nil else { return nil }
        let stripped = value.filter { !PhoneNormalizer.separators.contains($0) }
        guard (3...6).contains(stripped.count), stripped.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return stripped
    }
    public var isShortCode: Bool { shortCodeDigits != nil }
}

public enum PhoneNormalizer {
    public static func normalize(_ raw: String, defaultRegion: PhoneRegion = .us) -> NormalizedPhone {
        // Contacts exported from iOS often wrap numbers in bidi controls (Cf).
        let cleaned = String(raw.unicodeScalars.filter { $0.properties.generalCategory != .format })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return NormalizedPhone(value: "", extensionDigits: nil, isNormalizable: false)
        }

        let (body, ext) = splitExtension(cleaned)
        guard let e164 = e164(from: body, region: defaultRegion) else {
            return NormalizedPhone(value: cleaned, extensionDigits: nil, isNormalizable: false)
        }
        return NormalizedPhone(value: e164, extensionDigits: ext, isNormalizable: true)
    }

    private static func splitExtension(_ s: String) -> (body: String, ext: String?) {
        // Regex isn't Sendable, so it can't live in a static under strict concurrency.
        let pattern = /^(.*?)\s*(?:extension|ext\.?|x|[,;]+)\s*(\d+)$/.ignoresCase()
        guard let match = s.wholeMatch(of: pattern) else { return (s, nil) }
        return (String(match.1), String(match.2))
    }

    fileprivate static let separators: Set<Character> = [
        " ", "-", ".", "(", ")", "/", "\u{00A0}", "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}",
    ]

    private static func e164(from body: String, region: PhoneRegion) -> String? {
        var text = body
        // "+44 (0)20 ..." — the bracketed trunk zero is not dialled internationally.
        if text.hasPrefix("+") { text = text.replacing("(0)", with: "") }

        var digits = ""
        var international = false
        for (index, ch) in text.enumerated() {
            if ch == "+", index == 0 {
                international = true
            } else if ch.isASCII, ch.isNumber {
                digits.append(ch)
            } else if !separators.contains(ch) {
                return nil
            }
        }

        switch region {
        case .us:
            if !international {
                // 00 is the ITU international prefix; 011 is the US exit code.
                if digits.hasPrefix("011") {
                    digits.removeFirst(3)
                    international = true
                } else if digits.hasPrefix("00") {
                    digits.removeFirst(2)
                    international = true
                }
            }
            if international {
                return internationalNumber(digits)
            }
            switch digits.count {
            case 10 where isNANP(digits): return "+1" + digits
            case 11 where digits.hasPrefix("1") && isNANP(String(digits.dropFirst())): return "+" + digits
            default: return nil
            }
        }
    }

    private static func internationalNumber(_ digits: String) -> String? {
        guard (8...15).contains(digits.count), !digits.hasPrefix("0") else { return nil }
        if digits.hasPrefix("1"), !(digits.count == 11 && isNANP(String(digits.dropFirst()))) { return nil }
        return "+" + digits
    }

    /// North American Numbering Plan: area code and exchange both start with 2-9.
    private static func isNANP(_ ten: String) -> Bool {
        let chars = Array(ten)
        guard chars.count == 10 else { return false }
        return ("2"..."9").contains(chars[0]) && ("2"..."9").contains(chars[3])
    }
}
