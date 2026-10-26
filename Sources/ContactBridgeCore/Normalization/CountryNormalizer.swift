import Foundation

/// Maps the country as written ("USA", "U.S.", "United States of America") to its ISO 3166 region code, so two spellings
/// of one country are one address.
public enum CountryNormalizer {
    /// Lowercase two-letter code for a country name or code, nil when the text names no country known here.
    public static func regionCode(for name: String) -> String? {
        let key = NameNormalizer.foldedKey(name)
        return key.isEmpty ? nil : lookup[key]
    }

    /// What `MergePlan.addressKey` uses for the country: the ISO code when the record has one, else the code for the name,
    /// else the folded text.
    static func key(country: String, isoCode: String?) -> String {
        if let iso = isoCode?.trimmingCharacters(in: .whitespacesAndNewlines), !iso.isEmpty { return iso.lowercased() }
        if let code = regionCode(for: country) { return code }
        let folded = NameNormalizer.foldedKey(country)
        return folded.isEmpty ? country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : folded
    }

    /// Folded name to lowercase code: English and current-locale names, the codes themselves, and common aliases.
    private static let lookup: [String: String] = {
        var table: [String: String] = [:]
        let codes = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }
        let locales = [Locale(identifier: "en_US"), Locale.current]
        for code in codes {
            let lower = code.lowercased()
            table[lower] = lower
            for locale in locales {
                guard let name = locale.localizedString(forRegionCode: code) else { continue }
                let folded = NameNormalizer.foldedKey(name)
                if !folded.isEmpty, table[folded] == nil { table[folded] = lower }
            }
        }
        let aliases: [String: String] = [
            "usa": "us", "united states of america": "us", "america": "us", "u s a": "us",
            "uk": "gb", "great britain": "gb", "britain": "gb", "england": "gb",
            "czech republic": "cz", "south korea": "kr", "republic of korea": "kr", "russian federation": "ru",
            "uae": "ae", "holland": "nl", "deutschland": "de",
        ]
        for (alias, code) in aliases { table[alias] = code }
        return table
    }()
}
