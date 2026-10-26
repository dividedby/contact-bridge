import Foundation
import Testing
@testable import ContactBridgeCore

struct GooglePersonMapperTests {
    private func full() throws -> GooglePerson { try GoogleFixtures.decode(GooglePerson.self, "person_full") }

    // MARK: reading

    @Test("The primary name wins whatever its position")
    func primaryName() {
        let person = GooglePerson(resourceName: "people/c1", names: [
            GoogleName(givenName: "Annie", familyName: "L"),
            GoogleName(metadata: GoogleFieldMetadata(primary: true), givenName: "Ann", familyName: "Lee"),
        ])
        #expect(GooglePersonMapper.record(from: person)?.givenName == "Ann")
    }

    @Test("Birthdays without a year, or with year 0, are year-less; text-only birthdays are ignored")
    func birthdays() {
        func record(_ date: GoogleDate?) -> ContactRecord? {
            GooglePersonMapper.record(from: GooglePerson(resourceName: "people/c1", birthdays: [GoogleBirthday(date: date, text: "March")]))
        }
        #expect(record(GoogleDate(month: 3, day: 9))?.birthday == DateComponents(month: 3, day: 9))
        #expect(record(GoogleDate(year: 0, month: 3, day: 9))?.birthday == DateComponents(month: 3, day: 9))
        #expect(record(GoogleDate(year: 1990, month: 3, day: 9))?.birthday == DateComponents(year: 1990, month: 3, day: 9))
        #expect(record(nil)?.birthday == nil)
        #expect(record(GoogleDate(year: 1990))?.birthday == nil)
    }

    @Test("A person without a resource name has no record")
    func noResourceName() {
        #expect(GooglePersonMapper.record(from: GooglePerson(names: [GoogleName(givenName: "A")])) == nil)
    }

    @Test("Labels map to the same friendly names the Apple side uses, and custom types pass through", arguments: [
        ("mobile", "mobile"), ("home", "home"), ("work", "work"), ("other", "other"), ("main", "main"),
        ("homeFax", "home fax"), ("workFax", "work fax"), ("otherFax", "other fax"), ("pager", "pager"),
        ("workMobile", "work mobile"), ("workPager", "work pager"), ("googleVoice", "google voice"),
        ("homePage", "homepage"), ("Cabin", "Cabin"),
    ])
    func labels(type: String, friendly: String) {
        #expect(GooglePersonMapper.friendlyLabel(type) == friendly)
        #expect(GooglePersonMapper.googleType(friendly) == type)
    }

    @Test("Label edge cases")
    func labelEdges() {
        #expect(GooglePersonMapper.googleType("Mobile") == "mobile")
        #expect(GooglePersonMapper.googleType(" HOME FAX ") == "homeFax")
        #expect(GooglePersonMapper.googleType(nil) == nil)
        #expect(GooglePersonMapper.googleType("  ") == nil)
        #expect(GooglePersonMapper.friendlyLabel("") == nil)
        #expect(GooglePersonMapper.friendlyLabel(nil) == nil)
    }

    // MARK: writing

    @Test("A created person round-trips every modeled field and carries no read-only data")
    func createRoundTrip() throws {
        let record = try #require(GooglePersonMapper.record(from: try full()))
        let payload = GooglePersonMapper.createPayload(for: record)
        #expect(payload.resourceName == nil && payload.etag == nil && payload.metadata == nil)
        #expect(payload.clientData == nil)
        #expect(payload.names?.first?.displayName == nil)

        var stored = payload
        stored.resourceName = record.id
        let again = try #require(GooglePersonMapper.record(from: stored))
        #expect(again == record)
    }

    @Test("Create payload splits a two-line street, omits blanks, and uppercases the country code")
    func createDetails() throws {
        var record = ContactRecord(id: "x", source: .google, sourceIdentifier: "x", givenName: "Ann")
        record.postalAddresses = [Labeled(label: "home", value: PostalAddress(
            street: "1 Main\nApt 2", city: "Austin", isoCountryCode: "us"
        ))]
        record.phones = [Labeled(label: "home fax", value: "555-0100"), Labeled(label: nil, value: "555-0101"), Labeled(label: nil, value: " ")]
        let payload = GooglePersonMapper.createPayload(for: record)
        let address = try #require(payload.addresses?.first)
        #expect(address.streetAddress == "1 Main" && address.extendedAddress == "Apt 2" && address.countryCode == "US")
        #expect(address.region == nil && address.postalCode == nil)
        #expect(payload.phoneNumbers?.map(\.type) == ["homeFax", nil])
        #expect(payload.nicknames == nil && payload.organizations == nil && payload.birthdays == nil)
    }

    @Test("The create payload encodes without nulls")
    func encodesCleanly() throws {
        let record = ContactRecord(id: "x", source: .google, sourceIdentifier: "x", givenName: "Ann", emails: [Labeled(label: "work", value: "a@x.com")])
        let json = String(decoding: try JSONEncoder().encode(GooglePersonMapper.createPayload(for: record)), as: UTF8.self)
        #expect(!json.contains("null"))
        #expect(json.contains(#""givenName":"Ann""#))
    }

    @Test("Birthdays write with or without a year")
    func writesBirthdays() {
        var record = ContactRecord(id: "x", source: .google, sourceIdentifier: "x")
        record.birthday = DateComponents(month: 3, day: 9)
        #expect(GooglePersonMapper.createPayload(for: record).birthdays?.first?.date == GoogleDate(month: 3, day: 9))
        record.birthday = DateComponents(year: 1990, month: 3, day: 9)
        #expect(GooglePersonMapper.createPayload(for: record).birthdays?.first?.date == GoogleDate(year: 1990, month: 3, day: 9))
    }

    // MARK: update payloads

    @Test("The update mask lists only modeled fields, adding clientData only when the ownership tag is written")
    func mask() throws {
        let existing = try full()
        let record = try #require(GooglePersonMapper.record(from: existing))
        let plain = GooglePersonMapper.updatePayload(for: record, existing: existing)
        #expect(plain.updatePersonFields == "names,nicknames,organizations,phoneNumbers,emailAddresses,addresses,urls,birthdays")
        #expect(plain.person.clientData == nil)
        #expect(plain.person.etag == existing.etag && plain.resourceName == existing.resourceName)

        let tagged = GooglePersonMapper.updatePayload(for: record, existing: existing, ownershipSourceID: "NEW-ID")
        #expect(tagged.updatePersonFields.hasSuffix(",clientData"))
        #expect(GooglePersonMapper.updatePersonFields(includingOwnershipTag: true) == tagged.updatePersonFields)
    }

    @Test("Updating keeps what the record cannot express: other names, department, PO box, other apps' client data")
    func updatePreserves() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.givenName = "Anne"
        record.jobTitle = "CEO"
        record.phones[0].value = "(415) 555-9999"
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing, ownershipSourceID: "NEW-ID").person

        #expect(payload.names?.count == 2)
        #expect(payload.names?[0].givenName == "Anne")
        #expect(payload.names?[0].middleName == "Marie" && payload.names?[0].honorificPrefix == "Dr.")
        #expect(payload.names?[0].phoneticGivenName == "An")
        #expect(payload.names?[0].displayName == nil)
        #expect(payload.names?[1].givenName == "Annie")
        #expect(payload.organizations?.first?.department == "R&D")
        #expect(payload.organizations?.first?.title == "CEO")
        #expect(payload.addresses?.first?.poBox == "PO 99")
        #expect(payload.phoneNumbers?[0].value == "(415) 555-9999")
        #expect(payload.phoneNumbers?[1].canonicalForm == "+12125553344")
        #expect(payload.clientData?.contains(GoogleClientData(key: "otherApp.note", value: "keep me")) == true)
        #expect(payload.contactBridgeSourceID == "NEW-ID")
        #expect(payload.clientData?.count == 2)
    }

    @Test("Update payload entries carry no metadata")
    func updateStripsMetadata() throws {
        let existing = try full()
        let record = try #require(GooglePersonMapper.record(from: existing))
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing).person
        #expect(payload.names?.allSatisfy { $0.metadata == nil } == true)
        #expect(payload.phoneNumbers?.allSatisfy { $0.metadata == nil } == true)
        #expect(payload.emailAddresses?.allSatisfy { $0.metadata == nil } == true)
        #expect(payload.addresses?.allSatisfy { $0.metadata == nil } == true)
        #expect(payload.organizations?.allSatisfy { $0.metadata == nil } == true)
    }

    @Test("Cleared fields are removed, but secondary entries survive")
    func updateClears() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.nickname = ""
        record.organization = ""
        record.jobTitle = ""
        record.phones = []
        record.birthday = nil
        record.givenName = ""
        record.middleName = ""
        record.familyName = ""
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing).person
        #expect(payload.nicknames?.isEmpty ?? true)
        #expect(payload.organizations?.isEmpty ?? true)
        #expect(payload.phoneNumbers?.isEmpty ?? true)
        #expect(payload.birthdays?.isEmpty ?? true)
        #expect(payload.names?.count == 1)
        #expect(payload.names?.first?.givenName == "Annie")
    }

    @Test("Update payload round-trips back to the edited record")
    func updateRoundTrip() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.emails.append(Labeled(label: "other", value: "new@x.com"))
        record.urls = []
        var stored = GooglePersonMapper.updatePayload(for: record, existing: existing).person
        stored.resourceName = record.id
        #expect(GooglePersonMapper.record(from: stored) == record)
    }

    // MARK: ownership tag

    @Test("The ownership tag reads, writes and replaces without disturbing other client data")
    func ownership() {
        #expect(GoogleOwnership.clientDataKey == "contactBridge.sourceID")
        var person = GooglePerson(clientData: [GoogleClientData(key: "other", value: "1")])
        #expect(GoogleOwnership.sourceID(of: person) == nil)
        GoogleOwnership.setSourceID("ICLOUD-1", on: &person)
        #expect(GoogleOwnership.sourceID(of: person) == "ICLOUD-1")
        GoogleOwnership.setSourceID("ICLOUD-2", on: &person)
        #expect(person.clientData?.map(\.key) == ["other", "contactBridge.sourceID"])
        #expect(person.contactBridgeSourceID == "ICLOUD-2")
        GoogleOwnership.setSourceID(nil, on: &person)
        #expect(person.clientData == [GoogleClientData(key: "other", value: "1")])
        var bare = GooglePerson()
        GoogleOwnership.setSourceID(nil, on: &bare)
        #expect(bare.clientData == nil)
    }

    @Test("A created payload can carry the iCloud identifier as the ownership tag")
    func createWithTag() {
        let record = ContactRecord(id: "x", source: .google, sourceIdentifier: "x", givenName: "Ann")
        let payload = GooglePersonMapper.createPayload(for: record, ownershipSourceID: "ICLOUD-9")
        #expect(payload.contactBridgeSourceID == "ICLOUD-9")
    }

    // MARK: unknown keys survive edits

    private func editedRecord(from existing: GooglePerson) throws -> ContactRecord {
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.givenName = "Anne"
        record.jobTitle = "CEO"
        record.phones[0].value = "(415) 555-9999"
        record.emails[0].value = "ann@new.example"
        record.urls[0].value = "https://example.com/new"
        record.postalAddresses[0].value.street = "2 Main St\nApt 3"
        record.birthday = DateComponents(year: 1991, month: 4, day: 10)
        return record
    }

    @Test("Edited entries keep every key the models do not declare")
    func unknownKeysSurviveEdits() throws {
        let existing = try full()
        let payload = GooglePersonMapper.updatePayload(for: try editedRecord(from: existing), existing: existing).person

        #expect(payload.names?[0].givenName == "Anne")
        #expect(payload.names?[0].extras["phoneticFullName"] == .string("An Mari Li"))
        #expect(payload.names?[0].extras["phoneticHonorificPrefix"] == .string("Dokutā"))
        let organization = try #require(payload.organizations?.first)
        #expect(organization.title == "CEO")
        #expect(organization.extras["jobDescription"] == .string("Runs engineering"))
        #expect(organization.extras["startDate"] == .object(["year": .int(2019), "month": .int(4)]))
        #expect(organization.extras["costCenter"] == .string("CC-1042") && organization.extras["location"] == .string("Austin HQ"))
        #expect(organization.extras["domain"] == .string("acme.com"))
        #expect(payload.phoneNumbers?[0].value == "(415) 555-9999")
        #expect(payload.phoneNumbers?[0].canonicalForm == nil)
        #expect(payload.phoneNumbers?[0].extras["futureField"] == .string("keep-phoneNumbers"))
        #expect(payload.emailAddresses?[0].value == "ann@new.example")
        #expect(payload.emailAddresses?[0].extras["futureField"] == .string("keep-emailAddresses"))
        #expect(payload.urls?[0].value == "https://example.com/new")
        #expect(payload.urls?[0].extras["futureField"] == .string("keep-urls"))
        let address = try #require(payload.addresses?.first)
        #expect(address.streetAddress == "2 Main St" && address.extendedAddress == "Apt 3")
        #expect(address.poBox == "PO 99" && address.formattedValue == nil)
        #expect(address.extras["futureField"] == .string("keep-addresses"))
        let birthday = try #require(payload.birthdays?.first)
        #expect(birthday.date == GoogleDate(year: 1991, month: 4, day: 10))
        #expect(birthday.extras["futureField"] == .string("keep-birthdays"))
    }

    @Test("An unedited record leaves entries exactly as fetched, minus metadata")
    func uneditedUnchanged() throws {
        let existing = try full()
        let record = try #require(GooglePersonMapper.record(from: existing))
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing).person
        var expectedPhone = try #require(existing.phoneNumbers?.first)
        expectedPhone.metadata = nil
        #expect(payload.phoneNumbers?.first == expectedPhone)
        var expectedAddress = try #require(existing.addresses?.first)
        expectedAddress.metadata = nil
        #expect(payload.addresses?.first == expectedAddress)
    }

    @Test("The encoded payload carries the unknown keys at entry level and no wrapper key")
    func payloadJSON() throws {
        let existing = try full()
        let payload = GooglePersonMapper.updatePayload(for: try editedRecord(from: existing), existing: existing).person
        let json = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        for key in ["phoneticFullName", "jobDescription", "costCenter", "startDate", "futureField", "poBox"] {
            #expect(json.contains(key), "missing \(key)")
        }
        #expect(!json.contains(#""extras""#))
        #expect(!json.contains("biographies"))
    }

    // MARK: read-only (non-CONTACT) entries

    @Test("Profile- and domain-sourced entries are ignored when mapping to a record")
    func profileEntriesIgnored() throws {
        let person = try GoogleFixtures.decode(GooglePerson.self, "person_profile_entries")
        let record = try #require(GooglePersonMapper.record(from: person))
        #expect(record.givenName == "Bo" && record.familyName == "Contact")
        #expect(record.organization == "Side Gig" && record.jobTitle == "Advisor")
        #expect(record.nickname == "")
        #expect(record.phones == [Labeled(label: "mobile", value: "+1 415 555 0001")])
        #expect(record.emails == [Labeled(label: "home", value: "bo@home.example")])
        #expect(record.postalAddresses.map(\.value.street) == ["5 Home St"])
        #expect(record.urls == [Labeled(label: "homepage", value: "https://bo.example")])
        #expect(record.birthday == nil)
    }

    @Test("Payloads never send read-only entries back as contact data")
    func profileEntriesNeverSent() throws {
        let person = try GoogleFixtures.decode(GooglePerson.self, "person_profile_entries")
        var record = try #require(GooglePersonMapper.record(from: person))
        record.emails[0].value = "bo@new.example"
        let update = GooglePersonMapper.updatePayload(for: record, existing: person)
        let json = String(decoding: try JSONEncoder().encode(update.person), as: UTF8.self)
        for forbidden in ["bo@corp.com", "Redmond", "corp.example", "Robert", "Corp Inc", "Bobby", "+1 415 555 0002"] {
            #expect(!json.contains(forbidden), "sent \(forbidden)")
        }
        #expect(update.person.emailAddresses?.map(\.value) == ["bo@new.example"])
        #expect(update.person.names?.count == 1)
        #expect(!update.updatePersonFields.contains("birthdays"))
    }

    // MARK: address matching

    @Test("Address matching ignores sub-locality, sub-administrative area and ISO case, so the PO box survives")
    func addressMatching() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.postalAddresses[0].value.subLocality = "Downtown"
        record.postalAddresses[0].value.subAdministrativeArea = "Travis"
        record.postalAddresses[0].value.isoCountryCode = "US"
        let reused = try #require(GooglePersonMapper.updatePayload(for: record, existing: existing).person.addresses?.first)
        #expect(reused.poBox == "PO 99" && reused.countryCode == "US")
        #expect(reused.extras["futureField"] == .string("keep-addresses"))
        #expect(reused.formattedValue != nil)
    }

    @Test("An edited address replaces its labelled match and carries the PO box forward")
    func editedAddressKeepsPOBox() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.postalAddresses[0].value.city = "Dallas"
        record.postalAddresses[0].value.isoCountryCode = "US"
        let edited = try #require(GooglePersonMapper.updatePayload(for: record, existing: existing).person.addresses)
        #expect(edited.count == 1)
        #expect(edited[0].city == "Dallas" && edited[0].poBox == "PO 99" && edited[0].countryCode == "US")
        #expect(edited[0].extras["futureField"] == .string("keep-addresses"))

        record.postalAddresses[0].label = "work"
        let relabelled = try #require(GooglePersonMapper.updatePayload(for: record, existing: existing).person.addresses)
        #expect(relabelled[0].poBox == nil && relabelled[0].type == "work")
    }

    // MARK: text-only birthdays

    @Test("A text-only Google birthday is left alone when the record has none")
    func textOnlyBirthdayUntouched() throws {
        let existing = try GoogleFixtures.decode(GooglePerson.self, "person_text_birthday")
        let record = try #require(GooglePersonMapper.record(from: existing))
        #expect(record.birthday == nil)
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing)
        #expect(!payload.updatePersonFields.split(separator: ",").contains("birthdays"))
        #expect(payload.person.birthdays == nil)
        #expect(payload.updatePersonFields == "names,nicknames,organizations,phoneNumbers,emailAddresses,addresses,urls")
    }

    @Test("A record birthday replaces a text-only one, keeping unknown keys")
    func textOnlyBirthdayReplaced() throws {
        let existing = try GoogleFixtures.decode(GooglePerson.self, "person_text_birthday")
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.birthday = DateComponents(month: 3, day: 9)
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing)
        #expect(payload.updatePersonFields.split(separator: ",").contains("birthdays"))
        #expect(payload.person.birthdays?.count == 1)
        #expect(payload.person.birthdays?[0].date == GoogleDate(month: 3, day: 9))
        #expect(payload.person.birthdays?[0].text == nil)
        #expect(payload.person.birthdays?[0].extras["futureField"] == .string("text-only"))
    }

    @Test("Clearing a dated birthday still sends an empty birthdays field")
    func clearingDatedBirthday() throws {
        let existing = try full()
        var record = try #require(GooglePersonMapper.record(from: existing))
        record.birthday = nil
        let payload = GooglePersonMapper.updatePayload(for: record, existing: existing)
        #expect(payload.updatePersonFields.split(separator: ",").contains("birthdays"))
        #expect(payload.person.birthdays?.isEmpty ?? true)
    }
}
