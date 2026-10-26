import Foundation

public enum GoogleScopes {
    /// Read and write contacts.
    public static let contacts = "https://www.googleapis.com/auth/contacts"
    /// Read "Other contacts" (people you emailed but never saved).
    public static let otherContactsReadonly = "https://www.googleapis.com/auth/contacts.other.readonly"
    /// The signed-in account's address. people/me only returns it with this scope, not with `contacts`.
    public static let email = "https://www.googleapis.com/auth/userinfo.email"
    public static let all = [contacts, otherContactsReadonly, email]
}
