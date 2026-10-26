import Foundation
import Testing
@testable import ContactBridgeCore

struct PhotoSettingsTests {
    @Test("Photo sync starts on and profile photos off; both are saved")
    func defaults() throws {
        let store = InMemorySyncStateStore()
        let settings = try PhotoSettings.read(store)
        #expect(settings.syncPhotos && !settings.useGoogleProfilePhotos)

        try PhotoSettings.setSyncPhotos(false, in: store)
        #expect(try store.load().syncPhotos == false)
        try PhotoSettings.setSyncPhotos(true, in: store)
        #expect(try store.load().syncPhotos)
    }

    @Test("Turning profile photos on forgets the last full listing, so the next run lists Google in full; turning them off keeps what was copied")
    func profileSwitch() throws {
        let store = InMemorySyncStateStore(SyncState(lastPhotoFullListingAt: SyncFixtures.t0))
        try PhotoSettings.setUseGoogleProfilePhotos(true, in: store)
        var state = try store.load()
        #expect(state.useGoogleProfilePhotos && state.lastPhotoFullListingAt == nil)

        state.lastPhotoFullListingAt = SyncFixtures.t0
        try store.save(state)
        try PhotoSettings.setUseGoogleProfilePhotos(false, in: store)
        let off = try store.load()
        #expect(!off.useGoogleProfilePhotos && off.lastPhotoFullListingAt == SyncFixtures.t0)
    }

    @Test("Profile photos need photo sync: with it off they cannot be switched on, and the settings say so")
    func profileNeedsPhotoSync() throws {
        let store = InMemorySyncStateStore(SyncState(syncPhotos: false))
        #expect(try PhotoSettings.read(store).canChooseProfilePhotos == false)
        #expect(throws: PhotoSettingsError.photoSyncIsOff) { try PhotoSettings.setUseGoogleProfilePhotos(true, in: store) }
        #expect(try store.load().useGoogleProfilePhotos == false)
        try PhotoSettings.setSyncPhotos(true, in: store)
        #expect(try PhotoSettings.read(store).canChooseProfilePhotos)
    }
}
