import Photos
import SwiftUI
import UserNotifications

/// Post-sign-in onboarding. There is no stored "onboarding done" flag: the next step is derived from real state
/// (face profile on the server, system permission status), so it resumes where the user left off after a
/// force-quit or reinstall, and it never re-asks for something the user already answered.
enum OnboardingStep: Int, CaseIterable {
    case faceProfile, photoAccess, friendSuggestions, firstFriend, notifications

    private static let notificationsOfferedKey = "onboarding.notificationsOffered"
    private static let firstFriendOfferedKey = "onboarding.firstFriendOffered"
    private static let suggestionsOfferedKey = "onboarding.suggestionsOffered"

    /// Shown once per device: continuing or skipping both count.
    static func markSuggestionsOffered() {
        UserDefaults.standard.set(true, forKey: suggestionsOfferedKey)
    }

    /// Shown once: sharing or skipping both count.
    static func markFirstFriendOffered() {
        UserDefaults.standard.set(true, forKey: firstFriendOfferedKey)
    }

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
        case .friendSuggestions:
            // Needs the library, and is pointless for invitees (their friend is already waiting) or people with friends.
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { return false }
            if InviteRouter.hasStoredInvite() { return false }
            if UserDefaults.standard.bool(forKey: Self.suggestionsOfferedKey) { return false }
            if UserDefaults.standard.bool(forKey: Self.firstFriendOfferedKey) { return false }
            return !(await Self.hasFriendsOrInvites())
        case .firstFriend:
            // Someone who arrived from an invite already has a friend waiting: the accept screen comes next instead.
            if InviteRouter.hasStoredInvite() { return false }
            if UserDefaults.standard.bool(forKey: Self.firstFriendOfferedKey) { return false }
            // People who already have a friend, or have sent an invite (existing accounts, reinstalls), skip it.
            return !(await Self.hasFriendsOrInvites())
        case .notifications:
            if UserDefaults.standard.bool(forKey: Self.notificationsOfferedKey) { return false }
            // The settings read can hang (seen on a freshly erased simulator): never let it hold the app on a spinner.
            // If it doesn't answer in time, show the step; asking again is harmless.
            return await Self.notificationStatus(timeout: .seconds(3)).map { $0 == .notDetermined } ?? true
        }
    }

    /// Resumes from whichever comes first, the system answer or the timer. (A task group would still wait for the hung call.)
    private static func notificationStatus(timeout: Duration) async -> UNAuthorizationStatus? {
        await withCheckedContinuation { (continuation: CheckedContinuation<UNAuthorizationStatus?, Never>) in
            let once = ResumeOnce(continuation)
            UNUserNotificationCenter.current().getNotificationSettings { once.resume($0.authorizationStatus) }
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { once.resume(nil) }
        }
    }

    private static func hasFriendsOrInvites() async -> Bool {
        do {
            let friends: [Friend] = try await supabase.rpc("list_friends").execute().value
            if !friends.isEmpty { return true }
            let invites: [OpenInvite] = try await supabase.from("invites")
                .select("code, created_at, expires_at").limit(1).execute().value
            return !invites.isEmpty
        } catch {
            return true   // offline or failing: don't block onboarding on a nice-to-have step
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
                Text(authManager.currentProfile.map { "hi, \($0.displayName)" } ?? "")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.barkSoft)
                Spacer()
                Menu {
                    Button("sign out", role: .destructive) { Task { await authManager.signOut() } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(OttoColor.barkSoft)
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
                case .friendSuggestions:
                    FriendSuggestionsStep(step: 3, total: total) {
                        OnboardingStep.markSuggestionsOffered()
                        Task { await advance() }
                    }
                case .firstFriend:
                    FirstFriendStep(step: 4, total: total) { Task { await advance() } }
                case .notifications:
                    NotificationStep(step: 5, total: total) { Task { await advance() } }
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

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UNAuthorizationStatus?, Never>?
    init(_ continuation: CheckedContinuation<UNAuthorizationStatus?, Never>) { self.continuation = continuation }
    func resume(_ value: UNAuthorizationStatus?) {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume(returning: value)
    }
}
