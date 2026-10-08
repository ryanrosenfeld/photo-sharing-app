import Photos
import SwiftUI
import UserNotifications

/// Post-sign-in onboarding. There is no stored "onboarding done" flag: the next step is derived from real state
/// (face profile on the server, system permission status), so it resumes where the user left off after a
/// force-quit or reinstall, and it never re-asks for something the user already answered.
enum OnboardingStep: Int, CaseIterable {
    case faceProfile, photoAccess, notifications

    private static let notificationsOfferedKey = "onboarding.notificationsOffered"

    /// "Not now" leaves the system status undetermined, so remember that we already offered.
    static func markNotificationsOffered() {
        UserDefaults.standard.set(true, forKey: notificationsOfferedKey)
    }

    /// Whether this step still needs doing.
    func isPending(profile: UserProfile) async -> Bool {
        switch self {
        case .faceProfile:
            return !profile.faceProfileEnabled
        case .photoAccess:
            return PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
        case .notifications:
            if UserDefaults.standard.bool(forKey: Self.notificationsOfferedKey) { return false }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return settings.authorizationStatus == .notDetermined
        }
    }

    /// First pending step at or after `self`'s position (pass `after: nil` to start from the top).
    static func firstPending(after current: OnboardingStep?, profile: UserProfile?) async -> OnboardingStep? {
        guard let profile else { return nil }
        let start = current.map { $0.rawValue + 1 } ?? 0
        for step in allCases where step.rawValue >= start {
            if await step.isPending(profile: profile) { return step }
        }
        return nil
    }
}

struct OnboardingFlow: View {
    @EnvironmentObject var authManager: AuthManager
    let initial: OnboardingStep
    let onFinished: () -> Void

    @State private var step: OnboardingStep

    private let total = OnboardingStep.allCases.count

    init(initial: OnboardingStep, onFinished: @escaping () -> Void) {
        self.initial = initial
        self.onFinished = onFinished
        _step = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(authManager.currentProfile.map { "Hi, \($0.displayName)" } ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Sign out", role: .destructive) { Task { await authManager.signOut() } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityIdentifier("onboarding.menu")
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Group {
                switch step {
                case .faceProfile:
                    if let userId = authManager.session?.user.id {
                        FaceProfileStep(userId: userId, step: 1, total: total) {
                            Task {
                                await authManager.fetchProfile(userId: userId)
                                await advance()
                            }
                        }
                    }
                case .photoAccess:
                    PhotoAccessStep(step: 2, total: total) { Task { await advance() } }
                case .notifications:
                    NotificationStep(step: 3, total: total) { Task { await advance() } }
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
        }
        .animation(.easeInOut(duration: 0.25), value: step)
    }

    private func advance() async {
        if let next = await OnboardingStep.firstPending(after: step, profile: authManager.currentProfile) {
            step = next
        } else {
            onFinished()
        }
    }
}
