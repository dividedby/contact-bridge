import AppKit
import ContactBridgeCore
import Network
import Observation
import Synchronization

enum SidebarSection: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case backup = "Backup"
    case importContacts = "Import"
    case dedupe = "Dedupe"
    case cleanUp = "Clean up"
    case sync = "Sync"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .setup: "checklist"
        case .backup: "externaldrive"
        case .importContacts: "square.and.arrow.down"
        case .dedupe: "person.2.crop.square.stack"
        case .cleanUp: "trash"
        case .sync: "arrow.triangle.2.circlepath"
        }
    }
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Composition root and shared state. The per-screen models hold their own state and reach the services through here.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarSection = .setup
    var alert: AlertInfo?

    @ObservationIgnored let deps: AppDependencies
    var signIn: SignInController { deps.signIn }
    @ObservationIgnored private(set) var setup: SetupModel!
    @ObservationIgnored private(set) var backup: BackupModel!
    @ObservationIgnored private(set) var importing: ImportModel!
    @ObservationIgnored private(set) var dedupe: DedupeModel!
    @ObservationIgnored private(set) var cleanup: CleanupModel!
    @ObservationIgnored private(set) var sync: SyncModel!
    @ObservationIgnored private(set) var review: ReviewModel!
    @ObservationIgnored private(set) var photoSettings: PhotoSettingsModel!
    @ObservationIgnored let loginItem: LoginItemSettings
    @ObservationIgnored let shell: ShellSettings
    @ObservationIgnored let notifier: SyncNotifier
    @ObservationIgnored private var started = false
    @ObservationIgnored private var cachedStore: (id: String, store: any ContactStoring)?
    @ObservationIgnored private(set) lazy var backupCoordinator = BackupCoordinator(makeSetup: { [self] in try await makeBackupSetup() })

    init(dependencies: AppDependencies) {
        deps = dependencies
        loginItem = LoginItemSettings(service: dependencies.loginItem)
        shell = ShellSettings(defaults: dependencies.defaults)
        notifier = SyncNotifier(
            delivery: dependencies.notifications, unavailableReason: dependencies.notificationsUnavailableReason,
            defaults: dependencies.defaults, knownReviewIDs: Set((try? dependencies.reviews.load())?.map(\.id) ?? [])
        )
        setup = SetupModel(app: self)
        backup = BackupModel(app: self)
        importing = ImportModel(app: self)
        dedupe = DedupeModel(app: self)
        cleanup = CleanupModel(app: self)
        sync = SyncModel(app: self)
        review = ReviewModel(app: self)
        photoSettings = PhotoSettingsModel(app: self)
        // A click on a notification: the review list and the confirmation both live on the Sync screen.
        notifier.onOpen = { [weak self] _ in self?.showWindow(.sync) }
    }

    static func make() -> AppModel {
        AppModel(dependencies: AppDependencies.demoRequested ? .demo() : .live())
    }

    /// Brings the window to the front (creating it if it was closed), on `section` if given.
    func showWindow(_ section: SidebarSection? = nil) {
        if let section { selection = section }
        ActivationPolicyController.shared.showMainWindow()
    }

    /// Starts everything that runs without a window: sign-in, setup state, the sync engine and its triggers.
    func start() async {
        guard !started else { return }
        started = true
        loginItem.refresh()
        await notifier.start()
        await signIn.restore()
        await setup.refresh()
        // The probe can raise the Automation prompt, so on a live launch it only runs on its own once the user has
        // granted access before; then macOS answers silently (or reports a revoke). Demo has no permission to ask for.
        if deps.isDemo || deps.defaults.bool(forKey: SetupModel.notesGrantedKey) { await setup.checkNotes() }
        await backup.refresh()
        await sync.start()
    }

    // MARK: shared services

    /// The store for the selected container, or nil until permission is granted and a container is chosen.
    var store: (any ContactStoring)? {
        guard setup.contactsStatus == .authorized, let container = setup.selectedContainer else { return nil }
        if cachedStore?.id != container.id { cachedStore = (container.id, deps.makeStore(container.id)) }
        return cachedStore?.store
    }

    /// Why contacts cannot be read yet, phrased as the next step; nil when ready.
    var notReadyReason: String? {
        switch setup.contactsStatus {
        case .authorized: break
        case .notDetermined: return "Allow access to Contacts in Setup first."
        case .denied, .restricted:
            return "Contacts access is off. Turn it on in System Settings > Privacy & Security > Contacts, then reopen Setup."
        }
        if case .savedChoiceUnavailable = setup.resolution {
            return "Your saved contacts account is no longer available. Pick one in Setup first; nothing is changed until you do."
        }
        if setup.selectedContainer == nil { return "Choose which contacts account is iCloud in Setup first." }
        return nil
    }

    var googleClient: (any GoogleContactsClient)? { deps.googleClient(signIn) }
    var notesAreAccessible: Bool { setup.notesStatus == .authorized }

    func makeWorkflows() throws -> ContactWorkflows {
        guard let store else { throw ContactStoreError.accessDenied }
        return ContactWorkflows(
            store: store, google: googleClient, notes: notesAreAccessible ? deps.notes : nil, backups: backupCoordinator,
            links: deps.links, syncState: deps.syncState, gate: deps.writeGate, dismissals: deps.dismissals,
            containerID: setup.selectedContainer?.id
        )
    }

    /// The decisions on the sync screen's review list. Needs a signed-in Google account as well as contacts access.
    func makeReviewWorkflows() throws -> ReviewWorkflows {
        guard let store else { throw ContactStoreError.accessDenied }
        guard let google = googleClient else { throw GoogleAuthError.notSignedIn }
        return ReviewWorkflows(
            store: store, google: google, notes: notesAreAccessible ? deps.notes : nil, backups: backupCoordinator, links: deps.links,
            state: deps.syncState, reviews: deps.reviews, journal: deps.syncJournal, history: deps.syncHistory, gate: deps.writeGate,
            containerID: setup.selectedContainer?.id, photos: deps.photoSupport
        )
    }

    /// What a sync run works on right now, or what is missing. Asked at the start of every run.
    func syncEnvironment() -> SyncEnvironmentState {
        if let reason = notReadyReason { return .notReady(reason) }
        guard case .signedIn(let email) = signIn.status, let store, let google = googleClient else {
            return .notReady("Sign in with Google in Setup first.")
        }
        return .ready(SyncEnvironment(
            store: store, notes: notesAreAccessible ? deps.notes : nil, google: google, accountEmail: email,
            containerID: setup.selectedContainer?.id
        ))
    }

    private func makeBackupSetup() throws -> BackupSetup {
        guard let store else { throw ContactStoreError.accessDenied }
        let writer = BackupWriter(
            store: store, google: googleClient, notes: notesAreAccessible ? deps.notes : nil, photoFetcher: deps.photoSupport?.fetcher,
            baseDirectory: deps.backupDirectory
        )
        return BackupSetup(writer: writer, containerID: setup.selectedContainer?.id)
    }

    /// The container or notes access changed: anything loaded from the old state is stale.
    func servicesChanged() {
        // A cached backup covers one container, one notes state, one Google state: drop it so none is reused for another.
        Task { await backupCoordinator.invalidate() }
        importing.reset()
        dedupe.reset()
        cleanup.reset()
        review.reset()
        sync.servicesChanged()
    }

    func present(_ error: any Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }
}

// MARK: - setup

@MainActor
@Observable
final class SetupModel {
    var contactsStatus: ContactAuthorization = .notDetermined
    var containers: [ContactContainer] = []
    var resolution: ContainerResolution?
    var notesStatus: NotesAccessStatus = .unknown
    var isCheckingNotes = false

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private lazy var statusStore = app.deps.makeStore(nil)
    static let containerKey = "selectedContainerID"
    static let notesGrantedKey = "notesAccessGranted"

    init(app: AppModel) {
        self.app = app
    }

    var selectedContainer: ContactContainer? {
        if case .selected(let container, _) = resolution { container } else { nil }
    }

    /// Containers the user may pick between: every CardDAV account.
    var choosableContainers: [ContactContainer] {
        if case .needsUserChoice(let options) = resolution { return options }
        if case .savedChoiceUnavailable(let options) = resolution { return options }
        return containers.filter { $0.kind == .cardDAV }
    }

    func refresh() async {
        contactsStatus = await statusStore.authorizationStatus()
        if contactsStatus == .authorized { await loadContainers() }
    }

    func requestContactsAccess() async {
        do { contactsStatus = try await statusStore.requestAccess() } catch { app.present(error, title: "Contacts access") }
        if contactsStatus == .authorized { await loadContainers() }
    }

    func loadContainers() async {
        do {
            containers = try await app.deps.containerLister.containers()
            resolve()
        } catch {
            app.present(error, title: "Could not list contact accounts")
        }
    }

    func choose(containerID: String) {
        app.deps.defaults.set(containerID, forKey: Self.containerKey)
        resolve()
    }

    private func resolve() {
        resolution = ContainerResolver.resolve(containers: containers, savedID: app.deps.defaults.string(forKey: Self.containerKey))
        app.servicesChanged()
    }

    func checkNotes() async {
        isCheckingNotes = true
        notesStatus = await NotesAccessProbe.check(app.deps.notes)
        isCheckingNotes = false
        switch notesStatus {
        case .authorized: app.deps.defaults.set(true, forKey: Self.notesGrantedKey)
        case .notAuthorized: app.deps.defaults.set(false, forKey: Self.notesGrantedKey)
        case .unknown, .unavailable: break // Contacts not reachable right now says nothing about the permission.
        }
        app.servicesChanged()
    }
}

// MARK: - backup

@MainActor
@Observable
final class BackupModel {
    var entries: [BackupEntry] = []
    var isRunning = false
    var lastMessage: String?

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func refresh() async {
        let directory = app.deps.backupDirectory
        entries = await Task.detached { BackupCatalog.list(in: directory) }.value
    }

    func backUpNow() async {
        guard !isRunning else { return }
        if let reason = app.notReadyReason {
            app.alert = AlertInfo(title: "Cannot back up yet", message: reason)
            return
        }
        isRunning = true
        lastMessage = nil
        defer { isRunning = false }
        do {
            let receipt = try await app.backupCoordinator.backUpNow()
            let counts = receipt.manifest.counts
            var message = "Backed up \(counts.icloud ?? 0) iCloud contacts"
            if let connections = counts.googleConnections { message += ", \(connections) Google contacts" }
            if let others = counts.googleOther { message += ", \(others) other contacts" }
            message += receipt.manifest.notesIncluded ? ", with notes." : ". Notes were not included: check notes access in Setup, then back up again."
            lastMessage = message
        } catch {
            app.present(error, title: "Backup failed")
        }
        await refresh()
    }

    func moveToTrash(_ entry: BackupEntry) async {
        let directory = app.deps.backupDirectory
        do {
            try await Task.detached { try BackupCatalog.moveToTrash(entry, in: directory) }.value
            // The cached receipt may point at this folder; never let a trashed backup stand behind a later write.
            await app.backupCoordinator.invalidate()
            lastMessage = "Moved the backup from \(entry.createdAt.formatted(date: .abbreviated, time: .shortened)) to the Trash."
        } catch {
            app.present(error, title: "Could not move the backup to the Trash")
        }
        await refresh()
    }
}

// MARK: - import

@MainActor
@Observable
final class ImportModel {
    var plan: ImportPlan?
    var selectedConnections: Set<String> = []
    var selectedOthers: Set<String> = []
    /// Google resource names of "already in iCloud" name-only matches the user chose to import anyway.
    var importAnyway: Set<String> = []
    var isLoading = false
    var isImporting = false
    var result: ImportResult?
    var showingConfirmation = false

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func reset() {
        plan = nil
        result = nil
    }

    var selectedCandidates: [ImportCandidate] {
        guard let plan else { return [] }
        let forced = plan.links.compactMap { link in
            importAnyway.contains(link.googleResourceName) ? link.importAnywayCandidate : nil
        }.map { var c = $0; c.isSelected = true; return c }
        return plan.toImport.filter { selectedConnections.contains($0.id) }.map { var c = $0; c.isSelected = true; return c }
            + forced
            + plan.otherContactCandidates.filter { selectedOthers.contains($0.id) }.map { var c = $0; c.isSelected = true; return c }
    }

    var selectedConnectionCount: Int { selectedCandidates.filter { $0.record.source == .google }.count }
    var selectedOtherCount: Int { selectedCandidates.filter { $0.record.source == .googleOther }.count }

    var blockReason: String? {
        if let reason = app.notReadyReason { return reason }
        if app.googleClient == nil { return "Sign in with Google in Setup to see what can be imported." }
        return nil
    }

    func loadIfNeeded() async {
        if plan == nil, blockReason == nil, !isLoading { await load() }
    }

    func load() async {
        guard blockReason == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await app.makeWorkflows().loadImportPlan()
            plan = loaded
            selectedConnections = Set(loaded.toImport.filter(\.isSelected).map(\.id))
            selectedOthers = Set(loaded.otherContactCandidates.filter(\.isSelected).map(\.id))
            importAnyway = []
        } catch {
            app.present(error, title: "Could not load Google contacts")
        }
    }

    func runImport() async {
        isImporting = true
        defer { isImporting = false }
        do {
            let run = try await app.makeWorkflows().runImport(selectedCandidates)
            result = run.result
            await app.backup.refresh()
            let created = Set(run.result.created.map(\.candidateID))
            selectedConnections.subtract(created)
            selectedOthers.subtract(created)
            importAnyway.subtract(created)
            await load()
            app.dedupe.reset()
            app.cleanup.reset()
        } catch {
            showingConfirmation = false
            app.present(error, title: "Import failed")
        }
    }
}

// MARK: - dedupe

/// Set from the main actor, read by the bulk merge between groups from another thread.
private final class StopSignal: Sendable {
    private let requested = Mutex(false)
    var isRequested: Bool { requested.withLock { $0 } }
    func request() { requested.withLock { $0 = true } }
}

@MainActor
@Observable
final class DedupeModel {
    var scan: DuplicateScan?
    var notes: [String: String] = [:]
    var recordsByID: [String: ContactRecord] = [:]
    var notesIssue: String?
    var isLoading = false
    var selectedClusterID: String? {
        didSet { if oldValue != selectedClusterID { draft = scan?.clusters.first { $0.id == selectedClusterID }.map(MergeDraft.init) } }
    }
    var draft: MergeDraft?
    var showingConfirmation = false
    var isMerging = false
    var mergeRun: MergeRun?

    /// Each group as the matcher suggests it, by cluster id: what a bulk merge would do.
    private(set) var suggestedDrafts: [String: MergeDraft] = [:]
    private(set) var eligibility: [String: BulkEligibility] = [:]
    var checkedClusterIDs: Set<String> = []
    var showingBulkSheet = false
    var isBulkMerging = false
    var isStopRequested = false
    var bulkProgress: BulkProgress?
    var bulkReport: BulkMergeReport?
    @ObservationIgnored private var stopSignal = StopSignal()

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func reset() {
        scan = nil
        draft = nil
        selectedClusterID = nil
        checkedClusterIDs = []
        suggestedDrafts = [:]
        eligibility = [:]
    }

    var blockReason: String? { app.notReadyReason }

    // MARK: bulk selection

    var safeClusterIDs: [String] { (scan?.clusters ?? []).map(\.id).filter { eligibility[$0] == .safe } }
    /// The ticked groups in list order, as the matcher suggests merging them.
    var checkedDrafts: [MergeDraft] { (scan?.clusters ?? []).compactMap { checkedClusterIDs.contains($0.id) ? suggestedDrafts[$0.id] : nil } }
    var checkedDeleteCount: Int { checkedDrafts.reduce(0) { $0 + $1.others.count } }

    func isChecked(_ clusterID: String) -> Bool { checkedClusterIDs.contains(clusterID) }

    func setChecked(_ clusterID: String, _ on: Bool) {
        guard eligibility[clusterID] != .needsReview else { return }
        if on { checkedClusterIDs.insert(clusterID) } else { checkedClusterIDs.remove(clusterID) }
    }

    func selectAllSafe() { checkedClusterIDs = Set(safeClusterIDs) }
    func selectNone() { checkedClusterIDs = [] }

    /// Why a bulk merge is unavailable, or nil. (Not duplicates only needs the list.)
    var bulkMergeBlockReason: String? {
        if let reason = app.notReadyReason { return reason }
        if !app.notesAreAccessible {
            return "Grant notes access in Setup first, so notes on the contacts that get deleted are kept."
        }
        return nil
    }

    /// Why Merge is unavailable for the open draft, or nil.
    var mergeBlockReason: String? {
        if let reason = app.notReadyReason { return reason }
        guard let draft, draft.canMerge else { return "A merge needs at least two contacts." }
        if !app.notesAreAccessible {
            return "Grant notes access in Setup first, so notes on the contacts that get deleted are kept."
        }
        return nil
    }

    func loadIfNeeded() async {
        if scan == nil, blockReason == nil, !isLoading { await load() }
    }

    func load() async {
        guard blockReason == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let workflows = try app.makeWorkflows()
            let loaded = try await workflows.loadDuplicates()
            scan = loaded
            suggestedDrafts = Dictionary(loaded.clusters.map { ($0.id, MergeDraft(cluster: $0)) }, uniquingKeysWith: { first, _ in first })
            eligibility = suggestedDrafts.mapValues(\.bulkEligibility)
            checkedClusterIDs = checkedClusterIDs.filter { eligibility[$0] != nil && eligibility[$0] != .needsReview }
            recordsByID = Dictionary(loaded.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            if app.notesAreAccessible {
                do {
                    notes = try await workflows.loadNotes(ids: loaded.records.map(\.sourceIdentifier))
                    notesIssue = nil
                } catch {
                    notes = [:]
                    notesIssue = error.localizedDescription
                }
            } else {
                notes = [:]
                notesIssue = "Notes are not shown because notes access has not been granted (see Setup)."
            }
            let keep = selectedClusterID
            selectedClusterID = nil
            selectedClusterID = loaded.clusters.contains { $0.id == keep } ? keep : nil
        } catch {
            app.present(error, title: "Could not look for duplicates")
        }
    }

    func removeMember(_ id: String) { draft?.remove(memberID: id) }
    func restoreMember(_ id: String) { draft?.restore(memberID: id) }
    func chooseSurvivor(_ id: String) { draft?.chooseSurvivor(id) }
    func pick(_ field: MergeField, recordID: String) { draft?.pick(field, recordID: recordID) }

    func dismissSelected() async {
        guard let draft else { return }
        do {
            try app.makeWorkflows().dismiss(draft)
            await load()
        } catch {
            app.present(error, title: "Could not save that choice")
        }
    }

    func dismissChecked() async {
        let drafts = checkedDrafts
        guard !drafts.isEmpty else { return }
        do {
            try app.makeWorkflows().dismiss(drafts)
            checkedClusterIDs = []
            await load()
        } catch {
            app.present(error, title: "Could not save that choice")
        }
    }

    func restoreDismissed() async {
        do {
            try app.makeWorkflows().restoreDismissed()
            await load()
        } catch {
            app.present(error, title: "Could not restore hidden groups")
        }
    }

    func merge() async {
        guard let draft, mergeBlockReason == nil else { return }
        isMerging = true
        defer { isMerging = false }
        do {
            mergeRun = try await app.makeWorkflows().runMerge(draft)
            await app.backup.refresh()
            await load()
            app.importing.reset()
            app.cleanup.reset()
        } catch {
            showingConfirmation = false
            app.present(error, title: "Merge failed")
        }
    }

    // MARK: bulk merge

    func bulkMerge() async {
        let drafts = checkedDrafts
        guard !drafts.isEmpty, !isBulkMerging, bulkMergeBlockReason == nil else { return }
        stopSignal = StopSignal()
        let signal = stopSignal
        isStopRequested = false
        bulkProgress = nil
        isBulkMerging = true
        defer {
            isBulkMerging = false
            bulkProgress = nil
        }
        do {
            let report = try await app.makeWorkflows().runBulkMerge(
                drafts,
                progress: { [weak self] update in Task { @MainActor in if self?.isBulkMerging == true { self?.bulkProgress = update } } },
                isCancelled: { signal.isRequested }
            )
            bulkReport = report
            checkedClusterIDs = []
            await app.backup.refresh()
            await load()
            app.importing.reset()
            app.cleanup.reset()
        } catch {
            showingBulkSheet = false
            app.present(error, title: "Merge failed")
        }
    }

    /// Takes effect after the group being merged.
    func stopBulkMerge() {
        isStopRequested = true
        stopSignal.request()
    }
}

// MARK: - clean up

@MainActor
@Observable
final class CleanupModel {
    /// Every contact in the account, sorted by name.
    private(set) var rows: [CleanupRow] = [] { didSet { refilter() } }
    private(set) var shownRows: [CleanupRow] = []
    private(set) var hasLoaded = false
    var filter = CleanupFilter() { didSet { if filter != oldValue { refilter() } } }
    /// Contact ids. Kept when the filter or search changes, so the count is everything ticked, shown or not.
    var selection: Set<String> = []
    var isLoading = false
    var showingConfirmation = false
    var isDeleting = false
    var phase: CleanupPhase?
    var run: CleanupRun?
    /// How many of the ticked contacts the next sync would also remove from Google; set when the confirmation opens.
    private(set) var googleRemovalsPending = 0
    /// Whether syncing is approved: deleted contacts then keep their import link until the sync has removed the Google copy.
    private(set) var syncIsOn = false

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    private func refilter() { shownRows = filter.apply(to: rows) }

    func reset() {
        rows = []
        hasLoaded = false
        selection = []
    }

    var blockReason: String? { app.notReadyReason }

    /// Why Delete is unavailable, or nil: the backup that makes it safe must include notes.
    var deleteBlockReason: String? {
        if let reason = app.notReadyReason { return reason }
        if !app.notesAreAccessible {
            return "Grant notes access in Setup first, so notes on the contacts that get deleted are kept in the backup."
        }
        return nil
    }

    /// The ticked contacts in list order.
    var selectedRows: [CleanupRow] { rows.filter { selection.contains($0.id) } }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func setSelected(_ id: String, _ on: Bool) {
        if on { selection.insert(id) } else { selection.remove(id) }
    }

    func selectAllShown() { selection.formUnion(shownRows.map(\.id)) }
    func selectNone() { selection = [] }

    func confirmDelete() {
        googleRemovalsPending = (try? app.makeWorkflows().googleRemovalsPending(ifDeleting: selectedRows.map(\.id))) ?? 0
        syncIsOn = (try? app.deps.syncState.load().firstSyncApproved) == true
        showingConfirmation = true
    }

    func loadIfNeeded() async {
        if !hasLoaded, blockReason == nil, !isLoading { await load() }
    }

    func load() async {
        guard blockReason == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await app.makeWorkflows().loadCleanupRows()
            hasLoaded = true
            selection.formIntersection(Set(rows.map(\.id)))
        } catch {
            app.present(error, title: "Could not load contacts")
        }
    }

    func deleteSelected() async {
        let ids = selectedRows.map(\.id)
        guard !ids.isEmpty, !isDeleting, deleteBlockReason == nil else { return }
        run = nil
        phase = .backingUp
        isDeleting = true
        defer {
            isDeleting = false
            phase = nil
        }
        do {
            run = try await app.makeWorkflows().deleteContacts(
                ids: ids, progress: { [weak self] update in Task { @MainActor in if self?.isDeleting == true { self?.phase = update } } }
            )
            selection = []
            await app.backup.refresh()
            await load()
            app.dedupe.reset()
            app.importing.reset()
        } catch {
            showingConfirmation = false
            app.present(error, title: "Delete failed")
        }
    }
}

// MARK: - sync

/// The sync engine's state for the screen, plus the system events that wake it (store changes, wake, network).
@MainActor
@Observable
final class SyncModel {
    private(set) var snapshot = SyncSnapshot()
    /// Said after "Start syncing" when the plan moved on since the preview was shown.
    var notice: String?
    private(set) var isApproving = false

    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var storeWatch: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    init(app: AppModel) {
        self.app = app
        let deps = app.deps
        engine = SyncEngine(
            environment: { [weak app] in await app?.syncEnvironment() ?? .notReady("Contact Bridge is closing.") },
            links: deps.links, state: deps.syncState, reviews: deps.reviews, journal: deps.syncJournal, history: deps.syncHistory,
            backups: app.backupCoordinator, gate: deps.writeGate, contactsAppRunning: deps.contactsAppRunning,
            acquireLock: deps.acquireSyncLock, photos: deps.photoSupport
        )
    }

    /// Changes when something that decides whether sync can run changes, so the screen builds its preview again.
    var readyKey: String {
        [
            String(describing: snapshot.status == .notStarted), app.notReadyReason ?? "", String(describing: app.signIn.status),
            app.setup.selectedContainer?.id ?? "", String(app.notesAreAccessible),
        ].joined(separator: "|")
    }

    func start() async {
        guard observing == nil else { return }
        observing = Task { [engine] in
            for await next in await engine.snapshots() {
                snapshot = next
                app.notifier.observe(next)
            }
        }
        await engine.start()
        watchStore()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [engine] _ in
            Task { await engine.trigger(.wake) }
        }
        let monitor = NWPathMonitor()
        let reachable = Mutex(true)
        monitor.pathUpdateHandler = { [engine] path in
            let online = path.status == .satisfied
            let wasOnline = reachable.withLock { state in
                defer { state = online }
                return state
            }
            if online, !wasOnline { Task { await engine.trigger(.networkBack) } }
        }
        monitor.start(queue: DispatchQueue(label: "dev.dividedby.contactbridge.network"))
        pathMonitor = monitor
    }

    /// The chosen account, sign-in or notes access changed.
    func servicesChanged() {
        watchStore()
        Task { await engine.trigger(.settingsChanged) }
    }

    private func watchStore() {
        storeWatch?.cancel()
        guard let store = app.store else { return }
        storeWatch = Task { [engine] in
            for await _ in store.changes() { await engine.trigger(.storeChanged) }
        }
    }

    /// Builds the first-sync preview when the screen shows one that is missing. Once syncing is approved, a change in what
    /// sync works on (sign-in, account, notes access) asks for a run.
    func screenAppeared() async {
        guard snapshot.status != .notStarted else { return }
        if snapshot.firstSyncApproved {
            await engine.trigger(.settingsChanged)
        } else if snapshot.preview == nil, !snapshot.isRunning {
            await engine.refreshPreview()
        }
    }

    func refreshPreview() async {
        notice = nil
        await engine.refreshPreview()
    }

    func approve() async {
        guard !isApproving else { return }
        isApproving = true
        notice = nil
        defer { isApproving = false }
        switch await engine.approveFirstSync() {
        case .started, .alreadyApproved: break
        case .previewChanged:
            notice = "Your contacts changed while you were looking, so the numbers above are new. Check them, then press Start syncing again."
        case .noPreview:
            notice = "The preview is not ready yet."
        case .unavailable(let reason):
            app.alert = AlertInfo(title: "Cannot start syncing", message: reason)
        }
    }

    func syncNow() async { await engine.syncNow() }
    func pause() async { await engine.pause() }
    func resume() async { await engine.resume() }
    func confirm() async { await engine.confirmAndContinue() }
    func keepPaused() async { await engine.keepPaused() }
}

// MARK: - photo settings

/// The two photo switches in Setup. They live in the sync state, so the engine and the review screen see them at once.
@MainActor
@Observable
final class PhotoSettingsModel {
    private(set) var settings = PhotoSettings(syncPhotos: true, useGoogleProfilePhotos: false)

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func refresh() {
        do {
            settings = try PhotoSettings.read(app.deps.syncState)
        } catch {
            app.present(error, title: "Could not read the photo settings")
        }
    }

    /// Off: no photo is read, written or asked about, and stored questions are hidden (not deleted). The sync screen's list is
    /// republished right away.
    func setSyncPhotos(_ on: Bool) {
        change(runNow: true) { try PhotoSettings.setSyncPhotos(on, in: $0) }
    }

    /// On: the next run lists Google in full to find profile photos.
    func setUseGoogleProfilePhotos(_ on: Bool) {
        change(runNow: false) { try PhotoSettings.setUseGoogleProfilePhotos(on, in: $0) }
    }

    private func change(runNow: Bool, _ apply: (any SyncStateStoring) throws -> Void) {
        do {
            try apply(app.deps.syncState)
        } catch {
            app.present(error, title: "Could not change the photo setting")
        }
        refresh()
        guard app.sync.snapshot.firstSyncApproved else { return }
        Task { [sync = app.sync] in
            if runNow { await sync.syncNow() } else { await sync.engine.trigger(.settingsChanged) }
        }
    }
}

// MARK: - sync review

/// What the user is asked to confirm before it happens.
enum ReviewConfirmation: String, Identifiable {
    case deleteFromICloud
    case keepDeleted
    case deleteFromGoogle
    case deleteFromBoth

    var id: Self { self }
}

/// Which side the bulk photo action keeps.
enum PhotoBulkSide: String, Identifiable {
    case icloud, google

    var id: Self { self }
    var name: String { self == .icloud ? "iCloud" : "Google" }
}

/// The review list's open item and the decisions on it. Every decision goes through `ReviewWorkflows` (inside the write gate),
/// then asks the engine for a run so the list and the baselines settle.
@MainActor
@Observable
final class ReviewModel {
    /// The item on screen, with the live data its decision needs.
    private(set) var detail: ReviewDetail?
    private(set) var isLoading = false
    private(set) var isWorking = false
    /// Said above the open item when it moved while the user was looking.
    var notice: String?
    /// Said on the list after a decision.
    private(set) var resultMessage: String?
    var confirming: ReviewConfirmation?
    /// Items decided on, hidden until the engine's next list no longer has them.
    private(set) var hidden: Set<String> = []

    var showingBulk = false
    private(set) var isBulkWorking = false
    private(set) var bulkReport: BulkKeepReport?

    /// A photo choice that removes a photo, waiting for the user's OK.
    var confirmingPhoto: PhotoReviewDraft.Option?
    /// The bulk photo sheet: which side it keeps, while it is open.
    var photoBulkSide: PhotoBulkSide?
    private(set) var isPhotoBulkWorking = false
    private(set) var photoBulkReport: BulkPhotoReport?

    var showingIgnored = false
    private(set) var ignored: [IgnoredContact] = []
    private(set) var isLoadingIgnored = false

    @ObservationIgnored private unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    func reset() {
        detail = nil
        notice = nil
    }

    var isOpen: Bool { detail != nil || isLoading }

    /// The engine's list without what was just decided.
    var items: [SyncReviewSummary] { app.sync.snapshot.reviewItems.filter { !hidden.contains($0.id) } }
    /// The photo questions (the engine leaves them out while photo sync is off).
    var photoItems: [SyncReviewSummary] { items.filter { $0.kind == .photoConflict } }
    /// First-link conflicts, which "Keep iCloud for all" settles together.
    var firstLinkItems: [SyncReviewSummary] { items.filter { $0.kind == .bothEdited && $0.isFirstLink } }

    // MARK: what is possible

    /// Why decisions cannot be made right now, or nil.
    var blockReason: String? {
        if let reason = app.notReadyReason { return reason }
        if app.googleClient == nil { return "Sign in with Google in Setup first." }
        switch app.sync.snapshot.status {
        case .paused: return "Syncing is paused. Resume it, or clear the pause, before deciding on these."
        case .disabled: return "Syncing is off in this copy of Contact Bridge."
        default: return nil
        }
    }

    /// Saving, Import, Delete, Put back and Restore read or write notes; Link, Keep separate, Ignore and Keep deleted never do.
    func needsNotes(_ action: ReviewAction) -> Bool {
        switch action {
        case .save, .importContact, .deleteFromICloud, .putBack, .restore, .deleteFromBoth: true
        case .ignore, .link, .keepSeparate, .keepDeleted, .photo, .deleteFromGoogle: false
        }
    }

    func block(for action: ReviewAction) -> String? {
        if let reason = blockReason { return reason }
        if needsNotes(action), !app.notesAreAccessible {
            return "Grant notes access in Setup first, so no note is lost."
        }
        return nil
    }

    // MARK: opening

    func open(_ id: String) async {
        guard !isLoading, !isWorking else { return }
        if let reason = blockReason {
            app.alert = AlertInfo(title: "Cannot open this yet", message: reason)
            return
        }
        isLoading = true
        notice = nil
        resultMessage = nil
        defer { isLoading = false }
        do {
            guard let item = try app.deps.reviews.load().first(where: { $0.id == id }) else {
                resultMessage = "That item was already settled."
                return
            }
            detail = try await app.makeReviewWorkflows().loadDetail(item)
        } catch {
            app.present(error, title: "Could not open this item")
        }
    }

    func close() {
        detail = nil
        notice = nil
    }

    /// Reads the open item's contacts again.
    func reload() async {
        guard let item = detail?.item, !isWorking else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            detail = try await app.makeReviewWorkflows().loadDetail(item)
            notice = nil
        } catch {
            app.present(error, title: "Could not read this item again")
        }
    }

    // MARK: the draft

    func pick(_ field: SyncField, _ side: SyncReviewDraft.Side) { detail?.draft?.pick(field, side) }
    func setAction(_ action: SyncReviewDraft.EntryAction, forEntry id: String) { detail?.draft?.setAction(action, forEntry: id) }
    func pickNote(_ pick: SyncReviewDraft.NotePick) { detail?.draft?.pickNote(pick) }
    func chooseICloudEverywhere() { detail?.draft?.chooseICloudEverywhere() }

    // MARK: deciding

    func save() async { await decide(.save, done: "Saved to iCloud and Google.") { try await $0.apply($1) } }
    func importContact() async { await decide(.importContact, done: "Imported to iCloud.") { try await $0.importToICloud($1) } }
    func deleteFromICloud() async { await decide(.deleteFromICloud, done: "Deleted from iCloud.") { try await $0.deleteFromICloud($1) } }
    func putBack() async { await decide(.putBack, done: "Put back in Google.") { try await $0.putBackInGoogle($1) } }
    func keepDeleted() async { await decide(.keepDeleted, done: "Deleted from Google too.") { try await $0.keepDeleted($1) } }
    func restore() async { await decide(.restore, done: "Restored to iCloud.") { try await $0.restoreToICloud($1) } }
    func deleteFromGoogle() async { await decide(.deleteFromGoogle, done: "Deleted from Google.") { try await $0.deleteFromGoogle($1) } }
    func deleteFromBoth() async { await decide(.deleteFromBoth, done: "Deleted from iCloud and Google.") { try await $0.deleteFromBoth($1) } }
    func link() async { await decide(.link, done: "Linked. The next sync compares the two and asks about anything that differs.") { try await $0.link($1) } }

    /// Deciding a photo question. A choice that removes a photo is confirmed first (`confirmingPhoto`).
    func choosePhoto(_ option: PhotoReviewDraft.Option) {
        if option.isDestructive { confirmingPhoto = option } else { Task { await applyPhoto(option) } }
    }

    func applyPhoto(_ option: PhotoReviewDraft.Option) async {
        confirmingPhoto = nil
        await decide(.photo, done: "Photo decided.") { try await $0.applyPhoto($1, choice: option.choice) }
    }

    func ignore() async {
        await decide(.ignore, done: "Ignored. Use Show ignored to bring it back.") { workflows, detail in
            try await workflows.ignore(detail.item)
            return .done(warnings: [])
        }
    }

    func keepSeparate() async {
        await decide(.keepSeparate, done: "Kept separate. The iCloud contact is created in Google on the next sync.") { workflows, detail in
            try await workflows.keepSeparate(detail.item)
            return .done(warnings: [])
        }
    }

    private func decide(
        _ action: ReviewAction, done message: String, _ run: (ReviewWorkflows, ReviewDetail) async throws -> ReviewOutcome
    ) async {
        guard let current = detail, !isWorking, block(for: action) == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            switch try await run(try app.makeReviewWorkflows(), current) {
            case .done(let warnings):
                hidden.insert(current.id)
                detail = nil
                notice = nil
                resultMessage = message
                if !warnings.isEmpty { app.alert = AlertInfo(title: "Done, with a note", message: warnings.joined(separator: "\n")) }
                settle(revealing: [current.id])
            case .changedSinceShown(let fresh):
                notice = "This changed since you looked, so nothing was done. Check it again."
                if let fresh {
                    detail = fresh
                } else {
                    detail = nil
                    resultMessage = "That item changed and was refreshed. Nothing was done."
                    settle()
                }
            }
        } catch {
            app.present(error, title: "Could not save that decision")
            if detail != nil { await reload() }
        }
    }

    /// After a change to contacts: other screens' lists are stale, and the engine settles baselines and the review list.
    /// The sync runs in the background, so the next item can be opened while it does; `decided` stay hidden until it ends.
    private func settle(revealing decided: Set<String> = []) {
        app.importing.reset()
        app.dedupe.reset()
        app.cleanup.reset()
        Task {
            await app.backup.refresh()
            await app.sync.syncNow()
            hidden.subtract(decided)
        }
    }

    // MARK: keep iCloud for all

    func startBulk() {
        bulkReport = nil
        showingBulk = true
    }

    func keepICloudForAll() async {
        guard !isBulkWorking, block(for: .save) == nil else { return }
        let ids = Set(firstLinkItems.map(\.id))
        isBulkWorking = true
        defer { isBulkWorking = false }
        do {
            let items = try app.deps.reviews.load().filter { ids.contains($0.id) }
            let report = try await app.makeReviewWorkflows().keepICloudForAll(items)
            bulkReport = report
            hidden.formUnion(report.applied)
            settle(revealing: Set(report.applied))
        } catch {
            showingBulk = false
            app.present(error, title: "Could not keep iCloud for all")
        }
    }

    // MARK: photos for all

    func startPhotoBulk(_ side: PhotoBulkSide) {
        photoBulkReport = nil
        photoBulkSide = side
    }

    /// "Keep iCloud/Google photos for all". A change bigger than the photo limits comes back as a question first
    /// (`photoBulkReport.needsConfirmation`); `confirmed` goes ahead with it.
    func runPhotoBulk(confirmed: Bool) async {
        guard !isPhotoBulkWorking, let side = photoBulkSide, block(for: .photo) == nil else { return }
        let ids = Set(photoItems.map(\.id))
        isPhotoBulkWorking = true
        defer { isPhotoBulkWorking = false }
        do {
            let items = try app.deps.reviews.load().filter { ids.contains($0.id) }
            let workflows = try app.makeReviewWorkflows()
            let report = side == .icloud
                ? try await workflows.keepICloudPhotosForAll(items, confirmed: confirmed)
                : try await workflows.keepGooglePhotosForAll(items, confirmed: confirmed)
            photoBulkReport = report
            hidden.formUnion(report.applied)
            if report.needsConfirmation == nil { settle(revealing: Set(report.applied)) }
        } catch {
            photoBulkSide = nil
            app.present(error, title: "Could not keep \(side.name) photos for all")
        }
    }

    // MARK: ignored contacts

    func showIgnored() async {
        guard blockReason == nil else {
            app.alert = AlertInfo(title: "Cannot list ignored contacts", message: blockReason ?? "")
            return
        }
        showingIgnored = true
        await loadIgnored()
    }

    private func loadIgnored() async {
        isLoadingIgnored = true
        defer { isLoadingIgnored = false }
        do {
            ignored = try await app.makeReviewWorkflows().loadIgnored()
        } catch {
            app.present(error, title: "Could not read the ignored contacts")
        }
    }

    func unignore(_ contact: IgnoredContact) async {
        do {
            try await app.makeReviewWorkflows().unignore([contact.resourceName])
            ignored.removeAll { $0.id == contact.id }
            resultMessage = "\(contact.name) will be offered again on the next sync."
            settle()
        } catch {
            app.present(error, title: "Could not show that contact again")
        }
    }
}

/// What the buttons on an open item do.
enum ReviewAction {
    case save, importContact, ignore, deleteFromICloud, putBack, keepDeleted, restore, link, keepSeparate, photo, deleteFromGoogle,
         deleteFromBoth
}
