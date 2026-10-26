import Foundation

/// One-time fixes to stored photo records, run before a sync run plans when `SyncState.photoRepairVersion` is behind.
///
/// Version 1: once iCloud has synced a contact photo, macOS reports it only as a centre-square thumbnail
/// (`ICloudPhotoRead`). Records made before this was handled read such a photo as missing, which turned photos sync had just
/// copied into "removed in iCloud" questions, and fingerprinted pictures whole, so a cropped thumbnail of a wide photo
/// looked like another picture. Every pair whose iCloud contact has a photo (or thumbnail) is therefore looked at afresh,
/// as if for the first time, and its photo questions are dropped. A pair whose iCloud contact really has no photo keeps its
/// record and its questions: a removal the user made is still asked about.
public enum PhotoRepair {
    public static let currentVersion = 1

    /// Returns the iCloud ids looked at afresh.
    @discardableResult
    static func run(store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring) async throws -> [String] {
        let recorded = try state.load().baselines.filter { $0.value.photo != nil }.map(\.key)
        let signatures = recorded.isEmpty ? [:] : try await store.photoSignatures(ids: recorded)
        let fresh = Set(recorded.filter { signatures[$0]?.hasPhoto == true })
        // Questions first: should the state update fail, the next run finds the same pairs and does this again.
        let questions = try reviews.load().filter { $0.kind == .photoConflict && $0.icloudID.map(fresh.contains) == true }
        if !questions.isEmpty { try reviews.remove(ids: questions.map(\.id)) }
        try state.update {
            for id in fresh { $0.baselines[id]?.photo = nil }
            $0.photoRepairVersion = currentVersion
        }
        return fresh.sorted()
    }
}
