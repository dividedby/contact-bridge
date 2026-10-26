import Contacts
import Foundation
import Testing
@testable import ContactBridgeCore

struct VCardWriterTests {
    private let photo = Data((0..<400).map { UInt8($0 % 251) })

    private func contact() -> CNMutableContact {
        let c = CNMutableContact()
        c.namePrefix = "Dr."
        c.givenName = "Ann"
        c.middleName = "Marie"
        c.familyName = "Lee"
        c.nameSuffix = "PhD"
        c.nickname = "Annie"
        c.organizationName = "Acme; Inc, East"
        c.departmentName = "R&D"
        c.jobTitle = "CTO"
        c.phoneticGivenName = "An"
        c.phoneticFamilyName = "Li"
        c.previousFamilyName = "Smith"
        c.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "(415) 555-2671")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "+1 212 555 3344")),
            CNLabeledValue(label: "Cabin", value: CNPhoneNumber(stringValue: "555-0100")),
            CNLabeledValue(label: nil, value: CNPhoneNumber(stringValue: "555-0101")),
        ]
        c.emailAddresses = [
            CNLabeledValue(label: CNLabelHome, value: "ann@example.com" as NSString),
            CNLabeledValue(label: CNLabelOther, value: "ann@other.example" as NSString),
        ]
        c.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://example.com/Ann" as NSString)]
        let address = CNMutablePostalAddress()
        address.street = "1 Main St\nApt 2"
        address.city = "Austin"
        address.state = "TX"
        address.postalCode = "78701"
        address.country = "United States"
        address.isoCountryCode = "us"
        c.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: address)]
        c.birthday = DateComponents(calendar: Calendar(identifier: .gregorian), year: 1990, month: 3, day: 9)
        c.instantMessageAddresses = [CNLabeledValue(label: CNLabelHome, value: CNInstantMessageAddress(username: "ann", service: "Skype"))]
        c.socialProfiles = [
            CNLabeledValue(label: nil, value: CNSocialProfile(urlString: "https://twitter.com/ann", username: "ann", userIdentifier: nil, service: "Twitter")),
        ]
        c.contactRelations = [CNLabeledValue(label: CNLabelContactRelationSpouse, value: CNContactRelation(name: "Bo"))]
        c.dates = [CNLabeledValue(label: CNLabelDateAnniversary, value: DateComponents(year: 2010, month: 6, day: 1) as NSDateComponents)]
        c.imageData = photo
        return c
    }

    private func text(_ contacts: [CNContact]) -> String {
        String(decoding: VCardWriter.data(for: contacts), as: UTF8.self)
    }

    @Test("Writes a vCard 3.0 with every fetched field")
    func fields() {
        let out = text([contact()])
        let unfolded = out.replacing("\r\n ", with: "")
        #expect(out.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0\r\n"))
        #expect(out.hasSuffix("END:VCARD\r\n"))
        for expected in [
            "N:Lee;Ann;Marie;Dr.;PhD", "FN:Dr. Ann Marie Lee PhD", "NICKNAME:Annie", #"ORG:Acme\; Inc\, East;R&D"#, "TITLE:CTO",
            "X-PHONETIC-FIRST-NAME:An", "X-PHONETIC-LAST-NAME:Li", "X-PREVIOUS-FAMILY-NAME:Smith",
            "TEL;TYPE=CELL:(415) 555-2671", "TEL;TYPE=WORK:+1 212 555 3344",
            "EMAIL;TYPE=HOME:ann@example.com", "BDAY:1990-03-09",
            #"ADR;TYPE=HOME:;;1 Main St\nApt 2;Austin;TX;78701;United States"#,
            "X-ABRELATEDNAMES", "X-ABDATE", "X-SOCIALPROFILE", "IMPP",
            "PHOTO;ENCODING=b;TYPE=JPEG:" + photo.base64EncodedString(),
        ] {
            #expect(unfolded.contains(expected), "missing \(expected)")
        }
        #expect(unfolded.contains("X-ABLabel:Cabin"))
    }

    @Test("Long lines are folded at 75 characters and escaped values never break a line")
    func folding() {
        let out = text([contact()])
        for line in out.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 75, "too long: \(line.prefix(40))") }
        #expect(!out.contains("\n\n"))
    }

    @Test("Several contacts are written back to back; year-less birthdays use Apple's omit-year convention")
    func multiple() {
        let a = CNMutableContact()
        a.givenName = "Ann"
        a.birthday = DateComponents(calendar: Calendar(identifier: .gregorian), month: 3, day: 9)
        let b = CNMutableContact()
        b.organizationName = "Acme"
        let out = text([a, b])
        #expect(out.components(separatedBy: "BEGIN:VCARD").count == 3)
        #expect(out.contains("BDAY;X-APPLE-OMIT-YEAR=1604:1604-03-09"))
        #expect(out.contains("FN:Acme"))
        #expect(VCardWriter.data(for: []).isEmpty)
    }

    @Test("Apple's own parser reads the output back")
    func roundTripsThroughCNParser() throws {
        let original = contact()
        let parsed = try CNContactVCardSerialization.contacts(with: VCardWriter.data(for: [original]))
        #expect(parsed.count == 1)
        let c = try #require(parsed.first)
        #expect(c.namePrefix == "Dr." && c.givenName == "Ann" && c.middleName == "Marie" && c.familyName == "Lee")
        #expect(c.nameSuffix == "PhD" && c.nickname == "Annie")
        #expect(c.organizationName == "Acme; Inc, East" && c.jobTitle == "CTO")
        #expect(c.phoneNumbers.map(\.value.stringValue) == ["(415) 555-2671", "+1 212 555 3344", "555-0100", "555-0101"])
        // The parser reports an unlabeled entry as an empty label.
        #expect(c.phoneNumbers.map { $0.label ?? "" } == [CNLabelPhoneNumberMobile, CNLabelWork, "Cabin", ""])
        #expect(c.emailAddresses.map { $0.value as String } == ["ann@example.com", "ann@other.example"])
        #expect(c.emailAddresses.map(\.label) == [CNLabelHome, CNLabelOther])
        #expect(c.urlAddresses.map { $0.value as String } == ["https://example.com/Ann"])
        let address = try #require(c.postalAddresses.first?.value)
        #expect(address.street == "1 Main St\nApt 2" && address.city == "Austin" && address.state == "TX")
        #expect(address.postalCode == "78701" && address.country == "United States")
        #expect(c.birthday?.year == 1990 && c.birthday?.month == 3 && c.birthday?.day == 9)
        #expect(c.imageData == photo)
    }
}
