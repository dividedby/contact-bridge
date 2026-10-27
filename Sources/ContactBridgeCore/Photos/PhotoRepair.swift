import Foundation

/// Fixes to stored photo records, run before a sync run plans when `SyncState.photoRepairVersion` is behind.
///
/// Version 1, once: once iCloud has synced a contact photo, macOS reports it only as a centre-square thumbnail
/// (`ICloudPhotoRead`). Records made before this was handled read such a photo as missing, which turned photos sync had just
/// copied into "removed in iCloud" questions, and fingerprinted pictures whole, so a cropped thumbnail of a wide photo
/// looked like another picture. Every pair whose iCloud contact has a photo (or thumbnail) is therefore looked at afresh,
/// as if for the first time, and its photo questions are dropped. A pair whose iCloud contact really has no photo keeps its
/// record and its questions: a removal the user made is still asked about.
///
/// Versions 2 to 5, each time the version moves: iCloud photos the Contacts framework refused with error 134092 were given
/// up on until a photo changed. They now go through the Contacts app (`ContactsAppPhotoWriter`), and each version fixed a
/// way that fallback still gave up, so the photos given up on for 134092 are tried again. A later fix to the fallback bumps
/// the version for the same reason.
public enum PhotoRepair {
    public static let currentVersion = 5

    /// Returns the iCloud ids looked at afresh by version 1.
    @discardableResult
    static func run(store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring) async throws -> [String] {
        let from = try state.load().photoRepairVersion
        var fresh: [String] = []
        if from < 1 { fresh = try await lookAfresh(store: store, state: state, reviews: reviews) }
        try retryLostPictureFiles(state: state)
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

    /// Clears the 134092 failure markers; returns the iCloud ids. A record left holding nothing is dropped: it was a pair's
    /// first look (a copy that never happened), and an unchanged pair is only read again when its record is missing. A
    /// record that holds more stays, so what it says (a removal the user asked for, say) is planned again, not undone.
    @discardableResult
    static func retryLostPictureFiles(state: any SyncStateStoring) throws -> [String] {
        var retried: [String] = []
        try state.update {
            for (id, baseline) in $0.baselines {
                guard var photo = baseline.photo, photo.failure?.message.contains("134092") == true else { continue }
                photo.failure = nil
                $0.baselines[id]?.photo = holdsNothing(photo) ? nil : photo
                retried.append(id)
            }
        }
        return retried.sorted()
    }

    private static func holdsNothing(_ photo: PhotoBaseline) -> Bool {
        photo.icloud == nil && photo.google == nil && photo.googleProfile == nil && photo.icloudHint == nil
            && photo.googleURLKey == nil && photo.googleProfileKey == nil && photo.pendingRemoval == nil && photo.failure == nil
    }
}
