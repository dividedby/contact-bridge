import Foundation

// User-facing text for Core errors, shown in the app's alerts: what happened, then what to do.

extension ContactStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Contact Bridge is not allowed to read your contacts. Open System Settings > Privacy & Security > Contacts and turn on Contact Bridge."
        case .noICloudContainer:
            "No iCloud contacts account was found. Turn on Contacts for iCloud in System Settings, then try again."
        case .containerChoiceRequired:
            "More than one contacts account could be iCloud. Choose the one to use under Setup."
        case .notFound(let ids):
            "\(ids.count) contact(s) no longer exist in Contacts, probably changed elsewhere. Reload and try again."
        case .outsideSelectedContainer(let ids):
            "\(ids.count) contact(s) are outside the selected contacts account and were left untouched."
        case .photosUnsupported:
            "Contact photos cannot be read or changed here."
        case .photoNotSaved:
            "macOS Contacts could not save this contact's photo, directly or through the Contacts app (Cocoa error 134092: its database seems to have lost the contact's old picture file). Setting the photo by hand in the Contacts app may still work."
        }
    }
}

extension BackupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .verificationFailed(let file):
            "The backup could not be verified (\(file)). Nothing was changed. Try backing up again."
        case .pagingDidNotTerminate(let source):
            "Google kept returning pages for \(source). Nothing was changed. Try backing up again later."
        case .noFreeFolderName:
            "A backup folder name could not be chosen. Nothing was changed. Try backing up again."
        }
    }
}

extension MergeExecutor.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleBackup: "The last backup is more than an hour old. Back up now, then merge."
        }
    }
}

extension ImportExecutor.Failure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleBackup: "The last backup is more than an hour old. Back up now, then import."
        }
    }
}

extension LinkStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "links.json was written by a newer version of Contact Bridge (format \(version)) and was left as it was. Update the app."
        case .unreadable(let reason):
            "links.json could not be read and was left as it was: \(reason)"
        }
    }
}

extension GoogleAPIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .syncTokenExpired: "Google's sync checkpoint expired. Run a full sync."
        case .etagMismatch: "The Google contact changed since it was loaded. Reload and try again."
        case .rateLimited: "Google is limiting requests. Please wait a minute and try again."
        case .notFound: "Google no longer has that contact."
        case .unauthorized: "Google rejected the request. Open Setup, sign in again, and retry."
        case .other(let status, let message):
            "Google answered with an error (\(status)): \(message)"
        }
    }
}

extension GoogleListingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .pagingDidNotTerminate(let source):
            "Google kept returning pages for \(source). Try again later."
        }
    }
}

extension PhotoEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .undecodable: "The photo could not be read as a picture, so it was left alone."
        case .tooLarge: "The photo is too large to send to Google even after shrinking it, so it was left alone."
        }
    }
}

extension ContactsAppUnavailable: LocalizedError {
    public var errorDescription: String? {
        "macOS Contacts refuses this photo directly (Cocoa error 134092) and the Contacts app could not be reached: \(reason)"
    }
}
