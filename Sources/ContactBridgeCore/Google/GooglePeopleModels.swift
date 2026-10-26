import Foundation

// Codable mirrors of the People API resources this app reads and writes. Only fields the app models are declared;
// everything else in a response (biographies, photos, ...) is ignored on decode. Updates therefore never send those
// fields and always carry an `updatePersonFields` mask, so untouched fields are not clobbered (see GooglePersonMapper).

public struct GoogleSource: Codable, Sendable, Hashable {
    public var type: String?
    public var id: String?
    public var etag: String?
    public var updateTime: String?
}

public struct GoogleFieldMetadata: Codable, Sendable, Hashable {
    public var primary: Bool?
    public var verified: Bool?
    public var sourcePrimary: Bool?
    public var source: GoogleSource?
}

public struct GooglePersonMetadata: Codable, Sendable, Hashable {
    public var sources: [GoogleSource]?
    /// True on sync entries for people removed since the sync token; such stubs carry only the resource name.
    public var deleted: Bool?
    public var objectType: String?
    public var previousResourceNames: [String]?
    public var linkedPeopleResourceNames: [String]?
}

protocol GoogleMetadataCarrying: Sendable {
    var metadata: GoogleFieldMetadata? { get set }
}

public struct GoogleName: Sendable, Hashable, GoogleMetadataCarrying {
    // displayName, displayNameLastFirst and unstructuredName are output only; never sent on update.
    public var metadata: GoogleFieldMetadata?
    public var displayName: String?
    public var displayNameLastFirst: String?
    public var unstructuredName: String?
    public var givenName: String?
    public var familyName: String?
    public var middleName: String?
    public var honorificPrefix: String?
    public var honorificSuffix: String?
    public var phoneticGivenName: String?
    public var phoneticMiddleName: String?
    public var phoneticFamilyName: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleName: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, displayName, displayNameLastFirst, unstructuredName, givenName, familyName, middleName, honorificPrefix, honorificSuffix, phoneticGivenName, phoneticMiddleName, phoneticFamilyName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        displayNameLastFirst = try container.decodeIfPresent(String.self, forKey: .displayNameLastFirst)
        unstructuredName = try container.decodeIfPresent(String.self, forKey: .unstructuredName)
        givenName = try container.decodeIfPresent(String.self, forKey: .givenName)
        familyName = try container.decodeIfPresent(String.self, forKey: .familyName)
        middleName = try container.decodeIfPresent(String.self, forKey: .middleName)
        honorificPrefix = try container.decodeIfPresent(String.self, forKey: .honorificPrefix)
        honorificSuffix = try container.decodeIfPresent(String.self, forKey: .honorificSuffix)
        phoneticGivenName = try container.decodeIfPresent(String.self, forKey: .phoneticGivenName)
        phoneticMiddleName = try container.decodeIfPresent(String.self, forKey: .phoneticMiddleName)
        phoneticFamilyName = try container.decodeIfPresent(String.self, forKey: .phoneticFamilyName)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(displayNameLastFirst, forKey: .displayNameLastFirst)
        try container.encodeIfPresent(unstructuredName, forKey: .unstructuredName)
        try container.encodeIfPresent(givenName, forKey: .givenName)
        try container.encodeIfPresent(familyName, forKey: .familyName)
        try container.encodeIfPresent(middleName, forKey: .middleName)
        try container.encodeIfPresent(honorificPrefix, forKey: .honorificPrefix)
        try container.encodeIfPresent(honorificSuffix, forKey: .honorificSuffix)
        try container.encodeIfPresent(phoneticGivenName, forKey: .phoneticGivenName)
        try container.encodeIfPresent(phoneticMiddleName, forKey: .phoneticMiddleName)
        try container.encodeIfPresent(phoneticFamilyName, forKey: .phoneticFamilyName)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleNickname: Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var value: String?
    public var type: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleNickname: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, value, type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleOrganization: Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var type: String?
    public var formattedType: String?
    public var name: String?
    public var title: String?
    public var department: String?
    public var current: Bool?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleOrganization: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, type, formattedType, name, title, department, current
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        formattedType = try container.decodeIfPresent(String.self, forKey: .formattedType)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        department = try container.decodeIfPresent(String.self, forKey: .department)
        current = try container.decodeIfPresent(Bool.self, forKey: .current)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(formattedType, forKey: .formattedType)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(department, forKey: .department)
        try container.encodeIfPresent(current, forKey: .current)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GooglePhoneNumber: Sendable, Hashable, GoogleMetadataCarrying {
    // canonicalForm and formattedType are computed by Google (output only).
    public var metadata: GoogleFieldMetadata?
    public var value: String?
    public var canonicalForm: String?
    public var type: String?
    public var formattedType: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GooglePhoneNumber: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, value, canonicalForm, type, formattedType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        canonicalForm = try container.decodeIfPresent(String.self, forKey: .canonicalForm)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        formattedType = try container.decodeIfPresent(String.self, forKey: .formattedType)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(canonicalForm, forKey: .canonicalForm)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(formattedType, forKey: .formattedType)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleEmailAddress: Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var value: String?
    public var type: String?
    public var formattedType: String?
    public var displayName: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleEmailAddress: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, value, type, formattedType, displayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        formattedType = try container.decodeIfPresent(String.self, forKey: .formattedType)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(formattedType, forKey: .formattedType)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleAddress: Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var type: String?
    public var formattedType: String?
    public var formattedValue: String?
    public var streetAddress: String?
    public var extendedAddress: String?
    public var poBox: String?
    public var city: String?
    public var region: String?
    public var postalCode: String?
    public var country: String?
    public var countryCode: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleAddress: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, type, formattedType, formattedValue, streetAddress, extendedAddress, poBox, city, region, postalCode, country, countryCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        formattedType = try container.decodeIfPresent(String.self, forKey: .formattedType)
        formattedValue = try container.decodeIfPresent(String.self, forKey: .formattedValue)
        streetAddress = try container.decodeIfPresent(String.self, forKey: .streetAddress)
        extendedAddress = try container.decodeIfPresent(String.self, forKey: .extendedAddress)
        poBox = try container.decodeIfPresent(String.self, forKey: .poBox)
        city = try container.decodeIfPresent(String.self, forKey: .city)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        postalCode = try container.decodeIfPresent(String.self, forKey: .postalCode)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        countryCode = try container.decodeIfPresent(String.self, forKey: .countryCode)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(formattedType, forKey: .formattedType)
        try container.encodeIfPresent(formattedValue, forKey: .formattedValue)
        try container.encodeIfPresent(streetAddress, forKey: .streetAddress)
        try container.encodeIfPresent(extendedAddress, forKey: .extendedAddress)
        try container.encodeIfPresent(poBox, forKey: .poBox)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(region, forKey: .region)
        try container.encodeIfPresent(postalCode, forKey: .postalCode)
        try container.encodeIfPresent(country, forKey: .country)
        try container.encodeIfPresent(countryCode, forKey: .countryCode)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleUrl: Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var value: String?
    public var type: String?
    public var formattedType: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleUrl: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, value, type, formattedType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        value = try container.decodeIfPresent(String.self, forKey: .value)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        formattedType = try container.decodeIfPresent(String.self, forKey: .formattedType)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(formattedType, forKey: .formattedType)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleBirthday: Sendable, Hashable, GoogleMetadataCarrying {
    // `text` is free text such as "March 9"; it carries no usable date.
    public var metadata: GoogleFieldMetadata?
    public var date: GoogleDate?
    public var text: String?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]
}

extension GoogleBirthday: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata, date, text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decodeIfPresent(GoogleFieldMetadata.self, forKey: .metadata)
        date = try container.decodeIfPresent(GoogleDate.self, forKey: .date)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(date, forKey: .date)
        try container.encodeIfPresent(text, forKey: .text)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GooglePerson: Sendable, Hashable {
    public var resourceName: String?
    public var etag: String?
    public var metadata: GooglePersonMetadata?
    public var names: [GoogleName]?
    public var nicknames: [GoogleNickname]?
    public var organizations: [GoogleOrganization]?
    public var phoneNumbers: [GooglePhoneNumber]?
    public var emailAddresses: [GoogleEmailAddress]?
    public var addresses: [GoogleAddress]?
    public var urls: [GoogleUrl]?
    public var birthdays: [GoogleBirthday]?
    public var memberships: [GoogleMembership]?
    public var clientData: [GoogleClientData]?
    /// Keys this model does not declare, kept verbatim so edits never drop them.
    public var extras: [String: JSONValue] = [:]

    public var isDeleted: Bool { metadata?.deleted == true }
}

extension GooglePerson: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case resourceName, etag, metadata, names, nicknames, organizations, phoneNumbers, emailAddresses, addresses, urls, birthdays, memberships, clientData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resourceName = try container.decodeIfPresent(String.self, forKey: .resourceName)
        etag = try container.decodeIfPresent(String.self, forKey: .etag)
        metadata = try container.decodeIfPresent(GooglePersonMetadata.self, forKey: .metadata)
        names = try container.decodeIfPresent([GoogleName].self, forKey: .names)
        nicknames = try container.decodeIfPresent([GoogleNickname].self, forKey: .nicknames)
        organizations = try container.decodeIfPresent([GoogleOrganization].self, forKey: .organizations)
        phoneNumbers = try container.decodeIfPresent([GooglePhoneNumber].self, forKey: .phoneNumbers)
        emailAddresses = try container.decodeIfPresent([GoogleEmailAddress].self, forKey: .emailAddresses)
        addresses = try container.decodeIfPresent([GoogleAddress].self, forKey: .addresses)
        urls = try container.decodeIfPresent([GoogleUrl].self, forKey: .urls)
        birthdays = try container.decodeIfPresent([GoogleBirthday].self, forKey: .birthdays)
        memberships = try container.decodeIfPresent([GoogleMembership].self, forKey: .memberships)
        clientData = try container.decodeIfPresent([GoogleClientData].self, forKey: .clientData)
        extras = try GoogleExtras.decode(from: decoder, excluding: Set(CodingKeys.allCases.map(\.rawValue)))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(resourceName, forKey: .resourceName)
        try container.encodeIfPresent(etag, forKey: .etag)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(names, forKey: .names)
        try container.encodeIfPresent(nicknames, forKey: .nicknames)
        try container.encodeIfPresent(organizations, forKey: .organizations)
        try container.encodeIfPresent(phoneNumbers, forKey: .phoneNumbers)
        try container.encodeIfPresent(emailAddresses, forKey: .emailAddresses)
        try container.encodeIfPresent(addresses, forKey: .addresses)
        try container.encodeIfPresent(urls, forKey: .urls)
        try container.encodeIfPresent(birthdays, forKey: .birthdays)
        try container.encodeIfPresent(memberships, forKey: .memberships)
        try container.encodeIfPresent(clientData, forKey: .clientData)
        try GoogleExtras.encode(extras, to: encoder)
    }
}

public struct GoogleDate: Codable, Sendable, Hashable {
    /// Absent (or 0) for year-less birthdays.
    public var year: Int?
    public var month: Int?
    public var day: Int?
}

public struct GoogleContactGroupMembership: Codable, Sendable, Hashable {
    public var contactGroupId: String?
    public var contactGroupResourceName: String?
}

public struct GoogleMembership: Codable, Sendable, Hashable, GoogleMetadataCarrying {
    public var metadata: GoogleFieldMetadata?
    public var contactGroupMembership: GoogleContactGroupMembership?
}

/// Per-client key/value storage on a person (max 10 entries).
public struct GoogleClientData: Codable, Sendable, Hashable {
    public var key: String
    public var value: String
}

public struct GoogleContactGroup: Codable, Sendable, Hashable {
    public var resourceName: String?
    public var etag: String?
    public var name: String?
    public var groupType: String?
    public var memberCount: Int?
}

// MARK: list responses

public struct GoogleConnectionsResponse: Codable, Sendable, Hashable {
    public var connections: [GooglePerson]?
    public var nextPageToken: String?
    /// Present only on the last page.
    public var nextSyncToken: String?
    public var totalPeople: Int?
    public var totalItems: Int?
}

public struct GoogleOtherContactsResponse: Codable, Sendable, Hashable {
    public var otherContacts: [GooglePerson]?
    public var nextPageToken: String?
    public var nextSyncToken: String?
    public var totalSize: Int?
}

/// One page of either list endpoint, normalized.
public struct GooglePeoplePage: Sendable, Hashable {
    public var people: [GooglePerson]
    public var nextPageToken: String?
    public var nextSyncToken: String?

    public init(people: [GooglePerson], nextPageToken: String? = nil, nextSyncToken: String? = nil) {
        self.people = people
        self.nextPageToken = nextPageToken
        self.nextSyncToken = nextSyncToken
    }

    public init(_ response: GoogleConnectionsResponse) {
        self.init(people: response.connections ?? [], nextPageToken: response.nextPageToken, nextSyncToken: response.nextSyncToken)
    }

    public init(_ response: GoogleOtherContactsResponse) {
        self.init(people: response.otherContacts ?? [], nextPageToken: response.nextPageToken, nextSyncToken: response.nextSyncToken)
    }
}
