import Foundation
import Synchronization

/// Notes held in memory, for the demo mode and tests. Same contract as `ContactsAppNotesProvider`: reads return only the
/// requested ids that have a note.
public final class InMemoryNotesStore: NotesStoring, Sendable {
    private struct State {
        var notes: [String: String]
        var readError: (any Error)?
        var writeError: (any Error)?
        var fetched: [[String]] = []
        var written: [(id: String, note: String?)] = []
    }

    private let state: Mutex<State>

    public init(notes: [String: String] = [:], readError: (any Error)? = nil, writeError: (any Error)? = nil) {
        state = Mutex(State(notes: notes, readError: readError, writeError: writeError))
    }

    /// Every `fetchNotes` call's ids, in order.
    public var fetchedIDs: [[String]] { state.withLock { $0.fetched } }
    public var writes: [(id: String, note: String?)] { state.withLock { $0.written } }

    public func setReadError(_ error: (any Error)?) { state.withLock { $0.readError = error } }

    public func fetchNotes(ids: [String]) async throws -> [String: String] {
        try state.withLock { state in
            state.fetched.append(ids)
            if let error = state.readError { throw error }
            return state.notes.filter { ids.contains($0.key) }
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
