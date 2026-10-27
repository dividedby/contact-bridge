import CryptoKit
import Foundation
import Testing
@testable import ContactBridgeCore

// Google's side of photo sync: reading photos off a person, the two photo calls, and the fake that stands in for them.

private func person(_ json: String) throws -> GooglePerson {
    try JSONDecoder().decode(GooglePerson.self, from: Data(json.utf8))
}

private let contactPhoto = "https://lh3.googleusercontent.com/contacts/AEmZk1=s100"
private let profilePhoto = "https://lh3.googleusercontent.com/a/ACg8oc=s100"

private func photoEntry(_ url: String, source: String, primary: Bool? = nil, isDefault: Bool? = nil) -> String {
    let flags = [primary.map { #""primary":\#($0)"# }, #""source":{"type":"\#(source)","id":"1"}"#].compactMap { $0 }.joined(separator: ",")
    return #"{"metadata":{\#(flags)},"url":"\#(url)"\#(isDefault.map { #","default":\#($0)"# } ?? "")}"#
}

private func personWithPhotos(_ entries: [String], sources: String = #"[{"type":"CONTACT","id":"c1","updateTime":"2026-03-01T10:20:30.123456Z"}]"#) throws -> GooglePerson {
    try person(#"{"resourceName":"people/c1","etag":"E","metadata":{"sources":\#(sources)},"photos":[\#(entries.joined(separator: ","))]}"#)
}

struct GooglePhotoMapperTests {
    @Test("The contact's own photo and the profile photo are told apart, with their URL keys and the contact's update time")
    func contactAndProfile() throws {
        let photos = GooglePersonMapper.photos(of: try personWithPhotos([
            photoEntry(profilePhoto, source: "PROFILE", primary: true), photoEntry(contactPhoto, source: "CONTACT"),
        ]))
        #expect(photos.contact?.url == contactPhoto && photos.contact?.key == "https://lh3.googleusercontent.com/contacts/AEmZk1")
        #expect(photos.profile?.url == profilePhoto && photos.profile?.key == "https://lh3.googleusercontent.com/a/ACg8oc")
        // Fractions are read to the millisecond.
        #expect(abs(try #require(photos.contactUpdatedAt).timeIntervalSince1970 - 1_772_360_430.123) < 0.001)
    }

    @Test("Default (letter) avatars are no photo, from the contact or the profile")
    func defaultAvatars() throws {
        let photos = GooglePersonMapper.photos(of: try personWithPhotos([
            photoEntry("https://lh3.googleusercontent.com/a/default-user=s100", source: "PROFILE", primary: true, isDefault: true),
            photoEntry("https://lh3.googleusercontent.com/contacts/letter=s100", source: "CONTACT", isDefault: true),
        ]))
        #expect(photos.contact == nil && photos.profile == nil)

        // A real photo next to a default one is still found.
        let mixed = GooglePersonMapper.photos(of: try personWithPhotos([
            photoEntry("https://lh3.googleusercontent.com/contacts/letter=s100", source: "CONTACT", primary: true, isDefault: true),
            photoEntry(contactPhoto, source: "CONTACT", isDefault: false),
        ]))
        #expect(mixed.contact?.url == contactPhoto)
    }

    @Test("A person with only a profile photo has no contact photo; one with none has neither")
    func onlyProfileOrNone() throws {
        let profileOnly = GooglePersonMapper.photos(of: try personWithPhotos([photoEntry(profilePhoto, source: "PROFILE", primary: true)]))
        #expect(profileOnly.contact == nil && profileOnly.profile?.url == profilePhoto)
        let none = GooglePersonMapper.photos(of: try personWithPhotos([]))
        #expect(none.contact == nil && none.profile == nil)
        #expect(GooglePersonMapper.photos(of: GooglePerson(resourceName: "people/c1")) == GooglePhotos())
    }

    @Test("The primary photo of a kind wins, and other sources are ignored")
    func primaryAndSources() throws {
        let photos = GooglePersonMapper.photos(of: try personWithPhotos([
            photoEntry("https://lh3.googleusercontent.com/contacts/first=s100", source: "CONTACT", primary: false),
            photoEntry("https://lh3.googleusercontent.com/contacts/second=s100", source: "CONTACT", primary: true),
            photoEntry("https://lh3.googleusercontent.com/d/domain=s100", source: "DOMAIN_PROFILE", primary: true),
            photoEntry("https://lh3.googleusercontent.com/o/other=s100", source: "OTHER_CONTACT"),
        ]))
        #expect(photos.contact?.key == "https://lh3.googleusercontent.com/contacts/second")
        #expect(photos.profile == nil)
    }

    @Test("The key drops a size suffix, whatever the size options, and leaves other URLs as they are")
    func keys() {
        for suffix in ["=s100", "=s0", "=s1024", "=s128-c", "=s64-c-k-no"] {
            #expect(GooglePhotoRef(url: "https://lh3.googleusercontent.com/p/AAA\(suffix)").key == "https://lh3.googleusercontent.com/p/AAA", "\(suffix)")
        }
        #expect(GooglePhotoRef(url: "https://lh3.googleusercontent.com/-x/AAAA/photo.jpg").key == "https://lh3.googleusercontent.com/-x/AAAA/photo.jpg")
        #expect(GooglePhotoRef(url: "https://lh3.googleusercontent.com/a/AAA=w100-h100").key == "https://lh3.googleusercontent.com/a/AAA=w100-h100")
        let ref = GooglePhotoRef(url: contactPhoto)
        #expect(ref.sizedURL(128)?.absoluteString == "https://lh3.googleusercontent.com/contacts/AEmZk1=s128")
        #expect(ref.sizedURL(1024)?.absoluteString == "https://lh3.googleusercontent.com/contacts/AEmZk1=s1024")
        #expect(GooglePhotoRef(url: "https://lh3.googleusercontent.com/p/AAA=s64").key == GooglePhotoRef(url: "https://lh3.googleusercontent.com/p/AAA=s2048").key)
    }

    @Test("The update time is the contact's source, with or without fractional seconds, and absent when Google gave none")
    func updateTime() throws {
        let entries = [photoEntry(contactPhoto, source: "CONTACT")]
        func updated(_ sources: String) throws -> Date? { GooglePersonMapper.photos(of: try personWithPhotos(entries, sources: sources)).contactUpdatedAt }
        #expect(try updated(#"[{"type":"CONTACT","updateTime":"2026-03-01T10:20:30Z"}]"#) == Date(timeIntervalSince1970: 1_772_360_430))
        #expect(try updated(#"[{"type":"CONTACT","updateTime":"2026-03-01T10:20:30.123456789Z"}]"#) != nil)
        // The profile's update time is not the contact's.
        #expect(try updated(#"[{"type":"PROFILE","updateTime":"2026-03-01T10:20:30Z"}]"#) == nil)
        #expect(try updated(#"[{"type":"CONTACT"}]"#) == nil)
        #expect(try updated(#"[{"type":"CONTACT","updateTime":"yesterday"}]"#) == nil)
    }

    @Test("Photos are kept when a person is encoded again, and do not become part of the contact record or an update mask")
    func photosStayOutOfTheContact() throws {
        let original = try personWithPhotos([photoEntry(contactPhoto, source: "CONTACT")])
        let again = try JSONDecoder().decode(GooglePerson.self, from: JSONEncoder().encode(original))
        #expect(GooglePersonMapper.photos(of: again) == GooglePersonMapper.photos(of: original) && again == original)
        #expect(!GooglePersonMapper.updatePersonFields(includingOwnershipTag: true).contains("photos"))
        #expect(!GooglePersonMapper.modeledFields.contains("photos"))
        var withName = original
        withName.names = [GoogleName(givenName: "Ann", familyName: "Lee")]
        var other = withName
        other.extras["photos"] = nil
        #expect(GooglePersonMapper.record(from: withName) == GooglePersonMapper.record(from: other), "photos are not a ContactRecord field")
    }
}

struct GooglePhotoClientTests {
    private let transport = FakeHTTPTransport()
    private let sleeps = SleepRecorder()

    private func client() -> URLSessionGoogleContactsClient {
        URLSessionGoogleContactsClient(transport: transport, auth: StaticTokenProvider(), sleep: { await sleeps.record($0) }, jitter: { 0 })
    }

    private let bytes = Data((0..<300).map { UInt8($0 % 251) })

    // MARK: fields

    @Test("Every person read asks for photos; the fields version moved with it, so the next run lists Google in full once")
    func fieldsVersion() async throws {
        #expect(URLSessionGoogleContactsClient.personFields.split(separator: ",").contains("photos"))
        let before = URLSessionGoogleContactsClient.personFields.replacing(",photos", with: "")
        #expect(before == "names,nicknames,organizations,phoneNumbers,emailAddresses,addresses,urls,birthdays,biographies,metadata,clientData,memberships")
        let oldVersion = SHA256.hash(data: Data(before.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(GoogleChangeFeed.currentFieldsVersion != oldVersion)

        // A state saved with the old version and a good token is read in full, read-only, and gets the new version.
        let google = FakeGoogleClient(people: [SyncFixtures.person("Ann", "Lee"), SyncFixtures.person("Bob", "Ray")])
        let first = try await GoogleChangeFeed(client: google, fieldsVersion: oldVersion).fetch(state: SyncState())
        let saved = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: oldVersion)
        let feed = try await GoogleChangeFeed(client: google).fetch(state: saved)
        #expect(feed.mode == .full(.fieldsVersionChanged) && feed.people.count == 2)
        #expect(feed.fieldsVersion == GoogleChangeFeed.currentFieldsVersion)
        #expect(await google.photoWrites.isEmpty)

        // With that version stored, the next run is incremental again.
        let current = SyncState(googleSyncToken: feed.nextSyncToken, fieldsVersion: feed.fieldsVersion)
        #expect(try await GoogleChangeFeed(client: google).fetch(state: current).mode == .incremental)
    }

    // MARK: updateContactPhoto

    @Test("updateContactPhoto PATCHes the base64 bytes and the person fields to people/...:updateContactPhoto and returns the person")
    func update() async throws {
        await transport.route("PATCH", ":updateContactPhoto", [.json(200, #"{"person":{"resourceName":"people/c1","etag":"E9"}}"#)])
        let updated = try await client().updateContactPhoto(resourceName: "people/c1", photoBytes: bytes)

        let request = try #require(await transport.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.url.absoluteString.hasPrefix(base + "people/c1:updateContactPhoto"), "the colon stays literal")
        #expect(request.url.path == "/v1/people/c1:updateContactPhoto")
        #expect(request.query.isEmpty)
        #expect(request.headers["Content-Type"] == "application/json" && request.headers["Authorization"] == "Bearer tok-1")
        let body = try #require(request.bodyJSON)
        #expect(body["photoBytes"] as? String == bytes.base64EncodedString())
        #expect(body["personFields"] as? String == personFields && body.count == 2)
        #expect(updated.resourceName == "people/c1" && updated.etag == "E9")
    }

    @Test("updateContactPhoto waits out a rate limit and retries, and retries a server error, since the same bytes can be sent twice")
    func updateRetries() async throws {
        await transport.route("PATCH", ":updateContactPhoto", [
            .json(429, #"{"error":{"code":429,"message":"slow down","status":"RESOURCE_EXHAUSTED"}}"#, headers: ["Retry-After": "7"]),
            .json(503, "{}"),
            .json(200, #"{"person":{"resourceName":"people/c1","etag":"E2"}}"#),
        ])
        let updated = try await client().updateContactPhoto(resourceName: "people/c1", photoBytes: bytes)
        let sent = await transport.requests.count
        let delays = await sleeps.delays
        #expect(updated.etag == "E2" && sent == 3)
        #expect(delays.first == 7 && delays.count == 2)
    }

    @Test("updateContactPhoto with the rate limit never lifting gives up with rateLimited")
    func updateRateLimited() async throws {
        await transport.route("PATCH", ":updateContactPhoto", [.json(429, #"{"error":{"code":429,"message":"slow","status":"RESOURCE_EXHAUSTED"}}"#)])
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: nil)) {
            try await client().updateContactPhoto(resourceName: "people/c1", photoBytes: bytes)
        }
        #expect(await transport.requests.count == URLSessionGoogleContactsClient.maxAttempts)
    }

    @Test("updateContactPhoto reports a missing contact, a rejected photo, and an answer with no contact")
    func updateErrors() async throws {
        await transport.route("PATCH", "people/gone:updateContactPhoto", [.json(404, #"{"error":{"code":404,"message":"not found","status":"NOT_FOUND"}}"#)])
        await transport.route("PATCH", "people/bad:updateContactPhoto", [.json(400, #"{"error":{"code":400,"message":"Invalid photo","status":"INVALID_ARGUMENT"}}"#)])
        await transport.route("PATCH", "people/empty:updateContactPhoto", [.json(200, "{}")])
        await #expect(throws: GoogleAPIError.notFound) { try await client().updateContactPhoto(resourceName: "people/gone", photoBytes: bytes) }
        await #expect(throws: GoogleAPIError.other(status: 400, message: "Invalid photo")) {
            try await client().updateContactPhoto(resourceName: "people/bad", photoBytes: bytes)
        }
        await #expect(throws: GoogleAPIError.other(status: 200, message: "Google answered without the contact")) {
            try await client().updateContactPhoto(resourceName: "people/empty", photoBytes: bytes)
        }
    }

    // MARK: deleteContactPhoto

    @Test("deleteContactPhoto issues DELETE people/...:deleteContactPhoto with the person fields and returns the person")
    func delete() async throws {
        await transport.route("DELETE", ":deleteContactPhoto", [.json(200, #"{"person":{"resourceName":"people/c1","etag":"E3"}}"#)])
        let updated = try await client().deleteContactPhoto(resourceName: "people/c1")
        let request = try #require(await transport.requests.first)
        #expect(request.method == "DELETE" && request.url.path == "/v1/people/c1:deleteContactPhoto")
        #expect(request.url.absoluteString.hasPrefix(base + "people/c1:deleteContactPhoto?"))
        #expect(request.query == ["personFields": personFields] && request.body.isEmpty)
        #expect(request.headers["Authorization"] == "Bearer tok-1")
        #expect(updated.etag == "E3")
    }

    @Test("deleteContactPhoto retries a rate limit and a server error, and reports a missing contact")
    func deleteRetriesAndErrors() async throws {
        await transport.route("DELETE", "people/c1:deleteContactPhoto", [
            .json(429, #"{"error":{"code":429,"message":"slow","status":"RESOURCE_EXHAUSTED"}}"#), .json(502, "{}"),
            .json(200, #"{"person":{"resourceName":"people/c1","etag":"E4"}}"#),
        ])
        await transport.route("DELETE", "people/gone:deleteContactPhoto", [.json(404, #"{"error":{"code":404,"message":"nope","status":"NOT_FOUND"}}"#)])
        #expect(try await client().deleteContactPhoto(resourceName: "people/c1").etag == "E4")
        await #expect(throws: GoogleAPIError.notFound) { try await client().deleteContactPhoto(resourceName: "people/gone") }
    }
}

struct FakeGooglePhotoTests {
    private let red = PhotoTestImages.jpeg(PhotoTestImages.solid(.red))
    private let blue = PhotoTestImages.jpeg(PhotoTestImages.solid(.blue))

    private func fake() -> FakeGoogleClient {
        FakeGoogleClient(people: [SyncFixtures.person("Ann", "Lee"), SyncFixtures.person("Bob", "Ray")])
    }

    @Test("updateContactPhoto stores the bytes, gives the contact a photo with a URL key, and moves the etag")
    func updateStores() async throws {
        let google = fake()
        let before = try await google.getPerson(resourceName: "people/c1")
        #expect(GooglePersonMapper.photos(of: before).contact == nil)

        let updated = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red)
        let stored = try await google.getPerson(resourceName: "people/c1")
        #expect(updated.etag != before.etag && updated == stored)
        let ref = try #require(GooglePersonMapper.photos(of: updated).contact)
        #expect(ref.url.hasSuffix("=s100") && ref.key.hasPrefix("https://lh3.googleusercontent.com/"))
        #expect(await google.contactPhotoBytes(for: "people/c1") == red)
        #expect(await google.photoBytes(forURL: try #require(ref.sizedURL(1024))) == red, "any size serves the same image")
        #expect(await google.photoWrites == [FakeGoogleClient.PhotoWrite(resourceName: "people/c1", bytes: red)])
        #expect(GooglePersonMapper.photos(of: try await google.getPerson(resourceName: "people/c2")).contact == nil)
    }

    @Test("A new photo gets a new URL key, so a changed photo is seen as changed; the other fields are untouched")
    func replaceChangesKey() async throws {
        let google = fake()
        let first = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red)
        let second = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: blue)
        #expect(GooglePersonMapper.photos(of: first).contact?.key != GooglePersonMapper.photos(of: second).contact?.key)
        #expect(await google.contactPhotoBytes(for: "people/c1") == blue)
        #expect(GooglePersonMapper.record(from: second) == GooglePersonMapper.record(from: first))
        #expect(await google.photoWrites.count == 2)
    }

    @Test("deleteContactPhoto removes the contact's own photo only; the profile photo stays, and deleting twice is fine")
    func deleteKeepsProfile() async throws {
        let google = fake()
        _ = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red)
        try await google.setProfilePhoto(blue, for: "people/c1")
        let before = try await google.getPerson(resourceName: "people/c1")

        let after = try await google.deleteContactPhoto(resourceName: "people/c1")
        let photos = GooglePersonMapper.photos(of: after)
        #expect(photos.contact == nil && photos.profile == GooglePersonMapper.photos(of: before).profile && after.etag != before.etag)
        #expect(await google.contactPhotoBytes(for: "people/c1") == nil)
        _ = try await google.deleteContactPhoto(resourceName: "people/c1")
        #expect(await google.photoWrites.map(\.bytes) == [red, nil, nil])
    }

    @Test("Setting a profile photo is not a write by the app, and it moves the etag like another client's edit")
    func profilePhoto() async throws {
        let google = fake()
        let before = try await google.getPerson(resourceName: "people/c1")
        let after = try await google.setProfilePhoto(blue, for: "people/c1")
        #expect(after.etag != before.etag && GooglePersonMapper.photos(of: after).profile != nil && GooglePersonMapper.photos(of: after).contact == nil)
        #expect(await google.photoWrites.isEmpty)
        let removed = try await google.setProfilePhoto(nil, for: "people/c1")
        #expect(GooglePersonMapper.photos(of: removed).profile == nil)
    }

    @Test("A photo change shows up in the next incremental listing, like any edit")
    func listing() async throws {
        let google = fake()
        let first = try await GoogleChangeFeed(client: google, fieldsVersion: "v").fetch(state: SyncState())
        let state = SyncState(googleSyncToken: first.nextSyncToken, fieldsVersion: "v")
        _ = try await google.updateContactPhoto(resourceName: "people/c2", photoBytes: red)
        let feed = try await GoogleChangeFeed(client: google, fieldsVersion: "v").fetch(state: state)
        #expect(feed.mode == .incremental && Set(feed.people.keys) == ["people/c2"])
        let listed = try #require(feed.people["people/c2"])
        #expect(GooglePersonMapper.photos(of: listed).contact != nil)
    }

    @Test("A later field update leaves the photo alone, and a photo write leaves the fields alone")
    func independent() async throws {
        let google = fake()
        _ = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red)
        var person = try await google.getPerson(resourceName: "people/c1")
        person.nicknames = [GoogleNickname(value: "Annie")]
        let edited = try await google.updateContact(resourceName: "people/c1", etag: try #require(person.etag), person: person, updatePersonFields: "nicknames")
        #expect(GooglePersonMapper.photos(of: edited).contact != nil && edited.nicknames?.first?.value == "Annie")
        let rephotoed = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: blue)
        #expect(rephotoed.nicknames?.first?.value == "Annie" && rephotoed.names == edited.names)
    }

    @Test("Bytes that are not an image, and a contact that is not there, are refused without changing anything")
    func refusals() async throws {
        let google = fake()
        let before = try await google.getPerson(resourceName: "people/c1")
        await #expect(throws: GoogleAPIError.other(status: 400, message: "The photo is not a valid image")) {
            try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: Data("nope".utf8))
        }
        await #expect(throws: GoogleAPIError.notFound) { try await google.updateContactPhoto(resourceName: "people/c99", photoBytes: red) }
        await #expect(throws: GoogleAPIError.notFound) { try await google.deleteContactPhoto(resourceName: "people/c99") }
        let unchanged = try await google.getPerson(resourceName: "people/c1")
        let writes = await google.photoWrites
        #expect(unchanged == before && writes.isEmpty)
    }

    @Test("Injected failures hit the photo calls: a rate limit is thrown and nothing is stored, then the next call works")
    func failures() async throws {
        let google = fake()
        await google.inject(.rateLimited(retryAfter: 3), on: .updateContactPhoto)
        await google.inject(.error(.other(status: 500, message: "boom")), on: .deleteContactPhoto)
        let before = try await google.getPerson(resourceName: "people/c1")
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: 3)) { try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red) }
        await #expect(throws: GoogleAPIError.other(status: 500, message: "boom")) { try await google.deleteContactPhoto(resourceName: "people/c1") }
        let unchanged = try await google.getPerson(resourceName: "people/c1")
        let writes = await google.photoWrites
        #expect(unchanged == before && writes.isEmpty)

        _ = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: red)
        #expect(await google.contactPhotoBytes(for: "people/c1") == red)

        // An injection for another operation does not touch photo calls, and one with no operation hits whatever is next.
        await google.inject(.rateLimited(), on: .listConnections)
        _ = try await google.updateContactPhoto(resourceName: "people/c1", photoBytes: blue)
        await google.inject(.rateLimited())
        await #expect(throws: GoogleAPIError.rateLimited(retryAfter: nil)) { try await google.deleteContactPhoto(resourceName: "people/c1") }
    }
}
