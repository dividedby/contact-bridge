import AppKit
import ContactBridgeCore
import Observation

/// Google sign-in state for the UI. Later screens read `status` and use `session` to build the People API client.
@MainActor
@Observable
final class SignInController {
    enum Status: Equatable {
        case signedOut
        case signingIn
        case signedIn(email: String?)
        /// The stored refresh token was revoked or expired (Testing-mode tokens last 7 days).
        case needsReauthorization
        case failed(String)
    }

    private(set) var status: Status = .signedOut
    /// Set after a sign-out that could not confirm revocation with Google.
    private(set) var notice: String?
    /// Nil until the OAuth config has been read from the bundle.
    private(set) var session: GoogleAuthSession?

    @ObservationIgnored private let store: any TokenStore
    @ObservationIgnored private let loadConfig: @MainActor () throws -> OAuthConfig
    @ObservationIgnored private let openURL: @Sendable (URL) async -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Demo mode: sign-in is simulated for this account and nothing touches the Keychain, the network or the browser.
    @ObservationIgnored private let demoEmail: String?

    init(
        demoEmail: String?
    ) {
        self.demoEmail = demoEmail
        self.store = InMemoryTokenStore()
        self.loadConfig = { throw GoogleAuthError.notSignedIn }
        self.openURL = { _ in false }
        if demoEmail != nil { status = .signedIn(email: demoEmail) }
    }

    init(
        store: any TokenStore = KeychainTokenStore(),
        loadConfig: @escaping @MainActor () throws -> OAuthConfig = { try OAuthConfig.load() },
        openURL: @escaping @Sendable (URL) async -> Bool = { url in await MainActor.run { NSWorkspace.shared.open(url) } }
    ) {
        self.store = store
        self.loadConfig = loadConfig
        self.openURL = openURL
        self.demoEmail = nil
    }

    var isBusy: Bool { status == .signingIn }

    /// Reads stored credentials (no network) so the UI shows who is signed in.
    func restore() async {
        guard demoEmail == nil else { return }
        guard task == nil, status == .signedOut else { return }
        do {
            if let account = try await makeSession().currentAccount() { status = .signedIn(email: account.email) }
        } catch {
            status = .failed(Self.message(for: error))
        }
    }

    func signIn() {
        guard task == nil else { return }
        if let demoEmail {
            status = .signedIn(email: demoEmail)
            return
        }
        status = .signingIn
        notice = nil
        task = Task {
            defer { task = nil }
            do {
                let account = try await makeSession().signIn()
                status = .signedIn(email: account.email)
            } catch GoogleAuthError.cancelled {
                status = .signedOut
            } catch GoogleAuthError.needsReauthorization {
                status = .needsReauthorization
            } catch {
                status = .failed(Self.message(for: error))
            }
        }
    }

    func cancelSignIn() {
        guard status == .signingIn else { return }
        task?.cancel()
    }

    func signOut() {
        guard task == nil else { return }
        if demoEmail != nil {
            status = .signedOut
            return
        }
        task = Task {
            defer { task = nil }
            do {
                if let session = try? makeSession() {
                    if try await session.signOut() == false {
                        notice = "Signed out here, but Google could not be reached to revoke access. You can remove it at myaccount.google.com/permissions."
                    }
                } else {
                    try store.delete()
                }
                status = .signedOut
            } catch {
                status = .failed(Self.message(for: error))
            }
        }
    }

    private func makeSession() throws -> GoogleAuthSession {
        if let session { return session }
        let session = GoogleAuthSession(oauth: GoogleOAuthClient(config: try loadConfig()), store: store, openURL: openURL)
        self.session = session
        return session
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
