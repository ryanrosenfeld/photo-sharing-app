import Foundation
import GoogleSignIn
import Supabase

@MainActor
final class AuthManager: ObservableObject {
    @Published var session: Session?
    @Published var currentProfile: UserProfile?
    @Published var isLoading = true
    @Published var error: AuthError?
    @Published var profileLoadFailed = false
    /// Set when sign-up succeeded but the project requires email confirmation before a session exists.
    @Published var awaitingEmailConfirmation: String?

    init() {
        Task {
            await loadSession()
            await listenForAuthChanges()
        }
    }

    // MARK: - Session

    private func loadSession() async {
        session = try? await supabase.auth.session
        if let session {
            await fetchProfile(userId: session.user.id)
        }
        isLoading = false
    }

    private func listenForAuthChanges() async {
        for await (_, newSession) in supabase.auth.authStateChanges {
            session = newSession
            if let newSession {
                if currentProfile?.id != newSession.user.id { await fetchProfile(userId: newSession.user.id) }
            } else {
                currentProfile = nil
                profileLoadFailed = false
            }
        }
    }

    // MARK: - Profile

    func reloadProfile() async {
        guard let userId = session?.user.id else { return }
        profileLoadFailed = false
        await fetchProfile(userId: userId)
    }

    func fetchProfile(userId: UUID) async {
        do {
            currentProfile = try await supabase
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            profileLoadFailed = false
        } catch {
            // First load failing leaves the app without a profile: surface a retry screen, not an alert.
            if currentProfile == nil { profileLoadFailed = true }
            else { self.error = .message("Could not load profile: \(error.localizedDescription)") }
        }
    }

    func updateDisplayName(_ name: String) async {
        guard let userId = session?.user.id else { return }
        do {
            let updated: UserProfile = try await supabase
                .from("profiles")
                .update(["display_name": name])
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            currentProfile = updated
        } catch {
            self.error = .message("Could not update name: \(error.localizedDescription)")
        }
    }

    // MARK: - Sign In with Google

    func signInWithGoogle() async {
        guard
            let windowScene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
            let rootVC = windowScene.windows.first(where: \.isKeyWindow)?.rootViewController
        else {
            error = .message("Could not find root view controller")
            return
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: Secrets.googleClientID)

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            guard let idToken = result.user.idToken?.tokenString else {
                error = .message("Google Sign In failed: missing ID token")
                return
            }
            let accessToken = result.user.accessToken.tokenString
            try await supabase.auth.signInWithIdToken(
                credentials: .init(provider: .google, idToken: idToken, accessToken: accessToken)
            )
        } catch {
            let nsError = error as NSError
            if nsError.code != -5 { // -5 = user cancelled
                self.error = .message(error.localizedDescription)
            }
        }
    }

    // MARK: - Email / Password

    func signIn(email: String, password: String) async {
        do {
            try await supabase.auth.signIn(email: email, password: password)
        } catch {
            self.error = .message(Self.friendly(error))
        }
    }

    func signUp(email: String, password: String, displayName: String) async {
        do {
            let response = try await supabase.auth.signUp(
                email: email,
                password: password,
                data: ["display_name": .string(displayName)]
            )
            if response.session == nil { awaitingEmailConfirmation = email }
        } catch {
            self.error = .message(Self.friendly(error))
        }
    }

    /// Plain-language versions of the errors people actually hit.
    private static func friendly(_ error: Error) -> String {
        let text = error.localizedDescription
        let lower = text.lowercased()
        if lower.contains("invalid login credentials") { return "That email and password don't match. Check them and try again." }
        if lower.contains("already registered") || lower.contains("already been registered") {
            return "There's already an account with that email. Try signing in instead."
        }
        if lower.contains("password") && lower.contains("least") { return "Choose a password with at least 8 characters." }
        if lower.contains("offline") || lower.contains("network") || lower.contains("internet") {
            return "No connection. Check your internet and try again."
        }
        return text
    }

    // MARK: - Sign Out

    func signOut() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            self.error = .message(error.localizedDescription)
        }
    }

    func clearError() {
        error = nil
    }
}

// MARK: - AuthError

enum AuthError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let msg): return msg
        }
    }
}

