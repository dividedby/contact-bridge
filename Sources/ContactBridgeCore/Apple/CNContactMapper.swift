import Contacts
import Foundation

/// CNContact <-> ContactRecord. Pure: touches no store, so it is testable with in-memory CNMutableContact objects.
///
/// Notes and images are never read or written (the notes key needs a restricted entitlement). Fields ContactRecord does
/// not model (prefix, suffix, department, phonetic names, IM, social, relations, dates, ...) are left alone on update.
enum CNContactMapper {
    /// Everything `record(from:)` reads. Deliberately excludes the note and image keys.
    static var requiredKeys: [CNKeyDescriptor] {
        [
            CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey,
        ].map { $0 as NSString }
    }

    /// `requiredKeys` plus everything ContactRecord cannot express, and the full photo, for the merge path only.
    /// Still never the note key.
    static var mergeKeys: [CNKeyDescriptor] {
        requiredKeys + [
            CNContactNamePrefixKey, CNContactNameSuffixKey, CNContactDepartmentNameKey, CNContactPreviousFamilyNameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
            CNContactPhoneticOrganizationNameKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey,
            CNContactRelationsKey, CNContactDatesKey, CNContactImageDataKey, CNContactImageDataAvailableKey,
        ].map { $0 as NSString }
    }

    /// True for CNErrorCodeUnauthorizedKeys (102): a requested key needs an entitlement the app lacks.
    static func isUnauthorizedKeys(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == CNErrorDomain && nsError.code == CNError.Code.unauthorizedKeys.rawValue
    }

    // MARK: CNContact -> ContactRecord

    static func record(from contact: CNContact) -> ContactRecord {
        ContactRecord(
            id: contact.identifier,
            source: .icloud,
            sourceIdentifier: contact.identifier,
            givenName: contact.givenName,
            middleName: contact.middleName,
            familyName: contact.familyName,
            nickname: contact.nickname,
            organization: contact.organizationName,
            jobTitle: contact.jobTitle,
            phones: contact.phoneNumbers.map { Labeled(label: friendlyLabel($0.label), value: $0.value.stringValue) },
            emails: contact.emailAddresses.map { Labeled(label: friendlyLabel($0.label), value: $0.value as String) },
            postalAddresses: contact.postalAddresses.map { Labeled(label: friendlyLabel($0.label), value: address(from: $0.value)) },
            urls: contact.urlAddresses.map { Labeled(label: friendlyLabel($0.label), value: $0.value as String) },
            birthday: recordBirthday(contact.birthday)
        )
    }

    private static func address(from postal: CNPostalAddress) -> PostalAddress {
        PostalAddress(
            street: postal.street, city: postal.city, state: postal.state,
            postalCode: postal.postalCode, country: postal.country,
            isoCountryCode: nonBlank(postal.isoCountryCode),
            subLocality: nonBlank(postal.subLocality),
            subAdministrativeArea: nonBlank(postal.subAdministrativeArea)
        )
    }

    private static func nonBlank(_ text: String) -> String? { text.isBlank ? nil : text }

    /// Contacts stores year-less birthdays with no year, a year of 0, or the placeholder year 1604.
    private static func recordBirthday(_ components: DateComponents?) -> DateComponents? {
        guard let components, let month = defined(components.month), let day = defined(components.day) else { return nil }
        var year = defined(components.year)
        if let y = year, y <= 0 || y == 1604 { year = nil }
        return DateComponents(year: year, month: month, day: day)
    }

    private static func defined(_ value: Int?) -> Int? {
        guard let value, value != NSDateComponentUndefined else { return nil }
        return value
    }

    // MARK: ContactRecord -> CNMutableContact

    /// A new contact (fresh CN identifier) carrying the record's fields.
    static func makeContact(from record: ContactRecord) -> CNMutableContact {
        let contact = CNMutableContact()
        apply(record, to: contact)
        return contact
    }

    /// Overwrites every modeled field on `contact` (normally a mutable copy of a refetched contact). Unmodeled fields
    /// are untouched. Multi-value entries identical to an existing one are reused as-is so CN-only detail on them
    /// (e.g. an address's ISO country code) survives.
    static func apply(_ record: ContactRecord, to contact: CNMutableContact) {
        contact.givenName = record.givenName
        contact.middleName = record.middleName
        contact.familyName = record.familyName
        contact.nickname = record.nickname
        contact.organizationName = record.organization
        contact.jobTitle = record.jobTitle

        contact.phoneNumbers = reconcile(
            existing: contact.phoneNumbers, desired: record.phones,
            read: { $0.stringValue }, make: { CNPhoneNumber(stringValue: $0) }
        )
        contact.emailAddresses = reconcile(
            existing: contact.emailAddresses, desired: record.emails,
            read: { $0 as String }, make: { $0 as NSString }
        )
        contact.urlAddresses = reconcile(
            existing: contact.urlAddresses, desired: record.urls,
            read: { $0 as String }, make: { $0 as NSString }
        )
        contact.postalAddresses = reconcile(
            existing: contact.postalAddresses, desired: record.postalAddresses,
            read: { address(from: $0) }, make: { makePostal($0) }
        )
        // Leave an unchanged birthday alone: rewriting would replace Apple's placeholder year or calendar.
        if recordBirthday(contact.birthday) != normalizedBirthday(record.birthday) {
            contact.birthday = cnBirthday(record.birthday)
        }
    }

    private static func normalizedBirthday(_ birthday: DateComponents?) -> DateComponents? {
        guard let birthday, let month = defined(birthday.month), let day = defined(birthday.day) else { return nil }
        return DateComponents(year: defined(birthday.year), month: month, day: day)
    }

    // MARK: absorbing duplicates

    /// Folds into `survivor` what ContactRecord cannot express, from `duplicates` (fetched with `mergeKeys`):
    /// social profiles, IM, relations and dates are unioned by value (survivor's entry and label win); blank
    /// single-value fields are filled from the first duplicate that has them; a photo is copied only if the survivor
    /// has none. Nothing the survivor already has is overwritten.
    static func absorb(_ duplicates: [CNContact], into survivor: CNMutableContact) {
        guard !duplicates.isEmpty else { return }

        survivor.socialProfiles = unionByValue([survivor.socialProfiles] + duplicates.map(\.socialProfiles)) {
            [$0.service, $0.username, $0.urlString].map { $0.lowercased() }.joined(separator: "|")
        }
        survivor.instantMessageAddresses = unionByValue([survivor.instantMessageAddresses] + duplicates.map(\.instantMessageAddresses)) {
            [$0.service, $0.username].map { $0.lowercased() }.joined(separator: "|")
        }
        survivor.contactRelations = unionByValue([survivor.contactRelations] + duplicates.map(\.contactRelations)) {
            $0.name.lowercased()
        }
        survivor.dates = unionByValue([survivor.dates] + duplicates.map(\.dates)) { "\($0.year)-\($0.month)-\($0.day)" }

        let blankFillable: [(read: KeyPath<CNContact, String>, write: ReferenceWritableKeyPath<CNMutableContact, String>)] = [
            (\.namePrefix, \.namePrefix), (\.nameSuffix, \.nameSuffix), (\.departmentName, \.departmentName),
            (\.previousFamilyName, \.previousFamilyName),
            (\.phoneticGivenName, \.phoneticGivenName), (\.phoneticMiddleName, \.phoneticMiddleName),
            (\.phoneticFamilyName, \.phoneticFamilyName), (\.phoneticOrganizationName, \.phoneticOrganizationName),
        ]
        for field in blankFillable where survivor[keyPath: field.read].isBlank {
            if let value = duplicates.map({ $0[keyPath: field.read] }).first(where: { !$0.isBlank }) {
                survivor[keyPath: field.write] = value
            }
        }

        if survivor.isKeyAvailable(CNContactImageDataKey), survivor.imageData == nil {
            survivor.imageData = duplicates.lazy
                .compactMap { $0.isKeyAvailable(CNContactImageDataKey) ? $0.imageData : nil }
                .first
        }
    }

    private static func unionByValue<V: NSCopying & NSSecureCoding>(
        _ lists: [[CNLabeledValue<V>]], key: (V) -> String
    ) -> [CNLabeledValue<V>] {
        var seen = Set<String>()
        return lists.joined().filter { seen.insert(key($0.value)).inserted }
    }

    private static func reconcile<CNValue: NSCopying & NSSecureCoding, Value: Sendable & Hashable & Codable>(
        existing: [CNLabeledValue<CNValue>],
        desired: [Labeled<Value>],
        read: (CNValue) -> Value,
        make: (Value) -> CNValue
    ) -> [CNLabeledValue<CNValue>] {
        var unused = existing
        return desired.map { wanted in
            let match = unused.firstIndex { Labeled(label: friendlyLabel($0.label), value: read($0.value)) == wanted }
            if let match { return unused.remove(at: match) }
            return CNLabeledValue(label: cnLabel(wanted.label), value: make(wanted.value))
        }
    }

    private static func makePostal(_ address: PostalAddress) -> CNPostalAddress {
        let postal = CNMutablePostalAddress()
        postal.street = address.street
        postal.city = address.city
        postal.state = address.state
        postal.postalCode = address.postalCode
        postal.country = address.country
        if let iso = address.isoCountryCode { postal.isoCountryCode = iso }
        if let sub = address.subLocality { postal.subLocality = sub }
        if let admin = address.subAdministrativeArea { postal.subAdministrativeArea = admin }
        return postal
    }

    private static func cnBirthday(_ birthday: DateComponents?) -> DateComponents? {
        guard let birthday, let month = defined(birthday.month), let day = defined(birthday.day) else { return nil }
        return DateComponents(
            calendar: Calendar(identifier: .gregorian), year: defined(birthday.year), month: month, day: day
        )
    }

    // MARK: labels

    private static let friendlyByCN: [String: String] = [
        CNLabelHome: "home",
        CNLabelWork: "work",
        CNLabelOther: "other",
        CNLabelPhoneNumberMobile: "mobile",
        CNLabelPhoneNumberiPhone: "iPhone",
        CNLabelPhoneNumberMain: "main",
        CNLabelPhoneNumberHomeFax: "home fax",
        CNLabelPhoneNumberWorkFax: "work fax",
        CNLabelPhoneNumberOtherFax: "other fax",
        CNLabelPhoneNumberPager: "pager",
        CNLabelEmailiCloud: "iCloud",
        CNLabelURLAddressHomePage: "homepage",
    ]

    private static let cnByFriendly: [String: String] = {
        Dictionary(uniqueKeysWithValues: friendlyByCN.map { ($0.value.lowercased(), $0.key) })
    }()

    /// CN's `_$!<Mobile>!$_` constants become plain names; custom labels pass through unchanged.
    static func friendlyLabel(_ cnLabel: String?) -> String? {
        guard let cnLabel, !cnLabel.isBlank else { return nil }
        return friendlyByCN[cnLabel] ?? cnLabel
    }

    static func cnLabel(_ friendly: String?) -> String? {
        guard let friendly, !friendly.isBlank else { return nil }
        let key = friendly.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cnByFriendly[key] ?? friendly
    }
}
