import Foundation

/// The single writer for sync. One run is: settle any interrupted run, scan iCloud, read Google (in full when new contacts
/// need matching), plan, keep the review list in step with the plan, and (only once the user approved the first sync and
/// nothing is paused) execute the plan and save the tokens. Every run holds the `WriteGate`, so it never interleaves with
/// Import, Merge or Clean up.
///
/// - Before the first sync is approved a run only builds `SyncSnapshot.preview`. Nothing is written anywhere, and no
///   timer or event starts one: the sync screen asks (`refreshPreview()`).
/// - Triggers (`trigger(_:)`) and the regular timer are debounced; "Sync now" runs at once. A failed or stopped run backs
///   off (`SyncSchedule.backoffStart`, doubling) before any automatic retry; "Sync now" and Resume skip the wait.
/// - A plan that pauses with `.needsConfirmation` waits for `confirmAndContinue()` (runs again with the summary the user
///   saw accepted) or `keepPaused()`. Other plan pauses (wrong account, empty listing) are re-checked on every run.
/// - `pause()` is the kill switch: it is saved, stops the run in flight and keeps every trigger from starting another.
public actor SyncEngine {
    public enum ApprovalOutcome: Sendable, Hashable {
        /// Syncing is approved and the first run is under way (or done).
        case started
        /// The plan no longer matches what the user was shown; the new preview replaces it and nothing was approved.
        case previewChanged
        /// There is no preview to approve yet.
        case noPreview
        case alreadyApproved
        case unavailable(String)
    }

    private struct RunOptions: Sendable {
        enum Mode: Sendable {
            case regular
            /// Approve the first sync if the plan still has these counts.
            case approve(SyncPreview.Counts)
        }

        var trigger: SyncTrigger
        var mode = Mode.regular
        /// The summaries of the `.needsConfirmation` pauses the user accepted in this chain of questions. One run can hit
        /// several guards one after the other; each confirmation adds to the set instead of replacing the last.
        var confirmedSummaries: Set<String> = []
    }

    private struct Completion: Sendable {
        var report: SyncRunReport
        var waitingForNotes: Int
        var unlinkedWaitingForFullListing: Int
        var notesUnavailable: Bool
        var hasDeferred: Bool
        var reviews: [SyncReviewSummary]
        var unconfirmedCreates: Int
        /// Pairs linked or created this run: their photos are looked at for the first time by the next one.
        var newPairs: Int
    }

    private enum RunResult: Sendable {
        case notReady(String)
        case userPaused
        case cancelled
        case failed(String)
        case preview(SyncPreview)
        case previewChanged(SyncPreview)
        case paused(PauseReason, details: [SyncPreview.Item])
        case completed(Completion)
    }

    private let environment: @Sendable () async -> SyncEnvironmentState
    private let linkStore: any LinkStoring
    private let stateStore: any SyncStateStoring
    private let reviewStore: any ReviewStoring
    private let journalStore: any SyncJournalStoring
    private let historyStore: any SyncHistoryStoring
    private let backups: BackupCoordinator
    private let gate: WriteGate
    private let clock: any SyncClock
    private let schedule: SyncSchedule
    private let planner: SyncPlanner
    private let contactsAppRunning: @Sendable () -> Bool
    private let acquireLock: (@Sendable () throws -> any SyncLockHolding)?
    private let photos: SyncPhotoSupport?

    private var snapshot = SyncSnapshot()
    private var observers: [UUID: AsyncStream<SyncSnapshot>.Continuation] = [:]

    private var started = false
    private var disabledReason: String?
    private var heldLock: (any SyncLockHolding)?
    private var approved = false
    private var userPaused = false
    private var awaitingConfirmation = false
    /// What the user has confirmed since the first question of the current chain of `.needsConfirmation` pauses. Memory
    /// only (a relaunch asks again), and emptied as soon as the chain ends in anything but another question.
    private var confirmedChain: Set<String> = []
    private var approving = false
    private var lastApproval: ApprovalOutcome?

    private var timerTask: Task<Void, Never>?
    private var waiter: Task<Void, Never>?
    private var waiterGeneration = 0
    private var dueAt: Date?
    private var firstRequestAt: Date?
    private var runTask: Task<Void, Never>?
    private var rerunWanted = false
    private var failures = 0
    private var backoffUntil: Date?
    private var followUps = 0

    /// Display names from the latest look at each side, for the preview and the review list.
    private var icloudNames: [String: String] = [:]
    private var googleNames: [String: String] = [:]

    /// - Parameters:
    ///   - environment: asked at the start of every run; `.notReady` ends the run with a message for the sync screen.
    ///   - gate: shared with Import, Merge and Clean up.
    ///   - contactsAppRunning: whether the Contacts app is running, so a background run may read notes without launching it.
    ///   - acquireLock: the second-instance guard (`SyncProcessLock.acquire`), taken by `start()`. Nil means no guard (demo
    ///     mode, tests). If it throws, syncing stays off for this process.
    ///   - photos: what photo sync needs. Nil means runs read and write no photos at all.
    public init(
        environment: @escaping @Sendable () async -> SyncEnvironmentState, links: any LinkStoring, state: any SyncStateStoring,
        reviews: any ReviewStoring, journal: any SyncJournalStoring, history: any SyncHistoryStoring, backups: BackupCoordinator,
        gate: WriteGate = WriteGate(), clock: any SyncClock = SystemSyncClock(), schedule: SyncSchedule = SyncSchedule(),
        planner: SyncPlanner = SyncPlanner(), contactsAppRunning: @escaping @Sendable () -> Bool = { false },
        acquireLock: (@Sendable () throws -> any SyncLockHolding)? = nil, photos: SyncPhotoSupport? = nil
    ) {
        self.photos = photos
        self.environment = environment
        linkStore = links
        stateStore = state
        reviewStore = reviews
        journalStore = journal
        historyStore = history
        self.backups = backups
        self.gate = gate
        self.clock = clock
        self.schedule = schedule
        self.planner = planner
        self.contactsAppRunning = contactsAppRunning
        self.acquireLock = acquireLock
    }

    // MARK: observing

    public var current: SyncSnapshot { snapshot }

    /// A run is in flight (tests wait for this to clear).
    var isBusy: Bool { runTask != nil }

    // Tests wait on these instead of on real time: every run that ends, and every wake-up of the timer or the debounce
    // waiter once it has been handled, is counted.
    private(set) var completedRuns = 0
    private(set) var handledWakeups = 0
    private var runWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var wakeupWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func waitForRuns(_ target: Int) async {
        if completedRuns >= target { return }
        await withCheckedContinuation { runWaiters.append((target, $0)) }
    }

    func waitForWakeups(_ target: Int) async {
        if handledWakeups >= target { return }
        await withCheckedContinuation { wakeupWaiters.append((target, $0)) }
    }

    func waitUntilIdle() async {
        while let active = runTask { await active.value }
    }

    private func runFinished() {
        completedRuns += 1
        let ready = runWaiters.filter { $0.target <= completedRuns }
        runWaiters.removeAll { $0.target <= completedRuns }
        for waiter in ready { waiter.continuation.resume() }
    }

    private func wakeupHandled() {
        handledWakeups += 1
        let ready = wakeupWaiters.filter { $0.target <= handledWakeups }
        wakeupWaiters.removeAll { $0.target <= handledWakeups }
        for waiter in ready { waiter.continuation.resume() }
    }

    /// The current snapshot, then every change.
    public func snapshots() -> AsyncStream<SyncSnapshot> {
        let (stream, continuation) = AsyncStream<SyncSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers[id] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func publish(_ change: (inout SyncSnapshot) -> Void) {
        var updated = snapshot
        change(&updated)
        // The details belong to the confirmation pause and to nothing else.
        if case .paused(.needsConfirmation) = updated.status {} else { updated.pauseDetails = [] }
        guard updated != snapshot else { return }
        snapshot = updated
        for observer in observers.values { observer.yield(updated) }
    }

    // MARK: lifecycle

    /// Takes the instance lock, reads the saved switches and starts the timer. If sync was already approved (and is not
    /// paused) a first run starts right away; that run settles any interrupted one before planning.
    public func start() {
        guard !started else { return }
        started = true
        if let acquireLock {
            do {
                heldLock = try acquireLock()
            } catch {
                disabledReason = error.localizedDescription
                publish { $0.status = .disabled(error.localizedDescription) }
                return
            }
        }
        do {
            let saved = try stateStore.load()
            approved = saved.firstSyncApproved
            userPaused = saved.pause == .user
        } catch {
            publish { $0.status = .failed(error.localizedDescription) }
            return
        }
        publish {
            $0.firstSyncApproved = approved
            $0.status = userPaused && approved ? .paused(.user) : .idle
        }
        startTimer()
        if canRunAutomatically { request(delay: 0) }
        // The list is otherwise filled only when a run completes, and a launch that stays paused never gets there.
        Task { await publishStoredReviewsAtLaunch() }
    }

    private func publishStoredReviewsAtLaunch() async {
        guard case .ready(let env) = await environment(), snapshot.lastRunAt == nil else { return }
        try? await publishStoredReviews(google: env.google)
    }

    private func publishStoredReviews(google: any GoogleContactsClient) async throws {
        let state = try stateStore.load()
        let reviews = await summaries(of: try reviewStore.load(), baselines: state.baselines, showPhotos: state.syncPhotos, google: google)
        publish { $0.reviewItems = reviews }
    }

    /// Stops the timer and any run, and lets go of the instance lock.
    public func stop() async {
        started = false
        timerTask?.cancel()
        timerTask = nil
        cancelPending()
        rerunWanted = false
        let active = runTask
        active?.cancel()
        await active?.value
        heldLock?.release()
        heldLock = nil
    }

    private var canRunAutomatically: Bool {
        started && disabledReason == nil && approved && !userPaused && !awaitingConfirmation
    }

    // MARK: triggers

    /// Asks for a run once things have been quiet for the debounce time (30 seconds after a wake). Ignored while syncing is
    /// off, not yet approved, paused or waiting for a confirmation.
    public func trigger(_ event: SyncEvent) {
        guard canRunAutomatically else { return }
        request(delay: event == .wake ? schedule.wakeDelay : schedule.debounce)
    }

    /// Runs now, whatever the debounce or a back-off says, and returns when the run (or the one already going) is over.
    /// Before the first sync is approved this builds the preview.
    public func syncNow() async {
        guard started, disabledReason == nil else { return }
        await perform(RunOptions(trigger: .syncNow))
    }

    /// Builds the first-sync preview (reads iCloud and Google, writes nothing). No-op once sync is approved.
    public func refreshPreview() async {
        guard started, disabledReason == nil, !approved else { return }
        await perform(RunOptions(trigger: .syncNow))
    }

    private func startTimer() {
        timerTask?.cancel()
        let clock = clock
        let interval = schedule.interval
        var next = clock.now().addingTimeInterval(interval)
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(until: next) } catch { return }
                next = clock.now().addingTimeInterval(interval)
                await self?.timerTick()
            }
        }
    }

    private func timerTick() {
        trigger(.timer)
        wakeupHandled()
    }

    /// Debounce: the run is due `delay` after the latest request, but never more than `maxDebounce` after the first one,
    /// and never inside a back-off.
    private func request(delay: TimeInterval) {
        guard canRunAutomatically else { return }
        let now = clock.now()
        let first = firstRequestAt ?? now
        firstRequestAt = first
        var due = max(now.addingTimeInterval(delay), dueAt ?? .distantPast)
        due = min(due, first.addingTimeInterval(max(schedule.maxDebounce, delay)))
        if let backoffUntil { due = max(due, backoffUntil) }
        dueAt = due
        arm()
    }

    private func arm() {
        guard let dueAt else { return }
        waiter?.cancel()
        waiterGeneration += 1
        let generation = waiterGeneration
        let clock = clock
        waiter = Task { [weak self] in
            do { try await clock.sleep(until: dueAt) } catch { return }
            await self?.fire(generation)
        }
    }

    private func fire(_ generation: Int) async {
        defer { wakeupHandled() }
        guard generation == waiterGeneration, dueAt != nil else { return }
        // A trigger that arrived during a run that then failed or stopped early was armed before the back-off began.
        if let backoffUntil, clock.now() < backoffUntil {
            dueAt = backoffUntil
            arm()
            return
        }
        dueAt = nil
        firstRequestAt = nil
        waiter = nil
        guard canRunAutomatically else { return }
        if runTask != nil {
            rerunWanted = true
            return
        }
        await perform(RunOptions(trigger: .scheduled))
    }

    private func cancelPending() {
        waiter?.cancel()
        waiter = nil
        waiterGeneration += 1
        dueAt = nil
        firstRequestAt = nil
    }

    // MARK: user actions

    /// The kill switch. Saved, so it holds across launches; if saving fails it still holds in this process and
    /// `SyncSnapshot.pauseSaveWarning` says it will not survive a relaunch. Stops the run in flight (the journal settles
    /// whatever was mid-air next time) and returns once it has stopped.
    public func pause() async {
        guard started, disabledReason == nil else { return }
        userPaused = true
        awaitingConfirmation = false
        confirmedChain = []
        var warning: String?
        do {
            try stateStore.update { $0.pause = .user }
        } catch {
            warning = "Syncing is paused, but the pause could not be saved, so it will not survive a relaunch of Contact Bridge (\(error.localizedDescription))."
        }
        cancelPending()
        rerunWanted = false
        publish {
            $0.status = .paused(.user)
            $0.pauseSaveWarning = warning
        }
        let active = runTask
        active?.cancel()
        await active?.value
        publish { $0.status = .paused(.user) }
    }

    /// Clears the kill switch and runs once now. If the change cannot be saved, syncing stays paused (a relaunch would
    /// pause it again anyway) and `SyncSnapshot.pauseSaveWarning` says why.
    public func resume() async {
        guard started, disabledReason == nil, userPaused else { return }
        do {
            try stateStore.update { if $0.pause == .user { $0.pause = nil } }
        } catch {
            publish {
                $0.pauseSaveWarning = "Syncing is still paused: resuming could not be saved (\(error.localizedDescription))."
            }
            return
        }
        userPaused = false
        publish {
            $0.status = .idle
            $0.pauseSaveWarning = nil
        }
        await perform(RunOptions(trigger: .scheduled))
    }

    /// "Confirm" on a `.needsConfirmation` pause: plans again and, if the pause comes back with the same summary the user
    /// saw, lets it through. A mass of missing Google contacts is let through as `deletedInGoogle` reviews, never as deletes.
    public func confirmAndContinue() async {
        guard started, disabledReason == nil, let summary = snapshot.confirmationSummary else { return }
        awaitingConfirmation = false
        await perform(RunOptions(trigger: .syncNow, confirmedSummaries: confirmedChain.union([summary])))
    }

    /// "Keep paused" on a `.needsConfirmation` pause: the same as the kill switch, until the user resumes.
    public func keepPaused() async {
        await pause()
    }

    /// "Start syncing". Plans once more and, only if that plan has the counts of the preview the user saw, saves the
    /// approval and runs it. Ignored a second time (and while a first call is under way).
    @discardableResult
    public func approveFirstSync() async -> ApprovalOutcome {
        guard started else { return .unavailable("Syncing has not started yet.") }
        if let disabledReason { return .unavailable(disabledReason) }
        guard !approved, !approving else { return .alreadyApproved }
        if userPaused { return .unavailable("Syncing is paused. Resume it first.") }
        guard let shown = snapshot.preview else { return .noPreview }
        approving = true
        defer { approving = false }
        lastApproval = nil
        await perform(RunOptions(trigger: .syncNow, mode: .approve(shown.counts)))
        return lastApproval ?? .unavailable("Syncing was interrupted before it started. Try again.")
    }

    // MARK: running

    /// Waits for a run in flight, then runs `options`. Only one run exists at a time.
    private func perform(_ options: RunOptions) async {
        while let active = runTask { await active.value }
        // stop() may have come while this call waited for the run before it.
        guard started, disabledReason == nil else { return }
        cancelPending()
        let task = Task { await self.runOnce(options) }
        runTask = task
        await task.value
    }

    private func runOnce(_ options: RunOptions) async {
        publish { $0.status = .running(.waitingForOtherChanges) }
        let result: RunResult
        do {
            result = try await gate.withLock { try await self.pipeline(options) }
        } catch is CancellationError {
            result = .cancelled
        } catch {
            result = .failed(error.localizedDescription)
        }
        apply(result, options: options)
        runTask = nil
        runFinished()
        if rerunWanted {
            rerunWanted = false
            request(delay: schedule.debounce)
        }
    }

    private func setPhase(_ phase: SyncPhase) {
        publish { $0.status = .running(phase) }
    }

    private func pipeline(_ options: RunOptions) async throws -> RunResult {
        let env: SyncEnvironment
        switch await environment() {
        case .notReady(let reason): return .notReady(reason)
        case .ready(let ready): env = ready
        }

        var state = try stateStore.load()
        let approvingNow: Bool
        if case .approve = options.mode { approvingNow = true } else { approvingNow = false }
        // `userPaused` too: a pause that could not be saved is not in `state`, but it still holds.
        if state.pause == .user || userPaused, state.firstSyncApproved || approvingNow { return .userPaused }
        if photos != nil, state.syncPhotos, state.photoRepairVersion < PhotoRepair.currentVersion {
            try await PhotoRepair.run(store: env.store, state: stateStore, reviews: reviewStore)
            state = try stateStore.load()
        }
        if approvingNow, env.accountEmail == nil {
            return .notReady("Couldn't confirm which Google account is signed in. Sign out in Setup, then sign in again and allow access to your email address, then start syncing.")
        }
        let nowFn: @Sendable () -> Date = { [clock] in clock.now() }
        let executor = SyncExecutor(
            google: env.google, links: linkStore, state: stateStore, reviews: reviewStore, journal: journalStore,
            history: historyStore, backups: backups, containerID: env.containerID, now: nowFn
        )

        // Recovery first: held creates stay unconfirmed otherwise, and a plan made before it may be out of date.
        setPhase(.checkingInterruptedRun)
        _ = try await executor.recoverInterruptedRun()
        state = try stateStore.load()
        let table = try linkStore.load()

        setPhase(.readingICloud)
        let scan = try await ICloudScanner(store: env.store, notes: env.notes, contactsAppRunning: contactsAppRunning, now: nowFn)
            .scan(state: state, links: table, trigger: options.trigger)

        setPhase(.readingGoogle)
        // Profile photos change without touching the contact, so they are only seen in a full listing: once a day.
        let photosOn = photos != nil && state.syncPhotos
        let full = SyncPlanner.requiresFullGoogleListing(icloud: scan, links: table, state: state)
            || (photosOn && state.firstSyncApproved && PhotoReconciler.fullListingDue(state: state, now: clock.now()))
        let feed = try await GoogleChangeFeed(client: env.google)
            .fetch(state: state, accountEmail: env.accountEmail, requireFullListing: full)

        setPhase(.planning)
        remember(scan, feed)
        var planState = state
        var shown: SyncPreview.Counts?
        if case .approve(let counts) = options.mode {
            planState.firstSyncApproved = true
            shown = counts
        }
        let at = clock.now()
        var observed = PhotoObservations.none
        if let photos, planState.syncPhotos {
            let questioned = Set(try reviewStore.load().filter { $0.kind == .photoConflict }.compactMap(\.icloudID))
            observed = try await PhotoReconciler(store: env.store, google: env.google, fetcher: photos.fetcher, fingerprinter: photos.fingerprinter)
                .observe(icloud: scan, feed: feed, state: planState, links: table, keepSeparate: planState.keepSeparate, questioned: questioned)
        }
        // Pinned first-link conflicts are never derived again; the planner drops those whose live sides agree.
        let open = planState.firstSyncApproved && scan.status == .changed ? try reviewStore.load() : []
        let pinnedPeople = try await readPinnedPeople(open, feed: feed, google: env.google)
        var plan = planner.plan(
            icloud: scan, google: feed, state: planState, links: table, keepSeparate: planState.keepSeparate,
            allowMassGoogleDeletions: options.confirmedSummaries.contains { $0.hasPrefix(SyncPlanner.googleMissingSummaryPrefix) },
            openReviews: open, googleExtra: pinnedPeople, photos: observed, now: at
        )
        if case .needsConfirmation(let summary)? = plan.pause, options.confirmedSummaries.contains(summary) {
            plan.pause = nil
        }

        if !planState.firstSyncApproved {
            return .preview(makePreview(plan, state: state, hasNotes: env.notes != nil, at: at))
        }
        if let shown {
            let preview = makePreview(plan, state: state, hasNotes: env.notes != nil, at: at)
            guard preview.counts == shown else { return .previewChanged(preview) }
            // The account the baselines belong to: without it the account guard has nothing to compare against.
            try stateStore.update {
                $0.firstSyncApproved = true
                $0.googleAccount = $0.googleAccount ?? env.accountEmail
            }
            approved = true
            publish { $0.firstSyncApproved = true }
        }
        if let pause = plan.pause {
            try await publishStoredReviews(google: env.google)
            return .paused(pause, details: Self.forgottenItems(plan.guardedForgottenLinks))
        }

        try reviewStore.reconcile(with: plan, ignoredGoogle: state.ignoredGoogle, at: at)
        setPhase(.applying)
        var report = try await executor.execute(plan: plan)
        if let photos, observed.wasObserved {
            report.photo = try await runPhotos(plan, report: report, support: photos, env: env, tokensBefore: state, at: at)
            // A rate limit or sign-in problem in the photo phase stops the run like one in the field phase: back-off, the
            // "stopped" notice, and no follow-up run straight into it.
            report.halted = report.halted ?? report.photo.halted
            report.warnings += report.photo.warnings + (try leftAlonePhotos(given: report.photo, observed: observed)) + report.photo.putOffReasons
            if feed.isFullListing, planState.useGoogleProfilePhotos {
                try stateStore.update { $0.lastPhotoFullListingAt = at }
            }
        }

        let baselines = try stateStore.load().baselines
        let reviews = await summaries(
            of: try reviewStore.load(), baselines: baselines, showPhotos: try stateStore.load().syncPhotos, google: env.google
        )
        let unconfirmed = try journalStore.load().entries.filter { $0.kind == .create }.count
        return .completed(Completion(
            report: report, waitingForNotes: plan.waitingForNotes, unlinkedWaitingForFullListing: plan.unlinkedWaitingForFullListing,
            notesUnavailable: plan.notesUnavailable, hasDeferred: !plan.deferred.isEmpty, reviews: reviews, unconfirmedCreates: unconfirmed,
            newPairs: photos != nil && planState.syncPhotos ? report.linksAdded + report.created : 0
        ))
    }

    /// Every pair whose photo is left alone until it changes, from the stored failure marks plus this run's, grouped by
    /// reason and named: shown after every run, so the contacts stay listed until a photo changes, not only when they fail.
    private func leftAlonePhotos(given report: PhotoRunReport, observed: PhotoObservations) throws -> [String] {
        let baselines = try stateStore.load().baselines
        var messages = baselines.compactMapValues { $0.photo?.failure?.message }
        for failure in report.givenUp { messages[failure.icloudID] = failure.message }
        for (id, failure) in observed.failures { messages[id] = failure.message }
        return PhotoNotice.lines(
            messages.map { (name(icloudID: $0.key, resourceName: nil, baselines: baselines), $0.value) }, couldNotBe: "synced"
        )
    }

    /// Carries out the plan's photo ops after the field writes (the run still holds the write gate). If something is left
    /// undone, the checkpoint the field run just stored is taken back, so the next run reads the same changes again.
    private func runPhotos(
        _ plan: SyncPlan, report: SyncRunReport, support: SyncPhotoSupport, env: SyncEnvironment, tokensBefore: SyncState, at: Date
    ) async throws -> PhotoRunReport {
        guard !plan.photoOps.isEmpty, report.halted == nil else { return PhotoRunReport() }
        let nowFn: @Sendable () -> Date = { [clock] in clock.now() }
        let photoReport = try await PhotoExecutor(
            google: env.google, store: env.store, links: linkStore, state: stateStore, reviews: reviewStore, history: support.history,
            backups: backups, fetcher: support.fetcher, icloudFallback: support.icloudFallback, containerID: env.containerID,
            needsNotes: env.notes != nil, now: nowFn, sleep: support.sleep
        ).execute(plan.photoOps)
        if report.checkpointCommitted, !photoReport.isComplete {
            try stateStore.update {
                $0.icloudChangeToken = tokensBefore.icloudChangeToken
                $0.googleSyncToken = tokensBefore.googleSyncToken
                $0.fieldsVersion = tokensBefore.fieldsVersion
            }
        }
        return photoReport
    }

    /// The Google contacts of pinned conflicts that an incremental feed did not list (it lists only what changed). One that
    /// cannot be read is left out, and its conflict stays open.
    private func readPinnedPeople(_ items: [ReviewItem], feed: GoogleFeed, google: any GoogleContactsClient) async throws -> [String: GooglePerson] {
        var people: [String: GooglePerson] = [:]
        let names = Set(items.filter(SyncPlanner.canSettle).compactMap(\.resourceName)).sorted()
        for name in names where feed.people[name] == nil && !feed.deleted.contains(name) {
            do {
                people[name] = try await google.getPerson(resourceName: name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        return people
    }

    // MARK: results

    private func apply(_ result: RunResult, options: RunOptions) {
        // Confirmations only carry from one question to the next. Any other end of a run (done, failed, cancelled, a pause
        // for another reason) closes the chain, so an old OK never covers a later, different run.
        if case .paused(.needsConfirmation, _) = result, !options.confirmedSummaries.isEmpty {
            confirmedChain = options.confirmedSummaries
        } else {
            confirmedChain = []
        }
        if case .approve = options.mode {
            switch result {
            case .previewChanged: lastApproval = .previewChanged
            case .userPaused: lastApproval = .unavailable("Syncing is paused. Resume it first.")
            case .notReady(let reason): lastApproval = .unavailable(reason)
            case .failed(let message): lastApproval = .unavailable(message)
            case .preview, .cancelled: lastApproval = nil
            case .paused, .completed: lastApproval = .started
            }
            // Once the approval is saved, syncing has started, whatever happened to that first run.
            if approved { lastApproval = .started }
        }

        switch result {
        case .notReady(let reason):
            publish { $0.status = .notReady(reason) }

        case .userPaused:
            publish { $0.status = .paused(.user) }

        case .cancelled:
            publish { $0.status = userPaused && approved ? .paused(.user) : .idle }

        case .failed(let message):
            registerFailure()
            publish {
                $0.status = .failed(message)
                $0.nextAttemptAt = backoffUntil
            }

        case .preview(let preview), .previewChanged(let preview):
            publish {
                $0.status = .idle
                $0.preview = preview
            }

        case .paused(let reason, let details):
            if case .needsConfirmation = reason { awaitingConfirmation = true } else { registerFailure() }
            publish {
                $0.status = .paused(reason)
                $0.pauseDetails = details
                $0.nextAttemptAt = backoffUntil
            }

        case .completed(let done):
            let at = clock.now()
            awaitingConfirmation = false
            if done.report.halted != nil {
                registerFailure()
            } else {
                failures = 0
                backoffUntil = nil
            }
            publish {
                $0.status = .idle
                $0.preview = nil
                $0.firstSyncApproved = true
                $0.lastRunAt = at
                $0.lastRun = SyncRunSummary(finishedAt: at, report: done.report)
                $0.nextAttemptAt = backoffUntil
                $0.reviewItems = done.reviews
                $0.waitingForNotes = done.waitingForNotes
                $0.unlinkedWaitingForFullListing = done.unlinkedWaitingForFullListing
                $0.unconfirmedCreates = done.unconfirmedCreates
                $0.notesUnavailable = done.notesUnavailable
            }
            // Work the mutation cap carried over is picked up soon, as long as the runs keep making progress.
            let carriedOver = done.hasDeferred && done.report.googleWrites > 0
            if carriedOver || done.newPairs > 0, done.report.halted == nil, followUps < schedule.maxFollowUps {
                followUps += 1
                request(delay: schedule.debounce)
            } else {
                followUps = 0
            }
        }
    }

    private func registerFailure() {
        failures += 1
        let wait = min(schedule.backoffStart * pow(2, Double(failures - 1)), schedule.backoffMax)
        backoffUntil = clock.now().addingTimeInterval(wait)
    }

    // MARK: names and the preview

    private func remember(_ scan: ICloudScan, _ feed: GoogleFeed) {
        if scan.status == .changed {
            icloudNames = Dictionary(scan.records.map { ($0.sourceIdentifier, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }
        if feed.isFullListing { googleNames = [:] }
        for (name, person) in feed.people {
            if let record = GooglePersonMapper.record(from: person, source: .google) { googleNames[name] = record.displayName }
        }
    }

    private func name(icloudID: String?, resourceName: String?, baselines: [String: SyncBaseline]) -> String {
        if let icloudID, let known = icloudNames[icloudID] ?? baselines[icloudID]?.icloud.displayName { return known }
        if let resourceName, let known = googleNames[resourceName] { return known }
        return "Unknown contact"
    }

    private func summary(
        id: String, kind: ReviewKind, icloudID: String?, resourceName: String?, fields: [SyncField], pinned: Bool = false,
        photoReason: PhotoConflictReason? = nil, baselines: [String: SyncBaseline]
    ) -> SyncReviewSummary {
        let mayBe = kind == .possibleLink ? resourceName.flatMap { googleNames[$0] } : nil
        return SyncReviewSummary(
            id: id, kind: kind, name: name(icloudID: icloudID, resourceName: resourceName, baselines: baselines), detail: mayBe,
            fields: fields, photoReason: photoReason, isFirstLink: pinned
        )
    }

    /// Stored review items as the screen lists them. Google contacts this run did not list are looked up by name, a few
    /// at a time.
    /// Photo questions are left out while photo sync is off: they stay stored, and come back when it is switched on.
    private func summaries(
        of stored: [ReviewItem], baselines: [String: SyncBaseline], showPhotos: Bool, google: any GoogleContactsClient
    ) async -> [SyncReviewSummary] {
        let items = showPhotos ? stored : stored.filter { $0.kind != .photoConflict }
        var lookups = 25
        for item in items {
            guard let resourceName = item.resourceName, googleNames[resourceName] == nil,
                  item.icloudID == nil || item.kind == .possibleLink, lookups > 0, !Task.isCancelled
            else { continue }
            lookups -= 1
            if let person = try? await google.getPerson(resourceName: resourceName),
               let record = GooglePersonMapper.record(from: person, source: .google) {
                googleNames[resourceName] = record.displayName
            }
        }
        return items.map {
            summary(
                id: $0.id, kind: $0.kind, icloudID: $0.icloudID, resourceName: $0.resourceName, fields: $0.fields, pinned: $0.pinned,
                photoReason: $0.photoReason, baselines: baselines
            )
        }
    }

    private static func forgottenItems(_ links: [DroppedLinkInfo]) -> [SyncPreview.Item] {
        links.map {
            SyncPreview.Item(id: $0.icloudID, name: $0.name, detail: $0.reason == .iCloudGone ? "deleted in iCloud" : "gone from iCloud and Google")
        }
    }

    private func makePreview(_ plan: SyncPlan, state: SyncState, hasNotes: Bool, at: Date) -> SyncPreview {
        let baselines = state.baselines
        var backups: [String] = []
        if plan.mutationCount > 0 {
            backups.append("Right before the first change to Google, a full backup of your iCloud and Google contacts is taken\(hasNotes ? ", with notes" : ""). A backup from the last 24 hours is reused.")
            if !hasNotes { backups.append("Notes are not in that backup: notes access is not granted (see Setup).") }
        } else {
            backups.append("Nothing in Google would be changed, so no backup is needed for this run.")
        }
        return SyncPreview(
            links: plan.links.map {
                SyncPreview.Item(id: $0.icloudID, name: $0.baseline.icloud.displayName, detail: $0.reasons.isEmpty ? nil : $0.reasons.joined(separator: ", "))
            },
            creates: plan.creates.map { SyncPreview.Item(id: $0.icloudID, name: $0.record.displayName, detail: nil) },
            updates: plan.updates.map {
                SyncPreview.Item(
                    id: $0.icloudID, name: $0.baseline.icloud.displayName,
                    detail: SyncField.allCases.filter($0.fields.contains).map(\.title).joined(separator: ", ")
                )
            },
            deletes: plan.deletes.map { SyncPreview.Item(id: $0.icloudID, name: $0.baseline.icloud.displayName, detail: nil) },
            photos: plan.photoOps.filter { $0.kind != .recordBaseline }.map {
                SyncPreview.Item(id: $0.icloudID, name: name(icloudID: $0.icloudID, resourceName: $0.resourceName, baselines: baselines), detail: $0.kind.text)
            },
            reviews: plan.review.map {
                summary(
                    id: $0.id, kind: $0.kind, icloudID: $0.icloudID, resourceName: $0.resourceName, fields: $0.fields,
                    photoReason: $0.photoReason, baselines: baselines
                )
            },
            forgottenLinks: Self.forgottenItems(plan.forgottenLinkInfo), waitingForNotes: plan.waitingForNotes,
            unlinkedWaitingForFullListing: plan.unlinkedWaitingForFullListing, notesUnavailable: plan.notesUnavailable,
            pause: plan.pause, backups: backups, generatedAt: at
        )
    }
}
