import Foundation

/// Reads and writes contact notes. `NotesProvider` covers backup (read-only); merging also needs `setNote`.
public protocol NotesStoring: NotesProvider {
    /// Replaces the note of the contact. A nil note clears it.
    func setNote(_ note: String?, forID id: String) async throws
}

/// Notes through the Contacts app's AppleScript dictionary, because `CNContactNoteKey` needs a restricted entitlement.
/// Needs the Automation permission for Contacts (error -1743 becomes `NotesAccessError.notAuthorized`).
///
/// Unverified assumption, confirm by hand: Contacts' AppleScript `id` of a person is the same string as
/// `CNContact.identifier` on macOS ("UUID:ABPerson"). `ContactsAppIDs` holds all the matching in one place: exact match
/// first, then the part before ":".
public struct ContactsAppNotesProvider: NotesStoring {
    private let runner: any AppleScriptRunning
    private let retryDelay: Duration

    public init(runner: any AppleScriptRunning = NSAppleScriptRunner(), retryDelay: Duration = .seconds(1)) {
        self.runner = runner
        self.retryDelay = retryDelay
    }

    // MARK: scripts (constant text: nothing from callers or from parsing is ever interpolated into them)

    /// One round trip for the whole address book: two parallel lists, ids and notes (`missing value` for no note).
    static let bulkScript = #"tell application id "com.apple.AddressBook" to get {id, note} of every person"#

    static let setNoteHandler = "setNote"
    /// `pid` is the exact id, `pidUUID` the part before ":" for the fallback. Contacts only persists after `save`.
    static let setNoteScript = """
        on setNote(pid, pidUUID, txt)
            if pid is "" or pidUUID is "" then error "No contact id given." number -1728
            tell application id "com.apple.AddressBook"
                set matches to every person whose id is pid
                if (count of matches) is 0 then set matches to every person whose id begins with pidUUID
                if (count of matches) is 0 then error "No contact with that id." number -1728
                set note of item 1 of matches to txt
                save
            end tell
            return true
        end setNote
        """

    // MARK: NotesProvider

    public func fetchNotes(ids: [String]) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let result = try await perform { try await runner.run(source: Self.bulkScript) }
        return try ContactsAppIDs.notes(for: ids, in: Self.parseBulk(result))
    }

    // MARK: NotesStoring

    public func setNote(_ note: String?, forID id: String) async throws {
        // An empty UUID part would make `begins with ""` match every contact.
        guard !ContactsAppIDs.uuidPart(of: id).isEmpty else { throw NotesAccessError.contactNotFound(id) }
        let arguments = [id, ContactsAppIDs.uuidPart(of: id), note ?? ""].map { NSAppleEventDescriptor(string: $0) }
        do {
            _ = try await perform { try await runner.call(handler: Self.setNoteHandler, in: Self.setNoteScript, arguments: arguments) }
        } catch NotesAccessError.scriptFailed(-1728, _) {
            throw NotesAccessError.contactNotFound(id)
        }
    }

    // MARK: helpers

    /// Runs once; on -600 (Contacts not running yet, it launches on demand) waits and runs once more.
    private func perform<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as AppleScriptError where error.number == AppleScriptError.appNotRunning {
            try await Task.sleep(for: retryDelay)
            do { return try await operation() } catch let retry as AppleScriptError { throw Self.map(retry) }
        } catch let error as AppleScriptError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: AppleScriptError) -> NotesAccessError {
        switch error.number {
        case AppleScriptError.notAuthorized: .notAuthorized
        case AppleScriptError.appNotRunning: .contactsAppUnavailable
        default: .scriptFailed(number: error.number, message: error.message)
        }
    }

    /// `{{id, ...}, {note-or-missing-value, ...}}` into id/note pairs. Empty notes are `nil`.
    private static func parseBulk(_ result: NSAppleEventDescriptor) throws -> [(id: String, note: String?)] {
        guard result.numberOfItems == 2, let idList = result.atIndex(1), let noteList = result.atIndex(2) else {
            throw NotesAccessError.unexpectedResult("expected two lists, got \(result.numberOfItems) item(s)")
        }
        guard idList.numberOfItems == noteList.numberOfItems else {
            throw NotesAccessError.unexpectedResult("\(idList.numberOfItems) ids but \(noteList.numberOfItems) notes")
        }
        return try (1...max(idList.numberOfItems, 1)).compactMap { position in
            guard position <= idList.numberOfItems else { return nil }
            guard let id = idList.atIndex(position)?.stringValue else {
                throw NotesAccessError.unexpectedResult("person \(position) has no text id")
            }
            guard let noteItem = noteList.atIndex(position) else {
                throw NotesAccessError.unexpectedResult("person \(position) has no note entry")
            }
            if ContactsAppIDs.isMissingValue(noteItem) { return (id, nil) }
            guard let note = noteItem.stringValue else {
                throw NotesAccessError.unexpectedResult("the note of person \(position) is not text")
            }
            return (id, note.isEmpty ? nil : note)
        }
    }
}

/// Id matching between what the caller holds (`CNContact.identifier`) and what Contacts' AppleScript reports.
enum ContactsAppIDs {
    /// "ABC-123:ABPerson" -> "ABC-123"; an id without a colon is its own UUID part.
    static func uuidPart(of id: String) -> String {
        id.firstIndex(of: ":").map { String(id[..<$0]) } ?? id
    }

    /// AppleScript's `missing value` arrives as a type descriptor holding 'msng' (verified with `return missing value`),
    /// not typeNull; typeNull is accepted too.
    static func isMissingValue(_ descriptor: NSAppleEventDescriptor) -> Bool {
        descriptor.descriptorType == typeNull
            || (descriptor.descriptorType == typeType && descriptor.typeCodeValue == 0x6D73_6E67)
    }

    /// Notes for `requested`, keyed by the requested id. Exact id match first, then UUID-part match. People without a
    /// note are omitted.
    static func notes(for requested: [String], in people: [(id: String, note: String?)]) -> [String: String] {
        var exact: [String: String?] = [:]
        var byUUID: [String: String?] = [:]
        for person in people {
            if exact[person.id] == nil { exact[person.id] = .some(person.note) }
            let uuid = uuidPart(of: person.id)
            if byUUID[uuid] == nil { byUUID[uuid] = .some(person.note) }
        }
        var result: [String: String] = [:]
        for id in requested where !uuidPart(of: id).isEmpty {
            let match = exact[id] ?? byUUID[uuidPart(of: id)]
            if let note = match ?? nil { result[id] = note }
        }
        return result
    }
}
