import Foundation

/// What the user decides about a photo question. "Keep" names the side whose state wins, and "no photo" is a state: keeping a
/// side with no photo removes the other side's. Which sentence goes with each choice depends on the question
/// (`PhotoReviewDraft`).
public enum PhotoChoice: Sendable, Hashable {
    case keepICloud
    case keepGoogle
    /// Record how things are now as agreed, so the question is not asked again until either side changes. For a removed
    /// profile photo it also stops using their profile photo for this contact.
    case doNothing
}

/// The buttons and words for one photo question. Pure.
public struct PhotoReviewDraft: Sendable, Hashable {
    public struct Option: Sendable, Hashable, Identifiable {
        public var choice: PhotoChoice
        public var title: String
        /// What the choice does, in a sentence.
        public var detail: String
        /// Removes a photo somewhere.
        public var isDestructive: Bool

        public var id: PhotoChoice { choice }
    }

    public var reason: PhotoConflictReason
    public var title: String
    public var explanation: String
    public var options: [Option]

    /// A question about their Google profile photo: the "don't use it" action belongs with it.
    public var isAboutProfilePhoto: Bool { reason == .profileRemovedInICloud }

    public init(reason: PhotoConflictReason) {
        self.reason = reason
        switch reason {
        case .bothChanged:
            title = "Photo changed in both places"
            explanation = "The photo was changed in iCloud and in Google to different pictures. Pick the one to keep; the other side gets it."
            options = [
                Option(choice: .keepICloud, title: "Keep iCloud's photo", detail: "Google gets iCloud's photo.", isDestructive: false),
                Option(choice: .keepGoogle, title: "Keep Google's photo", detail: "iCloud gets Google's photo.", isDestructive: false),
            ]
        case .firstSightDiffers:
            title = "Photo differs"
            explanation = "These two contacts have different photos, and this is the first time they are compared. Pick the one to keep; the other side gets it."
            options = [
                Option(choice: .keepICloud, title: "Keep iCloud's photo", detail: "Google gets iCloud's photo.", isDestructive: false),
                Option(choice: .keepGoogle, title: "Keep Google's photo", detail: "iCloud gets Google's photo.", isDestructive: false),
            ]
        case .removedOneChangedOther:
            title = "Photo removed on one side, changed on the other"
            explanation = "One side removed its photo while the other changed it. Keeping a side with no photo removes the other side's photo too."
            options = [
                Option(choice: .keepICloud, title: "Keep iCloud's version", detail: "Google gets iCloud's photo, or loses its own if iCloud has none.", isDestructive: true),
                Option(choice: .keepGoogle, title: "Keep Google's version", detail: "iCloud gets Google's photo, or loses its own if Google has none.", isDestructive: true),
            ]
        case .removedInICloud:
            title = "Photo removed in iCloud"
            explanation = "The photo was removed from the iCloud contact; the Google contact still has its own. Nothing is removed without asking."
            options = [
                Option(choice: .keepGoogle, title: "Add Google's photo back to iCloud", detail: "iCloud gets Google's photo again.", isDestructive: false),
                Option(choice: .keepICloud, title: "Delete it from Google too", detail: "Google's photo is removed. It is saved to the photo history first.", isDestructive: true),
                Option(choice: .doNothing, title: "Do nothing", detail: "Leave both as they are. You are asked again only if either photo changes.", isDestructive: false),
            ]
        case .removedInGoogle:
            title = "Photo removed in Google"
            explanation = "The photo was removed from the Google contact; the iCloud contact still has one. Nothing is removed without asking."
            options = [
                Option(choice: .keepICloud, title: "Add iCloud's photo back to Google", detail: "Google gets iCloud's photo again.", isDestructive: false),
                Option(choice: .keepGoogle, title: "Delete it from iCloud too", detail: "iCloud's photo is removed, after a backup is taken.", isDestructive: true),
                Option(choice: .doNothing, title: "Do nothing", detail: "Leave both as they are. You are asked again only if either photo changes.", isDestructive: false),
            ]
        case .profileRemovedInICloud:
            title = "Google profile photo removed in iCloud"
            explanation = "The photo on this iCloud contact was a copy of their Google profile picture, and you removed it. It is their own Google picture, so it can't be removed from Google."
            options = [
                Option(choice: .keepGoogle, title: "Add their Google profile photo back", detail: "iCloud gets their profile picture again, and keeps it up to date.", isDestructive: false),
                Option(choice: .doNothing, title: "Do nothing (stop using their profile photo for this contact)", detail: "No profile photo is copied to this contact any more.", isDestructive: false),
            ]
        }
    }
}

/// The pictures of a photo question, as they are now.
public struct PhotoReviewDetail: Sendable, Hashable {
    public var draft: PhotoReviewDraft
    /// The iCloud photo; nil when the contact has none.
    public var icloud: Data?
    /// The Google contact's own photo; nil when it has none (or it could not be downloaded).
    public var google: Data?
    /// Their Google profile photo, for a question about it.
    public var profile: Data?
    /// When the Google contact was last edited. Google does not date photos, so this is a hint at most, and any edit to the
    /// contact moves it; it is not when the photo changed. iCloud has no dates at all.
    public var googleContactUpdatedAt: Date?
}

/// What "Keep iCloud photos for all" and "Keep Google photos for all" did, by review item id.
public struct BulkPhotoReport: Sendable, Hashable {
    public var applied: [String] = []
    public var failed: [BulkKeepReport.Failure] = []
    /// Left in the list: a photo moved on, or a contact is gone, since the list was made.
    public var changedSinceShown: [String] = []
    /// Left in the list: not a photo question.
    public var skipped: [String] = []
    /// Left in the list for another go: Google takes at most 60 photo writes per run.
    public var carried: [String] = []
    /// When set, nothing was done: the changes are more than the photo limits allow without asking. The text says what would
    /// happen; call again with `confirmed: true` to go ahead.
    public var needsConfirmation: String?
    public var warnings: [String] = []
}
