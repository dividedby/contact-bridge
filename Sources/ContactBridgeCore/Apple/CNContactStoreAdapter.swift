import Contacts
import Foundation

/// `ContactStoring` over the real Contacts database, scoped to one CardDAV (iCloud) container.
///
/// Container policy (see `ContainerSelection`): never silently write to a Gmail/Google CardDAV container. When the
/// choice is ambiguous, calls throw `ContactStoreError.containerChoiceRequired`; call `containers()`, let the user
/// pick, and build a new adapter with `containerID:`.
///
/// Not exercised by automated tests: it needs the real store and the Contacts permission. The pure parts
/// (`CNContactMapper`, `ContainerSelection`) are tested.
public final class CNContactStoreAdapter: ContactStoring, @unchecked Sendable {
    // CNContactStore is documented as thread-safe but is not annotated Sendable.
    private let store: CNContactStore
    private let explicitContainerID: String?
    /// CN calls block (and can take seconds on large books), so they run here rather than on the cooperative pool.
    private let queue = DispatchQueue(label: "ContactBridge.CNContactStoreAdapter", qos: .userInitiated)

    public init(store: CNContactStore = CNContactStore(), containerID: String? = nil) {
        self.store = store
        self.explicitContainerID = containerID
    }

    // MARK: authorization

    public func authorizationStatus() async -> ContactAuthorization {
        Self.map(CNContactStore.authorizationStatus(for: .contacts))
    }

    public func requestAccess() async throws -> ContactAuthorization {
        _ = try await store.requestAccess(for: .contacts)
        return await authorizationStatus()
    }

    private static func map(_ status: CNAuthorizationStatus) -> ContactAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .authorized
        @unknown default: .denied
        }
    }

    private func requireAccess() async throws {
        guard await authorizationStatus() == .authorized else { throw ContactStoreError.accessDenied }
    }

    // MARK: containers

    /// Every container, so the UI can offer a choice.
    public func containers() async throws -> [ContactContainer] {
        try await requireAccess()
        return try await onQueue { try self.allContainers() }
    }

    private func allContainers() throws -> [ContactContainer] {
        let defaultID = store.defaultContainerIdentifier()
        return try store.containers(matching: nil).map { container in
            ContactContainer(
                id: container.identifier,
                name: container.name,
                kind: Self.map(container.type),
                isDefault: container.identifier == defaultID
            )
        }
    }

    private static func map(_ type: CNContainerType) -> ContactContainer.Kind {
        switch type {
        case .local: .local
        case .exchange: .exchange
        case .cardDAV: .cardDAV
        case .unassigned: .unassigned
        @unknown default: .unassigned
        }
    }

    /// The container every call reads from and writes to.
    private func resolveContainer() throws -> ContactContainer {
        let all = try allContainers()
        if let explicitContainerID {
            guard let chosen = all.first(where: { $0.id == explicitContainerID && $0.kind == .cardDAV }) else {
                throw ContactStoreError.noICloudContainer
            }
            return chosen
        }
        switch ContainerSelection.choose(from: all) {
        case .selected(let container): return container
        case .needsUserChoice(let options): throw ContactStoreError.containerChoiceRequired(options)
        case .none: throw ContactStoreError.noICloudContainer
        }
    }

    // MARK: reads

    public func fetchAll() async throws -> [ContactRecord] {
        try await requireAccess()
        return try await onQueue {
            let container = try self.resolveContainer()
            let predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.id)
            return try self.fetch(predicate: predicate, keys: CNContactMapper.requiredKeys).map(CNContactMapper.record(from:))
        }
    }

    /// Uses `CNContactVCardSerialization`; if the system refuses its required keys (the gated note key,
    /// `CNError.unauthorizedKeys`), falls back to `VCardWriter`, which has no notes (backups get them from `ContactsAppNotesProvider`
    /// as `icloud-notes.json`).
    public func exportVCard(ids: [String]) async throws -> Data {
        try await requireAccess()
        return try await onQueue {
            let container = try self.resolveContainer()
            try self.requireInContainer(try self.fetchContacts(ids: ids, keys: [CNContactIdentifierKey as NSString]), container)
            do {
                let contacts = try self.fetchContacts(ids: ids, keys: [CNContactVCardSerialization.descriptorForRequiredKeys()])
                return try CNContactVCardSerialization.data(with: contacts)
            } catch where CNContactMapper.isUnauthorizedKeys(error) {
                return VCardWriter.data(for: try self.fetchContacts(ids: ids, keys: CNContactMapper.mergeKeys))
            }
        }
    }

    // MARK: writes

    /// Saves, then refetches the new contact and returns what the store actually holds.
    public func create(_ record: ContactRecord, backup: BackupReceipt) async throws -> ContactRecord {
        try await requireAccess()
        return try await onQueue {
            let container = try self.resolveContainer()
            let contact = CNContactMapper.makeContact(from: record)
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: container.id)
            try self.store.execute(request)

            let stored = try self.fetchContacts(ids: [contact.identifier], keys: CNContactMapper.requiredKeys)
            try self.requireInContainer(stored, container)
            return CNContactMapper.record(from: stored[0])
        }
    }

    public func update(_ record: ContactRecord, backup: BackupReceipt) async throws {
        try await requireAccess()
        try await onQueue {
            let container = try self.resolveContainer()
            let contacts = try self.fetchContacts(ids: [record.sourceIdentifier], keys: CNContactMapper.requiredKeys)
            try self.requireInContainer(contacts, container)
            guard let working = contacts[0].mutableCopy() as? CNMutableContact else {
                throw ContactStoreError.notFound([record.sourceIdentifier])
            }
            CNContactMapper.apply(record, to: working)
            let request = CNSaveRequest()
            request.update(working)
            try self.store.execute(request)
        }
    }

    /// One CNSaveRequest: update the survivor (record fields plus what the duplicates carry that ContactRecord cannot
    /// express) and delete the duplicates. Never requests notes:
    /// `MergeExecutor` combines and writes them separately, after this call succeeds.
    public func merge(survivor: ContactRecord, absorbing ids: [String], backup: BackupReceipt) async throws {
        try await requireAccess()
        try await onQueue {
            let container = try self.resolveContainer()
            var seen: Set<String> = [survivor.sourceIdentifier]
            let duplicateIDs = ids.filter { seen.insert($0).inserted }

            let contacts = try self.fetchContacts(ids: [survivor.sourceIdentifier] + duplicateIDs, keys: CNContactMapper.mergeKeys)
            try self.requireInContainer(contacts, container)
            guard let working = contacts[0].mutableCopy() as? CNMutableContact else {
                throw ContactStoreError.notFound([survivor.sourceIdentifier])
            }
            let duplicates = Array(contacts.dropFirst())

            CNContactMapper.absorb(duplicates, into: working)
            CNContactMapper.apply(survivor, to: working)

            let request = CNSaveRequest()
            request.update(working)
            for duplicate in duplicates {
                if let doomed = duplicate.mutableCopy() as? CNMutableContact { request.delete(doomed) }
            }
            try self.store.execute(request)
        }
    }

    public func delete(ids: [String], backup: BackupReceipt) async throws {
        try await requireAccess()
        try await onQueue {
            let container = try self.resolveContainer()
            let contacts = try self.fetchContacts(ids: ids, keys: [CNContactIdentifierKey as NSString])
            try self.requireInContainer(contacts, container)
            let request = CNSaveRequest()
            for contact in contacts {
                if let doomed = contact.mutableCopy() as? CNMutableContact { request.delete(doomed) }
            }
            try self.store.execute(request)
        }
    }

    // MARK: photos

    /// Identifiers per predicate: the Contacts framework slows down on very long `withIdentifiers` lists.
    private static let photoPredicateChunk = 100

    private static var photoSignatureKeys: [CNKeyDescriptor] {
        [CNContactIdentifierKey, CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey].map { $0 as NSString }
    }

    /// Reads only the availability flag and the small thumbnail, in chunks. Contacts outside the container are left out, as
    /// are ids that no longer exist.
    public func photoSignatures(ids: [String]) async throws -> [String: PhotoSignature] {
        try await requireAccess()
        return try await onQueue {
            let container = try self.resolveContainer()
            let inContainer = Set(
                try self.fetch(predicate: CNContact.predicateForContactsInContainer(withIdentifier: container.id), keys: [CNContactIdentifierKey as NSString])
                    .map(\.identifier)
            )
            let wanted = Array(Set(ids)).filter(inContainer.contains).sorted()
            var signatures: [String: PhotoSignature] = [:]
            for chunk in wanted.chunked(into: Self.photoPredicateChunk) {
                for contact in try self.fetch(predicate: CNContact.predicateForContacts(withIdentifiers: chunk), keys: Self.photoSignatureKeys) {
                    signatures[contact.identifier] = PhotoSignature(
                        hasPhoto: contact.imageDataAvailable, thumbnailHash: contact.thumbnailImageData.map(PhotoHash.sha256Hex)
                    )
                }
            }
            return signatures
        }
    }

    public func photoData(id: String) async throws -> Data? {
        try await requireAccess()
        return try await onQueue {
            let container = try self.resolveContainer()
            let contacts = try self.fetchContacts(ids: [id], keys: [CNContactIdentifierKey, CNContactImageDataAvailableKey, CNContactImageDataKey].map { $0 as NSString })
            try self.requireInContainer(contacts, container)
            return contacts[0].imageDataAvailable ? contacts[0].imageData : nil
        }
    }

    public func setPhoto(id: String, data: Data?, backup: BackupReceipt) async throws {
        try await requireAccess()
        try await onQueue {
            let container = try self.resolveContainer()
            let contacts = try self.fetchContacts(ids: [id], keys: [CNContactIdentifierKey, CNContactImageDataKey].map { $0 as NSString })
            try self.requireInContainer(contacts, container)
            guard let working = contacts[0].mutableCopy() as? CNMutableContact else { throw ContactStoreError.notFound([id]) }
            working.imageData = data
            let request = CNSaveRequest()
            request.update(working)
            try self.store.execute(request)
        }
    }

    // MARK: change detection

    /// `CNContactStore.currentHistoryToken`: moves on any change to the store, including other containers and this
    /// process's own saves.
    public func changeToken() async throws -> Data? {
        try await requireAccess()
        return try await onQueue { self.store.currentHistoryToken }
    }

    public func containerID() async throws -> String? {
        try await requireAccess()
        return try await onQueue { try self.resolveContainer().id }
    }

    // MARK: changes

    public func changes() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = ObserverToken(
                NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { _ in
                    continuation.yield()
                }
            )
            continuation.onTermination = { _ in NotificationCenter.default.removeObserver(token.observer) }
        }
    }

    private final class ObserverToken: @unchecked Sendable {
        let observer: NSObjectProtocol
        init(_ observer: NSObjectProtocol) { self.observer = observer }
    }

    // MARK: helpers

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Raw (non-unified) contacts: linked contacts stay separate so dedupe sees every record.
    private func fetch(predicate: NSPredicate, keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = predicate
        request.unifyResults = false
        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in contacts.append(contact) }
        return contacts
    }

    /// In the order requested; throws `notFound` if any id is missing.
    private func fetchContacts(ids: [String], keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let fetched = try fetch(predicate: CNContact.predicateForContacts(withIdentifiers: ids), keys: keys)
        let byID = Dictionary(fetched.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = ids.filter { byID[$0] == nil }
        guard missing.isEmpty else { throw ContactStoreError.notFound(missing) }
        return ids.compactMap { byID[$0] }
    }

    private func requireInContainer(_ contacts: [CNContact], _ container: ContactContainer) throws {
        var outside: [String] = []
        for contact in contacts {
            let owners = try store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: contact.identifier))
            if owners.first?.identifier != container.id { outside.append(contact.identifier) }
        }
        guard outside.isEmpty else { throw ContactStoreError.outsideSelectedContainer(outside) }
    }
}
