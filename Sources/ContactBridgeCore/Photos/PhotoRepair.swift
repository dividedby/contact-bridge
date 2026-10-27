import Foundation

/// One-time fixes to stored photo records, run before a sync run plans when `SyncState.photoRepairVersion` is behind. Each
/// version's step runs once, in order, from the version the state is at.
///
/// Version 1: once iCloud has synced a contact photo, macOS reports it only as a centre-square thumbnail
/// (`ICloudPhotoRead`). Records made before this was handled read such a photo as missing, which turned photos sync had just
/// copied into "removed in iCloud" questions, and fingerprinted pictures whole, so a cropped thumbnail of a wide photo
/// looked like another picture. Every pair whose iCloud contact has a photo (or thumbnail) is therefore looked at afresh,
/// as if for the first time, and its photo questions are dropped. A pair whose iCloud contact really has no photo keeps its
/// record and its questions: a removal the user made is still asked about.
///
/// Version 2: iCloud photos the Contacts framework refused with error 134092 were given up on until a photo changed. They
/// now go through the Contacts app instead (`ContactsAppPhotoWriter`), so those pairs are looked at afresh and tried again.
/// A pair is only read again when a side changed or its record is missing, so the record is dropped, not just the failure.
///
/// Version 3: the first build of version 2 cleared those failures but kept the records, which then held nothing at all and
/// left the pairs unread. Records that hold nothing are dropped, so those pairs are looked at afresh too. A pair with no photo
/// on either side holds an empty record as well; looked at again, it is recorded the same way.
public enum PhotoRepair {
    public static let currentVersion = 3

    /// Returns the iCloud ids looked at afresh by version 1.
    @discardableResult
    static func run(store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring) async throws -> [String] {
        let from = try state.load().photoRepairVersion
        var fresh: [String] = []
        if from < 1 { fresh = try await lookAfresh(store: store, state: state, reviews: reviews) }
        if from < 2 { try retryLostPictureFiles(state: state) }
        if from < 3 { try dropEmptyRecords(state: state) }
        try state.update { $0.photoRepairVersion = currentVersion }
        return fresh
    }

    private static func lookAfresh(store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring) async throws -> [String] {
        let recorded = try state.load().baselines.filter { $0.value.photo != nil }.map(\.key)
        let signatures = recorded.isEmpty ? [:] : try await store.photoSignatures(ids: recorded)
        let fresh = Set(recorded.filter { signatures[$0]?.hasPhoto == true })
        // Questions first: should the state update fail, the next run finds the same pairs and does this again.
        let questions = try reviews.load().filter { $0.kind == .photoConflict && $0.icloudID.map(fresh.contains) == true }
        if !questions.isEmpty { try reviews.remove(ids: questions.map(\.id)) }
        try state.update {
            for id in fresh { $0.baselines[id]?.photo = nil }
        }
        return fresh.sorted()
    }

    /// Drops the records of photos given up on for error 134092; returns their iCloud ids.
    @discardableResult
    static func retryLostPictureFiles(state: any SyncStateStoring) throws -> [String] {
        try dropRecords(state: state) { $0.failure?.message.contains("134092") == true }
    }

    /// Drops photo records that hold no picture, key, waiting removal or failure; returns their iCloud ids.
    @discardableResult
    static func dropEmptyRecords(state: any SyncStateStoring) throws -> [String] {
        try dropRecords(state: state) { photo in
            photo.icloud == nil && photo.google == nil && photo.googleProfile == nil && photo.icloudHint == nil
                && photo.googleURLKey == nil && photo.googleProfileKey == nil && photo.pendingRemoval == nil && photo.failure == nil
        }
    }

    private static func dropRecords(state: any SyncStateStoring, where matches: (PhotoBaseline) -> Bool) throws -> [String] {
        var dropped: [String] = []
        try state.update {
            for (id, baseline) in $0.baselines {
                guard let photo = baseline.photo, matches(photo) else { continue }
                $0.baselines[id]?.photo = nil
                dropped.append(id)
            }
        }
        return dropped.sorted()
    }
}
