import Foundation
import Synchronization
import Testing
@testable import ContactBridgeCore

/// Pictures that are different from each other (and the same as themselves) as far as the fingerprint is concerned.
enum PhotoPictures {
    static func picture(_ seed: UInt64) -> Data { PhotoTestImages.jpeg(PhotoTestImages.scene(seed: seed)) }
    /// The same picture as `picture(seed)`, recompressed and rescaled the way another client would hand it back.
    static func lookAlike(_ seed: UInt64) -> Data {
        PhotoTestImages.jpeg(PhotoTestImages.scaled(PhotoTestImages.scene(seed: seed), width: 180, height: 180), quality: 0.5)
    }
}

/// Counts how many downloads are under way at once.
actor ConcurrencyProbe: GooglePhotoFetching {
    private let inner: any GooglePhotoFetching
    private var active = 0
    private(set) var peak = 0
    private(set) var total = 0

    init(_ inner: any GooglePhotoFetching) {
        self.inner = inner
    }

    func fetch(_ url: URL) async throws -> Data {
        active += 1
        total += 1
        peak = max(peak, active)
        // Let the other downloads start before this one finishes.
        for _ in 0..<5 { await Task.yield() }
        defer { active -= 1 }
        return try await inner.fetch(url)
    }
}

/// An `ExecutorRig` of linked contacts with the photo side added: the fake downloader, a photo history, and helpers to give
/// either side a photo, then observe, plan and execute the way the engine does.
final class PhotoRig: @unchecked Sendable {
    let base: ExecutorRig
    let fetcher: FakeGooglePhotoFetcher
    let photoHistory = InMemoryPhotoHistoryStore()
    private final class Sleeps: Sendable {
        let values = Mutex<[TimeInterval]>([])
    }

    private let recordedSleeps = Sleeps()

    init(_ base: ExecutorRig) {
        self.base = base
        fetcher = FakeGooglePhotoFetcher(client: base.world.google)
    }

    static func linked(count: Int = 4) async throws -> PhotoRig { PhotoRig(try await ExecutorRig.linked(count: count)) }

    var store: InMemoryContactStore { base.world.store }
    var google: FakeGoogleClient { base.world.google }
    var state: SyncState { get throws { try base.stateStore.load() } }
    var sleeps: [TimeInterval] { recordedSleeps.values.withLock { $0 } }
    func cleanUp() { base.cleanUp() }

    func setICloudPhoto(_ id: String, _ data: Data?) async throws { try await store.setPhoto(id: id, data: data, backup: SyncFixtures.receipt()) }
    func setGooglePhoto(_ index: Int, _ data: Data?) async throws { try await google.setContactPhoto(data, for: "people/c\(index)") }
    func setGoogleProfile(_ index: Int, _ data: Data?) async throws { try await google.setProfilePhoto(data, for: "people/c\(index)") }
    func googlePhoto(_ index: Int) async -> Data? { await google.contactPhotoBytes(for: "people/c\(index)") }
    func icloudPhoto(_ id: String) async throws -> Data? { try await store.photoData(id: id) }
    func photoBaseline(_ id: String) throws -> PhotoBaseline? { try state.baselines[id]?.photo }

    func reconciler(maxDownloads: Int = PhotoReconciler.maxDownloads, fetcher: (any GooglePhotoFetching)? = nil) -> PhotoReconciler {
        PhotoReconciler(store: store, google: base.faulty, fetcher: fetcher ?? self.fetcher, maxDownloads: maxDownloads)
    }

    func executor(
        state: (any SyncStateStoring)? = nil, maxGoogleWrites: Int = PhotoExecutor.maxGoogleWrites,
        google client: (any GoogleContactsClient)? = nil, fetcher: (any GooglePhotoFetching)? = nil
    ) -> PhotoExecutor {
        let clock = base.clock
        let sleeps = recordedSleeps
        return PhotoExecutor(
            google: client ?? base.faulty, store: store, links: base.linkStore, state: state ?? base.stateStore, reviews: base.reviews,
            history: photoHistory, backups: base.backups, fetcher: fetcher ?? self.fetcher, now: { clock.now() },
            sleep: { seconds in sleeps.values.withLock { $0.append(seconds) } }, maxGoogleWrites: maxGoogleWrites
        )
    }

    struct Look {
        var scan: ICloudScan
        var feed: GoogleFeed
        var observed: PhotoObservations
        var plan: SyncPlan
    }

    /// Scans iCloud, reads Google, observes the photos and plans, from what the stores hold now.
    func look(
        _ trigger: SyncTrigger = .scheduled, fullListing: Bool = false, maxDownloads: Int = PhotoReconciler.maxDownloads,
        fetcher: (any GooglePhotoFetching)? = nil, planner: SyncPlanner? = nil
    ) async throws -> Look {
        let world = base.world
        world.state = try base.stateStore.load()
        world.links = try base.linkStore.load()
        world.clock = base.clock.now()
        let at = world.clock
        let scan = try await ICloudScanner(store: world.store, notes: world.notes, contactsAppRunning: { false }, now: { at })
            .scan(state: world.state, links: world.links, trigger: trigger)
        let full = fullListing || SyncPlanner.requiresFullGoogleListing(icloud: scan, links: world.links, state: world.state)
        let feed = try await GoogleChangeFeed(client: base.faulty, fieldsVersion: world.feedFieldsVersion)
            .fetch(state: world.state, accountEmail: world.account, requireFullListing: full)
        let observed = try await reconciler(maxDownloads: maxDownloads, fetcher: fetcher)
            .observe(icloud: scan, feed: feed, state: world.state, links: world.links, keepSeparate: world.state.keepSeparate)
        let plan = (planner ?? world.planner).plan(
            icloud: scan, google: feed, state: world.state, links: world.links, keepSeparate: world.state.keepSeparate, photos: observed, now: at
        )
        return Look(scan: scan, feed: feed, observed: observed, plan: plan)
    }

    /// A whole run as the engine makes it: the field plan, then the photo ops.
    @discardableResult
    func sync(_ trigger: SyncTrigger = .scheduled, fullListing: Bool = false) async throws -> (fields: SyncRunReport, photos: PhotoRunReport) {
        let plan = try await look(trigger, fullListing: fullListing).plan
        let fields = try await base.run(plan)
        return (fields, try await executor().execute(plan.photoOps))
    }
}

extension ManualSyncClock {
    /// `waitForSleepers`, but giving up after `timeout` seconds of real time so a test that would wait forever fails instead.
    func waitForSleepers(_ count: Int, timeout: TimeInterval) async -> Bool {
        final class Once: Sendable {
            let done = Mutex(false)
            func first() -> Bool {
                done.withLock { done in
                    defer { done = true }
                    return !done
                }
            }
        }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task {
                await self.waitForSleepers(count)
                if once.first() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if once.first() { continuation.resume(returning: false) }
            }
        }
    }
}
