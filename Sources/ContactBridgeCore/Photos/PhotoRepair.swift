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
/// now go through the Contacts app instead (`ContactsAppPhotoWriter`), so those failure markers are cleared and the photos
/// are tried again.
public enum PhotoRepair {
    public static let currentVersion = 2

    /// Returns the iCloud ids looked at afresh by version 1.
    @discardableResult
    static func run(store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring) async throws -> [String] {
        let from = try state.load().photoRepairVersion
        var fresh: [String] = []
        if from < 1 { fresh = try await lookAfresh(store: store, state: state, reviews: reviews) }
        if from < 2 { try retryLostPictureFiles(state: state) }
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

    /// Clears the failure markers of photos given up on for error 134092; returns their iCloud ids.
    @discardableResult
    static func retryLostPictureFiles(state: any SyncStateStoring) throws -> [String] {
        var cleared: [String] = []
        try state.update {
            for (id, baseline) in $0.baselines where baseline.photo?.failure?.message.contains("134092") == true {
                $0.baselines[id]?.photo?.failure = nil
                cleared.append(id)
            }
        }
        return cleared.sorted()
    }
}
