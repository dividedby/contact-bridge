import Foundation

public enum NotesMerge {
    /// The note a merged contact should carry: the survivor's note first, then each other note that adds something,
    /// separated by a blank line, in the order given.
    ///
    /// Notes count as the same when equal after trimming whitespace and newlines and folding case; the first one wins.
    /// The survivor's note is returned exactly as it was when nothing is appended. Returns nil when every note is blank.
    public static func combine(survivor: String?, others: [(id: String, note: String?)]) -> String? {
        var seen: Set<String> = []
        var appended: [String] = []
        let survivorKey = key(survivor)
        if let survivorKey { seen.insert(survivorKey) }
        for other in others {
            guard let note = other.note, let otherKey = key(note), seen.insert(otherKey).inserted else { continue }
            appended.append(note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let survivor, survivorKey != nil else {
            return appended.isEmpty ? nil : appended.joined(separator: "\n\n")
        }
        guard !appended.isEmpty else { return survivor }
        let head = survivor.replacing(/\s+\z/, with: "")
        return ([head] + appended).joined(separator: "\n\n")
    }

    /// nil for a blank note.
    private static func key(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed.folding(options: .caseInsensitive, locale: nil)
    }
}
