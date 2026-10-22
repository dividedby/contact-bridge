import Foundation

public enum GoogleScopes {
    /// Read and write contacts.
    public static let contacts = "https://www.googleapis.com/auth/contacts"
    /// Read "Other contacts" (people you emailed but never saved).
    public static let otherContactsReadonly = "https://www.googleapis.com/auth/contacts.other.readonly"
    public static let all = [contacts, otherContactsReadonly]
}
