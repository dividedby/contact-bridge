import Foundation

public enum ReviewWorkflowError: Error, Sendable, Equatable {
    /// Every decision needs notes access, so no note is lost or left out of the baseline.
    case notesUnavailable
    /// A contact the decision is about is not there any more (the next sync lists what is left to decide).
    case contactGone(String)
    /// Google refused or did not confirm the write. `icloudSaved` says the iCloud half of the decision was already saved.
    case googleWriteFailed(reason: String, icloudSaved: Bool)
    case importFailed(String)
    /// The review kind has no such action.
    case wrongKind(ReviewKind)
}

extension ReviewWorkflowError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notesUnavailable:
            "Deciding on this needs notes access, so no note is lost. Grant notes access in Setup, then try again."
        case .contactGone(let what):
            "\(what) is no longer there, so nothing was changed. The next sync lists what is left to decide."
        case .googleWriteFailed(let reason, let icloudSaved):
            (icloudSaved ? "Your choices were saved in iCloud, but Google was not updated: " : "Google was not updated: ")
                + reason + (icloudSaved ? " The next sync will try to settle it." : " Nothing was changed.")
        case .importFailed(let reason):
            "The contact could not be copied into iCloud: \(reason)"
        case .wrongKind: "That choice does not apply to this kind of item."
        }
    }
}

/// What a decision did.
public enum ReviewOutcome: Sendable, Hashable {
    /// Done. `warnings` are things that did not work but did not undo it (a note that could not be copied).
    case done(warnings: [String])
    /// One of the contacts moved on since it was shown, so nothing was changed. Carries the item as it is now to show
    /// instead; nil when it cannot be shown any more (it was resolved elsewhere or a contact is gone).
    case changedSinceShown(ReviewDetail?)
}

/// Which contacts and note a `ReviewDetail` was made from. A decision is only applied if they are still the same.
struct ReviewStamp: Sendable, Hashable {
    var googleEtag: String?
    var icloudFingerprint: String?
    var icloudNoteHash: String?
    var hasICloud: Bool
    var hasGoogle: Bool
}

/// One review item with the live data its decision needs, as the review screen shows it.
public struct ReviewDetail: Sendable, Hashable, Identifiable {
    public var id: String { item.id }
    public var item: ReviewItem
    public var name: String
    public var icloud: ContactRecord?
    public var google: ContactRecord?
    /// Google's side as of the last sync; what a `deletedInICloudEditedInGoogle` contact was before it was edited.
    public var googleBefore: ContactRecord?
    /// The iCloud note; nil when it could not be read.
    public var icloudNote: String?
    public var googleNote: String
    /// The field-by-field working copy, for `googleEdited` and `bothEdited` items whose contacts are both there.
    public var draft: SyncReviewDraft?
    var stamp: ReviewStamp
}

/// An ignored Google contact, for the "Show ignored" list.
public struct IgnoredContact: Sendable, Hashable, Identifiable {
    public var id: String { resourceName }
    public var resourceName: String
    public var name: String
    public var detail: String?
}

/// What "Keep iCloud for all" did, by review item id.
public struct BulkKeepReport: Sendable, Hashable {
    public struct Failure: Sendable, Hashable {
        public var itemID: String
        public var name: String
        public var reason: String
    }

    public var applied: [String] = []
    public var failed: [Failure] = []
    /// Left in the list: not a first-link conflict, or a contact is gone.
    public var skipped: [String] = []
    /// Left in the list because a contact moved on, or the conflict grew, since the list was made: nothing was done for
    /// them, and they need a look one by one.
    public var changedSinceShown: [String] = []
    /// Per applied item, the groups where iCloud has nothing and Google's value was left as it is.
    public var keptFromGoogle: [String: [SyncField]] = [:]
    public var warnings: [String] = []
}

/// What the user decides about each review item, applied. Every action runs inside the `WriteGate`, re-reads the contacts
/// first and refuses (`.changedSinceShown`) if what the user looked at has moved. Callers run a sync (`SyncEngine.syncNow`)
/// after an action to settle anything it left for the planner.
///
/// - iCloud writes take a fresh backup with notes first and then re-read the iCloud change token when nothing else had
///   moved it, so the sync does not read the app's own write as an edit.
/// - Google writes go through `SyncExecutor` (Google backup of at most 24 hours, history log, journal), so they behave
///   exactly like a sync run's writes.
/// - After a decision both baselines are set from what the two sides now hold, with both note hashes known, so the next
///   plan finds nothing to send back.
public struct ReviewWorkflows: Sendable {
    /// Review kinds whose baseline keeps the pre-conflict iCloud values.
    private static let iCloudSideKinds: Set<ReviewKind> = [.googleEdited, .bothEdited]

    private let store: any ContactStoring
    private let google: any GoogleContactsClient
    private let notes: (any NotesStoring)?
    private let backups: BackupCoordinator
    private let links: any LinkStoring
    private let state: any SyncStateStoring
    private let reviews: any ReviewStoring
    private let journal: any SyncJournalStoring
    private let history: any SyncHistoryStoring
    private let gate: WriteGate
    private let containerID: String?
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - notes: nil means notes cannot be read; every decision that writes or baselines refuses (`.notesUnavailable`).
    ///   - gate: the write gate shared with the sync engine and the other workflows.
    public init(
        store: any ContactStoring, google: any GoogleContactsClient, notes: (any NotesStoring)?, backups: BackupCoordinator,
        links: any LinkStoring, state: any SyncStateStoring, reviews: any ReviewStoring, journal: any SyncJournalStoring,
        history: any SyncHistoryStoring, gate: WriteGate, containerID: String? = nil, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.google = google
        self.notes = notes
        self.backups = backups
        self.links = links
        self.state = state
        self.reviews = reviews
        self.journal = journal
        self.history = history
        self.gate = gate
        self.containerID = containerID
        self.now = now
    }

    // MARK: loading

    /// The stored items, oldest first.
    public func items() throws -> [ReviewItem] { try reviews.load() }

    /// Reads the contacts the item is about and builds what the screen shows. Keeps the stored item's etag, fingerprint and
    /// fields in step with what was read, so the list never offers a stale one.
    @concurrent
    public func loadDetail(_ item: ReviewItem) async throws -> ReviewDetail {
        let live = try await fetchLive(item)
        let detail = makeDetail(item, live, baseline: try item.icloudID.flatMap { try state.load().baselines[$0] })
        try refresh(item, with: detail)
        return detail
    }

    // MARK: edits (googleEdited, bothEdited)

    /// Saves the draft's result to iCloud, then copies it to Google and sets both baselines.
    @concurrent
    public func apply(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        guard detail.item.kind == .googleEdited || detail.item.kind == .bothEdited else { throw ReviewWorkflowError.wrongKind(detail.item.kind) }
        return try await exclusively {
            guard notes != nil else { throw ReviewWorkflowError.notesUnavailable }
            let baseline = try detail.item.icloudID.flatMap { try state.load().baselines[$0] }
            let live = try await fetchLive(detail.item)
            let fresh = makeDetail(detail.item, live, baseline: baseline)
            guard fresh.stamp == detail.stamp, let draft = detail.draft else {
                try refresh(detail.item, with: fresh)
                return .changedSinceShown(fresh.draft == nil ? nil : fresh)
            }
            guard let icloud = live.icloud, let person = live.person, let google = live.google, let baseline else {
                throw ReviewWorkflowError.contactGone(detail.name)
            }
            return try await commit(draft, item: detail.item, icloud: icloud, person: person, google: google, live: live, baseline: baseline)
        }
    }

    /// "Keep iCloud for all" on first-link conflicts: iCloud's values are pushed to Google, entries only Google has stay
    /// Google-only, and nothing in iCloud changes. One backup check, one read of each side, Google written in batches.
    @concurrent
    public func keepICloudForAll(_ items: [ReviewItem]) async throws -> BulkKeepReport {
        try await exclusively {
            guard notes != nil else { throw ReviewWorkflowError.notesUnavailable }
            var report = BulkKeepReport()
            let candidates = items.filter { $0.kind == .bothEdited }
            report.skipped = items.filter { $0.kind != .bothEdited }.map(\.id)
            guard !candidates.isEmpty else { return report }

            _ = try await executor().recoverInterruptedRun()
            let icloud = Dictionary(
                try await store.fetchAll().map { ($0.sourceIdentifier, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let noteTexts = try? await notes?.fetchNotes(ids: candidates.compactMap(\.icloudID))
            let feed = try await GoogleChangeFeed(client: google).fetch(state: SyncState(), requireFullListing: true)
            let baselines = try state.load().baselines

            var updates: [PlannedUpdate] = []
            var baselineOnly: [String: SyncBaseline] = [:]
            var itemByID: [String: ReviewItem] = [:]
            for item in candidates {
                guard item.pinned, let id = item.icloudID, let name = item.resourceName, let record = icloud[id], let person = feed.people[name],
                      let google = GooglePersonMapper.record(from: person, source: .google), let baseline = baselines[id]
                else {
                    report.skipped.append(item.id)
                    continue
                }
                var draft = SyncReviewDraft(
                    icloud: record, google: google, base: baseline, reviewFields: item.fields,
                    icloudNote: noteTexts.map { $0[id] ?? "" }, googleNote: GooglePersonMapper.note(of: person)
                )
                // Only what the user was shown is settled: either contact moving on, or a wider conflict (a Google edit since
                // linking shows up as one more group), is for a look one by one.
                guard person.etag == item.googleEtag, ContactFingerprint.of(record) == item.icloudFingerprint,
                      Set(draft.reviewFields) == Set(item.fields)
                else {
                    report.changedSinceShown.append(item.id)
                    continue
                }
                draft.chooseICloudEverywhere()
                let resolved = draft.resolve()
                guard !resolved.changesICloud else {
                    report.skipped.append(item.id)
                    continue
                }
                if !draft.keptFromGoogle.isEmpty {
                    report.keptFromGoogle[item.id] = draft.keptFromGoogle
                    report.warnings.append(
                        "\(baseline.icloud.displayName): iCloud has no \(draft.keptFromGoogle.map(\.title).joined(separator: ", ")), so Google's was left as it is."
                    )
                }
                itemByID[id] = item
                switch googleStep(
                    icloudID: id, resourceName: name, resolved: resolved, baseline: baseline, icloud: record, person: person, google: google
                ) {
                case .update(let update): updates.append(update)
                case .baselineOnly(let settled): baselineOnly[id] = settled
                }
            }

            var failedIDs = Set<String>()
            if !updates.isEmpty {
                var plan = SyncPlan(isPreview: false)
                plan.updates = updates
                let run = try await executor().execute(plan: plan)
                for skipped in run.leftForNextRun {
                    failedIDs.insert(skipped.icloudID)
                    let item = itemByID[skipped.icloudID]
                    report.failed.append(BulkKeepReport.Failure(
                        itemID: item?.id ?? skipped.icloudID, name: baselines[skipped.icloudID]?.icloud.displayName ?? "Contact",
                        reason: skipped.reason.text
                    ))
                }
                report.warnings += run.warnings
            }
            if !baselineOnly.isEmpty {
                try state.update { state in
                    for (id, settled) in baselineOnly { state.baselines[id] = settled }
                }
            }
            for (id, item) in itemByID where !failedIDs.contains(id) {
                try clear(item)
                report.applied.append(item.id)
            }
            report.applied.sort()
            return report
        }
    }

    // MARK: new in Google

    /// Copies the Google contact (and its note) into iCloud and links the two.
    @concurrent
    public func importToICloud(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        guard detail.item.kind == .newInGoogle else { throw ReviewWorkflowError.wrongKind(detail.item.kind) }
        return try await exclusively {
            guard let notes else { throw ReviewWorkflowError.notesUnavailable }
            let live = try await fetchLive(detail.item)
            let fresh = makeDetail(detail.item, live, baseline: nil)
            guard fresh.stamp == detail.stamp, let person = live.person, let record = live.google, let resourceName = person.resourceName,
                  try links.load().links.values.allSatisfy({ $0.googleResourceName != resourceName })
            else {
                try refresh(detail.item, with: fresh)
                return .changedSinceShown(live.person == nil ? nil : fresh)
            }

            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true, needsGoogle: true))
            let tokenBefore = try await store.changeToken()
            let result = try await ImportExecutor(store: store, receipt: receipt, links: links)
                .execute([ImportCandidate(record: record, isSelected: true)], now: now())
            if let stopped = result.stopped {
                if case .failed(_, let reason) = stopped { throw ReviewWorkflowError.importFailed(reason) }
                throw CancellationError()
            }
            if let linkError = result.linkSaveError { throw ReviewWorkflowError.importFailed("the link could not be saved (\(linkError))") }
            guard let created = result.created.first else { throw ReviewWorkflowError.importFailed("nothing was created") }

            var warnings: [String] = []
            let googleNote = live.googleNote
            var icloudNoteHash = NoteHash.hash("")
            if !googleNote.isBlank {
                do {
                    try await notes.setNote(googleNote, forID: created.record.sourceIdentifier)
                    icloudNoteHash = NoteHash.hash(googleNote)
                } catch {
                    warnings.append("The contact was copied, but its note was not: \(error.localizedDescription)")
                }
            }
            let stored = try await reread(created.record.sourceIdentifier) ?? created.record
            let baseline = SyncBaseline(
                icloud: stored, google: record, googleEtag: person.etag ?? "", icloudNoteHash: icloudNoteHash,
                googleNoteHash: NoteHash.hash(googleNote), syncedAt: now()
            )
            try state.update { $0.baselines[stored.sourceIdentifier] = baseline }
            try clear(detail.item)
            try await advanceICloudToken(from: tokenBefore)
            return .done(warnings: warnings)
        }
    }

    /// Leaves the Google contact alone and never offers it again, until `unignore`.
    @concurrent
    public func ignore(_ item: ReviewItem) async throws {
        guard item.kind == .newInGoogle, let resourceName = item.resourceName else { throw ReviewWorkflowError.wrongKind(item.kind) }
        try await exclusively {
            try state.update { $0.ignoredGoogle.insert(resourceName) }
            try reviews.remove(ids: [item.id])
        }
    }

    /// The ignored Google contacts by name. A contact that cannot be read shows by its resource name.
    @concurrent
    public func loadIgnored() async throws -> [IgnoredContact] {
        var result: [IgnoredContact] = []
        for name in try state.load().ignoredGoogle.sorted() {
            do {
                let person = try await google.getPerson(resourceName: name)
                guard let record = GooglePersonMapper.record(from: person, source: .google) else { throw GoogleAPIError.notFound }
                let line = [record.emails.first?.value, record.phones.first?.value].compactMap { $0 }.filter { !$0.isBlank }.first
                result.append(IgnoredContact(resourceName: name, name: record.displayName, detail: line))
            } catch is CancellationError {
                throw CancellationError()
            } catch GoogleAPIError.notFound {
                result.append(IgnoredContact(resourceName: name, name: "Deleted from Google", detail: name))
            } catch {
                result.append(IgnoredContact(resourceName: name, name: "Unknown contact", detail: name))
            }
        }
        return result
    }

    /// Offers the contacts again. The next sync lists Google in full for it, since an incremental listing would not mention them.
    @concurrent
    public func unignore(_ resourceNames: [String]) async throws {
        try await exclusively {
            _ = try state.update { state in
                state.ignoredGoogle.subtract(resourceNames)
                state.googleSyncToken = nil
                state.fieldsVersion = nil
            }
        }
    }

    // MARK: deleted in Google

    /// Deletes the iCloud contact too (backup with notes first) and forgets the link.
    @concurrent
    public func deleteFromICloud(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        try await decideDeletedInGoogle(detail) { live, id, tokenBefore in
            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true))
            try await store.delete(ids: [id], backup: receipt)
            try forget(id)
            try clear(detail.item)
            try await advanceICloudToken(from: tokenBefore)
            return []
        }
    }

    /// Creates a new Google contact from the iCloud one (with its note) and links them.
    @concurrent
    public func putBackInGoogle(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        try await decideDeletedInGoogle(detail) { live, id, _ in
            guard let record = live.icloud else { throw ReviewWorkflowError.contactGone(detail.name) }
            // A Google contact already made from this one would be doubled by a create; the sync links it by its tag instead.
            let feed = try await GoogleChangeFeed(client: google).fetch(state: SyncState(), requireFullListing: true)
            try forget(id)
            guard feed.ownershipIndex[id] == nil else {
                try clear(detail.item)
                return ["A Google contact made from this one already exists. It is linked on the next sync."]
            }
            let note = live.icloudNote ?? ""
            var plan = SyncPlan(isPreview: false)
            plan.creates = [PlannedCreate(icloudID: id, record: record, note: note.isBlank ? nil : note, icloudNoteHash: NoteHash.hash(note))]
            plan.createsVerifiedAgainstFullListing = true
            let run = try await executor().execute(plan: plan)
            try Self.requireWritten(run, icloudSaved: false)
            guard run.created > 0 else { throw ReviewWorkflowError.googleWriteFailed(reason: "the contact was not created.", icloudSaved: false) }
            try clear(detail.item)
            return []
        }
    }

    /// The shared guard of the two ways out of `deletedInGoogle`: the iCloud contact must be there and unchanged, and Google
    /// must still lack its counterpart.
    private func decideDeletedInGoogle(
        _ detail: ReviewDetail, _ act: @Sendable (Live, String, Data?) async throws -> [String]
    ) async throws -> ReviewOutcome {
        guard detail.item.kind == .deletedInGoogle, let id = detail.item.icloudID else { throw ReviewWorkflowError.wrongKind(detail.item.kind) }
        return try await exclusively {
            guard notes != nil else { throw ReviewWorkflowError.notesUnavailable }
            let live = try await fetchLive(detail.item)
            let fresh = makeDetail(detail.item, live, baseline: try state.load().baselines[id])
            guard fresh.stamp == detail.stamp, live.icloud != nil, live.person == nil else {
                try refresh(detail.item, with: fresh)
                return .changedSinceShown(live.icloud == nil ? nil : fresh)
            }
            return .done(warnings: try await act(live, id, try await store.changeToken()))
        }
    }

    // MARK: deleted in iCloud, edited in Google

    /// Keeps the iCloud deletion: the Google contact is deleted too (Google backup first, change logged).
    @concurrent
    public func keepDeleted(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        try await decideDeletedInICloud(detail) { live, id, name in
            guard let baseline = try state.load().baselines[id], try links.load().links[id]?.googleResourceName == name,
                  let etag = live.person?.etag
            else { throw ReviewWorkflowError.contactGone(detail.name) }
            var plan = SyncPlan(isPreview: false)
            plan.deletes = [PlannedDelete(icloudID: id, resourceName: name, baseline: baseline)]
            // Only the version the user saw is approved: a Google edit made while the backup was taken is not deleted.
            let run = try await executor().execute(plan: plan, approvedDeletes: [id: etag])
            if run.reviewsAdded.contains(detail.item.id) {
                let fresh = makeDetail(detail.item, try await fetchLive(detail.item), baseline: baseline)
                try refresh(detail.item, with: fresh)
                return .changedSinceShown(fresh)
            }
            try Self.requireWritten(run, icloudSaved: false)
            guard run.deleted + run.alreadyGone > 0 else {
                throw ReviewWorkflowError.googleWriteFailed(reason: "the contact was not deleted.", icloudSaved: false)
            }
            try clear(detail.item)
            return .done(warnings: [])
        }
    }

    /// Restores the contact to iCloud from Google (backup with notes first) and links the new contact in place of the old.
    @concurrent
    public func restoreToICloud(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        try await decideDeletedInICloud(detail) { live, id, name in
            guard let notes, let person = live.person, let record = live.google else { throw ReviewWorkflowError.contactGone(detail.name) }
            let origin = try links.load().links[id]?.effectiveOrigin ?? .imported
            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true, needsGoogle: true))
            let tokenBefore = try await store.changeToken()
            let result = try await ImportExecutor(store: store, receipt: receipt, links: links)
                .execute([ImportCandidate(record: record, isSelected: true)], now: now())
            if let stopped = result.stopped {
                if case .failed(_, let reason) = stopped { throw ReviewWorkflowError.importFailed(reason) }
                throw CancellationError()
            }
            guard let created = result.created.first else { throw ReviewWorkflowError.importFailed("nothing was created") }
            let newID = created.record.sourceIdentifier
            // The import linked it as imported, replacing the old entry; keep how the pair originally came about.
            try links.add([ImportedLink(icloudID: newID, googleResourceName: name, origin: origin, displayName: created.record.displayName)], at: now())

            var warnings: [String] = []
            var icloudNoteHash = NoteHash.hash("")
            if !live.googleNote.isBlank {
                do {
                    try await notes.setNote(live.googleNote, forID: newID)
                    icloudNoteHash = NoteHash.hash(live.googleNote)
                } catch {
                    warnings.append("The contact was restored, but its note was not: \(error.localizedDescription)")
                }
            }
            let stored = try await reread(newID) ?? created.record
            let baseline = SyncBaseline(
                icloud: stored, google: record, googleEtag: person.etag ?? "", icloudNoteHash: icloudNoteHash,
                googleNoteHash: NoteHash.hash(live.googleNote), syncedAt: now()
            )
            try state.update { state in
                state.baselines[id] = nil
                state.baselines[newID] = baseline
            }
            try clear(detail.item)
            try await advanceICloudToken(from: tokenBefore)
            return .done(warnings: warnings)
        }
    }

    private func decideDeletedInICloud(
        _ detail: ReviewDetail, _ act: @Sendable (Live, String, String) async throws -> ReviewOutcome
    ) async throws -> ReviewOutcome {
        guard detail.item.kind == .deletedInICloudEditedInGoogle, let id = detail.item.icloudID, let name = detail.item.resourceName else {
            throw ReviewWorkflowError.wrongKind(detail.item.kind)
        }
        return try await exclusively {
            let live = try await fetchLive(detail.item)
            guard live.icloud == nil else {
                // The contact is back in iCloud: this question is moot.
                try reviews.remove(ids: [detail.item.id])
                return .changedSinceShown(nil)
            }
            guard live.person != nil else {
                // Gone from both sides: only the link and baseline are left to forget.
                try forget(id)
                try clear(detail.item)
                return .done(warnings: [])
            }
            let fresh = makeDetail(detail.item, live, baseline: try state.load().baselines[id])
            guard fresh.stamp == detail.stamp else {
                try refresh(detail.item, with: fresh)
                return .changedSinceShown(fresh)
            }
            return try await act(live, id, name)
        }
    }

    // MARK: possible match

    /// Links the two contacts as the same person. Nothing is written to either: the next sync takes the baseline from both
    /// sides as they are and asks about any field that differs.
    @concurrent
    public func link(_ detail: ReviewDetail) async throws -> ReviewOutcome {
        guard detail.item.kind == .possibleLink, let id = detail.item.icloudID, let name = detail.item.resourceName else {
            throw ReviewWorkflowError.wrongKind(detail.item.kind)
        }
        return try await exclusively {
            let live = try await fetchLive(detail.item)
            let table = try links.load().links
            let free = table[id] == nil && table.values.allSatisfy { $0.googleResourceName != name }
            let fresh = makeDetail(detail.item, live, baseline: nil)
            guard fresh.stamp == detail.stamp, live.icloud != nil, live.person != nil, free else {
                try refresh(detail.item, with: fresh)
                if live.icloud == nil || live.person == nil || !free { try reviews.remove(ids: [detail.item.id]) }
                return .changedSinceShown(live.icloud == nil || live.person == nil || !free ? nil : fresh)
            }
            try links.add([ImportedLink(icloudID: id, googleResourceName: name, origin: .matched, displayName: live.icloud?.displayName)], at: now())
            // A link without a baseline is adopted by a full scan; an unchanged iCloud token would skip it.
            try state.update { $0.icloudChangeToken = nil }
            try clear(detail.item)
            return .done(warnings: [])
        }
    }

    /// Remembers that these are different people. The iCloud contact is created in Google by the next sync.
    @concurrent
    public func keepSeparate(_ item: ReviewItem) async throws {
        guard item.kind == .possibleLink, let id = item.icloudID, let name = item.resourceName else { throw ReviewWorkflowError.wrongKind(item.kind) }
        try await exclusively {
            try state.update { $0.keepSeparate.insert(id + "|" + name) }
            try reviews.remove(ids: [item.id])
        }
    }

    // MARK: writing

    private func exclusively<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await gate.withLock(body)
    }

    private func executor() -> SyncExecutor {
        SyncExecutor(
            google: google, links: links, state: state, reviews: reviews, journal: journal, history: history, backups: backups,
            containerID: containerID, now: now
        )
    }

    /// Saves one draft: iCloud first (backup, contact, note), then Google, then the baseline.
    private func commit(
        _ draft: SyncReviewDraft, item: ReviewItem, icloud: ContactRecord, person: GooglePerson, google: ContactRecord, live: Live,
        baseline: SyncBaseline
    ) async throws -> ReviewOutcome {
        let resolved = draft.resolve()
        let icloudID = icloud.sourceIdentifier
        let writesNote = resolved.note.map { NoteHash.hash($0) != NoteHash.hash(live.icloudNote ?? "") } ?? false
        let tokenBefore = try await store.changeToken()
        _ = try await executor().recoverInterruptedRun()

        var saved = icloud
        if resolved.changesICloud || writesNote {
            let receipt = try await backups.freshReceipt(requiring: BackupRequirement(containerID: containerID, needsNotes: true, needsGoogle: true))
            // A backup can take a while: look once more before writing over whatever happened meanwhile.
            let again = try await fetchLive(item)
            guard stamp(of: again) == stamp(of: live) else {
                let fresh = makeDetail(item, again, baseline: baseline)
                try refresh(item, with: fresh)
                return .changedSinceShown(fresh.draft == nil ? nil : fresh)
            }
            if resolved.changesICloud { try await store.update(resolved.icloud, backup: receipt) }
            if writesNote, let note = resolved.note { try await notes?.setNote(note.isBlank ? nil : note, forID: icloudID) }
            saved = try await reread(icloudID) ?? resolved.icloud
        }

        let didWriteICloud = resolved.changesICloud || writesNote
        switch googleStep(
            icloudID: icloudID, resourceName: person.resourceName ?? "", resolved: resolved, baseline: baseline, icloud: saved, person: person,
            google: google
        ) {
        case .update(let update):
            var plan = SyncPlan(isPreview: false)
            plan.updates = [update]
            let run = try await executor().execute(plan: plan)
            try Self.requireWritten(run, icloudSaved: didWriteICloud)
        case .baselineOnly(let settled):
            try state.update { $0.baselines[icloudID] = settled }
        }
        try clear(item, covering: Set(draft.reviewFields))
        if didWriteICloud { try await advanceICloudToken(from: tokenBefore) }
        return .done(warnings: [])
    }

    private enum GoogleStep {
        case update(PlannedUpdate)
        /// Google already holds the result: only the baseline moves.
        case baselineOnly(SyncBaseline)
    }

    /// The Google half of a decision. The baseline carries the iCloud contact as saved and Google as it is; when an update is
    /// confirmed the executor replaces its Google half with what Google returns.
    private func googleStep(
        icloudID: String, resourceName: String, resolved: SyncReviewDraft.Resolution, baseline: SyncBaseline, icloud: ContactRecord,
        person: GooglePerson, google: ContactRecord
    ) -> GoogleStep {
        let noteHash = resolved.note.map(NoteHash.hash)
        let settled = SyncBaseline(
            icloud: icloud, google: google, googleEtag: person.etag ?? baseline.googleEtag,
            icloudNoteHash: noteHash ?? baseline.icloudNoteHash, googleNoteHash: noteHash ?? baseline.googleNoteHash, syncedAt: now()
        )
        let pushesNote = noteHash.map { $0 != GooglePersonMapper.noteHash(of: person) } ?? false
        guard resolved.changesGoogle || pushesNote else { return .baselineOnly(settled) }
        var fields = Set(SyncField.recordFields)
        if pushesNote { fields.insert(.note) }
        return .update(PlannedUpdate(
            icloudID: icloudID, resourceName: resourceName, etag: person.etag ?? "", existing: person, fields: fields,
            desired: resolved.google, note: pushesNote ? resolved.note : nil, baseline: settled
        ))
    }

    private static func requireWritten(_ run: SyncRunReport, icloudSaved: Bool) throws {
        if let skipped = run.leftForNextRun.first {
            throw ReviewWorkflowError.googleWriteFailed(reason: skipped.reason.text, icloudSaved: icloudSaved)
        }
        if let halted = run.halted { throw ReviewWorkflowError.googleWriteFailed(reason: halted, icloudSaved: icloudSaved) }
    }

    // MARK: shared

    /// The iCloud and Google contacts an item is about, as they are now.
    fileprivate struct Live: Sendable {
        var icloud: ContactRecord?
        var person: GooglePerson?
        /// Nil when the note could not be read.
        var icloudNote: String?

        var google: ContactRecord? { person.flatMap { GooglePersonMapper.record(from: $0, source: .google) } }
        var googleNote: String { person.map(GooglePersonMapper.note(of:)) ?? "" }
    }

    private func fetchLive(_ item: ReviewItem) async throws -> Live {
        var live = Live()
        if let id = item.icloudID { live.icloud = try await reread(id) }
        if let name = item.resourceName {
            do {
                let person = try await google.getPerson(resourceName: name)
                live.person = person.isDeleted ? nil : person
            } catch GoogleAPIError.notFound {
                live.person = nil
            }
        }
        if live.icloud != nil, let notes, let id = item.icloudID {
            do {
                live.icloudNote = try await notes.fetchNotes(ids: [id])[id] ?? ""
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                live.icloudNote = nil
            }
        }
        return live
    }

    private func reread(_ icloudID: String) async throws -> ContactRecord? {
        try await store.fetchAll().first { $0.sourceIdentifier == icloudID }
    }

    private func makeDetail(_ item: ReviewItem, _ live: Live, baseline: SyncBaseline?) -> ReviewDetail {
        let google = live.google
        var draft: SyncReviewDraft?
        if iCloudSideKindsContain(item.kind), let icloud = live.icloud, let google, let baseline {
            draft = SyncReviewDraft(
                icloud: icloud, google: google, base: baseline, reviewFields: item.fields, icloudNote: live.icloudNote,
                googleNote: live.googleNote
            )
        }
        return ReviewDetail(
            item: item, name: (live.icloud ?? google ?? baseline?.icloud)?.displayName ?? "Unknown contact", icloud: live.icloud,
            google: google, googleBefore: baseline?.google, icloudNote: live.icloudNote, googleNote: live.googleNote, draft: draft,
            stamp: stamp(of: live)
        )
    }

    private func stamp(of live: Live) -> ReviewStamp {
        ReviewStamp(
            googleEtag: live.person?.etag, icloudFingerprint: live.icloud.map(ContactFingerprint.of),
            icloudNoteHash: live.icloudNote.map(NoteHash.hash), hasICloud: live.icloud != nil, hasGoogle: live.person != nil
        )
    }

    private func iCloudSideKindsContain(_ kind: ReviewKind) -> Bool { Self.iCloudSideKinds.contains(kind) }

    /// Brings the stored item's etag, fingerprint and fields up to what was just read, unless it has been resolved meanwhile.
    private func refresh(_ item: ReviewItem, with detail: ReviewDetail) throws {
        guard try reviews.load().contains(where: { $0.id == item.id }) else { return }
        let hasEtag = item.kind != .deletedInGoogle
        let hasFingerprint = item.kind != .newInGoogle && item.kind != .deletedInICloudEditedInGoogle
        let fields = detail.draft?.reviewFields ?? item.fields
        let etag = hasEtag ? detail.stamp.googleEtag : nil
        let fingerprint = hasFingerprint ? detail.stamp.icloudFingerprint : nil
        guard etag != item.googleEtag || fingerprint != item.icloudFingerprint || fields != item.fields else { return }
        try reviews.add([ReviewCandidate(
            kind: item.kind, icloudID: item.icloudID, resourceName: item.resourceName, googleEtag: etag, icloudFingerprint: fingerprint,
            fields: fields
        )], at: now())
    }

    /// Removes the item that was decided, and nothing else, unless `covering` says what the user was shown: then also the
    /// other edit conflicts about the same contact whose groups were all on screen. Anything else is asked about separately.
    private func clear(_ item: ReviewItem, covering shown: Set<SyncField> = []) throws {
        var doomed = [item.id]
        if !shown.isEmpty {
            doomed += try reviews.items(concerning: item.icloudID, resourceName: item.resourceName)
                .filter { ($0.kind == .googleEdited || $0.kind == .bothEdited) && Set($0.fields).isSubset(of: shown) }.map(\.id)
        }
        try reviews.remove(ids: Array(Set(doomed)))
    }

    /// A contact gone from iCloud (or replaced): its link and baseline go.
    private func forget(_ icloudID: String) throws {
        try links.remove(icloudIDs: [icloudID])
        try state.update { $0.baselines[icloudID] = nil }
    }

    /// Moves the stored iCloud change token past this app's own write, so the sync does not read it as an edit. Only when
    /// nothing else moved the token since it was stored and no conflict is open (an open one needs every scan to read the
    /// whole book); otherwise it stays, and the next scan reads everything.
    private func advanceICloudToken(from before: Data?) async throws {
        guard let before, try state.load().icloudChangeToken == before,
              try !reviews.load().contains(where: { Self.iCloudSideKinds.contains($0.kind) })
        else { return }
        let after = try await store.changeToken()
        try state.update { $0.icloudChangeToken = after }
    }
}

extension SyncRunReport.Skipped.Reason {
    /// For error messages: why Google was not written.
    var text: String {
        switch self {
        case .failed(let message): message
        case .notAttempted(let reason): "it was not sent (\(reason))."
        case .etagChanged: "the contact changed in Google again."
        case .nothingToSend: "there was nothing to send."
        case .vanishedInGoogle: "the contact is gone from Google."
        case .notLinked: "the contact is not linked to its Google contact."
        case .alreadyLinked: "the contact is already linked."
        case .unconfirmed: "Google did not confirm the change."
        case .notApplied: "Google did not apply the change."
        }
    }
}
