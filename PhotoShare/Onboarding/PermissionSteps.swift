import Photos
import SwiftUI
import UserNotifications

/// Photo library access: explain first, then show the system prompt. A denial doesn't trap the user.
struct PhotoAccessStep: View {
    let step: Int
    let total: Int
    let onFinished: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var denied = false
    @State private var requesting = false
    /// Guards against calling `onFinished` twice (request result, foreground re-check and poll can all fire).
    @State private var finished = false

    private func isGranted(_ status: PHAuthorizationStatus) -> Bool { status == .authorized || status == .limited }

    /// Advances exactly once when access is granted; otherwise shows the denied state (unless still undetermined).
    private func evaluate() {
        guard !finished else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if isGranted(status) {
            finished = true
            onFinished()
        } else if status != .notDetermined {
            denied = true
        }
    }

    /// Shows the system prompt. The completion-handler API is used so a missed continuation can't leave us waiting;
    /// `evaluate()` reads the real status afterwards, and the poll covers a result that arrives late.
    private func requestAccess() {
        guard !requesting, !finished else { return }
        requesting = true
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
            Task { @MainActor in
                requesting = false
                evaluate()
            }
        }
        Task { @MainActor in
            for _ in 0..<60 where !finished {
                try? await Task.sleep(for: .milliseconds(500))
                if PHPhotoLibrary.authorizationStatus(for: .readWrite) != .notDetermined { evaluate(); break }
            }
        }
    }

    var body: some View {
        content
            .onChange(of: scenePhase) { _, phase in
                // Returning from the system alert or from Settings: re-check the real status.
                if phase == .active { evaluate() }
            }
    }

    @ViewBuilder private var content: some View {
        if denied {
            OnboardingPage(
                step: step, total: total, mascot: .sleeping, icon: "photo",
                title: "photo access is off",
                message: "without it, otto can't spot your friends in new photos, so nothing gets shared automatically. you can turn it on in settings any time."
            ) {
                Button("open settings") { openSettings() }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("photoAccess.settings")
                Button("continue without it") {
                    guard !finished else { return }
                    finished = true
                    onFinished()
                }
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.barkSoft)
                    .accessibilityIdentifier("photoAccess.skip")
            }
        } else {
            OnboardingPage(
                step: step, total: total, mascot: .floating, icon: "photo",
                title: "let otto see your photos",
                message: "when you take a photo with a friend in it, otto sends it to them automatically.",
                bullets: [
                    "faces are matched on your phone. nothing is analyzed on a server.",
                    "a photo is only sent when a friend you've connected with is in it.",
                    "choose “allow full access” so new photos are picked up.",
                ]
            ) {
                Button("continue") { requestAccess() }
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
            step: step, total: total, mascot: .friends, icon: "bell",
            title: "know when photos arrive",
            message: "get a nudge when a friend shares a photo of you, or when a friend request comes in."
        ) {
            Button("turn on notifications") {
                Task {
                    OnboardingStep.markNotificationsOffered()
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .badge, .sound])
                    onFinished()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("notifications.allow")
            Button("not now") {
                OnboardingStep.markNotificationsOffered()
                onFinished()
            }
                .font(.system(size: 14))
                .foregroundStyle(OttoColor.barkSoft)
                .accessibilityIdentifier("notifications.skip")
        }
    }
}

@MainActor func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}
