import Foundation

/// Why notes could not be read or written through the Contacts app.
public enum NotesAccessError: Error, Sendable, Equatable {
    /// Automation access to Contacts was refused (AppleScript error -1743) or never granted.
    case notAuthorized
    /// Contacts would not start or answer (AppleScript error -600, even after a retry).
    case contactsAppUnavailable
    /// The Contacts app has no person with this id.
    case contactNotFound(String)
    /// The script ran but its result was not what the notes protocol expects.
    case unexpectedResult(String)
    case scriptFailed(number: Int, message: String)
}

extension NotesAccessError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            "Contact Bridge is not allowed to control Contacts, which it needs to read and keep notes. "
                + "Open System Settings > Privacy & Security > Automation, and turn on Contacts under Contact Bridge."
        case .contactsAppUnavailable:
            "The Contacts app did not respond. Open Contacts once, then try again."
        case .contactNotFound(let id):
            "The Contacts app has no contact with id \(id)."
        case .unexpectedResult(let detail):
            "The Contacts app returned notes in an unexpected form: \(detail)"
        case .scriptFailed(let number, let message):
            "Reading notes from Contacts failed (error \(number)): \(message)"
        }
    }
}
