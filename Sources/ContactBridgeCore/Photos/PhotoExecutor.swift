import Foundation

/// What one run of photo changes did.
public struct PhotoRunReport: Sendable, Hashable {
    public struct Skipped: Sendable, Hashable {
        public enum Reason: Sendable, Hashable {
            /// The Google photo is not the one the plan saw (it changed since); the next listing shows the change.
            case googleChanged
            /// The iCloud photo is not the one the plan saw; the next scan shows the change.
            case icloudChanged
            /// The pair is no longer linked, or its baseline is gone.
            case notLinked
            /// The Google or iCloud contact is gone.
            case vanished
            /// The photo being replaced could not be saved to the history first, so it was not replaced.
            case couldNotSaveOld(String)
            /// A read, download, encode or write failed, perhaps for a moment. The next run plans it again.
            case failed(String)
            /// It failed in a way that repeating cannot fix (Google refuses the picture, say). Recorded on the pair's baseline,
            /// and not tried again until one of the photos changes.
            case permanent(String)
            /// Never tried: an earlier call hit an error that stops the run.
            case notAttempted(String)
        }

        public var icloudID: String
        public var reason: Reason

        /// Whether the next run would not see this again by itself (its token was already moved past the change).
        var needsAnotherLook: Bool {
            switch reason {
            case .couldNotSaveOld, .failed, .notAttempted: true
            case .googleChanged, .icloudChanged, .notLinked, .vanished, .permanent: false
            }
        }
    }

    /// iCloud ids whose op was carried out (or found already true).
    public var completed: [String] = []
    public var recorded = 0
    public var copiedToGoogle = 0
    public var copiedToICloud = 0
    public var removedFromGoogle = 0
    public var removedFromICloud = 0
    public var skipped: [Skipped] = []
    /// Google photo writes beyond the per-run limit, left for later runs.
    public var carried = 0
    /// Why the run stopped early (rate limit, sign-in or permission problem).
    public var halted: String?
    public var warnings: [String] = []

    /// Google writes this run made; the engine counts them like field writes when it decides on a follow-up run.
    public var googleWrites: Int { copiedToGoogle + removedFromGoogle }
    public var iCloudWrites: Int { copiedToICloud + removedFromICloud }

    /// Everything the plan asked for was done, or is bound to be planned again without help. When false the engine keeps its
    /// tokens where they were, so the next run reads the same changes again.
    public var isComplete: Bool { carried == 0 && halted == nil && !skipped.contains { $0.needsAnotherLook } }
}

/// Carries out the photo ops of a plan, after the field writes and inside the same `WriteGate` lock. The ops were decided on
/// what the reconciler saw, so each one first checks that the photos are still as seen.
///
/// - There is no journal. A write is idempotent in effect: if the process dies between a write and the baseline update, the
///   next run sees both sides holding the same picture and records the baseline, with nothing written twice.
/// - Before a Google photo is replaced or deleted the contact is fetched again, its photo must still be the one the plan saw,
///   and the old photo is saved to `PhotoHistoryStoring` (if it cannot be, the photo is not touched).
/// - Google writes are at least `minGoogleWriteInterval` apart and at most `maxGoogleWrites` per run; the rest are carried.
/// - Uploads to Google are `PhotoEncoder.jpegForGoogle` of the iCloud photo; iCloud gets Google's `=s1024` bytes as they
///   were downloaded. iCloud writes need a fresh backup, and move the stored iCloud change token afterwards.
/// - A rate limit or sign-in problem stops the run (`halted`); the rest is not attempted.
public struct PhotoExecutor: Sendable {
    public static let maxGoogleWrites = 60
    public static let minGoogleWriteInterval: TimeInterval = 1
    /// Size of the Google photo copied to iCloud, and of the old photo kept in the history.
    static let copySize = 1024

    private let google: any GoogleContactsClient
    private let store: any ContactStoring
    private let links: any LinkStoring
    private let state: any SyncStateStoring
    private let reviews: any ReviewStoring
    private let history: any PhotoHistoryStoring
    private let backups: BackupCoordinator
    private let fetcher: any GooglePhotoFetching
    private let containerID: String?
    private let needsNotes: Bool
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let maxGoogleWrites: Int
    private let minInterval: TimeInterval

    /// - Parameters:
    ///   - needsNotes: the iCloud backup must hold notes (they can be read); false when notes access is not granted.
    ///   - sleep: waits between Google writes; tests pass one that does not wait.
    public init(
        google: any GoogleContactsClient, store: any ContactStoring, links: any LinkStoring, state: any SyncStateStoring,
        reviews: any ReviewStoring, history: any PhotoHistoryStoring, backups: BackupCoordinator, fetcher: any GooglePhotoFetching,
        containerID: String? = nil, needsNotes: Bool = true, now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        maxGoogleWrites: Int = PhotoExecutor.maxGoogleWrites, minGoogleWriteInterval: TimeInterval = PhotoExecutor.minGoogleWriteInterval
    ) {
        self.google = google
        self.store = store
        self.links = links
        self.state = state
        self.reviews = reviews
        self.history = history
        self.backups = backups
        self.fetcher = fetcher
        self.containerID = containerID
        self.needsNotes = needsNotes
        self.now = now
        self.sleep = sleep
        self.maxGoogleWrites = maxGoogleWrites
        minInterval = minGoogleWriteInterval
    }

    /// Per-run bookkeeping.
    private struct RunProgress {
        var report = PhotoRunReport()
        var googleReceipt: BackupReceipt?
        var googleBackupFailure: String?
        var icloudReceipt: BackupReceipt?
        var icloudBackupFailure: String?
        var icloudTokenBefore: Data??
        var lastGoogleWrite: Date?
        var googleWritesMade = 0

        mutating func skip(_ op: PlannedPhotoOp, _ reason: PhotoRunReport.Skipped.Reason) {
            report.skipped.append(PhotoRunReport.Skipped(icloudID: op.icloudID, reason: reason))
        }
    }

    public func execute(_ ops: [PlannedPhotoOp]) async throws -> PhotoRunReport {
        guard !ops.isEmpty else { return PhotoRunReport() }
        let linked = try links.load().links
        var progress = RunProgress()
        for op in ops {
            try Task.checkCancellation()
            guard linked[op.icloudID]?.googleResourceName == op.resourceName, try state.load().baselines[op.icloudID] != nil else {
                progress.skip(op, .notLinked)
                continue
            }
            switch op.kind {
            case .recordBaseline:
                try saveBaseline(op.baseline, for: op.icloudID)
                progress.report.recorded += 1
                progress.report.completed.append(op.icloudID)
            case .copyToGoogle, .deleteOnGoogle:
                if let halted = progress.report.halted {
                    progress.skip(op, .notAttempted(halted))
                } else if progress.googleWritesMade >= maxGoogleWrites {
                    progress.report.carried += 1
                } else {
                    try await writeGoogle(op, &progress)
                }
            case .copyToICloud, .deleteOnICloud:
                try await writeICloud(op, &progress)
            }
        }
        // Our own iCloud writes moved the store's token; step the saved one past them so they are not read as edits.
        if let before = progress.icloudTokenBefore {
            try await ICloudTokenAdvance.advance(store: store, state: state, reviews: reviews, from: before)
        }
        do { try history.prune(now: now()) } catch { progress.report.warnings.append("Old photo history could not be cleaned up: \(error.localizedDescription)") }
        return progress.report
    }

    /// A failure that repeating cannot fix: noted on the pair's baseline against the photos it was planned on, and reported.
    private func giveUp(_ op: PlannedPhotoOp, _ error: any Error, _ progress: inout RunProgress) throws {
        let message = error.localizedDescription
        progress.skip(op, .permanent(message))
        progress.report.warnings.append("A contact photo could not be copied and will be left alone until it changes: \(message)")
        var marked = try state.load().baselines[op.icloudID]?.photo ?? PhotoBaseline(syncedAt: now())
        marked.failure = PhotoBaseline.Failure(stamp: op.failureStamp ?? "", message: message, at: now())
        try saveBaseline(marked, for: op.icloudID)
    }

    /// A failed step: permanent ones are given up on, the rest are noted and tried again next run.
    private func failed(_ op: PlannedPhotoOp, _ error: any Error, _ progress: inout RunProgress) throws {
        if PhotoErrors.isPermanent(error) {
            try giveUp(op, error, &progress)
        } else {
            progress.skip(op, .failed(error.localizedDescription))
        }
    }

    private func saveBaseline(_ baseline: PhotoBaseline, for id: String) throws {
        try state.update { $0.baselines[id]?.photo = baseline }
    }

    // MARK: Google

    private func writeGoogle(_ op: PlannedPhotoOp, _ progress: inout RunProgress) async throws {
        if let failure = progress.googleBackupFailure {
            progress.skip(op, .notAttempted(failure))
            return
        }
        // What goes up is read first: if iCloud moved on since the plan, nothing happens to Google.
        var upload: Data?
        if case .copyToGoogle = op.kind {
            do {
                guard try await store.photoSignatures(ids: [op.icloudID])[op.icloudID]?.thumbnailHash == op.expectedICloudHint,
                      let original = try await store.photoData(id: op.icloudID)
                else {
                    progress.skip(op, .icloudChanged)
                    return
                }
                upload = try PhotoEncoder.jpegForGoogle(original)
            } catch is CancellationError {
                throw CancellationError()
            } catch ContactStoreError.notFound {
                progress.skip(op, .vanished)
                return
            } catch {
                try failed(op, error, &progress)
                return
            }
        }

        let person: GooglePerson
        do {
            person = try await google.getPerson(resourceName: op.resourceName)
        } catch GoogleAPIError.notFound {
            progress.skip(op, .vanished)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try fail(op, error, &progress)
            return
        }
        let current = GooglePersonMapper.photos(of: person).contact
        guard current?.key == op.expectedGoogleURLKey else {
            progress.skip(op, .googleChanged)
            return
        }
        if upload == nil, current == nil {
            // Nothing there to delete: the intended end state is already true.
            try saveBaseline(op.baseline, for: op.icloudID)
            progress.report.completed.append(op.icloudID)
            return
        }

        if let current {
            do {
                guard let url = current.sizedURL(Self.copySize) else { throw GooglePhotoError.notAllowed("the photo has no usable address") }
                // One copy of each replaced photo: an attempt that fails after this must not add another next time.
                if try !history.hasEntry(resourceName: op.resourceName, urlKey: current.key) {
                    let old = try await fetcher.fetch(url)
                    let operation: PhotoHistoryEntry.Operation = upload == nil ? .delete : .replace
                    try history.append([PhotoHistoryEntry(
                        at: now(), operation: operation, icloudID: op.icloudID, resourceName: op.resourceName, urlKey: current.key, photo: old
                    )])
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if PhotoErrors.isPermanent(error) {
                    try giveUp(op, error, &progress)
                } else {
                    progress.skip(op, .couldNotSaveOld(error.localizedDescription))
                }
                return
            }
        }

        do {
            if progress.googleReceipt == nil {
                progress.googleReceipt = try await backups.freshReceipt(
                    requiring: BackupRequirement(containerID: containerID, needsGoogle: true), maxAge: SyncExecutor.maxBackupAge
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            progress.googleBackupFailure = error.localizedDescription
            progress.skip(op, .failed(error.localizedDescription))
            return
        }

        if let last = progress.lastGoogleWrite {
            let wait = minInterval - now().timeIntervalSince(last)
            if wait > 0 { try await sleep(wait) }
        }
        let returned: GooglePerson
        do {
            if let upload {
                returned = try await google.updateContactPhoto(resourceName: op.resourceName, photoBytes: upload)
            } else {
                returned = try await google.deleteContactPhoto(resourceName: op.resourceName)
            }
        } catch GoogleAPIError.notFound {
            progress.skip(op, .vanished)
            return
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try fail(op, error, &progress)
            return
        }
        progress.lastGoogleWrite = now()
        progress.googleWritesMade += 1
        if upload == nil { progress.report.removedFromGoogle += 1 } else { progress.report.copiedToGoogle += 1 }

        var baseline = op.baseline
        baseline.googleURLKey = GooglePersonMapper.photos(of: returned).contact?.key
        try saveBaseline(baseline, for: op.icloudID)
        progress.report.completed.append(op.icloudID)
    }

    /// A failed Google call: noted, and the run stops if every later call would fail the same way.
    private func fail(_ op: PlannedPhotoOp, _ error: any Error, _ progress: inout RunProgress) throws {
        if let api = error as? GoogleAPIError, let reason = SyncExecutor.haltReason(for: api) {
            progress.skip(op, .failed(error.localizedDescription))
            progress.report.halted = progress.report.halted ?? reason
        } else {
            try failed(op, error, &progress)
        }
    }

    // MARK: iCloud

    private func writeICloud(_ op: PlannedPhotoOp, _ progress: inout RunProgress) async throws {
        if let failure = progress.icloudBackupFailure {
            progress.skip(op, .notAttempted(failure))
            return
        }
        var finished: PhotoBaseline?
        do {
            guard try await store.photoSignatures(ids: [op.icloudID])[op.icloudID]?.thumbnailHash == op.expectedICloudHint else {
                progress.skip(op, .icloudChanged)
                return
            }
            var bytes: Data?
            if case .copyToICloud = op.kind {
                guard let key = op.expectedGoogleURLKey, let url = GooglePhotoRef(url: key).sizedURL(Self.copySize) else {
                    progress.skip(op, .googleChanged)
                    return
                }
                bytes = try await fetcher.fetch(url)
            }

            if progress.icloudReceipt == nil {
                do {
                    progress.icloudReceipt = try await backups.freshReceipt(
                        requiring: BackupRequirement(containerID: containerID, needsNotes: needsNotes)
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    progress.icloudBackupFailure = error.localizedDescription
                    progress.skip(op, .failed(error.localizedDescription))
                    return
                }
            }
            if progress.icloudTokenBefore == nil { progress.icloudTokenBefore = .some(try await store.changeToken()) }
            guard let receipt = progress.icloudReceipt else { return }
            try await store.setPhoto(id: op.icloudID, data: bytes, backup: receipt)
            if bytes == nil { progress.report.removedFromICloud += 1 } else { progress.report.copiedToICloud += 1 }

            var baseline = op.baseline
            baseline.icloudHint = try await store.photoSignatures(ids: [op.icloudID])[op.icloudID]?.thumbnailHash
            finished = baseline
        } catch is CancellationError {
            throw CancellationError()
        } catch ContactStoreError.notFound {
            progress.skip(op, .vanished)
        } catch {
            try failed(op, error, &progress)
        }
        if let finished {
            try saveBaseline(finished, for: op.icloudID)
            progress.report.completed.append(op.icloudID)
        }
    }
}

/// What the sync engine needs to sync photos. Without it (demo mode before its photos exist, tests that are not about
/// photos) a run makes no photo reads and no photo writes.
public struct SyncPhotoSupport: Sendable {
    public var fetcher: any GooglePhotoFetching
    public var history: any PhotoHistoryStoring
    public var fingerprinter: any PhotoFingerprinting
    /// Waits between Google photo writes.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        fetcher: any GooglePhotoFetching, history: any PhotoHistoryStoring,
        fingerprinter: any PhotoFingerprinting = ImageIOPhotoFingerprinter(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.fetcher = fetcher
        self.history = history
        self.fingerprinter = fingerprinter
        self.sleep = sleep
    }
}
