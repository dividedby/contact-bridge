import Foundation

/// In-memory People API for tests and previews. Models the behaviours the sync code depends on: etags that change on
/// every write, server-computed fields (primary flags, entry sources, canonical phone forms, display names),
/// `updatePersonFields` masks (read-only profile entries survive edits), sync tokens (changes since a token, deleted
/// stubs, expiry), pagination from a snapshot taken at the first page, 200-item batch chunking, and injectable failures.
public actor FakeGoogleClient: GoogleContactsClient {
    public enum Operation: Hashable, Sendable {
        case listConnections, listOtherContacts, getPerson
        case createContact, updateContact, deleteContact
        case batchCreate, batchUpdate, batchDelete
        case ensureGroup, addMembers
    }

    public enum Failure: Sendable {
        /// Fails the whole call before it has any effect.
        case error(GoogleAPIError)
        /// For batch calls: fails only the items at these positions (within one chunk) and applies the rest.
        case partialBatch(indices: Set<Int>, error: GoogleAPIError)

        public static func rateLimited(retryAfter: TimeInterval? = nil) -> Failure { .error(.rateLimited(retryAfter: retryAfter)) }
        public static var etagMismatch: Failure { .error(.etagMismatch) }
    }

    private struct Injection {
        var operation: Operation?
        var failure: Failure
        var remaining: Int
    }

    private struct Change {
        var version: Int
        var resourceName: String
        var deleted: Bool
    }

    private var people: [String: GooglePerson] = [:]
    private var order: [String] = []
    private var others: [GooglePerson]
    private var groups: [String: GoogleContactGroup] = [:]
    private var changes: [Change] = []
    private var version = 0
    private var expiredBefore = 0
    private var nextID = 1
    private var nextGroupID = 1
    private var injections: [Injection] = []
    private var batchSizes: [Operation: [Int]] = [:]
    private var snapshots: [Int: Snapshot] = [:]
    private var nextSnapshotID = 1
    private let pageSize: Int

    /// What a paginated listing sees: fixed when the first page is served.
    private struct Snapshot {
        var items: [GooglePerson]
        var version: Int
    }

    public init(people seeded: [GooglePerson] = [], otherContacts: [GooglePerson] = [], pageSize: Int = 100) {
        self.pageSize = max(pageSize, 1)
        self.others = otherContacts.enumerated().map { index, person in
            var person = person
            person.resourceName = person.resourceName ?? "otherContacts/c\(index + 1)"
            person.etag = person.etag ?? "e0"
            return person
        }
        // Seeding is the starting state, not a change to sync, so nothing is logged.
        var seededPeople: [String: GooglePerson] = [:]
        var seededOrder: [String] = []
        var counter = 1
        var seededVersion = 0
        for var person in seeded {
            let name = person.resourceName ?? "people/c\(counter)"
            counter += 1
            seededVersion += 1
            person.resourceName = name
            person = Self.stamp(person, resourceName: name, version: seededVersion)
            if seededPeople[name] == nil { seededOrder.append(name) }
            seededPeople[name] = person
        }
        self.people = seededPeople
        self.order = seededOrder
        self.nextID = counter
        self.version = seededVersion
    }

    // MARK: test controls

    /// Queues a failure. With `operation` nil it hits whatever is called next; it applies `times` times.
    public func inject(_ failure: Failure, on operation: Operation? = nil, times: Int = 1) {
        injections.append(Injection(operation: operation, failure: failure, remaining: times))
    }

    /// Invalidates every sync token issued so far (as Google does after ~7 days or on server-side resets).
    public func expireSyncTokens() {
        version += 1
        expiredBefore = version
    }

    /// Chunk sizes of the underlying batch calls made so far for `operation`.
    public func batchCallSizes(_ operation: Operation) -> [Int] { batchSizes[operation] ?? [] }

    /// Current contacts in creation order.
    public var allPeople: [GooglePerson] { order.compactMap { people[$0] } }

    // MARK: reads

    public func listConnections(syncToken: String?, pageToken: String?) async throws -> GooglePeoplePage {
        try fail(.listConnections)
        var fresh: Snapshot?
        if pageToken == nil {
            let items: [GooglePerson]
            if let syncToken {
                guard let since = Self.version(fromSyncToken: syncToken) else {
                    throw GoogleAPIError.other(status: 400, message: "Invalid sync token")
                }
                guard since >= expiredBefore else { throw GoogleAPIError.syncTokenExpired }
                var lastChange: [String: Bool] = [:]
                for change in changes where change.version > since { lastChange[change.resourceName] = change.deleted }
                items = lastChange.keys.sorted(by: orderedBefore).compactMap { name in
                    if lastChange[name] == true {
                        return GooglePerson(resourceName: name, metadata: GooglePersonMetadata(deleted: true, objectType: "PERSON"))
                    }
                    return people[name]
                }
            } else {
                items = allPeople
            }
            fresh = Snapshot(items: items, version: version)
        }
        let (slice, next, snapshotVersion) = try page(fresh, pageToken: pageToken)
        return GooglePeoplePage(people: slice, nextPageToken: next, nextSyncToken: next == nil ? "sync-\(snapshotVersion)" : nil)
    }

    public func listOtherContacts(pageToken: String?) async throws -> GooglePeoplePage {
        try fail(.listOtherContacts)
        let fresh = pageToken == nil ? Snapshot(items: others, version: version) : nil
        let (slice, next, _) = try page(fresh, pageToken: pageToken)
        return GooglePeoplePage(people: slice, nextPageToken: next)
    }

    public func getPerson(resourceName: String) async throws -> GooglePerson {
        try fail(.getPerson)
        if let person = people[resourceName] ?? others.first(where: { $0.resourceName == resourceName }) { return person }
        throw GoogleAPIError.notFound
    }

    // MARK: single writes

    public func createContact(_ person: GooglePerson) async throws -> GooglePerson {
        try fail(.createContact)
        try Self.checkClientData(person.clientData)
        return store(person)
    }

    public func updateContact(
        resourceName: String, etag: String, person: GooglePerson, updatePersonFields: String
    ) async throws -> GooglePerson {
        try fail(.updateContact)
        return try applyUpdate(resourceName: resourceName, etag: etag, person: person, mask: updatePersonFields)
    }

    public func deleteContact(resourceName: String) async throws {
        try fail(.deleteContact)
        try remove(resourceName)
    }

    // MARK: batches

    public func batchCreate(_ batch: [GooglePerson]) async throws -> [GoogleBatchResult] {
        try runBatch(.batchCreate, batch) { person in
            try Self.checkClientData(person.clientData)
            let created = self.store(person)
            return GoogleBatchResult(resourceName: created.resourceName, person: created)
        }
    }

    public func batchUpdate(_ updates: [GoogleContactUpdate]) async throws -> [GoogleBatchResult] {
        var results = [GoogleBatchResult?](repeating: nil, count: updates.count)
        for group in updates.maskGroupedChunks() {
            let mask = group[0].update.updatePersonFields
            let outcome = try runBatch(.batchUpdate, group.map(\.update)) { update in
                let updated = try self.applyUpdate(
                    resourceName: update.resourceName, etag: update.etag, person: update.person, mask: mask
                )
                return GoogleBatchResult(resourceName: update.resourceName, person: updated)
            } resourceName: { $0.resourceName }
            for (position, result) in outcome.enumerated() { results[group[position].index] = result }
        }
        return results.compactMap { $0 }
    }

    /// Like the real endpoint, a missing resource fails the whole call (per chunk), and nothing in that chunk is deleted.
    public func batchDelete(_ resourceNames: [String]) async throws {
        for chunk in resourceNames.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            try fail(.batchDelete)
            batchSizes[.batchDelete, default: []].append(chunk.count)
            guard chunk.allSatisfy({ people[$0] != nil }) else { throw GoogleAPIError.notFound }
            for name in chunk where people[name] != nil { try remove(name) }
        }
    }

    private func runBatch<Item>(
        _ operation: Operation, _ items: [Item],
        apply: (Item) throws -> GoogleBatchResult,
        resourceName: (Item) -> String? = { _ in nil }
    ) throws -> [GoogleBatchResult] {
        var results: [GoogleBatchResult] = []
        for chunk in items.chunked(into: GoogleBatchLimits.maxItemsPerCall) {
            let partial = try failBatch(operation)
            batchSizes[operation, default: []].append(chunk.count)
            for (index, item) in chunk.enumerated() {
                if let error = partial[index] {
                    results.append(GoogleBatchResult(resourceName: resourceName(item), error: error))
                    continue
                }
                do {
                    results.append(try apply(item))
                } catch let error as GoogleAPIError {
                    results.append(GoogleBatchResult(resourceName: resourceName(item), error: error))
                }
            }
        }
        return results
    }

    // MARK: groups

    public func ensureGroup(named name: String) async throws -> String {
        try fail(.ensureGroup)
        if let existing = groups.values.first(where: { $0.name == name }), let resourceName = existing.resourceName {
            return resourceName
        }
        let resourceName = "contactGroups/\(String(nextGroupID + 0xA0B0, radix: 16))"
        nextGroupID += 1
        groups[resourceName] = GoogleContactGroup(resourceName: resourceName, etag: "g0", name: name, groupType: "USER_CONTACT_GROUP", memberCount: 0)
        return resourceName
    }

    public func addMembers(groupResourceName: String, memberResourceNames: [String]) async throws {
        try fail(.addMembers)
        guard var group = groups[groupResourceName] else { throw GoogleAPIError.notFound }
        guard memberResourceNames.allSatisfy({ people[$0] != nil }) else { throw GoogleAPIError.notFound }
        let groupID = String(groupResourceName.dropFirst("contactGroups/".count))
        for name in memberResourceNames {
            guard var person = people[name] else { continue }
            var memberships = person.memberships ?? []
            if memberships.contains(where: { $0.contactGroupMembership?.contactGroupResourceName == groupResourceName }) { continue }
            memberships.append(GoogleMembership(
                contactGroupMembership: GoogleContactGroupMembership(contactGroupId: groupID, contactGroupResourceName: groupResourceName)
            ))
            person.memberships = memberships
            commit(person, deleted: false)
            group.memberCount = (group.memberCount ?? 0) + 1
        }
        groups[groupResourceName] = group
    }

    // MARK: internals

    private func store(_ person: GooglePerson) -> GooglePerson {
        var person = person
        let name = person.resourceName ?? "people/c\(nextID)"
        nextID += 1
        person.resourceName = name
        if people[name] == nil { order.append(name) }
        commit(person, deleted: false)
        return people[name] ?? person
    }

    /// Stores `person`, bumping the global version and the person's etag and restamping server-computed fields, and logs
    /// the change for sync.
    private func commit(_ person: GooglePerson, deleted: Bool) {
        version += 1
        guard let name = person.resourceName else { return }
        people[name] = deleted ? person : Self.stamp(person, resourceName: name, version: version)
        changes.append(Change(version: version, resourceName: name, deleted: deleted))
    }

    private static let acceptedMasks: Set<String> = [
        "addresses", "ageRanges", "biographies", "birthdays", "calendarUrls", "clientData", "emailAddresses", "events",
        "externalIds", "genders", "imClients", "interests", "locales", "locations", "memberships", "miscKeywords",
        "names", "nicknames", "occupations", "organizations", "phoneNumbers", "relations", "sipAddresses", "urls", "userDefined",
    ]

    private func applyUpdate(resourceName: String, etag: String, person: GooglePerson, mask: String) throws -> GooglePerson {
        guard var stored = people[resourceName] else { throw GoogleAPIError.notFound }
        guard stored.etag == etag else { throw GoogleAPIError.etagMismatch }
        let fields = mask.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let bad = fields.first(where: { !Self.acceptedMasks.contains($0) }) {
            throw GoogleAPIError.other(status: 400, message: "Invalid updatePersonFields: \(bad)")
        }
        if fields.contains("clientData") { try Self.checkClientData(person.clientData) }
        for field in fields {
            switch field {
            case "names": stored.names = Self.replacingContactEntries(stored.names, with: person.names)
            case "nicknames": stored.nicknames = Self.replacingContactEntries(stored.nicknames, with: person.nicknames)
            case "organizations": stored.organizations = Self.replacingContactEntries(stored.organizations, with: person.organizations)
            case "phoneNumbers": stored.phoneNumbers = Self.replacingContactEntries(stored.phoneNumbers, with: person.phoneNumbers)
            case "emailAddresses": stored.emailAddresses = Self.replacingContactEntries(stored.emailAddresses, with: person.emailAddresses)
            case "addresses": stored.addresses = Self.replacingContactEntries(stored.addresses, with: person.addresses)
            case "urls": stored.urls = Self.replacingContactEntries(stored.urls, with: person.urls)
            case "birthdays": stored.birthdays = Self.replacingContactEntries(stored.birthdays, with: person.birthdays)
            case "memberships": stored.memberships = person.memberships
            case "clientData": stored.clientData = person.clientData
            default: stored.extras[field] = person.extras[field]
            }
        }
        commit(stored, deleted: false)
        return people[resourceName] ?? stored
    }

    private static func checkClientData(_ entries: [GoogleClientData]?) throws {
        if (entries?.count ?? 0) > 10 {
            throw GoogleAPIError.other(status: 400, message: "A person can have at most 10 clientData entries")
        }
    }

    /// Entries from the contact are replaced by the request's; entries merged in from a profile or directory are
    /// read-only and stay.
    private static func replacingContactEntries<T: GoogleMetadataCarrying>(_ stored: [T]?, with incoming: [T]?) -> [T]? {
        let readOnly = (stored ?? []).filter { !GooglePersonMapper.isContactSourced($0) }
        let writable = (incoming ?? []).filter(GooglePersonMapper.isContactSourced)
        let merged = writable + readOnly
        return merged.isEmpty ? nil : merged
    }

    private func remove(_ resourceName: String) throws {
        guard var person = people[resourceName] else { throw GoogleAPIError.notFound }
        order.removeAll { $0 == resourceName }
        person.metadata = GooglePersonMetadata(deleted: true, objectType: "PERSON")
        commit(person, deleted: true)
        people[resourceName] = nil
    }

    private func orderedBefore(_ a: String, _ b: String) -> Bool {
        let ia = order.firstIndex(of: a) ?? Int.max
        let ib = order.firstIndex(of: b) ?? Int.max
        return ia == ib ? a < b : ia < ib
    }

    /// Serves one page. `fresh` is a new snapshot for a first page; later pages read the snapshot named by the token, so
    /// changes made mid-pagination never shift offsets. The returned version is the snapshot's, for the sync token.
    private func page(_ fresh: Snapshot?, pageToken: String?) throws -> (people: [GooglePerson], next: String?, version: Int) {
        var snapshotID = 0
        var offset = 0
        var snapshot: Snapshot
        if let fresh {
            snapshot = fresh
            snapshotID = nextSnapshotID
        } else {
            let parts = (pageToken ?? "").split(separator: "-")
            guard parts.count == 3, parts[0] == "page", let id = Int(parts[1]), let start = Int(parts[2]),
                  let known = snapshots[id], start >= 0
            else { throw GoogleAPIError.other(status: 400, message: "Invalid page token") }
            snapshot = known
            snapshotID = id
            offset = start
        }
        guard offset < snapshot.items.count else {
            snapshots[snapshotID] = nil
            return ([], nil, snapshot.version)
        }
        let end = min(offset + pageSize, snapshot.items.count)
        let slice = Array(snapshot.items[offset..<end])
        guard end < snapshot.items.count else {
            snapshots[snapshotID] = nil
            return (slice, nil, snapshot.version)
        }
        if fresh != nil {
            nextSnapshotID += 1
            snapshots[snapshotID] = snapshot
        }
        return (slice, "page-\(snapshotID)-\(end)", snapshot.version)
    }

    private static func version(fromSyncToken token: String) -> Int? {
        token.hasPrefix("sync-") ? Int(token.dropFirst(5)) : nil
    }

    // MARK: server-computed fields

    /// What Google fills in on every write: person sources and etag, each entry's source, the primary flag, canonical
    /// phone forms, formatted types and display names. Entries that already carry a source (profile entries) are left alone.
    static func stamp(_ person: GooglePerson, resourceName: String, version: Int) -> GooglePerson {
        var person = person
        let id = String(resourceName.split(separator: "/").last ?? "")
        person.etag = "e\(version)"

        var metadata = person.metadata ?? GooglePersonMetadata()
        metadata.objectType = "PERSON"
        let updateTime = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_767_225_600 + Double(version)))
        let contactSource = GoogleSource(type: "CONTACT", id: id, etag: "#e\(version)", updateTime: updateTime)
        metadata.sources = (metadata.sources ?? []).filter { $0.type != "CONTACT" } + [contactSource]
        person.metadata = metadata

        person.names = stampList(person.names, id: id)
        person.nicknames = stampList(person.nicknames, id: id)
        person.organizations = stampList(person.organizations, id: id)
        person.phoneNumbers = stampList(person.phoneNumbers, id: id)
        person.emailAddresses = stampList(person.emailAddresses, id: id)
        person.addresses = stampList(person.addresses, id: id)
        person.urls = stampList(person.urls, id: id)
        person.birthdays = stampList(person.birthdays, id: id)

        person.names = person.names?.map { name in
            guard GooglePersonMapper.isContactSourced(name) else { return name }
            var name = name
            let parts = [name.givenName, name.middleName, name.familyName].compactMap { $0 }.filter { !$0.isEmpty }
            let display = parts.joined(separator: " ")
            name.displayName = display.isEmpty ? nil : display
            name.unstructuredName = name.displayName
            let tail = [name.givenName, name.middleName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            name.displayNameLastFirst = display.isEmpty ? nil : [name.familyName, tail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return name
        }
        let personDisplayName = person.names?.first(where: { $0.metadata?.primary == true })?.displayName ?? person.names?.first?.displayName

        person.phoneNumbers = person.phoneNumbers?.map { phone in
            guard GooglePersonMapper.isContactSourced(phone) else { return phone }
            var phone = phone
            let normalized = phone.value.map { PhoneNormalizer.normalize($0) }
            phone.canonicalForm = normalized?.isNormalizable == true ? normalized?.value : nil
            phone.formattedType = formattedType(phone.type)
            return phone
        }
        person.emailAddresses = person.emailAddresses?.map { email in
            guard GooglePersonMapper.isContactSourced(email) else { return email }
            var email = email
            email.formattedType = formattedType(email.type)
            email.displayName = personDisplayName
            return email
        }
        person.urls = person.urls?.map { url in
            guard GooglePersonMapper.isContactSourced(url) else { return url }
            var url = url
            url.formattedType = formattedType(url.type)
            return url
        }
        person.organizations = person.organizations?.map { organization in
            guard GooglePersonMapper.isContactSourced(organization) else { return organization }
            var organization = organization
            organization.formattedType = formattedType(organization.type)
            return organization
        }
        person.addresses = person.addresses?.map { address in
            guard GooglePersonMapper.isContactSourced(address) else { return address }
            var address = address
            address.formattedType = formattedType(address.type)
            let cityLine = [address.city, address.region, address.postalCode].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let lines = [address.streetAddress, address.extendedAddress, cityLine.isEmpty ? nil : cityLine, address.country]
            address.formattedValue = lines.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            return address
        }
        return person
    }

    /// Gives unsourced entries a CONTACT source, and the first contact entry the primary flag if the list has none.
    private static func stampList<T: GoogleMetadataCarrying>(_ list: [T]?, id: String) -> [T]? {
        guard var entries = list else { return nil }
        for index in entries.indices where entries[index].metadata?.source == nil {
            var metadata = entries[index].metadata ?? GoogleFieldMetadata()
            metadata.source = GoogleSource(type: "CONTACT", id: id)
            entries[index].metadata = metadata
        }
        if !entries.contains(where: { $0.metadata?.primary == true }),
           let first = entries.firstIndex(where: GooglePersonMapper.isContactSourced) {
            entries[first].metadata?.primary = true
        }
        return entries
    }

    private static let formattedTypes: [String: String] = [
        "homeFax": "Home Fax", "workFax": "Work Fax", "otherFax": "Other Fax", "workMobile": "Work Mobile",
        "workPager": "Work Pager", "googleVoice": "Google Voice", "homePage": "Home Page", "appInstallPage": "App Install Page",
    ]

    private static func formattedType(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }
        return formattedTypes[type] ?? (["mobile", "home", "work", "other", "main", "pager", "blog", "profile", "ftp", "reservations"].contains(type)
            ? type.prefix(1).uppercased() + type.dropFirst() : type)
    }

    // MARK: failure injection

    private func takeInjection(_ operation: Operation, batch: Bool) -> Failure? {
        guard let index = injections.firstIndex(where: { injection in
            injection.remaining > 0 && (injection.operation == nil || injection.operation == operation) && {
                if case .partialBatch = injection.failure { return batch }
                return true
            }()
        }) else { return nil }
        injections[index].remaining -= 1
        return injections[index].failure
    }

    private func fail(_ operation: Operation) throws {
        if case .error(let error)? = takeInjection(operation, batch: false) { throw error }
    }

    /// Whole-call failures throw; partial ones return the per-position errors to apply.
    private func failBatch(_ operation: Operation) throws -> [Int: GoogleAPIError] {
        switch takeInjection(operation, batch: true) {
        case .error(let error)?: throw error
        case .partialBatch(let indices, let error)?: return Dictionary(uniqueKeysWithValues: indices.map { ($0, error) })
        case nil: return [:]
        }
    }
}
