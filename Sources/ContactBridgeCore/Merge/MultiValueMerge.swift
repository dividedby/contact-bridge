import Foundation

extension MergePlan {
    /// Union across `lists` (survivor's first), de-duplicated by `key`. A nil key marks a blank value and drops it.
    /// The first occurrence keeps its value and label; if that label is missing, a later duplicate's label fills it in.
    /// A later duplicate whose label differs from the kept one (case-insensitively) is recorded in `dropped`.
    static func unionLabeled<Value>(
        _ field: MergeListField,
        _ lists: [[Labeled<Value>]],
        key: (Value) -> String?,
        describe: (Value) -> String,
        dropped: inout [DroppedLabel]
    ) -> [Labeled<Value>] {
        var result: [Labeled<Value>] = []
        var indexByKey: [String: Int] = [:]
        for entry in lists.joined() {
            guard let k = key(entry.value) else { continue }
            guard let index = indexByKey[k] else {
                indexByKey[k] = result.count
                result.append(entry)
                continue
            }
            guard let label = entry.label, !label.isBlank else { continue }
            if let kept = result[index].label, !kept.isBlank {
                let note = DroppedLabel(field: field, value: describe(result[index].value), keptLabel: kept, droppedLabel: label)
                if kept.lowercased() != label.lowercased(), !dropped.contains(note) { dropped.append(note) }
            } else {
                result[index].label = label
            }
        }
        return result
    }

    static func phoneKey(_ raw: String) -> String? {
        let phone = PhoneNormalizer.normalize(raw)
        guard !phone.value.isEmpty else { return nil }
        guard phone.isNormalizable else { return "raw|" + phone.value.lowercased() }
        return "e164|" + phone.value + (phone.extensionDigits.map { "x" + $0 } ?? "")
    }

    /// Scheme and host fold (case, `www.`); path and query are case-sensitive. Trailing slashes are ignored.
    static func urlKey(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text.removeFirst(prefix.count)
            break
        }
        let hostEnd = text.firstIndex(where: { "/?#".contains($0) }) ?? text.endIndex
        var host = text[..<hostEnd].lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var rest = String(text[hostEnd...])
        while rest.hasSuffix("/") { rest.removeLast() }
        let key = host + rest
        return key.isEmpty ? nil : key
    }

    /// Never nil for an address with any non-blank field: a part that folds to nothing ("#") keeps its raw text.
    static func addressKey(_ address: PostalAddress) -> String? {
        guard !address.isEmpty else { return nil }
        return [address.street, address.city, address.state, address.postalCode, address.country]
            .map { part in
                let folded = NameNormalizer.foldedKey(part)
                return folded.isEmpty ? part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : folded
            }
            .joined(separator: "|")
    }

    static func describe(_ address: PostalAddress) -> String {
        [address.street, address.city, address.state, address.postalCode, address.country]
            .filter { !$0.isBlank }
            .joined(separator: ", ")
    }
}
