import Foundation

/// A Google photo: where it is, and what identifies it.
public struct GooglePhotoRef: Sendable, Hashable, Codable {
    /// The URL as Google returned it, with its size suffix (`=s100`).
    public var url: String
    /// The URL without the size suffix: the same photo has the same key at every size, and a new photo has a new key. Sync
    /// compares keys to tell whether a photo changed without downloading it.
    public var key: String

    public init(url: String) {
        self.url = url
        key = GooglePersonMapper.photoKey(ofURL: url)
    }

    /// The photo at `side` pixels on its longest side (`=s128` for a fingerprint, `=s1024` to copy it).
    public func sizedURL(_ side: Int) -> URL? { URL(string: "\(key)=s\(side)") }
}

/// What a Google person shows for photos.
public struct GooglePhotos: Sendable, Hashable {
    /// The contact's own photo: one the user (or a client) set on the contact. Nil when there is none.
    public var contact: GooglePhotoRef?
    /// The photo of the person's Google profile. Read-only, and never the contact's own.
    public var profile: GooglePhotoRef?
    /// When the contact (not its photo) was last updated. Google does not date photos, so this is only a hint of how recent
    /// a change might be, and any edit to the contact moves it.
    public var contactUpdatedAt: Date?

    public init(contact: GooglePhotoRef? = nil, profile: GooglePhotoRef? = nil, contactUpdatedAt: Date? = nil) {
        self.contact = contact
        self.profile = profile
        self.contactUpdatedAt = contactUpdatedAt
    }
}

extension GooglePersonMapper {
    /// The person's photos, read from `photos` (kept in `extras`, like `biographies`) and `metadata.sources`. Entries Google
    /// flags `default` are its generated letter avatars, and count as no photo. A source type other than CONTACT or PROFILE
    /// (other contacts, domain directories) is skipped.
    public static func photos(of person: GooglePerson) -> GooglePhotos {
        var contact: [(url: String, primary: Bool)] = []
        var profile: [(url: String, primary: Bool)] = []
        if case .array(let entries)? = person.extras["photos"] {
            for entry in entries {
                guard case .object(let fields) = entry, case .string(let url)? = fields["url"], !url.isEmpty else { continue }
                if case .bool(true)? = fields["default"] { continue }
                var type = "CONTACT"
                var primary = false
                if case .object(let metadata)? = fields["metadata"] {
                    if case .bool(let flag)? = metadata["primary"] { primary = flag }
                    if case .object(let source)? = metadata["source"], case .string(let sourceType)? = source["type"] { type = sourceType }
                }
                switch type {
                case "CONTACT": contact.append((url, primary))
                case "PROFILE": profile.append((url, primary))
                default: break
                }
            }
        }
        func pick(_ photos: [(url: String, primary: Bool)]) -> GooglePhotoRef? {
            (photos.first { $0.primary } ?? photos.first).map { GooglePhotoRef(url: $0.url) }
        }
        let updated = person.metadata?.sources?.first { $0.type == "CONTACT" }?.updateTime.flatMap(parseTimestamp)
        return GooglePhotos(contact: pick(contact), profile: pick(profile), contactUpdatedAt: updated)
    }

    /// `url` without a trailing size option such as `=s100`, `=s100-c` or `=s0`.
    static func photoKey(ofURL url: String) -> String {
        guard let range = url.range(of: #"=s\d+[^/=?#]*$"#, options: .regularExpression) else { return url }
        return String(url[..<range.lowerBound])
    }

    /// RFC 3339 as Google writes it, with or without fractional seconds.
    private static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
