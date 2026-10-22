/// Supplies contact notes, which Contacts only hands to apps with a restricted entitlement via CNContact. The real
/// provider, `ContactsAppNotesProvider`, reads them through the Contacts app's AppleScript dictionary (and needs the
/// Automation permission). A provider is optional; without one backups carry no notes.
public protocol NotesProvider: Sendable {
    /// Notes keyed by contact identifier. Contacts without a note may be omitted.
    func fetchNotes(ids: [String]) async throws -> [String: String]
}
