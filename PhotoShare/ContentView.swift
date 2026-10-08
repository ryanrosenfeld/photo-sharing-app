import SwiftUI

struct ContentView: View {
    @StateObject private var authManager = AuthManager()

    private enum Onboarding { case checking, needed(OnboardingStep), done }
    @State private var onboarding: Onboarding = .checking

    var body: some View {
        Group {
            if authManager.isLoading {
                ProgressView()
            } else if authManager.session == nil {
                WelcomeView()
            } else if authManager.currentProfile == nil {
                ProfileLoadingView()
            } else {
                switch onboarding {
                case .checking:
                    ProgressView()
                case .needed(let step):
                    OnboardingFlow(initial: step) { onboarding = .done }
                case .done:
                    MainTabView()
                }
            }
        }
        .environmentObject(authManager)
        // Decide once per signed-in user; the flow itself drives later transitions.
        .task(id: authManager.currentProfile?.id) {
            guard let profile = authManager.currentProfile else {
                onboarding = .checking
                return
            }
            if let step = await OnboardingStep.firstPending(after: nil, profile: profile) {
                onboarding = .needed(step)
            } else {
                onboarding = .done
            }
        }
    }
}

/// Shown between "signed in" and "profile fetched". A failed fetch gets a retry instead of a blank spinner.
private struct ProfileLoadingView: View {
    @EnvironmentObject var authManager: AuthManager

    var body: some View {
        VStack(spacing: 16) {
            if authManager.profileLoadFailed {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("Couldn't load your account").font(.headline)
                Button("Try again") { Task { await authManager.reloadProfile() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("profileLoading.retry")
                Button("Sign out", role: .destructive) { Task { await authManager.signOut() } }
                    .font(.subheadline)
            } else {
                ProgressView()
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
