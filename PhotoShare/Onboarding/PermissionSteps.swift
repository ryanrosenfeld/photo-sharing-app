import Photos
import SwiftUI
import UserNotifications

/// Photo library access: explain first, then show the system prompt. A denial doesn't trap the user.
struct PhotoAccessStep: View {
    let step: Int
    let total: Int
    let onFinished: () -> Void

    @State private var denied = false

    var body: some View {
        if denied {
            OnboardingPage(
                step: step, total: total, icon: "photo.badge.exclamationmark",
                title: "Photo access is off",
                message: "Without it, otto can't spot your friends in new photos, so nothing gets shared automatically. You can turn it on in Settings any time."
            ) {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("photoAccess.settings")
                Button("Continue without it", action: onFinished)
                    .font(.subheadline)
                    .accessibilityIdentifier("photoAccess.skip")
            }
        } else {
            OnboardingPage(
                step: step, total: total, icon: "photo.on.rectangle.angled",
                title: "Let otto see your photos",
                message: "When you take a photo with a friend in it, otto sends it to them automatically.",
                bullets: [
                    "Faces are matched on your phone. Nothing is analyzed on a server.",
                    "A photo is only sent when a friend you've connected with is in it.",
                    "Choose “Allow Full Access” so new photos are picked up.",
                ]
            ) {
                Button("Continue") {
                    Task {
                        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        if status == .authorized || status == .limited { onFinished() } else { denied = true }
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("photoAccess.continue")
            }
        }
    }
}

/// Notification permission, asked after the user has seen what the app does. Fully skippable.
struct NotificationStep: View {
    let step: Int
    let total: Int
    let onFinished: () -> Void

    var body: some View {
        OnboardingPage(
            step: step, total: total, icon: "bell.badge",
            title: "Know when photos arrive",
            message: "Get a nudge when a friend shares a photo of you, or when a friend request comes in."
        ) {
            Button("Turn on notifications") {
                Task {
                    OnboardingStep.markNotificationsOffered()
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .badge, .sound])
                    onFinished()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("notifications.allow")
            Button("Not now") {
                OnboardingStep.markNotificationsOffered()
                onFinished()
            }
                .font(.subheadline)
                .accessibilityIdentifier("notifications.skip")
        }
    }
}

func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}
