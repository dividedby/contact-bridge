import Foundation

public struct ImportedLink: Sendable, Hashable {
    public var icloudID: String
    public var googleResourceName: String
    public var origin: LinkOrigin
    /// Stored with the link (`LinkEntry.displayName`) so a screen can name the contact after it is gone from iCloud.
    public var displayName: String?

    public init(icloudID: String, googleResourceName: String, origin: LinkOrigin = .imported, displayName: String? = nil) {
        self.icloudID = icloudID
        self.googleResourceName = googleResourceName
        self.origin = origin
        self.displayName = displayName
    }
}

/// What an import run did. A run that hits an error still returns normally, so the caller can show what was created.
public struct ImportResult: Sendable, Equatable {
    public struct Created: Sendable, Equatable {
        /// The Google resource name the record came from.
        public var candidateID: String
        /// The iCloud record as the store returned it, with its new identity.
        public var record: ContactRecord
    }

    public enum Stop: Sendable, Equatable {
        case failed(candidateID: String, reason: String)
        case cancelled
    }

    public var created: [Created] = []
    /// iCloud id to Google resource name, for records created from a connection.
    public var links: [ImportedLink] = []
    /// Why the run ended early; nil when every candidate was created.
    public var stopped: Stop?
    /// Selected candidates never attempted because of `stopped`, in order.
    public var notAttempted: [String] = []
    /// Set when contacts were created but the link file could not be written. `links` still holds what should be in it.
    public var linkSaveError: String?

    public var isComplete: Bool { stopped == nil }

    public init() {}
}

/// Creates the selected Google records in iCloud, one at a time, under a fresh backup. Stops at the first error.
///
/// Only candidates with `isSelected` are created. A record created from a Google connection is linked to its resource
/// name in the `LinkStoring` store, written once at the end (also after an early stop); "Other contacts" are not
/// linked because their resource names cannot be synced against.
public struct ImportExecutor: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// The receipt is older than `maxBackupAge`: nothing was created.
        case staleBackup
    }

    private let store: any ContactStoring
    private let receipt: BackupReceipt
    private let links: (any LinkStoring)?
    private let maxBackupAge: TimeInterval

    public init(store: any ContactStoring, receipt: BackupReceipt, links: (any LinkStoring)? = nil, maxBackupAge: TimeInterval = 3600) {
        self.store = store
        self.receipt = receipt
        self.links = links
        self.maxBackupAge = maxBackupAge
    }

    public func execute(_ candidates: [ImportCandidate], now: Date = Date()) async throws -> ImportResult {
        guard receipt.isFresh(maxAge: maxBackupAge, now: now) else { throw Failure.staleBackup }

        let selected = candidates.filter(\.isSelected)
        var result = ImportResult()
        for (index, candidate) in selected.enumerated() {
            if Task.isCancelled {
                result.stopped = .cancelled
                result.notAttempted = selected[index...].map(\.id)
                break
            }
            do {
                let stored = try await store.create(candidate.record, backup: receipt)
                result.created.append(ImportResult.Created(candidateID: candidate.id, record: stored))
                if candidate.record.source == .google {
                    result.links.append(ImportedLink(
                        icloudID: stored.sourceIdentifier, googleResourceName: candidate.googleResourceName, origin: .imported,
                        displayName: stored.displayName
                    ))
                }
            } catch {
                result.stopped = .failed(candidateID: candidate.id, reason: error.localizedDescription)
                result.notAttempted = selected[(index + 1)...].map(\.id)
                break
            }
        }

        if let links, !result.links.isEmpty {
            do { try links.add(result.links, at: now) } catch { result.linkSaveError = error.localizedDescription }
        }
        return result
    }
}
