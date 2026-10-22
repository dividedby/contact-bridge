import Foundation

public enum GoogleListingError: Error, Sendable, Equatable {
    /// A paged listing repeated a page token or ran past the page limit.
    case pagingDidNotTerminate(String)
}

extension GoogleContactsClient {
    private static var maxListingPages: Int { 1000 }

    /// Every connection, following page tokens to the end. A full listing, so no sync token is sent.
    public func allConnections() async throws -> [GooglePerson] {
        try await Self.allPages("connections") { try await self.listConnections(syncToken: nil, pageToken: $0) }
    }

    /// Every "Other contact", following page tokens to the end.
    public func allOtherContacts() async throws -> [GooglePerson] {
        try await Self.allPages("otherContacts") { try await self.listOtherContacts(pageToken: $0) }
    }

    /// A repeated token, or more than 1000 pages, throws instead of looping.
    private static func allPages(_ source: String, _ fetch: (String?) async throws -> GooglePeoplePage) async throws -> [GooglePerson] {
        var people: [GooglePerson] = []
        var seen = Set<String>()
        var token: String?
        var pages = 0
        while true {
            let page = try await fetch(token)
            people += page.people
            pages += 1
            guard let next = page.nextPageToken else { return people }
            guard pages < maxListingPages, seen.insert(next).inserted else { throw GoogleListingError.pagingDidNotTerminate(source) }
            token = next
        }
    }
}
