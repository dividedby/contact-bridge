/// Supplies contact notes, which Contacts only hands to apps with a restricted entitlement. A provider (for example one
/// driven by AppleScript) is optional; without one backups carry no notes.
public protocol NotesProvider: Sendable {
    /// Notes keyed by contact identifier. Contacts without a note may be omitted.
    func fetchNotes(ids: [String]) async throws -> [String: String]
}
