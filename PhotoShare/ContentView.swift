import SwiftUI

struct ContentView: View {
    @StateObject private var authManager = AuthManager()

    private enum Onboarding { case checking, needed(OnboardingStep), done }
    @State private var onboarding: Onboarding = .checking

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            if authManager.isLoading {
                ProgressView().tint(OttoColor.sage)
            } else if authManager.session == nil {
                WelcomeView()
            } else if authManager.currentProfile == nil {
                ProfileLoadingView()
            } else {
                switch onboarding {
                case .checking:
                    ProgressView().tint(OttoColor.sage)
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
                OttoMascot(pose: .sleeping, width: 160)
                Text("Couldn't load your account")
                    .font(OttoFont.serifBold(size: 22))
                    .foregroundStyle(OttoColor.ink)
                OttoPillButton(title: "Try again", isFullWidth: false) { Task { await authManager.reloadProfile() } }
                    .accessibilityIdentifier("profileLoading.retry")
                Button("Sign out") { Task { await authManager.signOut() } }
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.wax)
            } else {
                ProgressView().tint(OttoColor.sage)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
