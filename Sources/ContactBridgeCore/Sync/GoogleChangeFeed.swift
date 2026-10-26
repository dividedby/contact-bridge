import CryptoKit
import Foundation

/// What one look at Google's contacts found.
public struct GoogleFeed: Sendable, Hashable {
    public enum Status: Sendable, Hashable {
        case ok
        /// Sync must not continue: `people` is empty and nothing may be derived from this feed.
        case paused(PauseReason)
    }

    /// Why the feed lists every contact instead of the changes since the sync token.
    public enum FullListingReason: String, Sendable, Hashable {
        case noToken
        /// The sync token was issued for different `personFields`, so Google would answer with the wrong fields.
        case fieldsVersionChanged
        case tokenExpired
        /// The caller needed the whole book (new iCloud contacts to match, say).
        case requested
    }

    public enum Mode: Sendable, Hashable {
        /// `people` holds only what changed since the sync token; `deleted` holds the removals.
        case incremental
        /// `people` holds every contact. A linked contact missing from it was deleted in Google.
        case full(FullListingReason)
    }

    public var status: Status
    public var mode: Mode
    /// Live contacts by resource name (deletion markers are never in here).
    public var people: [String: GooglePerson]
    /// Resource names the incremental listing reported as deleted. Empty after a full listing.
    public var deleted: Set<String>
    /// Save as `SyncState.googleSyncToken` once the run's results are committed. Nil if Google sent none.
    public var nextSyncToken: String?
    /// Save as `SyncState.fieldsVersion` together with `nextSyncToken`.
    public var fieldsVersion: String
    /// The account email, to save as `SyncState.googleAccount` when none was stored.
    public var account: String?
    /// iCloud contact identifier (the ownership tag) to the resource name of the Google contact created from it, over
    /// `people`. Complete only after a full listing.
    public var ownershipIndex: [String: String]

    public var isFullListing: Bool {
        if case .full = mode { true } else { false }
    }

    public var pause: PauseReason? {
        if case .paused(let reason) = status { reason } else { nil }
    }
}

public enum GoogleChangeFeedError: Error, Sendable, Equatable {
    /// An account is saved in the sync state but the signed-in account's email is not known, so it cannot be told whether
    /// it is the same one. Not a change of account: the run fails and tries again.
    case accountUnconfirmed
}

extension GoogleChangeFeedError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accountUnconfirmed:
            "Couldn't confirm which Google account is signed in, so Google was left alone this time. Sign in again in Setup if this keeps happening."
        }
    }
}

/// Reads Google's contacts the cheap way: with the stored sync token only what changed since the last run, and the whole
/// book when the token is missing, expired or was issued for other `personFields`.
public struct GoogleChangeFeed: Sendable {
    /// Hash of the fields the real client requests; part of the sync state so a field change forces a full listing.
    public static var currentFieldsVersion: String {
        SHA256.hash(data: Data(URLSessionGoogleContactsClient.personFields.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let maxPages = 1000

    private let client: any GoogleContactsClient
    private let fieldsVersion: String

    public init(client: any GoogleContactsClient, fieldsVersion: String = GoogleChangeFeed.currentFieldsVersion) {
        self.client = client
        self.fieldsVersion = fieldsVersion
    }

    /// - Parameters:
    ///   - accountEmail: the signed-in account, when known. A different one than `state.googleAccount` pauses. Unknown
    ///     (nil or empty) while an account is saved throws `GoogleChangeFeedError.accountUnconfirmed`: nothing is read.
    ///   - requireFullListing: list everything even though a valid sync token exists.
    public func fetch(state: SyncState, accountEmail: String? = nil, requireFullListing: Bool = false) async throws -> GoogleFeed {
        let accountEmail = accountEmail.flatMap { $0.isEmpty ? nil : $0 }
        func feed(
            _ status: GoogleFeed.Status, _ mode: GoogleFeed.Mode, people: [GooglePerson] = [], deleted: Set<String> = [], token: String? = nil
        ) -> GoogleFeed {
            var live: [String: GooglePerson] = [:]
            var index: [String: String] = [:]
            for person in people {
                guard let name = person.resourceName else { continue }
                live[name] = person
                if let tag = person.contactBridgeSourceID, !tag.isEmpty, (index[tag] ?? name) >= name { index[tag] = name }
            }
            return GoogleFeed(
                status: status, mode: mode, people: live, deleted: deleted, nextSyncToken: token, fieldsVersion: fieldsVersion,
                account: accountEmail ?? state.googleAccount, ownershipIndex: index
            )
        }

        if let saved = state.googleAccount {
            guard let accountEmail else { throw GoogleChangeFeedError.accountUnconfirmed }
            if saved.lowercased() != accountEmail.lowercased() { return feed(.paused(.accountChanged), .full(.requested)) }
        }

        var reason: GoogleFeed.FullListingReason?
        if requireFullListing {
            reason = .requested
        } else if state.googleSyncToken == nil {
            reason = .noToken
        } else if state.fieldsVersion != fieldsVersion {
            reason = .fieldsVersionChanged
        }

        if reason == nil, let token = state.googleSyncToken {
            do {
                let (changes, next) = try await list(syncToken: token)
                // A deletion marker is a stub with only a resource name, so it is told apart before anything is mapped.
                let markers = Set(changes.filter(\.isDeleted).compactMap(\.resourceName))
                return feed(.ok, .incremental, people: changes.filter { !$0.isDeleted }, deleted: markers, token: next)
            } catch GoogleAPIError.syncTokenExpired {
                reason = .tokenExpired
            }
        }

        let (everyone, next) = try await list(syncToken: nil)
        return feed(.ok, .full(reason ?? .noToken), people: everyone.filter { !$0.isDeleted }, token: next)
    }

    /// Follows page tokens to the end; the sync token comes with the last page.
    private func list(syncToken: String?) async throws -> (people: [GooglePerson], nextSyncToken: String?) {
        var people: [GooglePerson] = []
        var seen = Set<String>()
        var pageToken: String?
        var pages = 0
        while true {
            let page = try await client.listConnections(syncToken: syncToken, pageToken: pageToken)
            people += page.people
            pages += 1
            guard let next = page.nextPageToken else { return (people, page.nextSyncToken) }
            guard pages < Self.maxPages, seen.insert(next).inserted else { throw GoogleListingError.pagingDidNotTerminate("connections") }
            pageToken = next
        }
    }
}
