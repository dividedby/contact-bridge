import Foundation
import Testing
@testable import ContactBridgeCore

struct ContactRecordTests {
    @Test("Defaults produce an empty record")
    func defaults() {
        let record = ContactRecord(id: "1", source: .google, sourceIdentifier: "people/c1")
        #expect(record.givenName == "")
        #expect(record.phones.isEmpty)
        #expect(record.emails.isEmpty)
        #expect(record.postalAddresses.isEmpty)
        #expect(record.urls.isEmpty)
        #expect(record.birthday == nil)
        #expect(record.isEmpty)
    }

    @Test("Normalized accessors skip empty values and carry labels' values only")
    func normalizedAccessors() {
        let record = ContactRecord(
            id: "1", source: .icloud, sourceIdentifier: "A",
            givenName: "Ann",
            phones: [
                Labeled(label: "mobile", value: "(415) 555-2671"),
                Labeled(label: nil, value: ""),
                Labeled(label: "work", value: "911"),
            ],
            emails: [
                Labeled(label: "home", value: " Ann@Example.com "),
                Labeled(label: nil, value: "  "),
            ]
        )
        #expect(!record.isEmpty)
        #expect(record.normalizedPhones.map(\.value) == ["+14155552671", "911"])
        #expect(record.normalizedPhones.map(\.isNormalizable) == [true, false])
        #expect(record.normalizedEmails == ["ann@example.com"])
    }

    @Test("Birthday keeps year-less dates")
    func yearlessBirthday() {
        let record = ContactRecord(
            id: "1", source: .icloud, sourceIdentifier: "A",
            birthday: DateComponents(month: 3, day: 14)
        )
        #expect(record.birthday?.year == nil)
        #expect(record.birthday?.month == 3)
    }

    @Test("Round-trips through Codable")
    func codable() throws {
        let record = ContactRecord(
            id: "1", source: .googleOther, sourceIdentifier: "otherContacts/c9",
            givenName: "Zoë", organization: "Acme",
            postalAddresses: [Labeled(label: "home", value: PostalAddress(street: "1 Main St", city: "Austin", state: "TX", postalCode: "78701", country: "US"))],
            urls: [Labeled(label: nil, value: "https://example.com")],
            birthday: DateComponents(year: 1990, month: 1, day: 2)
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(ContactRecord.self, from: data) == record)
    }
}
