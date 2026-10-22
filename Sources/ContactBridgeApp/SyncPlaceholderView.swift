import SwiftUI

/// Placeholder for the Sync section until Phase 2.
struct SyncPlaceholderView: View {
    let app: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Sync is coming in Phase 2", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            switch app.signIn.status {
            case .signedIn(let email):
                Text(email.map { "Signed in to Google as \($0). Two-way sync will use this account." } ?? "Signed in to Google.")
            default:
                Text("Two-way sync needs a Google account. You can sign in now; nothing is synced yet.")
            }
        } actions: {
            switch app.signIn.status {
            case .signedIn:
                Button("Open Setup") { app.selection = .setup }
            default:
                Button("Sign in with Google") { app.signIn.signIn() }
                Button("Open Setup") { app.selection = .setup }
            }
        }
    }
}
