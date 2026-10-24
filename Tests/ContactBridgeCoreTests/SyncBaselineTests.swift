import Foundation
import Testing
@testable import ContactBridgeCore

struct SyncBaselineTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func baseline() -> SyncBaseline {
        var icloud = ContactRecord(id: "I1", source: .icloud, sourceIdentifier: "I1", givenName: "Ann", familyName: "Lee")
        icloud.phones = [Labeled(label: "mobile", value: "(415) 555-0100")]
        icloud.postalAddresses = [Labeled(label: "home", value: PostalAddress(street: "1 Main St", city: "Town", isoCountryCode: "us"))]
        icloud.birthday = DateComponents(month: 3, day: 9)
        var google = ContactRecord(id: "people/c1", source: .google, sourceIdentifier: "people/c1", givenName: "Ann", familyName: "Lee")
        google.emails = [Labeled(label: nil, value: "ann@example.com")]
        return SyncBaseline(
            icloud: icloud, google: google, googleEtag: "etag-1", icloudNoteHash: NoteHash.hash("hi"), googleNoteHash: nil, syncedAt: t0
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    @Test("A baseline survives JSON, including optional note hashes and year-less birthdays")
    func baselineRoundTrip() throws {
        let original = baseline()
        let decoded = try roundTrip(original)
        #expect(decoded == original)
        #expect(decoded.googleNoteHash == nil && decoded.icloudNoteHash != nil)
        #expect(decoded.icloud.birthday == DateComponents(month: 3, day: 9))
    }

    @Test("Sync state survives JSON with every field set")
    func stateRoundTrip() throws {
        let state = SyncState(
            baselines: ["I1": baseline()], googleSyncToken: "tok", fieldsVersion: "fv", icloudChangeToken: Data([1, 2, 3]),
            googleAccount: "me@example.com", ignoredGoogle: ["people/c9", "people/c8"], firstSyncApproved: true, pause: .user
        )
        let decoded = try roundTrip(state)
        #expect(decoded == state)
        #expect(decoded.version == 1)
    }

    @Test("A new state is empty, current-version, unapproved and not paused")
    func emptyState() throws {
        let state = SyncState()
        #expect(state.version == SyncState.currentVersion && state.baselines.isEmpty && state.ignoredGoogle.isEmpty)
        #expect(!state.firstSyncApproved && state.pause == nil && state.googleSyncToken == nil)
        #expect(try roundTrip(state) == state)
    }

    @Test("Every pause reason round-trips, keeping the confirmation summary")
    func pauseReasons() throws {
        let reasons: [PauseReason] = [
            .user, .accountChanged, .containerChanged, .googleEmpty, .notesUnavailable, .needsConfirmation(summary: "12 deletes"),
        ]
        for reason in reasons {
            let state = SyncState(pause: reason)
            #expect(try roundTrip(state).pause == reason)
        }
    }

    @Test("Note hashes ignore line-ending and surrounding-whitespace differences but not content")
    func noteHash() {
        #expect(NoteHash.hash("a\r\nb\n") == NoteHash.hash("a\nb"))
        #expect(NoteHash.hash("  a\rb ") == NoteHash.hash("a\nb"))
        #expect(NoteHash.hash("a") != NoteHash.hash("A"))
        #expect(NoteHash.hash("abc").count == 64)
    }
}
