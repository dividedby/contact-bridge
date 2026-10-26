import Foundation
import Synchronization

/// Notes held in memory, for the demo mode and tests. Same contract as `ContactsAppNotesProvider`: reads return only the
/// requested ids, with `""` for a contact that has no note; ids listed as unmatched are left out, like ids the Contacts
/// app did not return.
public final class InMemoryNotesStore: NotesStoring, Sendable {
    private struct State {
        var notes: [String: String]
        var unmatched: Set<String>
        var readError: (any Error)?
        var writeError: (any Error)?
        var fetched: [[String]] = []
        var written: [(id: String, note: String?)] = []
    }

    private let state: Mutex<State>

    public init(
        notes: [String: String] = [:], unmatchedIDs: Set<String> = [], readError: (any Error)? = nil, writeError: (any Error)? = nil
    ) {
        state = Mutex(State(notes: notes, unmatched: unmatchedIDs, readError: readError, writeError: writeError))
    }

    /// Every `fetchNotes` call's ids, in order.
    public var fetchedIDs: [[String]] { state.withLock { $0.fetched } }
    public var writes: [(id: String, note: String?)] { state.withLock { $0.written } }

    public func setUnmatched(_ ids: Set<String>) { state.withLock { $0.unmatched = ids } }
    public func setReadError(_ error: (any Error)?) { state.withLock { $0.readError = error } }

    public func fetchNotes(ids: [String]) async throws -> [String: String] {
        try state.withLock { state in
            state.fetched.append(ids)
            if let error = state.readError { throw error }
            return Dictionary(
                ids.filter { !state.unmatched.contains($0) }.map { ($0, state.notes[$0] ?? "") }, uniquingKeysWith: { first, _ in first }
            )
        }
    }

    public func setNote(_ note: String?, forID id: String) async throws {
        try state.withLock { state in
            state.written.append((id, note))
            if let error = state.writeError { throw error }
            state.notes[id] = note
        }
    }
}
