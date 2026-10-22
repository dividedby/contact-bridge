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

/// Outcome of one item in a batch call. Results come back in input order; failures are per item.
public struct GoogleBatchResult: Sendable, Hashable {
    public var resourceName: String?
    public var person: GooglePerson?
    public var error: GoogleAPIError?

    public var isSuccess: Bool { error == nil }
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

/// The People API operations this app uses. The URLSession implementation arrives with OAuth; tests use
/// `FakeGoogleClient`. Whole-call failures throw `GoogleAPIError`; `batchCreate` and `batchUpdate` chunk at
/// `GoogleBatchLimits.maxItemsPerCall` and report item failures in their results, while `batchDelete` has no per-item results.
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

    func batchCreate(_ people: [GooglePerson]) async throws -> [GoogleBatchResult]
    /// Groups updates by identical `updatePersonFields` (one API call needs one mask), chunks each group at 200, and
    /// returns results in input order.
    func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult]
    /// Fails the whole call (nothing in that chunk is deleted) if any resource name does not exist, as the real endpoint does.
    func batchDelete(_ resourceNames: [String]) async throws

    /// The group's resource name, creating the group if it does not exist.
    func ensureGroup(named name: String) async throws -> String
    func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws
}
