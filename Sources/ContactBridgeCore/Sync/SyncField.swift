/// The field groups Phase 2 sync keeps equal between an iCloud contact and its Google counterpart, each paired with the
/// People API field it travels in. A group is the unit of change detection, review and `updatePersonFields` masks.
///
/// Never synced: photos, relations, instant messaging, social profiles, prefix/suffix and group memberships.
public enum SyncField: String, Sendable, Hashable, Codable, CaseIterable {
    /// Given, middle and family name.
    case name
    case nickname
    /// Organization and job title.
    case organization
    case phones
    case emails
    case postalAddresses
    case urls
    case birthday
    /// Not part of `ContactRecord`: compared through note hashes and sent as Google `biographies`.
    case note

    public var peopleAPIField: String {
        switch self {
        case .name: "names"
        case .nickname: "nicknames"
        case .organization: "organizations"
        case .phones: "phoneNumbers"
        case .emails: "emailAddresses"
        case .postalAddresses: "addresses"
        case .urls: "urls"
        case .birthday: "birthdays"
        case .note: "biographies"
        }
    }

    /// Groups that live on `ContactRecord` (everything but the note).
    public static let recordFields = allCases.filter { $0 != .note }

    /// Comma-separated `updatePersonFields` for `fields`, in declaration order.
    public static func updateMask(for fields: Set<SyncField>) -> String {
        allCases.filter(fields.contains).map(\.peopleAPIField).joined(separator: ",")
    }
}

extension ContactRecord {
    /// Copies one group's values from `other`, leaving identity and every other group alone. The note is not on the record.
    mutating func copy(_ field: SyncField, from other: ContactRecord) {
        switch field {
        case .name:
            givenName = other.givenName
            middleName = other.middleName
            familyName = other.familyName
        case .nickname: nickname = other.nickname
        case .organization:
            organization = other.organization
            jobTitle = other.jobTitle
        case .phones: phones = other.phones
        case .emails: emails = other.emails
        case .postalAddresses: postalAddresses = other.postalAddresses
        case .urls: urls = other.urls
        case .birthday: birthday = other.birthday
        case .note: break
        }
    }
}
