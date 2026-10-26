import Foundation
import Testing
@testable import ContactBridgeCore

struct GoogleFixtureTests {
    @Test("connections.list first page decodes with a page token and no sync token")
    func connectionsPage1() throws {
        let page = try GoogleFixtures.decode(GoogleConnectionsResponse.self, "connections_page1")
        let connections = try #require(page.connections)
        #expect(connections.count == 2)
        #expect(page.nextPageToken == "CgwI_9a7pAYQ4LuHtwM")
        #expect(page.nextSyncToken == nil)
        #expect(page.totalPeople == 3)

        let ann = connections[0]
        #expect(ann.resourceName == "people/c1234567890123456789")
        #expect(ann.etag == "%EgUBAj0LNy4=")
        #expect(ann.metadata?.sources?.first?.type == "CONTACT")
        #expect(ann.metadata?.sources?.first?.etag == "#kQz1x2mWc0Y=")
        #expect(ann.names?.first?.givenName == "Ann")
        #expect(ann.names?.first?.metadata?.primary == true)
        #expect(ann.phoneNumbers?.first?.canonicalForm == "+14155552671")
        #expect(ann.phoneNumbers?.first?.formattedType == "Mobile")
        #expect(ann.memberships?.first?.contactGroupMembership?.contactGroupResourceName == "contactGroups/myContacts")
        #expect(connections[1].organizations?.first?.name == "Acme Corp")
    }

    @Test("The last connections page carries the next sync token and a year-less birthday")
    func connectionsPage2() throws {
        let page = try GoogleFixtures.decode(GoogleConnectionsResponse.self, "connections_page2")
        #expect(page.nextPageToken == nil)
        #expect(page.nextSyncToken == "CMjZ0uDYo7oDEMjZ0uDYo7oD")
        let birthday = try #require(page.connections?.first?.birthdays?.first?.date)
        #expect(birthday.year == nil && birthday.month == 3 && birthday.day == 9)
    }

    @Test("A sync response lists deleted people as stubs")
    func syncDeleted() throws {
        let page = try GoogleFixtures.decode(GoogleConnectionsResponse.self, "connections_sync_deleted")
        let people = try #require(page.connections)
        #expect(people[0].isDeleted)
        #expect(people[0].names == nil)
        #expect(!people[1].isDeleted)
        #expect(GooglePersonMapper.record(from: people[0]) == nil)
        #expect(GooglePersonMapper.record(from: people[1])?.givenName == "Robert")
    }

    @Test("otherContacts.list decodes and maps to .googleOther records without inventing names")
    func otherContacts() throws {
        let page = try GoogleFixtures.decode(GoogleOtherContactsResponse.self, "other_contacts_page")
        let people = try #require(page.otherContacts)
        #expect(people.count == 2)
        #expect(page.nextPageToken == "CgwIsecondPage")
        #expect(GooglePeoplePage(page).people == people)

        let carol = try #require(GooglePersonMapper.record(from: people[0], source: .googleOther))
        #expect(carol.source == .googleOther)
        #expect(carol.id == "otherContacts/c7410852096318274" && carol.sourceIdentifier == carol.id)
        #expect(carol.givenName == "" && carol.familyName == "")
        #expect(carol.emails == [Labeled(label: nil, value: "carol@mail.example")])

        let dan = try #require(GooglePersonMapper.record(from: people[1], source: .googleOther))
        #expect(dan.givenName == "Dan" && dan.familyName == "Poe")
        #expect(dan.phones == [Labeled(label: nil, value: "212-555-3344")])
    }

    @Test("A person with every field decodes, ignoring fields the app does not model")
    func fullPerson() throws {
        let person = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        #expect(person.names?.count == 2)
        #expect(person.names?[0].honorificPrefix == "Dr.")
        #expect(person.nicknames?.first?.value == "Annie")
        #expect(person.organizations?.first?.department == "R&D")
        #expect(person.phoneNumbers?.count == 4)
        #expect(person.phoneNumbers?[2].type == "Cabin")
        #expect(person.emailAddresses?[0].displayName == "Ann Lee")
        let address = try #require(person.addresses?.first)
        #expect(address.streetAddress == "1 Main St" && address.extendedAddress == "Apt 2" && address.poBox == "PO 99")
        #expect(address.city == "Austin" && address.region == "TX" && address.postalCode == "78701")
        #expect(address.country == "United States" && address.countryCode == "US")
        #expect(person.urls?.count == 2)
        #expect(person.birthdays?.first?.date == GoogleDate(year: 1990, month: 3, day: 9))
        #expect(person.memberships?.count == 2)
        #expect(person.clientData?.map(\.key) == ["contactBridge.sourceID", "otherApp.note"])
        #expect(person.contactBridgeSourceID == "B1C2D3E4-ICLOUD-ID:ABPerson")
    }

    @Test("The full person maps to a ContactRecord with friendly labels and the primary name")
    func fullPersonRecord() throws {
        let person = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        let record = try #require(GooglePersonMapper.record(from: person))
        #expect(record.id == "people/c2468013579246801357")
        #expect(record.source == .google)
        #expect(record.sourceIdentifier == record.id)
        #expect(record.givenName == "Ann" && record.middleName == "Marie" && record.familyName == "Lee")
        #expect(record.nickname == "Annie" && record.organization == "Acme Corp" && record.jobTitle == "CTO")
        #expect(record.phones == [
            Labeled(label: "mobile", value: "(415) 555-2671"),
            Labeled(label: "home fax", value: "+1 212 555 3344"),
            Labeled(label: "Cabin", value: "555-0100"),
            Labeled(label: nil, value: "555-0101"),
        ])
        #expect(record.emails == [Labeled(label: "work", value: "ann@acme.com"), Labeled(label: "home", value: "Ann@Example.com")])
        #expect(record.urls == [
            Labeled(label: "homepage", value: "https://example.com/Ann"), Labeled(label: "blog", value: "https://blog.example.com"),
        ])
        #expect(record.postalAddresses == [
            Labeled(label: "home", value: PostalAddress(
                street: "1 Main St\nApt 2", city: "Austin", state: "TX", postalCode: "78701", country: "United States",
                isoCountryCode: "us"
            )),
        ])
        #expect(record.birthday == DateComponents(year: 1990, month: 3, day: 9))
    }

    // MARK: errors

    @Test("Error bodies map to typed errors")
    func errors() throws {
        #expect(GoogleAPIError.parse(status: 410, body: try GoogleFixtures.data("error_410")) == .syncTokenExpired)
        #expect(GoogleAPIError.parse(status: 400, body: try GoogleFixtures.data("error_400_expired_sync_token")) == .syncTokenExpired)
        #expect(GoogleAPIError.parse(status: 400, body: try GoogleFixtures.data("error_400_etag")) == .etagMismatch)
        #expect(GoogleAPIError.parse(status: 429, body: try GoogleFixtures.data("error_429")) == .rateLimited(retryAfter: nil))
        #expect(GoogleAPIError.parse(status: 429, body: try GoogleFixtures.data("error_429"), retryAfter: 12) == .rateLimited(retryAfter: 12))
        #expect(GoogleAPIError.parse(status: 404, body: try GoogleFixtures.data("error_404")) == .notFound)
        #expect(GoogleAPIError.parse(status: 401, body: try GoogleFixtures.data("error_401")) == .unauthorized)
    }

    @Test("Unrecognised or unparseable errors become .other with the status and message")
    func otherErrors() {
        let body = Data(#"{"error":{"code":500,"message":"Backend Error","status":"INTERNAL"}}"#.utf8)
        #expect(GoogleAPIError.parse(status: 500, body: body) == .other(status: 500, message: "Backend Error"))
        #expect(GoogleAPIError.parse(status: 502, body: Data("<html>Bad gateway</html>".utf8)) == .other(status: 502, message: "<html>Bad gateway</html>"))
        #expect(GoogleAPIError.parse(status: 429, body: Data()) == .rateLimited(retryAfter: nil))
    }

    @Test("Retry-After header values parse as seconds")
    func retryAfter() {
        #expect(GoogleAPIError.retryAfter(fromHeader: "30") == 30)
        #expect(GoogleAPIError.retryAfter(fromHeader: " 2.5 ") == 2.5)
        #expect(GoogleAPIError.retryAfter(fromHeader: nil) == nil)
        #expect(GoogleAPIError.retryAfter(fromHeader: "not a delay") == nil)
    }

    @Test("Retry-After also accepts an HTTP-date, as seconds from now (never negative)")
    func retryAfterHTTPDate() throws {
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-21T07:27:30Z"))
        #expect(GoogleAPIError.retryAfter(fromHeader: "Wed, 21 Oct 2026 07:28:00 GMT", now: now) == 30)
        #expect(GoogleAPIError.retryAfter(fromHeader: "Wednesday, 21-Oct-26 07:28:00 GMT", now: now) == 30)
        #expect(GoogleAPIError.retryAfter(fromHeader: "Wed Oct 21 07:28:00 2026", now: now) == 30)
        #expect(GoogleAPIError.retryAfter(fromHeader: "Wed, 21 Oct 2026 07:00:00 GMT", now: now) == 0)
        #expect(GoogleAPIError.retryAfter(fromHeader: "-5", now: now) == 0)
        #expect(GoogleAPIError.retryAfter(fromHeader: "soon", now: now) == nil)
    }

    // MARK: unknown keys

    @Test("Keys the DTOs do not model are captured on entries and the person, and re-encoded")
    func extrasCaptured() throws {
        let person = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        #expect(person.names?[0].extras["phoneticFullName"] == .string("An Mari Li"))
        #expect(person.names?[0].extras["phoneticHonorificPrefix"] == .string("Dokutā"))
        let organization = try #require(person.organizations?.first)
        #expect(organization.extras["jobDescription"] == .string("Runs engineering"))
        #expect(organization.extras["startDate"] == .object(["year": .int(2019), "month": .int(4)]))
        #expect(Set(organization.extras.keys) == ["jobDescription", "startDate", "location", "costCenter", "domain", "symbol", "phoneticName"])
        #expect(person.phoneNumbers?[0].extras == ["futureField": .string("keep-phoneNumbers")])
        #expect(person.emailAddresses?[0].extras == ["futureField": .string("keep-emailAddresses")])
        #expect(person.urls?[0].extras == ["futureField": .string("keep-urls")])
        #expect(person.addresses?[0].extras == ["futureField": .string("keep-addresses")])
        #expect(person.birthdays?[0].extras == ["futureField": .string("keep-birthdays")])
        #expect(person.extras["biographies"] != nil)
        #expect(person.names?[0].extras["givenName"] == nil && person.phoneNumbers?[0].extras["value"] == nil)

        let again = try JSONDecoder().decode(GooglePerson.self, from: JSONEncoder().encode(person))
        #expect(again == person)
        let json = String(decoding: try JSONEncoder().encode(person), as: UTF8.self)
        #expect(json.contains("phoneticFullName") && json.contains("costCenter") && json.contains("biographies"))
        #expect(!json.contains(#""extras""#))
    }

    @Test("Numbers, booleans, nulls and nesting in unknown keys round-trip")
    func jsonValues() throws {
        let body = Data(#"{"names":[{"givenName":"A","x":{"a":[1,2.5,true,null,"s"],"n":{"m":-3}}}]}"#.utf8)
        let person = try JSONDecoder().decode(GooglePerson.self, from: body)
        #expect(person.names?[0].extras["x"] == .object([
            "a": .array([.int(1), .double(2.5), .bool(true), .null, .string("s")]),
            "n": .object(["m": .int(-3)]),
        ]))
        #expect(try JSONDecoder().decode(GooglePerson.self, from: JSONEncoder().encode(person)) == person)
    }

    // MARK: error classification details

    @Test("FAILED_PRECONDITION is an etag mismatch only when the message says etag; other preconditions are .other")
    func preconditions() throws {
        #expect(GoogleAPIError.parse(status: 400, body: try GoogleFixtures.data("error_400_group_full"))
            == .other(status: 400, message: "Contact group is full. Remove members before adding more."))
    }

    @Test("A sync-token message means expired even without ErrorInfo")
    func syncTokenMessage() throws {
        #expect(GoogleAPIError.parse(status: 400, body: try GoogleFixtures.data("error_400_sync_token_no_info")) == .syncTokenExpired)
    }

    @Test("403 with a rate-limit reason (legacy errors[] or ErrorInfo) is rate limiting; other 403s are not")
    func forbiddenRateLimits() throws {
        #expect(GoogleAPIError.parse(status: 403, body: try GoogleFixtures.data("error_403_rate_limit")) == .rateLimited(retryAfter: nil))
        #expect(GoogleAPIError.parse(status: 403, body: try GoogleFixtures.data("error_403_user_rate_limit"), retryAfter: 4) == .rateLimited(retryAfter: 4))
        let errorInfo = Data(#"{"error":{"code":403,"message":"Quota","status":"PERMISSION_DENIED","details":[{"reason":"RATE_LIMIT_EXCEEDED"}]}}"#.utf8)
        #expect(GoogleAPIError.parse(status: 403, body: errorInfo) == .rateLimited(retryAfter: nil))
        guard case .other(let status, _) = GoogleAPIError.parse(status: 403, body: try GoogleFixtures.data("error_403_forbidden")) else {
            Issue.record("expected .other")
            return
        }
        #expect(status == 403)
    }
}
