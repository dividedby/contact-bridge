import Foundation

public enum EmailNormalizer {
    /// Trims and lowercases. Gmail dots and plus-tags are deliberately preserved so distinct
    /// addresses are never conflated. Returns nil for empty input.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("mailto:") {
            text.removeFirst("mailto:".count)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text.lowercased()
    }
}
