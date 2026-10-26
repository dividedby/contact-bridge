import Foundation

public enum PhotoSettingsError: Error, Sendable, Equatable {
    /// Profile photos are part of photo sync: they cannot be switched on while it is off.
    case photoSyncIsOff
}

extension PhotoSettingsError: LocalizedError {
    public var errorDescription: String? { "Turn on Sync photos first: profile photos are part of it." }
}

/// The two photo switches in Setup, kept in `SyncState`.
public struct PhotoSettings: Sendable, Hashable {
    /// The master switch. On for new and existing installs.
    public var syncPhotos: Bool
    /// Copy a Google contact's profile photo to iCloud when neither side has a photo, and keep it up to date. Off by default.
    public var useGoogleProfilePhotos: Bool

    public init(syncPhotos: Bool = true, useGoogleProfilePhotos: Bool = false) {
        self.syncPhotos = syncPhotos
        self.useGoogleProfilePhotos = useGoogleProfilePhotos
    }

    /// The profile switch only means something while photos sync.
    public var canChooseProfilePhotos: Bool { syncPhotos }

    public static func read(_ store: any SyncStateStoring) throws -> PhotoSettings {
        let state = try store.load()
        return PhotoSettings(syncPhotos: state.syncPhotos, useGoogleProfilePhotos: state.useGoogleProfilePhotos)
    }

    /// Switching photo sync off stops all photo reads, writes and questions (stored questions are kept, and shown again when it
    /// is switched back on). The profile switch keeps its value.
    public static func setSyncPhotos(_ on: Bool, in store: any SyncStateStoring) throws {
        try store.update { $0.syncPhotos = on }
    }

    /// Switching profile photos on forgets when Google was last listed in full, so the next run lists it in full and finds
    /// the profile photos (an incremental listing would not mention them).
    public static func setUseGoogleProfilePhotos(_ on: Bool, in store: any SyncStateStoring) throws {
        try store.update { state in
            if on {
                guard state.syncPhotos else { throw PhotoSettingsError.photoSyncIsOff }
                state.lastPhotoFullListingAt = nil
            }
            state.useGoogleProfilePhotos = on
        }
    }
}
