import Foundation

/// Moves the stored iCloud change token past this app's own iCloud write, so the next sync does not read it as an edit.
/// Shared by the review decisions and the photo executor.
enum ICloudTokenAdvance {
    /// Review kinds whose baseline keeps the pre-conflict iCloud values: while one is open every scan must read the whole book.
    static let conflictKinds: Set<ReviewKind> = [.googleEdited, .bothEdited]

    /// Only when nothing else moved the token since it was stored (`before` is the store's token read before the write, and
    /// equals the stored one if so) and no conflict is open; otherwise it stays, and the next scan reads everything.
    static func advance(
        store: any ContactStoring, state: any SyncStateStoring, reviews: any ReviewStoring, from before: Data?
    ) async throws {
        guard let before, try state.load().icloudChangeToken == before,
              try !reviews.load().contains(where: { conflictKinds.contains($0.kind) })
        else { return }
        let after = try await store.changeToken()
        try state.update { $0.icloudChangeToken = after }
    }
}
