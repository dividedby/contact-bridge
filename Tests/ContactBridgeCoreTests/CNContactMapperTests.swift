import Contacts
import Foundation
import Testing
@testable import ContactBridgeCore

struct CNContactMapperTests {
    private let gregorian = Calendar(identifier: .gregorian)

    private func postal(
        street: String = "1 Main St", city: String = "Austin", state: String = "TX", zip: String = "78701",
        country: String = "United States", iso: String = "us"
    ) -> CNMutablePostalAddress {
        let address = CNMutablePostalAddress()
        address.street = street
        address.city = city
        address.state = state
        address.postalCode = zip
        address.country = country
        address.isoCountryCode = iso
        return address
    }

    private func fullContact() -> CNMutableContact {
        let contact = CNMutableContact()
        contact.givenName = "Ann"
        contact.middleName = "Marie"
        contact.familyName = "Lee"
        contact.nickname = "Annie"
        contact.organizationName = "Acme"
        contact.jobTitle = "CTO"
        contact.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(415) 555-2671")),
            CNLabeledValue(label: "Cabin", value: CNPhoneNumber(stringValue: "+1 212 555 3344")),
            CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-0100")),
        ]
        contact.emailAddresses = [
            CNLabeledValue(label: CNLabelWork, value: "ann@acme.com" as NSString),
            CNLabeledValue(label: CNLabelHome, value: "Ann@Example.com" as NSString),
        ]
        contact.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://example.com/Ann" as NSString)]
        contact.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal())]
        contact.birthday = DateComponents(calendar: gregorian, year: 1990, month: 3, day: 9)
        return contact
    }

    // MARK: CNContact -> ContactRecord

    @Test("Every ContactRecord field is read from a CNContact")
    func readsAllFields() {
        let contact = fullContact()
        let record = CNContactMapper.record(from: contact)
        #expect(record.id == contact.identifier)
        #expect(record.sourceIdentifier == contact.identifier)
        #expect(record.source == .icloud)
        #expect(record.givenName == "Ann" && record.middleName == "Marie" && record.familyName == "Lee")
        #expect(record.nickname == "Annie" && record.organization == "Acme" && record.jobTitle == "CTO")
        #expect(record.phones == [
            Labeled(label: "mobile", value: "(415) 555-2671"),
            Labeled(label: "Cabin", value: "+1 212 555 3344"),
            Labeled(label: nil, value: "555-0100"),
        ])
        #expect(record.emails == [Labeled(label: "work", value: "ann@acme.com"), Labeled(label: "home", value: "Ann@Example.com")])
        #expect(record.urls == [Labeled(label: "homepage", value: "https://example.com/Ann")])
        #expect(record.postalAddresses == [
            Labeled(label: "home", value: PostalAddress(
                street: "1 Main St", city: "Austin", state: "TX", postalCode: "78701", country: "United States",
                isoCountryCode: "us"
            )),
        ])
        #expect(record.birthday == DateComponents(year: 1990, month: 3, day: 9))
    }

    @Test("Year-less birthdays read as year nil, including Apple's 1604 placeholder")
    func yearlessBirthday() {
        for year in [nil, 1604, 0, NSDateComponentUndefined] as [Int?] {
            let contact = CNMutableContact()
            contact.birthday = DateComponents(calendar: gregorian, year: year, month: 3, day: 9)
            #expect(CNContactMapper.record(from: contact).birthday == DateComponents(month: 3, day: 9), "year \(String(describing: year))")
        }
        let none = CNMutableContact()
        #expect(CNContactMapper.record(from: none).birthday == nil)
    }

    // MARK: ContactRecord -> CNMutableContact

    @Test("CNContact to ContactRecord to CNMutableContact round-trips every field and CN label")
    func roundTrip() {
        let original = fullContact()
        let record = CNContactMapper.record(from: original)
        let rebuilt = CNContactMapper.makeContact(from: record)

        #expect(rebuilt.givenName == original.givenName && rebuilt.middleName == original.middleName)
        #expect(rebuilt.familyName == original.familyName && rebuilt.nickname == original.nickname)
        #expect(rebuilt.organizationName == original.organizationName && rebuilt.jobTitle == original.jobTitle)
        #expect(rebuilt.phoneNumbers.map(\.label) == original.phoneNumbers.map(\.label))
        #expect(rebuilt.phoneNumbers.map(\.value.stringValue) == original.phoneNumbers.map(\.value.stringValue))
        #expect(rebuilt.emailAddresses.map(\.label) == original.emailAddresses.map(\.label))
        #expect(rebuilt.emailAddresses.map { $0.value as String } == original.emailAddresses.map { $0.value as String })
        #expect(rebuilt.urlAddresses.map(\.label) == original.urlAddresses.map(\.label))
        #expect(rebuilt.postalAddresses.map(\.label) == original.postalAddresses.map(\.label))
        #expect(rebuilt.birthday?.year == 1990 && rebuilt.birthday?.month == 3 && rebuilt.birthday?.day == 9)

        var again = CNContactMapper.record(from: rebuilt)
        again.id = record.id
        again.sourceIdentifier = record.sourceIdentifier
        #expect(again == record)
    }

    @Test("Year-less birthdays are written without a year")
    func writesYearlessBirthday() {
        var record = ContactRecord(id: "x", source: .icloud, sourceIdentifier: "x")
        record.birthday = DateComponents(month: 3, day: 9)
        let contact = CNContactMapper.makeContact(from: record)
        #expect(contact.birthday?.year == nil)
        #expect(contact.birthday?.month == 3 && contact.birthday?.day == 9)
        #expect(contact.birthday?.calendar?.identifier == .gregorian)
    }

    @Test("A birthday missing month or day is not written")
    func incompleteBirthday() {
        var record = ContactRecord(id: "x", source: .icloud, sourceIdentifier: "x")
        record.birthday = DateComponents(year: 1990)
        #expect(CNContactMapper.makeContact(from: record).birthday == nil)
    }

    @Test("Labels use friendly names both ways and unknown labels pass through", arguments: [
        (CNLabelHome, "home"), (CNLabelWork, "work"), (CNLabelOther, "other"),
        (CNLabelPhoneNumberMobile, "mobile"), (CNLabelPhoneNumberiPhone, "iPhone"), (CNLabelPhoneNumberMain, "main"),
        (CNLabelPhoneNumberHomeFax, "home fax"), (CNLabelPhoneNumberWorkFax, "work fax"),
        (CNLabelPhoneNumberOtherFax, "other fax"), (CNLabelPhoneNumberPager, "pager"),
        (CNLabelEmailiCloud, "iCloud"), (CNLabelURLAddressHomePage, "homepage"),
        ("Cabin", "Cabin"), ("_$!<Weird>!$_", "_$!<Weird>!$_"),
    ])
    func labels(cn: String, friendly: String) {
        #expect(CNContactMapper.friendlyLabel(cn) == friendly)
        #expect(CNContactMapper.cnLabel(friendly) == cn)
    }

    @Test("Friendly labels are matched case-insensitively and nil/blank stay nil")
    func labelEdgeCases() {
        #expect(CNContactMapper.cnLabel("Mobile") == CNLabelPhoneNumberMobile)
        #expect(CNContactMapper.cnLabel(" WORK ") == CNLabelWork)
        #expect(CNContactMapper.cnLabel(nil) == nil)
        #expect(CNContactMapper.cnLabel("  ") == nil)
        #expect(CNContactMapper.friendlyLabel(nil) == nil)
    }

    // MARK: updates

    @Test("Applying a record to a refetched contact preserves fields ContactRecord does not model")
    func updatePreservesUnmapped() {
        let existing = fullContact()
        existing.namePrefix = "Dr."
        existing.nameSuffix = "PhD"
        existing.departmentName = "R&D"
        existing.previousFamilyName = "Smith"
        existing.phoneticGivenName = "An"
        existing.instantMessageAddresses = [
            CNLabeledValue(label: "Skype", value: CNInstantMessageAddress(username: "ann", service: "Skype")),
        ]
        existing.contactRelations = [CNLabeledValue(label: CNLabelContactRelationSpouse, value: CNContactRelation(name: "Bo"))]

        var record = CNContactMapper.record(from: existing)
        record.jobTitle = "CEO"
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)

        #expect(working.jobTitle == "CEO")
        #expect(working.namePrefix == "Dr." && working.nameSuffix == "PhD" && working.departmentName == "R&D")
        #expect(working.previousFamilyName == "Smith" && working.phoneticGivenName == "An")
        #expect(working.instantMessageAddresses.count == 1 && working.contactRelations.count == 1)
        #expect(working.identifier == existing.identifier)
    }

    @Test("Unchanged multi-value entries are reused so CN-only detail survives; changed ones are replaced")
    func updateReusesUnchangedEntries() {
        let existing = fullContact()
        let keptPostalIdentifier = existing.postalAddresses[0].identifier
        let keptPhoneIdentifier = existing.phoneNumbers[0].identifier

        var record = CNContactMapper.record(from: existing)
        record.phones[1].value = "+1 212 555 9999"
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)

        #expect(working.postalAddresses[0].identifier == keptPostalIdentifier)
        #expect(working.phoneNumbers[0].identifier == keptPhoneIdentifier)
        #expect(working.phoneNumbers[1].identifier != existing.phoneNumbers[1].identifier)
        #expect(working.phoneNumbers[1].value.stringValue == "+1 212 555 9999")
        #expect(working.phoneNumbers.count == 3)
    }

    @Test("Entries removed from the record are removed from the contact, and fields can be cleared")
    func updateRemoves() {
        let existing = fullContact()
        var record = CNContactMapper.record(from: existing)
        record.emails = [record.emails[1]]
        record.postalAddresses = []
        record.birthday = nil
        record.nickname = ""
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)
        #expect(working.emailAddresses.map { $0.value as String } == ["Ann@Example.com"])
        #expect(working.postalAddresses.isEmpty)
        #expect(working.birthday == nil)
        #expect(working.nickname == "")
    }

    @Test("Two identical entries are matched one-to-one, not collapsed")
    func duplicateEntries() {
        let existing = CNMutableContact()
        existing.phoneNumbers = [
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "415-555-2671")),
            CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "415-555-2671")),
        ]
        let record = CNContactMapper.record(from: existing)
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)
        #expect(working.phoneNumbers.map(\.identifier) == existing.phoneNumbers.map(\.identifier))
    }

    // MARK: birthdays and addresses on update

    @Test("An unchanged birthday is not rewritten, so placeholder years and calendars survive")
    func unchangedBirthdayUntouched() {
        let existing = fullContact()
        existing.birthday = DateComponents(calendar: gregorian, year: 1604, month: 3, day: 9)
        let record = CNContactMapper.record(from: existing)
        #expect(record.birthday == DateComponents(month: 3, day: 9))
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)
        #expect(working.birthday?.year == 1604)

        var changed = record
        changed.birthday = DateComponents(year: 1991, month: 3, day: 9)
        CNContactMapper.apply(changed, to: working)
        #expect(working.birthday?.year == 1991)
    }

    @Test("Changed and new addresses keep ISO country code, sub-locality and sub-administrative area")
    func addressExtrasSurvive() {
        let existing = fullContact()
        let detailed = postal()
        detailed.subLocality = "Downtown"
        detailed.subAdministrativeArea = "Travis"
        existing.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: detailed)]

        var record = CNContactMapper.record(from: existing)
        #expect(record.postalAddresses[0].value.subLocality == "Downtown")
        record.postalAddresses[0].value.street = "2 Main St"
        record.postalAddresses.append(Labeled(
            label: "work", value: PostalAddress(street: "9 Elm", city: "Dallas", isoCountryCode: "us", subLocality: "Uptown")
        ))
        let working = existing.mutableCopy() as! CNMutableContact
        CNContactMapper.apply(record, to: working)

        let first = working.postalAddresses[0].value
        #expect(first.street == "2 Main St")
        #expect(first.isoCountryCode == "us" && first.subLocality == "Downtown" && first.subAdministrativeArea == "Travis")
        let second = working.postalAddresses[1].value
        #expect(second.isoCountryCode == "us" && second.subLocality == "Uptown")
        #expect(CNContactMapper.makeContact(from: record).postalAddresses[0].value.subAdministrativeArea == "Travis")
    }

    @Test("PostalAddress decodes older JSON that lacks the extra fields")
    func postalAddressCompatibility() throws {
        let json = Data(#"{"street":"1 Main","city":"A","state":"B","postalCode":"1","country":"C"}"#.utf8)
        let decoded = try JSONDecoder().decode(PostalAddress.self, from: json)
        #expect(decoded == PostalAddress(street: "1 Main", city: "A", state: "B", postalCode: "1", country: "C"))
        #expect(decoded.isoCountryCode == nil)
    }

    // MARK: absorbing duplicates

    private func labeled<V>(_ label: String?, _ value: V) -> CNLabeledValue<V> { CNLabeledValue(label: label, value: value) }

    @Test("Absorbing unions social profiles, IM, relations and dates by value with the survivor's label first")
    func absorbUnions() {
        let survivor = CNMutableContact()
        survivor.socialProfiles = [labeled("work", CNSocialProfile(urlString: "https://twitter.com/ann", username: "Ann", userIdentifier: nil, service: "Twitter"))]
        survivor.instantMessageAddresses = [labeled("home", CNInstantMessageAddress(username: "ann", service: "Skype"))]
        survivor.contactRelations = [labeled(CNLabelContactRelationSpouse, CNContactRelation(name: "Bo"))]
        survivor.dates = [labeled(CNLabelDateAnniversary, DateComponents(year: 2010, month: 6, day: 1) as NSDateComponents)]

        let duplicate = CNMutableContact()
        duplicate.socialProfiles = [
            labeled("home", CNSocialProfile(urlString: "HTTPS://twitter.com/ann", username: "ann", userIdentifier: nil, service: "twitter")),
            labeled("other", CNSocialProfile(urlString: nil, username: "ann-gh", userIdentifier: nil, service: "GitHub")),
        ]
        duplicate.instantMessageAddresses = [
            labeled("work", CNInstantMessageAddress(username: "ANN", service: "skype")),
            labeled("work", CNInstantMessageAddress(username: "ann", service: "Jabber")),
        ]
        duplicate.contactRelations = [
            labeled(CNLabelContactRelationFriend, CNContactRelation(name: "bo")),
            labeled(CNLabelContactRelationChild, CNContactRelation(name: "Cy")),
        ]
        duplicate.dates = [
            labeled("other", DateComponents(year: 2010, month: 6, day: 1) as NSDateComponents),
            labeled("other", DateComponents(year: 2012, month: 1, day: 1) as NSDateComponents),
        ]

        CNContactMapper.absorb([duplicate], into: survivor)

        #expect(survivor.socialProfiles.map(\.label) == ["work", "other"])
        #expect(survivor.socialProfiles.map(\.value.service) == ["Twitter", "GitHub"])
        #expect(survivor.instantMessageAddresses.map(\.label) == ["home", "work"])
        #expect(survivor.instantMessageAddresses.map(\.value.service) == ["Skype", "Jabber"])
        #expect(survivor.contactRelations.map(\.value.name) == ["Bo", "Cy"])
        #expect(survivor.contactRelations.map(\.label) == [CNLabelContactRelationSpouse, CNLabelContactRelationChild])
        #expect(survivor.dates.count == 2)
        #expect(survivor.dates.map(\.label) == [CNLabelDateAnniversary, "other"])
    }

    @Test("Absorbing fills blank single-value fields from the first duplicate that has them, never overwriting")
    func absorbFillsBlanks() {
        let survivor = CNMutableContact()
        survivor.namePrefix = "Dr."
        survivor.phoneticFamilyName = "Li"

        let first = CNMutableContact()
        first.namePrefix = "Prof."
        first.nameSuffix = "Jr."
        first.phoneticGivenName = "An"
        first.previousFamilyName = "Smith"

        let second = CNMutableContact()
        second.nameSuffix = "III"
        second.departmentName = "R&D"
        second.phoneticMiddleName = "Mari"
        second.phoneticFamilyName = "Lee"
        second.phoneticOrganizationName = "Akmi"
        second.previousFamilyName = "Jones"

        CNContactMapper.absorb([first, second], into: survivor)

        #expect(survivor.namePrefix == "Dr.")
        #expect(survivor.nameSuffix == "Jr.")
        #expect(survivor.departmentName == "R&D")
        #expect(survivor.phoneticGivenName == "An" && survivor.phoneticMiddleName == "Mari")
        #expect(survivor.phoneticFamilyName == "Li" && survivor.phoneticOrganizationName == "Akmi")
        #expect(survivor.previousFamilyName == "Smith")
    }

    @Test("Absorbing copies a photo only when the survivor has none")
    func absorbImage() {
        let photo1 = Data([1, 2, 3])
        let photo2 = Data([9, 9])
        let withPhoto = CNMutableContact()
        withPhoto.imageData = photo1
        let other = CNMutableContact()
        other.imageData = photo2

        let bare = CNMutableContact()
        CNContactMapper.absorb([CNMutableContact(), other, withPhoto], into: bare)
        #expect(bare.imageData == photo2)

        let keeper = CNMutableContact()
        keeper.imageData = photo1
        CNContactMapper.absorb([other], into: keeper)
        #expect(keeper.imageData == photo1)
    }

    @Test("Merge keys add the unmodeled fields and the photo, and still never include notes")
    func mergeKeys() {
        let keys = CNContactMapper.mergeKeys.compactMap { $0 as? String }
        #expect(keys.count == CNContactMapper.mergeKeys.count)
        for key in CNContactMapper.requiredKeys.compactMap({ $0 as? String }) { #expect(keys.contains(key)) }
        for key in [
            CNContactNamePrefixKey, CNContactNameSuffixKey, CNContactDepartmentNameKey, CNContactPreviousFamilyNameKey,
            CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
            CNContactPhoneticOrganizationNameKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey,
            CNContactRelationsKey, CNContactDatesKey, CNContactImageDataKey, CNContactImageDataAvailableKey,
        ] {
            #expect(keys.contains(key), "missing \(key)")
        }
        #expect(!keys.contains(CNContactNoteKey))
        #expect(!keys.contains(CNContactThumbnailImageDataKey))
    }

    @Test("Only CNError 102 counts as unauthorized keys")
    func unauthorizedKeysDetection() {
        #expect(CNContactMapper.isUnauthorizedKeys(NSError(domain: CNErrorDomain, code: 102)))
        #expect(!CNContactMapper.isUnauthorizedKeys(NSError(domain: CNErrorDomain, code: 200)))
        #expect(!CNContactMapper.isUnauthorizedKeys(NSError(domain: NSCocoaErrorDomain, code: 102)))
    }

    // MARK: keys

    @Test("Required keys cover the record's fields and never request notes or images")
    func requiredKeys() {
        let keys = CNContactMapper.requiredKeys.compactMap { $0 as? String }
        #expect(keys.count == CNContactMapper.requiredKeys.count)
        for key in [
            CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            CNContactPostalAddressesKey, CNContactUrlAddressesKey, CNContactBirthdayKey,
        ] {
            #expect(keys.contains(key), "missing \(key)")
        }
        for forbidden in [CNContactNoteKey, CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey] {
            #expect(!keys.contains(forbidden), "must not request \(forbidden)")
        }
    }
}
