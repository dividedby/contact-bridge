/// Fuzzy string comparison on already-folded keys (see `NameNormalizer.foldedKey`).
enum StringSimilarity {
    /// Jaro-Winkler similarity in 0...1. Empty input is never similar, even to another empty string.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let s = Array(a)
        let t = Array(b)
        guard !s.isEmpty, !t.isEmpty else { return 0 }
        if s == t { return 1 }

        let jaroScore = jaro(s, t)
        guard jaroScore > 0.7 else { return jaroScore }
        var prefix = 0
        for (x, y) in zip(s, t).prefix(4) {
            guard x == y else { break }
            prefix += 1
        }
        return jaroScore + Double(prefix) * 0.1 * (1 - jaroScore)
    }

    private static func jaro(_ s: [Character], _ t: [Character]) -> Double {
        let window = max(max(s.count, t.count) / 2 - 1, 0)
        var sMatched = [Bool](repeating: false, count: s.count)
        var tMatched = [Bool](repeating: false, count: t.count)

        var matches = 0
        for i in s.indices {
            let lower = max(0, i - window)
            let upper = min(t.count - 1, i + window)
            guard lower <= upper else { continue }
            for j in lower...upper where !tMatched[j] && s[i] == t[j] {
                sMatched[i] = true
                tMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0 }

        var transpositions = 0
        var j = 0
        for i in s.indices where sMatched[i] {
            while !tMatched[j] { j += 1 }
            if s[i] != t[j] { transpositions += 1 }
            j += 1
        }

        let m = Double(matches)
        return (m / Double(s.count) + m / Double(t.count) + (m - Double(transpositions) / 2) / m) / 3
    }
}
