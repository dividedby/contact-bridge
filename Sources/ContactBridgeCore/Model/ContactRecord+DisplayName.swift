import Foundation

extension ContactRecord {
    /// What to call this contact in lists and confirmations: the person's name, else the organization, else the first
    /// thing that identifies them.
    public var displayName: String {
        let person = [givenName, middleName, familyName].filter { !$0.isBlank }.joined(separator: " ")
        if !person.isEmpty { return person }
        for candidate in [organization, nickname, emails.first?.value ?? "", phones.first?.value ?? ""] where !candidate.isBlank {
            return candidate
        }
        return "(No name)"
    }
}
