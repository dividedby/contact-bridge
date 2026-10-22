extension ContactRecord {
    /// Non-empty phones, normalized. Unnormalizable entries are included (flagged) so callers can still compare them as-is.
    public var normalizedPhones: [NormalizedPhone] {
        phones.map { PhoneNormalizer.normalize($0.value) }.filter { !$0.value.isEmpty }
    }

    public var normalizedEmails: [String] {
        emails.compactMap { EmailNormalizer.normalize($0.value) }
    }

    public var givenNameMatchKey: String { NameNormalizer.givenNameMatchKey(givenName) }
    public var familyNameMatchKey: String { NameNormalizer.familyNameMatchKey(familyName) }

    /// An automated text-message sender: only SMS short-code phones, no person name, no email. Often just a company name.
    public var isShortCodeSender: Bool {
        let phones = normalizedPhones
        return !phones.isEmpty && phones.allSatisfy(\.isShortCode)
            && [givenName, middleName, familyName, nickname].allSatisfy(\.isBlank)
            && normalizedEmails.isEmpty
    }
}
