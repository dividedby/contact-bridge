import Foundation

public enum GoogleBatchLimits {
    /// People API batch endpoints accept at most 200 items per call.
    public static let maxItemsPerCall = 200
}

extension Array {
    /// Consecutive slices of at most `size` elements (empty for an empty array).
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

extension Array where Element == GoogleContactUpdate {
    /// What a client should send as separate batch calls: updates grouped by identical `updatePersonFields` (groups in
    /// order of first appearance, each keeping input order), each group chunked at `GoogleBatchLimits.maxItemsPerCall`.
    /// `index` is the update's position in the original array, for returning results in input order.
    func maskGroupedChunks() -> [[(index: Int, update: GoogleContactUpdate)]] {
        var order: [String] = []
        var groups: [String: [(index: Int, update: GoogleContactUpdate)]] = [:]
        for (index, update) in enumerated() {
            if groups[update.updatePersonFields] == nil { order.append(update.updatePersonFields) }
            groups[update.updatePersonFields, default: []].append((index, update))
        }
        return order.flatMap { (groups[$0] ?? []).chunked(into: GoogleBatchLimits.maxItemsPerCall) }
    }
}

/// What happened to one item of a batch call.
public enum GoogleBatchOutcome: Sendable, Hashable {
    /// Google confirmed the change.
    case applied
    /// Google rejected this item (or its whole chunk); nothing was changed for it.
    case failed(GoogleAPIError)
    /// Never sent: an earlier chunk hit an error that makes continuing pointless (sign-in problem, quota, permissions,
    /// or an unknown outcome). Safe to retry as is.
    case notAttempted(reason: String)
    /// The request may or may not have been applied (transport error, timeout, 408, 5xx or unreadable answer on a mutating
    /// chunk). Reconcile before retrying: look the contact up by its ownership tag (create) or refetch its etag
    /// (update) so a retry cannot duplicate or clobber.
    case ambiguous(reason: String)
}

/// Outcome of one item in a batch call. Results come back in input order, one per input: batch calls never throw away
/// work that already completed.
public struct GoogleBatchResult: Sendable, Hashable {
    public var resourceName: String?
    public var person: GooglePerson?
    public var outcome: GoogleBatchOutcome

    public init(resourceName: String?, person: GooglePerson? = nil) {
        self.resourceName = resourceName
        self.person = person
        self.outcome = .applied
    }

    public init(resourceName: String?, error: GoogleAPIError) {
        self.resourceName = resourceName
        self.outcome = .failed(error)
    }

    public init(resourceName: String?, outcome: GoogleBatchOutcome) {
        self.resourceName = resourceName
        self.outcome = outcome
    }

    public var isSuccess: Bool { outcome == .applied }
    /// Google's rejection, when the outcome is `.failed`.
    public var error: GoogleAPIError? {
        if case .failed(let error) = outcome { error } else { nil }
    }
    public var isNotAttempted: Bool {
        if case .notAttempted = outcome { true } else { false }
    }
    public var isAmbiguous: Bool {
        if case .ambiguous = outcome { true } else { false }
    }
}

/// Problems with a batch request that are caught before anything is sent.
public enum GoogleBatchError: Error, Sendable, Hashable {
    /// `batchCreate` pairs Google's unordered answers to inputs by the ownership tag, so every person needs one.
    case missingOwnershipTag(index: Int)
    case duplicateOwnershipTag(String)
}

extension GoogleOwnership {
    /// The tag of each person, in order. Throws before anything is sent or applied if one is missing or repeated.
    static func requireDistinctTags(_ people: [GooglePerson]) throws -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        for (index, person) in people.enumerated() {
            guard let tag = sourceID(of: person), !tag.isEmpty else { throw GoogleBatchError.missingOwnershipTag(index: index) }
            guard seen.insert(tag).inserted else { throw GoogleBatchError.duplicateOwnershipTag(tag) }
            tags.append(tag)
        }
        return tags
    }
}

/// Decides what a failed batch call means for its items and whether later calls should still be made.
enum GoogleBatchFailure {
    case failed(GoogleAPIError, stops: Bool)
    case notAttempted(String)
    case ambiguous(String)

    static func classify(_ error: Error) -> GoogleBatchFailure {
        if let auth = error as? GoogleAuthError {
            // Raised before sending, or from a 401 (so the request was rejected): nothing was applied.
            return .notAttempted(auth.description)
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .ambiguous("the operation was cancelled while a request was in flight")
        }
        guard let api = error as? GoogleAPIError else {
            return .ambiguous("transport error: \(error.localizedDescription)")
        }
        switch api {
        case .unauthorized, .rateLimited:
            return .failed(api, stops: true)
        case .other(let status, _) where (200..<300).contains(status):
            return .ambiguous("Google answered but the response could not be read")
        case .other(408, _):
            // Request Timeout: the server may have received and applied the request before giving up on it.
            return .ambiguous("Google answered with a request timeout (408)")
        case .other(let status, _) where status >= 500:
            return .ambiguous("Google answered with a server error (\(status))")
        case .other(403, _):
            return .failed(api, stops: true)
        default:
            return .failed(api, stops: false)
        }
    }

    var outcome: GoogleBatchOutcome {
        switch self {
        case .failed(let error, _): .failed(error)
        case .notAttempted(let reason): .notAttempted(reason: reason)
        case .ambiguous(let reason): .ambiguous(reason: reason)
        }
    }

    /// Why later calls are skipped, or nil if they should still run.
    var stopReason: String? {
        switch self {
        case .failed(let error, let stops): stops ? "an earlier call failed (\(error))" : nil
        case .notAttempted(let reason): reason
        case .ambiguous: "an earlier call may or may not have been applied"
        }
    }
}

/// Runs the calls of one batch operation in order, turning each thrown error into per-item results and skipping the
/// remaining calls after an error that makes continuing pointless.
struct GoogleBatchRun {
    private var stopReason: String?

    nonisolated(nonsending) mutating func run<Item>(
        _ items: [Item], resourceName: (Item) -> String?, call: nonisolated(nonsending) ([Item]) async throws -> [GoogleBatchResult]
    ) async -> [GoogleBatchResult] {
        if let stopReason {
            return items.map { GoogleBatchResult(resourceName: resourceName($0), outcome: .notAttempted(reason: stopReason)) }
        }
        do {
            return try await call(items)
        } catch {
            let failure = GoogleBatchFailure.classify(error)
            stopReason = failure.stopReason
            return items.map { GoogleBatchResult(resourceName: resourceName($0), outcome: failure.outcome) }
        }
    }
}

public struct GoogleContactUpdate: Sendable, Hashable {
    public var resourceName: String
    public var etag: String
    /// Carries the new values for the fields named in `updatePersonFields`.
    public var person: GooglePerson
    /// This update's own mask. Masks differ per person (a text-only birthday is left out, the ownership tag adds
    /// clientData), so they are never merged: implementations send updates with identical masks together.
    public var updatePersonFields: String
}

/// The People API operations this app uses. `URLSessionGoogleContactsClient` is the real implementation; tests use
/// `FakeGoogleClient`. Single calls throw `GoogleAPIError`. A transport error, 408 or 5xx on `createContact` or `updateContact`
/// leaves the outcome unknown, so reconcile (by ownership tag / refetched etag) before retrying.
///
/// The batch calls (`batchCreate`, `batchUpdate`, `batchDelete`) chunk at `GoogleBatchLimits.maxItemsPerCall` and return
/// one `GoogleBatchResult` per input, in input order, so completed chunks are never lost to a later failure; see
/// `GoogleBatchOutcome` for what each outcome means. They throw only for invalid input, before anything is sent.
///
/// `createContact` is not idempotent: if the follow-up read fails after a create, callers must not retry the create
/// blindly (it would duplicate the contact); look the contact up by its ownership tag first.
public protocol GoogleContactsClient: Sendable {
    func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage
    func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage
    func getPerson(resourceName: String) async throws -> GooglePerson

    func createContact(_ person: GooglePerson) async throws -> GooglePerson
    /// Replaces only the fields in `updatePersonFields` (comma-separated), guarded by `etag`.
    func updateContact(resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String) async throws -> GooglePerson
    func deleteContact(resourceName: String) async throws

    /// Every person must carry the ownership tag (`GoogleOwnership`): the real endpoint answers in no guaranteed order,
    /// so created people are paired to inputs by tag. Throws `GoogleBatchError` if a tag is missing or repeated.
    func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult]
    /// Groups updates by identical `updatePersonFields` (one API call needs one mask), chunks each group at 200, and
    /// returns results in input order.
    func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult]
    /// The real endpoint rejects a whole chunk if any resource name is gone; implementations then delete that chunk's
    /// items one by one, so already-deleted contacts report `notFound` individually and the rest are deleted.
    func batchDelete(_ resourceNames: [String]) async throws -> [GoogleBatchResult]

    /// The group's resource name, creating the group if it does not exist.
    func ensureGroup(named name: String) async throws -> String
    func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws
}
