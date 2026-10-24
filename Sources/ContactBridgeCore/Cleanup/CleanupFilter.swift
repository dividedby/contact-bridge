import Foundation

/// One contact as the Clean up list shows it, with the facts the filters ask about worked out once.
public struct CleanupRow: Sendable, Hashable, Identifiable {
    /// The contact's store identifier: what a delete and the import links go by.
    public var id: String
    /// The name, else the organization, else "No name".
    public var displayName: String
    /// The first phone, else the first email; empty when there is neither.
    public var detail: String
    public var isTextMessageSender: Bool
    /// No name parts and no organization.
    public var hasNoName: Bool
    public var hasNoPhoneOrEmail: Bool
    /// Created by a Contact Bridge import (the id is in the link table).
    public var isImported: Bool

    /// Case- and diacritic-folded name parts, organization, phones and emails, one per line.
    fileprivate var searchText: String
    fileprivate var phoneDigits: [String]

    public init(record: ContactRecord, isImported: Bool) {
        let nameParts = [record.givenName, record.middleName, record.familyName].filter { !$0.isBlank }
        let phones = record.phones.map(\.value).filter { !$0.isBlank }
        let emails = record.emails.map(\.value).filter { !$0.isBlank }
        id = record.sourceIdentifier
        if !nameParts.isEmpty {
            displayName = nameParts.joined(separator: " ")
        } else if !record.nickname.isBlank {
            displayName = record.nickname
        } else if !record.organization.isBlank {
            displayName = record.organization
        } else {
            displayName = "No name"
        }
        detail = phones.first ?? emails.first ?? ""
        isTextMessageSender = record.isShortCodeSender
        hasNoName = nameParts.isEmpty && record.nickname.isBlank && record.organization.isBlank
        hasNoPhoneOrEmail = phones.isEmpty && emails.isEmpty
        self.isImported = isImported
        searchText = ([record.givenName, record.middleName, record.familyName, record.nickname, record.organization] + phones + emails)
            .map(Self.fold).joined(separator: "\n")
        phoneDigits = phones.map { $0.filter(\.isNumber) }
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Every word of the query is in the name, organization, a phone or an email. A word made of digits and phone
    /// punctuation also matches a phone by its digits, so "415 555" finds "(415) 555-2671".
    fileprivate func matches(searchWords words: [(folded: String, digits: String?)]) -> Bool {
        words.allSatisfy { word in
            if searchText.contains(word.folded) { return true }
            guard let digits = word.digits else { return false }
            return phoneDigits.contains { $0.contains(digits) }
        }
    }
}

/// Which contacts the Clean up list shows. The four options combine with AND: a contact must match every one that is on.
public struct CleanupFilter: Sendable, Equatable {
    public var textMessageSenders: Bool
    public var noName: Bool
    public var noPhoneOrEmail: Bool
    public var importedByContactBridge: Bool
    public var search: String

    public init(
        textMessageSenders: Bool = false, noName: Bool = false, noPhoneOrEmail: Bool = false, importedByContactBridge: Bool = false,
        search: String = ""
    ) {
        self.textMessageSenders = textMessageSenders
        self.noName = noName
        self.noPhoneOrEmail = noPhoneOrEmail
        self.importedByContactBridge = importedByContactBridge
        self.search = search
    }

    /// Any of the four options is on.
    public var hasActiveOptions: Bool { textMessageSenders || noName || noPhoneOrEmail || importedByContactBridge }

    /// The rows that pass every active option and the search, in their given order.
    public func apply(to rows: [CleanupRow]) -> [CleanupRow] {
        let words = search.split(whereSeparator: \.isWhitespace).map { word in
            let text = String(word)
            let isPhoneLike = text.allSatisfy { $0.isNumber || "+-().".contains($0) }
            let digits = text.filter(\.isNumber)
            return (folded: CleanupRow.fold(text), digits: isPhoneLike && !digits.isEmpty ? digits : nil)
        }
        return rows.filter { row in
            (!textMessageSenders || row.isTextMessageSender)
                && (!noName || row.hasNoName)
                && (!noPhoneOrEmail || row.hasNoPhoneOrEmail)
                && (!importedByContactBridge || row.isImported)
                && row.matches(searchWords: words)
        }
    }
}
