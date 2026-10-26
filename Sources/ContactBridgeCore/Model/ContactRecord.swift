import Foundation

public enum ContactSource: String, Sendable, Hashable, Codable, CaseIterable {
    case icloud
    case google
    /// Google "Other contacts" (auto-saved addresses, not part of the user's own list).
    case googleOther
}

/// A value paired with a free-form label ("mobile", "work", a custom label, or nil).
/// Labels stay as the source system spelled them; mapping to CN/Google label vocabularies is the adapters' job.
public struct Labeled<Value: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public var label: String?
    public var value: Value

    public init(label: String?, value: Value) {
        self.label = label
        self.value = value
    }
}

public struct PostalAddress: Sendable, Hashable, Codable {
    public var street: String
    public var city: String
    public var state: String
    public var postalCode: String
    public var country: String
    /// Detail some systems carry beyond the five display fields. Optional so absent data stays absent, and so older
    /// serialized records still decode. Not used for matching or de-duplication.
    public var isoCountryCode: String?
    public var subLocality: String?
    public var subAdministrativeArea: String?

    public init(
        street: String = "", city: String = "", state: String = "", postalCode: String = "", country: String = "",
        isoCountryCode: String? = nil, subLocality: String? = nil, subAdministrativeArea: String? = nil
    ) {
        self.street = street
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.country = country
        self.isoCountryCode = isoCountryCode
        self.subLocality = subLocality
        self.subAdministrativeArea = subAdministrativeArea
    }

    public var isEmpty: Bool {
        [street, city, state, postalCode, country].allSatisfy(\.isBlank)
    }
}

/// Source-agnostic contact. Deliberately free of CNContact / People API types so matching and merging stay pure.
/// Photos are not modeled (`PhotoBaseline` and `PhotoFingerprint` handle them apart from the fields). Notes are not modeled either (the CNContact note key needs a restricted entitlement); they are
/// read and written through the Contacts app's AppleScript dictionary (`NotesStoring`) and merged by `NotesMerge`.
public struct ContactRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var source: ContactSource
    /// CNContact.identifier, People API resourceName, etc.
    public var sourceIdentifier: String

    public var givenName: String
    public var middleName: String
    public var familyName: String
    public var nickname: String
    public var organization: String
    public var jobTitle: String

    public var phones: [Labeled<String>]
    public var emails: [Labeled<String>]
    public var postalAddresses: [Labeled<PostalAddress>]
    public var urls: [Labeled<String>]
    /// Year may be nil for year-less birthdays.
    public var birthday: DateComponents?

    public init(
        id: String,
        source: ContactSource,
        sourceIdentifier: String,
        givenName: String = "",
        middleName: String = "",
        familyName: String = "",
        nickname: String = "",
        organization: String = "",
        jobTitle: String = "",
        phones: [Labeled<String>] = [],
        emails: [Labeled<String>] = [],
        postalAddresses: [Labeled<PostalAddress>] = [],
        urls: [Labeled<String>] = [],
        birthday: DateComponents? = nil
    ) {
        self.id = id
        self.source = source
        self.sourceIdentifier = sourceIdentifier
        self.givenName = givenName
        self.middleName = middleName
        self.familyName = familyName
        self.nickname = nickname
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.postalAddresses = postalAddresses
        self.urls = urls
        self.birthday = birthday
    }

    /// True when no user-visible field carries data.
    public var isEmpty: Bool {
        [givenName, middleName, familyName, nickname, organization, jobTitle].allSatisfy(\.isBlank)
            && phones.allSatisfy { $0.value.isBlank }
            && emails.allSatisfy { $0.value.isBlank }
            && postalAddresses.allSatisfy { $0.value.isEmpty }
            && urls.allSatisfy { $0.value.isBlank }
            && birthday == nil
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
