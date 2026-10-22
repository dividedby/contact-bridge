import Foundation
import Testing
@testable import ContactBridgeCore

/// Alerts show `localizedDescription`, so every Core error that can reach the UI must say what happened and what to do.
struct ErrorDescriptionTests {
    private func text(_ error: some Error) -> String { error.localizedDescription }

    @Test("Contact store errors point at the setting or step that fixes them")
    func contactStoreErrors() {
        #expect(text(ContactStoreError.accessDenied).contains("Privacy & Security > Contacts"))
        #expect(text(ContactStoreError.noICloudContainer).contains("iCloud"))
        #expect(text(ContactStoreError.containerChoiceRequired([])).contains("Setup"))
        #expect(text(ContactStoreError.notFound(["a", "b"])).contains("2"))
        #expect(text(ContactStoreError.outsideSelectedContainer(["a"])).contains("left untouched"))
    }

    @Test("Backup errors say nothing was changed")
    func backupErrors() {
        #expect(text(BackupError.verificationFailed("icloud.vcf")).contains("icloud.vcf"))
        #expect(text(BackupError.verificationFailed("icloud.vcf")).contains("Nothing was changed"))
        #expect(text(BackupError.pagingDidNotTerminate("google-connections")).contains("google-connections"))
        #expect(!text(BackupError.noFreeFolderName).isEmpty)
    }

    @Test("A stale backup asks for a new one")
    func staleBackup() {
        #expect(text(MergeExecutor.Failure.staleBackup).contains("Back up"))
        #expect(text(ImportExecutor.Failure.staleBackup).contains("Back up"))
    }

    @Test("Workflow and backup-coordinator errors tell the user what to do")
    func workflowErrors() {
        #expect(text(WorkflowError.notesUnavailable).contains("notes access"))
        #expect(text(BackupCoordinatorError.requirementNotMet("notes")).contains("notes"))
    }

    @Test("Link file errors name the file and say it was left alone")
    func linkStoreErrors() {
        #expect(text(LinkStoreError.unsupportedVersion(7)).contains("links.json"))
        #expect(text(LinkStoreError.unsupportedVersion(7)).contains("7"))
        #expect(text(LinkStoreError.unreadable("boom")).contains("left as it was"))
    }

    @Test("Google API errors are readable")
    func googleAPIErrors() {
        #expect(text(GoogleAPIError.unauthorized).contains("sign in"))
        #expect(text(GoogleAPIError.rateLimited(retryAfter: nil)).contains("wait"))
        #expect(text(GoogleAPIError.other(status: 503, message: "try later")).contains("503"))
        #expect(text(GoogleListingError.pagingDidNotTerminate("connections")).contains("connections"))
    }

    @Test("No message falls back to Swift's generic wording")
    func nothingGeneric() {
        let errors: [any Error] = [
            ContactStoreError.accessDenied, BackupError.noFreeFolderName, MergeExecutor.Failure.staleBackup,
            LinkStoreError.unreadable("x"), GoogleAPIError.notFound, GoogleAPIError.syncTokenExpired, GoogleAPIError.etagMismatch,
            GoogleListingError.pagingDidNotTerminate("x"),
        ]
        for error in errors { #expect(!text(error).contains("couldn’t be completed"), "\(error)") }
    }
}
