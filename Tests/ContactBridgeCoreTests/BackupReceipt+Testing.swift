import Foundation
@testable import ContactBridgeCore

extension BackupReceipt {
    /// The only way tests (or previews via @testable) obtain a receipt without running the backup writer.
    static func forTesting(
        id: UUID = UUID(),
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        folderURL: URL = URL(fileURLWithPath: "/tmp/contact-bridge-test-backup")
    ) -> BackupReceipt {
        let manifest = BackupManifest(
            appVersion: "test", createdAt: createdAt, sources: [],
            counts: BackupManifest.Counts(), files: [], notesIncluded: false
        )
        return BackupReceipt(id: id, createdAt: createdAt, folderURL: folderURL, manifest: manifest)
    }
}
