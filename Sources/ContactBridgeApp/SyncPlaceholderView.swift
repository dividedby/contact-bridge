import SwiftUI

/// Placeholder for the Sync section: just the Google sign-in hook until the sync screens exist.
struct SyncPlaceholderView: View {
    let signIn: SignInController

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.largeTitle).foregroundStyle(.secondary)
            Text("Sync").font(.title2)
            statusText
            if let notice = signIn.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            actions
        }
        .padding()
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await signIn.restore() }
    }

    @ViewBuilder private var statusText: some View {
        switch signIn.status {
        case .signedOut:
            Text("Not signed in to Google.").foregroundStyle(.secondary)
        case .signingIn:
            HStack { ProgressView().controlSize(.small); Text("Waiting for you to finish signing in in the browser...") }
                .foregroundStyle(.secondary)
        case .signedIn(let email):
            Text(email.map { "Signed in as \($0)" } ?? "Signed in to Google").foregroundStyle(.secondary)
        case .needsReauthorization:
            Text("Google access expired or was revoked. Sign in again.").foregroundStyle(.orange)
        case .failed(let message):
            Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var actions: some View {
        switch signIn.status {
        case .signingIn:
            Button("Cancel") { signIn.cancelSignIn() }
        case .signedIn:
            Button("Sign out") { signIn.signOut() }
        case .signedOut, .needsReauthorization, .failed:
            Button("Sign in with Google") { signIn.signIn() }.buttonStyle(.borderedProminent)
        }
    }
}
