import Foundation

public enum NotesAccessStatus: Sendable, Equatable {
    /// Not checked yet.
    case unknown
    case authorized
    /// Automation access to Contacts is refused or was never granted.
    case notAuthorized
    case unavailable(String)
}

/// Tells whether notes can be read, by actually reading. The first real read is also what makes macOS ask for the
/// Automation permission.
public enum NotesAccessProbe {
    /// Not a real contact id: the answer is ignored, only whether the read worked matters.
    public static let probeID = "contact-bridge-access-probe"

    public static func check(_ notes: any NotesProvider) async -> NotesAccessStatus {
        do {
            _ = try await notes.fetchNotes(ids: [probeID])
            return .authorized
        } catch NotesAccessError.notAuthorized {
            return .notAuthorized
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
