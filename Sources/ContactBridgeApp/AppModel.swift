import AppKit
import ContactBridgeCore
import Observation
import Synchronization

enum SidebarSection: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case backup = "Backup"
    case importContacts = "Import"
    case dedupe = "Dedupe"
    case sync = "Sync"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .setup: "checklist"
        case .backup: "externaldrive"
        case .importContacts: "square.and.arrow.down"
        case .dedupe: "person.2.crop.square.stack"
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
    @ObservationIgnored private var cachedStore: (id: String, store: any ContactStoring)?
    @ObservationIgnored private(set) lazy var backupCoordinator = BackupCoordinator(makeSetup: { [self] in try await makeBackupSetup() })

    init(dependencies: AppDependencies) {
        deps = dependencies
        setup = SetupModel(app: self)
        backup = BackupModel(app: self)
        importing = ImportModel(app: self)
        dedupe = DedupeModel(app: self)
    }

    static func make() -> AppModel {
        AppModel(dependencies: AppDependencies.demoRequested ? .demo() : .live())
    }

    func start() async {
        await signIn.restore()
        await setup.refresh()
        // The probe can raise the Automation prompt, so on a live launch it only runs on its own once the user has
        // granted access before; then macOS answers silently (or reports a revoke). Demo has no permission to ask for.
        if deps.isDemo || deps.defaults.bool(forKey: SetupModel.notesGrantedKey) { await setup.checkNotes() }
        await backup.refresh()
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
            links: deps.links, dismissals: deps.dismissals, containerID: setup.selectedContainer?.id
        )
    }

    private func makeBackupSetup() throws -> BackupSetup {
        guard let store else { throw ContactStoreError.accessDenied }
        let writer = BackupWriter(store: store, google: googleClient, notes: notesAreAccessible ? deps.notes : nil, baseDirectory: deps.backupDirectory)
        return BackupSetup(writer: writer, containerID: setup.selectedContainer?.id)
    }

    /// The container or notes access changed: anything loaded from the old state is stale.
    func servicesChanged() {
        // A cached backup covers one container, one notes state, one Google state: drop it so none is reused for another.
        Task { await backupCoordinator.invalidate() }
        importing.reset()
        dedupe.reset()
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
