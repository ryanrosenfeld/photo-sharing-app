import SwiftUI

/// "Step 2 of 3" progress shown at the top of every onboarding screen.
struct OnboardingProgress: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...total, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? OttoColor.sage : OttoColor.line)
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step) of \(total)")
        .accessibilityIdentifier("onboarding.progress")
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(isEnabled ? OttoColor.sage : OttoColor.chip)
            .foregroundStyle(isEnabled ? Color.white : OttoColor.barkSoft)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Shared layout for the permission explainer screens: icon, title, body, bullets, bottom actions.
struct OnboardingPage<Actions: View>: View {
    let step: Int
    let total: Int
    var mascot: OttoMascot.Pose? = nil
    var icon: String = "photo"
    let title: String
    let message: String
    var bullets: [String] = []
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgress(step: step, total: total)
                .padding(.horizontal, 24)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 18) {
                    if let mascot {
                        OttoMascot(pose: mascot, width: 190).padding(.top, 28)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 52))
                            .foregroundStyle(OttoColor.sage)
                            .padding(.top, 40)
                    }
                    Text(title)
                        .font(OttoFont.serifBold(size: 28))
                        .foregroundStyle(OttoColor.ink)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.system(size: 16))
                        .lineSpacing(2)
                        .foregroundStyle(OttoColor.bark)
                        .multilineTextAlignment(.center)
                    if !bullets.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(bullets, id: \.self) { b in
                                Label(b, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(OttoColor.bark)
                                    .labelStyle(BulletLabelStyle())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 28)
            }

            VStack(spacing: 10, content: actions)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
                .padding(.top, 8)
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(OttoColor.sage)
            configuration.title
        }
    }
}
