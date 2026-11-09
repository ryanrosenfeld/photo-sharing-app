import SwiftUI

/// Onboarding: invite one person. otto does nothing without a friend, so this is where day-one value comes from.
/// Skipping is as visible as sharing; either way the step is never shown again.
struct FirstFriendStep: View {
    @EnvironmentObject var authManager: AuthManager
    let step: Int
    let total: Int
    let onFinished: () -> Void

    @StateObject private var friends = FriendsViewModel()
    @State private var code: String?
    @State private var failed = false
    @State private var shared = false
    @State private var showQR = false

    var body: some View {
        OnboardingPage(
            step: step, total: total, mascot: .friends, icon: "person.2",
            title: "bring a friend",
            message: "otto works between friends. send one person a link. once they join, photos of each other start arriving on their own.",
            bullets: [
                "they see your name and choose to accept.",
                "only photos they're in are ever sent to them.",
            ]
        ) {
            if let code {
                if showQR {
                    InviteQRCode(url: InviteLink.url(code: code))
                        .frame(width: 170, height: 170)
                }
                if shared {
                    // Each link works once; more friends are one tap away on the Friends tab.
                    Text("invite sent. you'll see them in friends once they accept.")
                        .font(.system(size: 14))
                        .foregroundStyle(OttoColor.bark)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("firstFriend.sent")
                    Button("continue") { finish() }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("firstFriend.continue")
                } else {
                    ShareLink(
                        item: InviteLink.url(code: code),
                        message: Text(InviteMessage.text(from: authManager.currentProfile?.displayName))
                    ) {
                        Text("send an invite")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(OttoColor.sage)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        FriendsViewModel.markShared(code)
                        // Flip after the share sheet is up, so the ShareLink isn't torn down under it.
                        Task { try? await Task.sleep(for: .milliseconds(800)); shared = true }
                    })
                    .accessibilityIdentifier("firstFriend.share")

                    HStack(spacing: 24) {
                        Button(showQR ? "hide code" : "they're with me") { withAnimation { showQR.toggle() } }
                            .accessibilityIdentifier("firstFriend.qr")
                        Button(showQR ? "they scanned it" : "skip for now") {
                            if showQR { FriendsViewModel.markShared(code) }
                            finish()
                        }
                        .accessibilityIdentifier("firstFriend.skip")
                    }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.bark)
                    .frame(height: 44)
                }
            } else if failed {
                Button("couldn't create a link. try again") { Task { await load() } }
                    .foregroundStyle(OttoColor.wax)
                Button("skip for now") { finish() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.bark)
                    .accessibilityIdentifier("firstFriend.skip")
            } else {
                ProgressView().tint(OttoColor.sage).frame(height: 52)
                Button("skip for now") { finish() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.bark)
                    .accessibilityIdentifier("firstFriend.skip")
            }
        }
        .task { await load() }
    }

    private func load() async {
        failed = false
        code = await friends.inviteToShare()
        failed = code == nil
    }

    private func finish() {
        OnboardingStep.markFirstFriendOffered()
        onFinished()
    }
}
