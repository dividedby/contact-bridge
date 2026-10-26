import Foundation

/// What was found out about one linked pair's photos this run, ready for `PhotoDecision`.
public struct PhotoObservation: Sendable, Hashable {
    public var icloudID: String
    public var resourceName: String
    public var seen: PhotoSnapshot
    /// Profile photos are on and this contact is not opted out.
    public var profileEnabled: Bool
    /// When the Google contact (not its photo) was last updated, for the review screen. Nil when the person was not read.
    public var contactUpdatedAt: Date?
}

/// Everything `PhotoReconciler.observe` found, by iCloud id.
public struct PhotoObservations: Sendable, Hashable {
    public var pairs: [String: PhotoObservation] = [:]
    /// Pairs that needed a look and did not get one (a failed read or download, or the download limit). Nothing is decided
    /// for them, and the run must not move its tokens past them.
    public var unevaluated: [String] = []
    /// Whether photo sync looked at all. False for `.none`: the switch is off, or the caller has no photo support.
    public var wasObserved = false
    /// Photos downloaded from Google.
    public var downloads = 0
    /// Pairs with a photo that cannot be read at all (it is refused, or not a picture), new this run, by iCloud id. They are
    /// not unevaluated: the planner records the failure, and the photo is left alone until it changes.
    public var failures: [String: PhotoReadFailure] = [:]
    /// Pairs not judged this run although they are linked: one with a photo that has failed to read the same way before, or one
    /// the user keeps apart. A stored question about such a pair is not settled by its absence from the plan.
    public var skipped: [String] = []

    public static let none = PhotoObservations()
}

/// Reads what a run needs to know about linked pairs' photos, and nothing else: it never writes. The reads are kept to the
/// minimum.
///
/// - iCloud is only asked when the scan found something changed, or for a pair whose photos were never looked at or that has
///   a removal waiting to be confirmed (unless the user is already being asked about it). Then one cheap signature (is there a photo, a hash of its thumbnail) is read per
///   pair, and the full picture only when that hash differs from the baseline's. A hash that differs but whose picture is
///   similar (a baseline moved by Dedupe carries the old contact's hash) is not a change: the fingerprints decide.
/// - Google is only asked about a person the feed listed (or, for a pair that needs a look, fetched), and a photo is only
///   downloaded (at 128 px, for its fingerprint) when its URL key differs from the baseline's.
/// - At most `maxDownloads` photos are downloaded per run, four at a time; pairs beyond that are left for the next run.
public struct PhotoReconciler: Sendable {
    public static let maxDownloads = 300
    public static let parallelDownloads = 4
    /// With Google profile photos on, Google is listed in full at least this often: a changed profile picture does not
    /// show in an incremental listing.
    public static let fullListingInterval: TimeInterval = 24 * 60 * 60
    /// Unlisted pairs that need a look are fetched one by one; the rest wait.
    public static let maxLookups = 100

    private let store: any ContactStoring
    private let google: any GoogleContactsClient
    private let fetcher: any GooglePhotoFetching
    private let fingerprinter: any PhotoFingerprinting
    private let maxDownloads: Int

    public init(
        store: any ContactStoring, google: any GoogleContactsClient, fetcher: any GooglePhotoFetching,
        fingerprinter: any PhotoFingerprinting = ImageIOPhotoFingerprinter(), maxDownloads: Int = PhotoReconciler.maxDownloads
    ) {
        self.store = store
        self.google = google
        self.fetcher = fetcher
        self.fingerprinter = fingerprinter
        self.maxDownloads = maxDownloads
    }

    /// Whether Google should be listed in full for photos' sake: profile photos are on and the last full listing is over a day
    /// old (or there never was one).
    public static func fullListingDue(state: SyncState, now: Date) -> Bool {
        guard state.syncPhotos, state.useGoogleProfilePhotos else { return false }
        guard let last = state.lastPhotoFullListingAt else { return true }
        return now.timeIntervalSince(last) >= fullListingInterval
    }

    private struct Pair {
        var id: String
        var name: String
        var baseline: PhotoBaseline?
        var icloud: PhotoSeen?
        var person: GooglePerson?
        var google: PhotoSeen?
        var profile: PhotoSeen?
        var profileEnabled: Bool
        /// A transient problem: look again next run.
        var failed = false
        /// A photo that has failed the same way before: nothing is decided and nothing is stored.
        var skipped = false
        var unreadable: PhotoReadFailure?
        /// Only the profile photo could not be read: the pair is judged without it.
        var profileFailure: PhotoReadFailure?
    }

    private struct Download {
        enum Kind { case contact, profile }
        var pair: Int
        var kind: Kind
        var ref: GooglePhotoRef
    }

    /// - Parameters:
    ///   - keepSeparate: `"<iCloud id>|<resource name>"` pairs the user keeps apart; they are skipped.
    ///   - questioned: iCloud ids that already have a photo question waiting. Such a pair is not read again just because its
    ///     baseline is missing or has a removal waiting; it is looked at when something about it changes.
    public func observe(
        icloud scan: ICloudScan, feed: GoogleFeed, state: SyncState, links: LinkTable, keepSeparate: Set<String> = [],
        questioned: Set<String> = []
    ) async throws -> PhotoObservations {
        // A scan or a feed that paused the run is not to be derived anything from, and the plan will not use photos anyway.
        guard state.syncPhotos, scan.pause == nil, feed.status == .ok else { return .none }
        var result = PhotoObservations()
        result.wasObserved = true
        let scanned = scan.status == .changed
        let present = scanned ? Set(scan.records.map(\.sourceIdentifier)) : []

        var pairs: [Pair] = []
        for id in links.links.keys.sorted() {
            guard let entry = links.links[id], let baseline = state.baselines[id] else { continue }
            let name = entry.googleResourceName
            if state.ignoredGoogle.contains(name) || keepSeparate.contains("\(id)|\(name)") {
                result.skipped.append(id)
                continue
            }
            if scanned && !present.contains(id) { continue }
            if feed.deleted.contains(name) || (feed.isFullListing && feed.people[name] == nil) { continue }
            if questioned.contains(id), !scanned, feed.people[name] == nil { continue }
            pairs.append(Pair(
                id: id, name: name, baseline: baseline.photo, profileEnabled: state.useGoogleProfilePhotos && !state.profilePhotoOptOut.contains(id)
            ))
        }

        func needsLook(_ pair: Pair) -> Bool { pair.baseline == nil || pair.baseline?.pendingRemoval != nil }

        // iCloud
        let toRead = pairs.filter { scanned || needsLook($0) }.map(\.id)
        let signatures = toRead.isEmpty ? [:] : try await store.photoSignatures(ids: toRead)
        let reading = Set(toRead)
        var dropped = Set<Int>()
        for index in pairs.indices {
            let id = pairs[index].id
            let known = pairs[index].baseline
            guard reading.contains(id) else {
                pairs[index].icloud = known?.icloud.map { PhotoSeen(fingerprint: $0, token: known?.icloudHint) }
                continue
            }
            guard let signature = signatures[id] else {
                dropped.insert(index)
                continue
            }
            guard signature.hasPhoto else { continue }
            if let fingerprint = known?.icloud, let hash = signature.thumbnailHash, hash == known?.icloudHint {
                pairs[index].icloud = PhotoSeen(fingerprint: fingerprint, token: hash)
                continue
            }
            let stamp = "icloud:\(signature.thumbnailHash ?? "")"
            if known?.failure?.stamp == stamp {
                pairs[index].skipped = true
                continue
            }
            do {
                guard let data = try await store.photoData(id: id) else {
                    pairs[index].failed = true
                    continue
                }
                guard let fingerprint = fingerprinter.fingerprint(of: data) else {
                    pairs[index].unreadable = PhotoReadFailure(
                        resourceName: pairs[index].name, stamp: stamp, message: "the iCloud photo is not a picture this Mac can read"
                    )
                    continue
                }
                pairs[index].icloud = PhotoSeen(fingerprint: fingerprint, token: signature.thumbnailHash)
            } catch is CancellationError {
                throw CancellationError()
            } catch ContactStoreError.notFound {
                dropped.insert(index)
            } catch {
                pairs[index].failed = true
            }
        }

        // Google: the people this run knows, and those a pair that needs a look has to fetch.
        var lookups = 0
        for index in pairs.indices where !dropped.contains(index) && !pairs[index].failed && !pairs[index].skipped && pairs[index].unreadable == nil {
            let name = pairs[index].name
            if let listed = feed.people[name] {
                pairs[index].person = listed
            } else if needsLook(pairs[index]) {
                guard lookups < Self.maxLookups else {
                    pairs[index].failed = true
                    continue
                }
                lookups += 1
                do {
                    pairs[index].person = try await google.getPerson(resourceName: name)
                } catch GoogleAPIError.notFound {
                    dropped.insert(index)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    pairs[index].failed = true
                }
            }
        }

        var downloads: [Download] = []
        var updatedAt: [Int: Date] = [:]
        for index in pairs.indices where !dropped.contains(index) && !pairs[index].failed && !pairs[index].skipped && pairs[index].unreadable == nil {
            let known = pairs[index].baseline
            guard let person = pairs[index].person else {
                // Not listed: as far as anyone knows, as the baseline left it.
                pairs[index].google = known?.google.map { PhotoSeen(fingerprint: $0, token: known?.googleURLKey) }
                if pairs[index].profileEnabled {
                    pairs[index].profile = known?.googleProfile.map { PhotoSeen(fingerprint: $0, token: known?.googleProfileKey) }
                }
                continue
            }
            let photos = GooglePersonMapper.photos(of: person)
            updatedAt[index] = photos.contactUpdatedAt
            if let ref = photos.contact {
                if let fingerprint = known?.google, known?.googleURLKey == ref.key {
                    pairs[index].google = PhotoSeen(fingerprint: fingerprint, token: ref.key)
                } else if known?.failure?.stamp == "google:\(ref.key)" {
                    pairs[index].skipped = true
                    continue
                } else {
                    downloads.append(Download(pair: index, kind: .contact, ref: ref))
                }
            }
            // The profile photo only matters to a contact that has no photo of its own, or whose iCloud photo is a copy of it.
            let canUseProfile = known?.icloudOrigin == .googleProfile || (pairs[index].icloud == nil && photos.contact == nil)
            if pairs[index].profileEnabled, canUseProfile, let ref = photos.profile {
                if let fingerprint = known?.googleProfile, known?.googleProfileKey == ref.key {
                    pairs[index].profile = PhotoSeen(fingerprint: fingerprint, token: ref.key)
                } else if known?.failure?.stamp == "profile:\(ref.key)" {
                    // Unreadable before: this pair goes on without a profile photo.
                } else {
                    downloads.append(Download(pair: index, kind: .profile, ref: ref))
                }
            }
        }

        let kept = Array(downloads.prefix(maxDownloads))
        for left in downloads.dropFirst(maxDownloads) { pairs[left.pair].failed = true }
        let fingerprints = try await download(kept)
        result.downloads = kept.count
        for (position, job) in kept.enumerated() {
            switch fingerprints[position] ?? .transient {
            case .transient:
                pairs[job.pair].failed = true
            case .permanent(let message):
                let stamp = "\(job.kind == .contact ? "google" : "profile"):\(job.ref.key)"
                let failure = PhotoReadFailure(resourceName: pairs[job.pair].name, stamp: stamp, message: message)
                if job.kind == .contact { pairs[job.pair].unreadable = failure } else { pairs[job.pair].profileFailure = failure }
            case .fingerprint(let fingerprint):
                let seen = PhotoSeen(fingerprint: fingerprint, token: job.ref.key)
                if job.kind == .contact { pairs[job.pair].google = seen } else { pairs[job.pair].profile = seen }
            }
        }

        for (index, pair) in pairs.enumerated() where !dropped.contains(index) {
            if pair.skipped {
                result.skipped.append(pair.id)
                continue
            }
            if let unreadable = pair.unreadable {
                result.failures[pair.id] = unreadable
                continue
            }
            if pair.failed {
                result.unevaluated.append(pair.id)
                continue
            }
            if let profileFailure = pair.profileFailure { result.failures[pair.id] = profileFailure }
            result.pairs[pair.id] = PhotoObservation(
                icloudID: pair.id, resourceName: pair.name, seen: PhotoSnapshot(icloud: pair.icloud, google: pair.google, profile: pair.profile),
                profileEnabled: pair.profileEnabled, contactUpdatedAt: updatedAt[index]
            )
        }
        return result
    }

    private enum Fetched: Sendable {
        case fingerprint(PhotoFingerprint)
        /// Fails the same way every time (a refused address, a missing photo, bytes that are not a picture).
        case permanent(String)
        case transient
    }

    /// Fingerprints of the photos at 128 px, by position in `jobs`.
    private func download(_ jobs: [Download]) async throws -> [Int: Fetched] {
        var fingerprints: [Int: Fetched] = [:]
        let fetcher = fetcher
        let fingerprinter = fingerprinter
        try await withThrowingTaskGroup(of: (Int, Fetched).self) { group in
            var running = 0
            for (position, job) in jobs.enumerated() {
                if running >= Self.parallelDownloads, let finished = try await group.next() {
                    running -= 1
                    fingerprints[finished.0] = finished.1
                }
                group.addTask {
                    guard let url = job.ref.sizedURL(128) else { return (position, .permanent("the photo has no usable address")) }
                    do {
                        guard let fingerprint = fingerprinter.fingerprint(of: try await fetcher.fetch(url)) else {
                            return (position, .permanent("the Google photo is not a picture this Mac can read"))
                        }
                        return (position, .fingerprint(fingerprint))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (position, PhotoErrors.isPermanent(error) ? .permanent(error.localizedDescription) : .transient)
                    }
                }
                running += 1
            }
            while let finished = try await group.next() { fingerprints[finished.0] = finished.1 }
        }
        return fingerprints
    }
}
