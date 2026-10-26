/// Supplies contact notes, which Contacts only hands to apps with a restricted entitlement via CNContact. The real
/// provider, `ContactsAppNotesProvider`, reads them through the Contacts app's AppleScript dictionary (and needs the
/// Automation permission). A provider is optional; without one backups carry no notes.
public protocol NotesProvider: Sendable {
    /// Notes keyed by the requested contact identifier. A contact that was found but has no note is present with `""`;
    /// an id that could not be matched is absent. Absence means the note is unknown, never that there is none: callers
    /// that compare or push notes must not turn it into an empty note.
    func fetchNotes(ids: [String]) async throws -> [String: String]
}
