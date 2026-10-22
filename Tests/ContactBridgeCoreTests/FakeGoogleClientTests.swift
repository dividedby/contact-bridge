import Foundation
import Testing
@testable import ContactBridgeCore

struct FakeGoogleClientTests {
    private func person(_ given: String, email: String? = nil) -> GooglePerson {
        GooglePerson(
            names: [GoogleName(givenName: given, familyName: "Test")],
            emailAddresses: email.map { [GoogleEmailAddress(value: $0, type: "home")] }
        )
    }

    private func fullList(_ client: FakeGoogleClient, syncToken: String? = nil) async throws -> (people: [GooglePerson], syncToken: String?) {
        var people: [GooglePerson] = []
        var pageToken: String?
        while true {
            let page = try await client.listConnections(syncToken: syncToken, pageToken: pageToken)
            people += page.people
            if page.nextPageToken == nil { return (people, page.nextSyncToken) }
            pageToken = page.nextPageToken
        }
    }

    // MARK: listing and sync

    @Test("Connections paginate, and the sync token appears only on the last page")
    func pagination() async throws {
        let client = FakeGoogleClient(people: (0..<5).map { person("P\($0)") }, pageSize: 2)
        let first = try await client.listConnections(syncToken: nil, pageToken: nil)
        #expect(first.people.count == 2 && first.nextPageToken != nil && first.nextSyncToken == nil)
        let second = try await client.listConnections(syncToken: nil, pageToken: first.nextPageToken)
        #expect(second.people.count == 2 && second.nextSyncToken == nil)
        let third = try await client.listConnections(syncToken: nil, pageToken: second.nextPageToken)
        #expect(third.people.count == 1 && third.nextPageToken == nil && third.nextSyncToken != nil)

        let all = try await fullList(client)
        #expect(all.people.compactMap { $0.names?.first?.givenName } == ["P0", "P1", "P2", "P3", "P4"])
        #expect(all.people.allSatisfy { $0.resourceName?.hasPrefix("people/c") == true && $0.etag != nil })
    }

    @Test("A sync token returns only what changed, with deleted people as stubs")
    func syncChanges() async throws {
        let client = FakeGoogleClient(people: [person("A"), person("B"), person("C")], pageSize: 2)
        let initial = try await fullList(client)
        let token = try #require(initial.syncToken)
        let a = try #require(initial.people[0].resourceName)
        let b = try #require(initial.people[1].resourceName)
        let c = try #require(initial.people[2].resourceName)

        var changedB = initial.people[1]
        changedB.names = [GoogleName(givenName: "Bee", familyName: "Test")]
        _ = try await client.updateContact(resourceName: b, etag: try #require(changedB.etag), person: changedB, updatePersonFields: "names")
        try await client.deleteContact(resourceName: c)
        let created = try await client.createContact(person("D"))

        let delta = try await fullList(client, syncToken: token)
        #expect(Set(delta.people.compactMap(\.resourceName)) == [b, c, try #require(created.resourceName)])
        #expect(!delta.people.contains { $0.resourceName == a })
        let stub = try #require(delta.people.first { $0.resourceName == c })
        #expect(stub.isDeleted && stub.names == nil)
        #expect(delta.people.first { $0.resourceName == b }?.names?.first?.givenName == "Bee")

        let newToken = try #require(delta.syncToken)
        #expect(newToken != token)
        let quiet = try await fullList(client, syncToken: newToken)
        #expect(quiet.people.isEmpty)
        #expect(quiet.syncToken != nil)
    }

    @Test("A person created then deleted since the token shows up as deleted")
    func createdThenDeleted() async throws {
        let client = FakeGoogleClient(people: [person("A")])
        let token = try #require(try await fullList(client).syncToken)
        let created = try await client.createContact(person("Temp"))
        let name = try #require(created.resourceName)
        try await client.deleteContact(resourceName: name)
        let delta = try await fullList(client, syncToken: token)
        #expect(delta.people.map(\.resourceName) == [name])
        #expect(delta.people[0].isDeleted)
    }

    @Test("Expired tokens fail with syncTokenExpired, and a fresh full sync works again")
    func expiry() async throws {
        let client = FakeGoogleClient(people: [person("A")])
        let token = try #require(try await fullList(client).syncToken)
        await client.expireSyncTokens()
        await #expect(throws: GoogleAPIError.syncTokenExpired) { try await client.listConnections(syncToken: token, pageToken: nil) }
        let fresh = try await fullList(client)
        let newToken = try #require(fresh.syncToken)
        #expect(fresh.people.count == 1)
        #expect(try await fullList(client, syncToken: newToken).people.isEmpty)
    }

    @Test("Other contacts paginate and have no sync token semantics to break")
    func otherContacts() async throws {
        let others = (0..<3).map { GooglePerson(emailAddresses: [GoogleEmailAddress(value: "o\($0)@x.com")]) }
        let client = FakeGoogleClient(otherContacts: others, pageSize: 2)
        let first = try await client.listOtherContacts(pageToken: nil)
        #expect(first.people.count == 2 && first.nextPageToken != nil)
        let second = try await client.listOtherContacts(pageToken: first.nextPageToken)
        #expect(second.people.count == 1 && second.nextPageToken == nil)
        #expect(first.people.allSatisfy { $0.resourceName?.hasPrefix("otherContacts/") == true })
    }

    // MARK: single writes

    @Test("Every write bumps the etag; create assigns identity")
    func etags() async throws {
        let client = FakeGoogleClient()
        let created = try await client.createContact(person("A"))
        let name = try #require(created.resourceName)
        let etag1 = try #require(created.etag)
        #expect(name.hasPrefix("people/c"))

        var edit = created
        edit.names = [GoogleName(givenName: "B", familyName: "Test")]
        let updated = try await client.updateContact(resourceName: name, etag: etag1, person: edit, updatePersonFields: "names")
        let etag2 = try #require(updated.etag)
        #expect(etag2 != etag1)
        #expect(try await client.getPerson(resourceName: name).etag == etag2)
    }

    @Test("Updates with a stale etag fail and change nothing")
    func staleEtag() async throws {
        let client = FakeGoogleClient()
        let created = try await client.createContact(person("A"))
        let name = try #require(created.resourceName)
        var edit = created
        edit.names = [GoogleName(givenName: "B")]
        _ = try await client.updateContact(resourceName: name, etag: try #require(created.etag), person: edit, updatePersonFields: "names")
        await #expect(throws: GoogleAPIError.etagMismatch) {
            try await client.updateContact(resourceName: name, etag: try #require(created.etag), person: edit, updatePersonFields: "names")
        }
        #expect(try await client.getPerson(resourceName: name).names?.first?.givenName == "B")
    }

    @Test("updatePersonFields limits what changes; a masked field missing from the body is cleared")
    func maskSemantics() async throws {
        let client = FakeGoogleClient(people: [
            GooglePerson(
                names: [GoogleName(givenName: "A")], nicknames: [GoogleNickname(value: "Ay")],
                phoneNumbers: [GooglePhoneNumber(value: "555-0100")], clientData: [GoogleClientData(key: "k", value: "v")]
            ),
        ])
        let existing = try #require(try await fullList(client).people.first)
        let name = try #require(existing.resourceName)
        var body = GooglePerson(etag: existing.etag)
        body.names = [GoogleName(givenName: "Z")]
        body.phoneNumbers = [GooglePhoneNumber(value: "should be ignored")]
        let updated = try await client.updateContact(
            resourceName: name, etag: try #require(existing.etag), person: body, updatePersonFields: "names,nicknames"
        )
        #expect(updated.names?.first?.givenName == "Z")
        #expect(updated.nicknames == nil)
        #expect(updated.phoneNumbers?.first?.value == "555-0100")
        #expect(updated.clientData == [GoogleClientData(key: "k", value: "v")])

        await #expect(throws: GoogleAPIError.other(status: 400, message: "Invalid updatePersonFields: bogus")) {
            try await client.updateContact(resourceName: name, etag: try #require(updated.etag), person: body, updatePersonFields: "bogus")
        }
    }

    @Test("Missing people give notFound")
    func notFound() async throws {
        let client = FakeGoogleClient(otherContacts: [GooglePerson(emailAddresses: [GoogleEmailAddress(value: "o@x.com")])])
        await #expect(throws: GoogleAPIError.notFound) { try await client.getPerson(resourceName: "people/c404") }
        await #expect(throws: GoogleAPIError.notFound) { try await client.deleteContact(resourceName: "people/c404") }
        await #expect(throws: GoogleAPIError.notFound) {
            try await client.updateContact(resourceName: "people/c404", etag: "e", person: GooglePerson(), updatePersonFields: "names")
        }
        let other = try #require(try await client.listOtherContacts(pageToken: nil).people.first?.resourceName)
        #expect(try await client.getPerson(resourceName: other).emailAddresses?.first?.value == "o@x.com")
    }

    // MARK: batches

    @Test("Batches are chunked at 200 per call and results keep input order")
    func batchChunking() async throws {
        let client = FakeGoogleClient()
        let results = try await client.batchCreate((0..<450).map { person("P\($0)") })
        #expect(results.count == 450)
        #expect(results.allSatisfy { $0.error == nil && $0.person?.resourceName != nil })
        #expect(results.compactMap { $0.person?.names?.first?.givenName } == (0..<450).map { "P\($0)" })
        #expect(await client.batchCallSizes(.batchCreate) == [200, 200, 50])
        #expect(try await fullList(client).people.count == 450)

        let names = results.compactMap(\.resourceName)
        try await client.batchDelete(names)
        #expect(await client.batchCallSizes(.batchDelete) == [200, 200, 50])
        #expect(try await fullList(client).people.isEmpty)
    }

    @Test("Empty batches make no calls")
    func emptyBatch() async throws {
        let client = FakeGoogleClient()
        #expect(try await client.batchCreate([]).isEmpty)
        try await client.batchDelete([])
        #expect(try await client.batchUpdate([]).isEmpty)
        #expect(await client.batchCallSizes(.batchCreate).isEmpty)
    }

    @Test("Batch updates report per-item etag mismatches and not-founds")
    func batchUpdateItems() async throws {
        let client = FakeGoogleClient(people: [person("A"), person("B")])
        let people = try await fullList(client).people
        func update(_ source: GooglePerson, etag: String? = nil, given: String) -> GoogleContactUpdate {
            var body = source
            body.names = [GoogleName(givenName: given)]
            return GoogleContactUpdate(
                resourceName: source.resourceName ?? "", etag: etag ?? source.etag ?? "", person: body, updatePersonFields: "names"
            )
        }
        let results = try await client.batchUpdate([
            update(people[0], given: "A2"),
            update(people[1], etag: "stale", given: "B2"),
            GoogleContactUpdate(resourceName: "people/c404", etag: "e", person: GooglePerson(), updatePersonFields: "names"),
        ])
        #expect(results.map(\.error) == [nil, .etagMismatch, .notFound])
        #expect(results[0].person?.names?.first?.givenName == "A2")
        let after = try await fullList(client).people
        #expect(after.compactMap { $0.names?.first?.givenName } == ["A2", "B"])
    }

    @Test("Each update is applied with its own mask: a text-only birthday survives next to a dated one")
    func batchUpdatePerUpdateMasks() async throws {
        let textOnly = try GoogleFixtures.decode(GooglePerson.self, "person_text_birthday")
        let dated = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        let client = FakeGoogleClient(people: [textOnly, dated])
        let fetched = try await fullList(client).people

        var updates: [GoogleContactUpdate] = []
        for person in fetched {
            var record = try #require(GooglePersonMapper.record(from: person))
            record.givenName = "Edited" + record.givenName
            let payload = GooglePersonMapper.updatePayload(for: record, existing: person)
            updates.append(GoogleContactUpdate(
                resourceName: try #require(person.resourceName), etag: try #require(person.etag),
                person: payload.person, updatePersonFields: payload.updatePersonFields
            ))
        }
        #expect(updates[0].updatePersonFields != updates[1].updatePersonFields)

        let results = try await client.batchUpdate(updates)
        #expect(results.allSatisfy { $0.error == nil })
        let after = try await fullList(client).people
        #expect(after[0].birthdays?.first?.text == "March 9th")
        #expect(after[0].names?.first?.givenName == "EditedTex")
        #expect(after[1].birthdays?.first?.date == GoogleDate(year: 1990, month: 3, day: 9))
        #expect(after[1].names?.first?.givenName == "EditedAnn")
    }

    @Test("Updates are grouped by identical mask, then chunked at 200 within each group; results keep input order")
    func batchUpdateGrouping() async throws {
        let client = FakeGoogleClient(people: (0..<450).map { person("P\($0)") })
        let people = try await fullList(client).people
        func update(_ index: Int, mask: String) -> GoogleContactUpdate {
            var body = people[index]
            body.names = [GoogleName(givenName: "U\(index)")]
            return GoogleContactUpdate(resourceName: people[index].resourceName ?? "", etag: people[index].etag ?? "", person: body, updatePersonFields: mask)
        }
        // 50 updates with "names,nicknames" interleaved among 400 with "names": groups run in order of first appearance.
        var updates: [GoogleContactUpdate] = []
        for index in 0..<450 { updates.append(update(index, mask: index % 9 == 0 ? "names,nicknames" : "names")) }
        let results = try await client.batchUpdate(updates)
        #expect(results.count == 450)
        #expect(results.map(\.resourceName) == updates.map(\.resourceName))
        #expect(results.allSatisfy { $0.error == nil })
        let namesOnly = updates.filter { $0.updatePersonFields == "names" }.count
        let both = 450 - namesOnly
        #expect(await client.batchCallSizes(.batchUpdate) == [both, 200, namesOnly - 200])
        #expect(try await fullList(client).people.compactMap { $0.names?.first?.givenName } == (0..<450).map { "U\($0)" })
    }

    @Test("A batch delete naming a missing person fails the whole call and deletes nothing in it")
    func batchDeleteFailsWhole() async throws {
        let client = FakeGoogleClient(people: [person("A"), person("B")])
        let names = try await fullList(client).people.compactMap(\.resourceName)
        await #expect(throws: GoogleAPIError.notFound) { try await client.batchDelete([names[0], "people/c404", names[1]]) }
        #expect(try await fullList(client).people.count == 2)
        try await client.batchDelete(names)
        #expect(try await fullList(client).people.isEmpty)
    }

    // MARK: failure injection

    @Test("Rate limiting can be injected once or repeatedly, per operation")
    func rateLimit() async throws {
        let client = FakeGoogleClient(people: [person("A")])
        await client.inject(.rateLimited(retryAfter: 3), on: .listConnections, times: 2)
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: 3)) { try await client.listConnections(syncToken: nil, pageToken: nil) }
        _ = try await client.listOtherContacts(pageToken: nil)
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: 3)) { try await client.listConnections(syncToken: nil, pageToken: nil) }
        #expect(try await client.listConnections(syncToken: nil, pageToken: nil).people.count == 1)
    }

    @Test("An injected failure on a write has no side effects")
    func injectedWriteFailure() async throws {
        let client = FakeGoogleClient()
        await client.inject(.etagMismatch, on: .createContact)
        await #expect(throws: GoogleAPIError.etagMismatch) { try await client.createContact(person("A")) }
        #expect(try await fullList(client).people.isEmpty)
        _ = try await client.createContact(person("A"))
        #expect(try await fullList(client).people.count == 1)
    }

    @Test("A failure with no operation filter hits whatever is called next")
    func anyOperation() async throws {
        let client = FakeGoogleClient()
        await client.inject(.error(.unauthorized))
        await #expect(throws: GoogleAPIError.unauthorized) { try await client.getPerson(resourceName: "people/c1") }
        await #expect(throws: GoogleAPIError.notFound) { try await client.getPerson(resourceName: "people/c1") }
    }

    @Test("Partial batch failures fail only the chosen items of the next batch call")
    func partialBatch() async throws {
        let client = FakeGoogleClient()
        await client.inject(.partialBatch(indices: [1, 3], error: .rateLimited(retryAfter: nil)), on: .batchCreate)
        let results = try await client.batchCreate((0..<5).map { person("P\($0)") })
        #expect(results.map { $0.error == nil } == [true, false, true, false, true])
        #expect(results[1].error == .rateLimited(retryAfter: nil))
        #expect(results[1].person == nil)
        #expect(try await fullList(client).people.compactMap { $0.names?.first?.givenName } == ["P0", "P2", "P4"])

        let again = try await client.batchCreate([person("Q")])
        #expect(again.allSatisfy { $0.error == nil })
    }

    // MARK: groups

    @Test("ensureGroup is idempotent and addMembers adds memberships and bumps etags")
    func groups() async throws {
        let client = FakeGoogleClient(people: [person("A"), person("B")])
        let group = try await client.ensureGroup(named: "Contact Bridge")
        #expect(group.hasPrefix("contactGroups/"))
        #expect(try await client.ensureGroup(named: "Contact Bridge") == group)
        #expect(try await client.ensureGroup(named: "Other") != group)

        let before = try await fullList(client).people
        let names = before.compactMap(\.resourceName)
        try await client.addMembers(groupResourceName: group, memberResourceNames: [names[0]])
        try await client.addMembers(groupResourceName: group, memberResourceNames: [names[0]])
        let a = try await client.getPerson(resourceName: names[0])
        #expect(a.memberships?.count == 1)
        #expect(a.memberships?.first?.contactGroupMembership?.contactGroupResourceName == group)
        #expect(a.etag != before[0].etag)
        #expect(try await client.getPerson(resourceName: names[1]).etag == before[1].etag)

        await #expect(throws: GoogleAPIError.notFound) { try await client.addMembers(groupResourceName: "contactGroups/nope", memberResourceNames: names) }
        await #expect(throws: GoogleAPIError.notFound) { try await client.addMembers(groupResourceName: group, memberResourceNames: ["people/c404"]) }
    }

    // MARK: server-computed fields

    @Test("Writes stamp the fields Google computes: primary flags, sources, canonical forms, display names")
    func stamping() async throws {
        let client = FakeGoogleClient()
        let created = try await client.createContact(GooglePerson(
            names: [GoogleName(givenName: "Ann", familyName: "Lee")],
            organizations: [GoogleOrganization(name: "Acme", title: "CTO")],
            phoneNumbers: [
                GooglePhoneNumber(value: "(415) 555-2671", type: "homeFax"), GooglePhoneNumber(value: "555-1234", type: "Cabin"),
                GooglePhoneNumber(value: "212-555-3344", type: "mobile"),
            ],
            emailAddresses: [GoogleEmailAddress(value: "a@x.com", type: "home"), GoogleEmailAddress(value: "b@x.com")]
        ))
        let name = try #require(created.resourceName)
        let id = String(name.dropFirst("people/".count))

        #expect(created.metadata?.objectType == "PERSON")
        let source = try #require(created.metadata?.sources?.first)
        #expect(source.type == "CONTACT" && source.id == id && source.etag != nil && source.updateTime != nil)

        let first = try #require(created.names?.first)
        #expect(first.metadata?.primary == true)
        #expect(first.metadata?.source?.type == "CONTACT" && first.metadata?.source?.id == id)
        #expect(first.displayName == "Ann Lee" && first.displayNameLastFirst == "Lee, Ann" && first.unstructuredName == "Ann Lee")
        #expect(created.organizations?.first?.metadata?.primary == true)

        let phones = try #require(created.phoneNumbers)
        #expect(phones.map(\.canonicalForm) == ["+14155552671", nil, "+12125553344"])
        #expect(phones.map(\.formattedType) == ["Home Fax", "Cabin", "Mobile"])
        #expect(phones.map { $0.metadata?.primary } == [true, nil, nil])
        #expect(phones.allSatisfy { $0.metadata?.source?.type == "CONTACT" && $0.metadata?.source?.id == id })
        #expect(created.emailAddresses?.map(\.formattedType) == ["Home", nil])
        #expect(created.emailAddresses?.first?.displayName == "Ann Lee")

        // Updates restamp: the client's stripped entries come back with metadata and fresh derived fields.
        var edit = created
        edit.phoneNumbers = [GooglePhoneNumber(value: "415-555-0000", type: "work")]
        let updated = try await client.updateContact(
            resourceName: name, etag: try #require(created.etag), person: edit, updatePersonFields: "phoneNumbers"
        )
        #expect(updated.phoneNumbers?.first?.canonicalForm == "+14155550000")
        #expect(updated.phoneNumbers?.first?.metadata?.primary == true)
        #expect(updated.metadata?.sources?.first?.etag != source.etag)
    }

    // MARK: pagination snapshot

    @Test("Pagination reads from a snapshot taken at the first page; later changes surface on the next sync")
    func snapshotPagination() async throws {
        let client = FakeGoogleClient(people: (0..<5).map { person("P\($0)") }, pageSize: 2)
        let first = try await client.listConnections(syncToken: nil, pageToken: nil)
        let names = try await fullList(client).people.compactMap(\.resourceName)

        try await client.deleteContact(resourceName: names[0])
        _ = try await client.createContact(person("Late"))

        var seen = first.people.compactMap { $0.names?.first?.givenName }
        var token = first.nextPageToken
        var syncToken: String?
        while let next = token {
            let page = try await client.listConnections(syncToken: nil, pageToken: next)
            seen += page.people.compactMap { $0.names?.first?.givenName }
            token = page.nextPageToken
            syncToken = page.nextSyncToken
        }
        #expect(seen == ["P0", "P1", "P2", "P3", "P4"])

        #expect(syncToken != nil)
        let delta = try await fullList(client, syncToken: syncToken)
        #expect(Set(delta.people.map(\.isDeleted)) == [true, false])
        #expect(delta.people.count == 2)
    }

    @Test("Other-contacts pagination also uses a snapshot")
    func otherContactsSnapshot() async throws {
        let others = (0..<3).map { GooglePerson(emailAddresses: [GoogleEmailAddress(value: "o\($0)@x.com")]) }
        let client = FakeGoogleClient(otherContacts: others, pageSize: 2)
        let first = try await client.listOtherContacts(pageToken: nil)
        #expect(first.people.count == 2)
        let second = try await client.listOtherContacts(pageToken: first.nextPageToken)
        #expect(second.people.count == 1 && second.nextPageToken == nil)
    }

    // MARK: limits and masks

    @Test("A person holds at most 10 client-data entries")
    func clientDataLimit() async throws {
        let client = FakeGoogleClient()
        func entries(_ count: Int) -> [GoogleClientData] { (0..<count).map { GoogleClientData(key: "k\($0)", value: "v") } }
        let created = try await client.createContact(GooglePerson(clientData: entries(10)))
        let name = try #require(created.resourceName)
        await #expect(throws: GoogleAPIError.self) { try await client.createContact(GooglePerson(clientData: entries(11))) }
        var tooMany = created
        tooMany.clientData = entries(11)
        await #expect(throws: GoogleAPIError.other(status: 400, message: "A person can have at most 10 clientData entries")) {
            try await client.updateContact(resourceName: name, etag: try #require(created.etag), person: tooMany, updatePersonFields: "clientData")
        }
        #expect(try await client.getPerson(resourceName: name).clientData?.count == 10)
        #expect(try await fullList(client).people.count == 1)
    }

    @Test("Every field the real API lists is an accepted mask; only listed fields are cleared; unmodeled ones go through extras")
    func masks() async throws {
        let stored = try GoogleFixtures.decode(GooglePerson.self, "person_full")
        let client = FakeGoogleClient(people: [stored])
        let existing = try #require(try await fullList(client).people.first)
        let name = try #require(existing.resourceName)
        #expect(existing.extras["biographies"] != nil)

        var etag = try #require(existing.etag)
        for field in [
            "addresses", "ageRanges", "biographies", "birthdays", "calendarUrls", "clientData", "emailAddresses", "events",
            "externalIds", "genders", "imClients", "interests", "locales", "locations", "memberships", "miscKeywords",
            "names", "nicknames", "occupations", "organizations", "phoneNumbers", "relations", "sipAddresses", "urls", "userDefined",
        ] {
            let result = try await client.updateContact(resourceName: name, etag: etag, person: GooglePerson(), updatePersonFields: field)
            etag = try #require(result.etag)
        }
        let cleared = try await client.getPerson(resourceName: name)
        #expect(cleared.extras["biographies"] == nil)
        #expect(cleared.names == nil && cleared.clientData == nil)

        await #expect(throws: GoogleAPIError.other(status: 400, message: "Invalid updatePersonFields: etag")) {
            try await client.updateContact(resourceName: name, etag: etag, person: GooglePerson(), updatePersonFields: "names,etag")
        }
    }

    @Test("A body field outside the mask is never applied, including unmodeled ones")
    func maskedOnly() async throws {
        let client = FakeGoogleClient(people: [GooglePerson(names: [GoogleName(givenName: "A")])])
        let existing = try #require(try await fullList(client).people.first)
        var body = GooglePerson()
        body.extras["biographies"] = .array([.string("x")])
        body.nicknames = [GoogleNickname(value: "Ay")]
        let updated = try await client.updateContact(
            resourceName: try #require(existing.resourceName), etag: try #require(existing.etag), person: body, updatePersonFields: "biographies"
        )
        #expect(updated.extras["biographies"] == .array([.string("x")]))
        #expect(updated.nicknames == nil)
        #expect(updated.names?.first?.givenName == "A")
    }

    // MARK: read-only entries end to end

    @Test("The fake serves profile-sourced entries, the mapper ignores them, and an update leaves them intact")
    func profileEntriesEndToEnd() async throws {
        let seeded = try GoogleFixtures.decode(GooglePerson.self, "person_profile_entries")
        let client = FakeGoogleClient(people: [seeded])
        let fetched = try #require(try await fullList(client).people.first)
        #expect(fetched.emailAddresses?.contains { $0.value == "bo@corp.com" } == true)

        var record = try #require(GooglePersonMapper.record(from: fetched))
        #expect(record.emails.map(\.value) == ["bo@home.example"])
        record.emails[0].value = "bo@new.example"
        record.nickname = "Bo"
        let payload = GooglePersonMapper.updatePayload(for: record, existing: fetched)
        let updated = try await client.updateContact(
            resourceName: try #require(fetched.resourceName), etag: try #require(fetched.etag),
            person: payload.person, updatePersonFields: payload.updatePersonFields
        )

        let contactEmails = updated.emailAddresses?.filter { $0.metadata?.source?.type == "CONTACT" }.compactMap(\.value)
        #expect(contactEmails == ["bo@new.example"])
        #expect(updated.emailAddresses?.contains { $0.value == "bo@corp.com" && $0.metadata?.source?.type == "PROFILE" } == true)
        #expect(updated.addresses?.contains { $0.city == "Redmond" } == true)
        #expect(updated.names?.contains { $0.givenName == "Robert" } == true)
        #expect(updated.birthdays?.count == 1)
        #expect(updated.nicknames?.contains { $0.value == "Bo" } == true)

        let reread = try #require(GooglePersonMapper.record(from: updated))
        #expect(reread.emails.map(\.value) == ["bo@new.example"])
        #expect(reread.birthday == nil)
    }
}
