import Foundation
import Testing
@testable import ContactBridgeCore

struct AddressKeyTests {
    private func address(country: String, iso: String? = nil, street: String = "308 Liberty St") -> PostalAddress {
        PostalAddress(street: street, city: "Hutto", state: "TX", postalCode: "78634", country: country, isoCountryCode: iso)
    }

    private func key(_ address: PostalAddress) -> String? { MergePlan.addressKey(address) }

    @Test("US country spellings share one key")
    func usSpellings() {
        let usa = key(address(country: "USA"))
        for spelling in ["US", "U.S.", "U.S.A.", "United States", "United States of America", "united states", "  usa "] {
            #expect(key(address(country: spelling)) == usa, "\(spelling)")
        }
    }

    @Test("An ISO code wins over the country text, and matches a named country")
    func isoCode() {
        #expect(key(address(country: "United States", iso: "US")) == key(address(country: "USA")))
        #expect(key(address(country: "", iso: "us")) == key(address(country: "US")))
        #expect(key(address(country: "Anything", iso: "US")) == key(address(country: "USA")))
    }

    @Test("Other countries and common aliases map to their code; different countries stay different")
    func otherCountries() {
        #expect(key(address(country: "UK")) == key(address(country: "United Kingdom")))
        #expect(key(address(country: "Great Britain")) == key(address(country: "GB")))
        #expect(key(address(country: "Germany")) == key(address(country: "DE")))
        #expect(key(address(country: "Canada")) != key(address(country: "USA")))
    }

    @Test("An unknown country falls back to its folded text; blank stays blank")
    func unknown() {
        #expect(key(address(country: "Narnia")) == key(address(country: " NARNIA ")))
        #expect(key(address(country: "Narnia")) != key(address(country: "Lilliput")))
        #expect(key(address(country: "")) != key(address(country: "USA")))
    }

    @Test("Street line breaks and commas do not change the key")
    func lineBreaks() {
        #expect(key(address(country: "USA", street: "5020 N Hermitage Ave, Unit 3")) == key(address(country: "USA", street: "5020 N Hermitage Ave\nUnit 3")))
    }

    @Test("A merge dedupes the same address spelled with US and USA")
    func mergeDedupes() {
        let a = ContactRecord(id: "a", source: .icloud, sourceIdentifier: "a", postalAddresses: [Labeled(label: "home", value: address(country: "USA"))])
        let b = ContactRecord(id: "g1", source: .google, sourceIdentifier: "g1", postalAddresses: [Labeled(label: nil, value: address(country: "US"))])
        #expect(MergePlan.build(survivor: a, others: [b]).merged.postalAddresses.count == 1)
    }
}
