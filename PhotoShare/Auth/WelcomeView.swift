import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var inviteRouter: InviteRouter
    @State private var showGetStarted = false
    @State private var showSignIn = false
    @State private var showPasteInvite = false
    @State private var pastedCode: String?
    @State private var invite: PublicInvitePreview?

    var body: some View {
        NavigationStack {
            ZStack {
                OttoColor.canvas.ignoresSafeArea()

                GeometryReader { geo in
                ScrollView {
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 32) {
                        OttoMascot(pose: .hero, width: 220)

                        VStack(spacing: 14) {
                            Text("shared photos,\nottomatically.")
                                .font(OttoFont.serifBoldItalic(size: 38))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .foregroundStyle(OttoColor.ink)

                            Text("when you're in the photo,\nyou get the photo.")
                                .font(OttoFont.ui(17))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(OttoColor.bark)
                        }
                    }

                    Spacer()

                    if let name = invite?.inviterName, invite?.usable == true {
                        InvitedBanner(name: name)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 20)
                    } else if invite?.usable == false {
                        Text("that invite link has expired or was already used. you can still join, and ask for a new link.")
                            .font(OttoFont.ui(13))
                            .foregroundStyle(OttoColor.wax)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                            .padding(.bottom, 16)
                            .accessibilityIdentifier("welcome.inviteProblem")
                    }

                    VStack(spacing: 12) {
                        OttoPillButton(title: invite?.usable == true ? "join \(invite?.inviterName ?? "them") on otto" : "get started") {
                            showGetStarted = true
                        }
                        .accessibilityIdentifier("welcome.getStarted")

                        Button {
                            showSignIn = true
                        } label: {
                            Text("already have an account? ")
                                .foregroundStyle(OttoColor.barkSoft) +
                            Text("sign in")
                                .foregroundStyle(OttoColor.sageDark)
                                .fontWeight(.medium)
                        }
                        .font(OttoFont.ui(14))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("welcome.signIn")

                        if inviteRouter.pendingCode == nil {
                            Button("have an invite link?") { showPasteInvite = true }
                                .font(OttoFont.ui(14))
                                .foregroundStyle(OttoColor.barkSoft)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityIdentifier("welcome.haveInvite")
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
                .frame(minHeight: geo.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                }
            }
            .navigationDestination(isPresented: $showGetStarted) {
                AuthView(startInSignUp: true)
            }
            .navigationDestination(isPresented: $showSignIn) {
                AuthView(startInSignUp: false)
            }
            .sheet(isPresented: $showPasteInvite, onDismiss: {
            if let pastedCode { inviteRouter.pendingCode = pastedCode; self.pastedCode = nil }
        }) { PasteInviteSheet(code: $pastedCode) }
            .task(id: inviteRouter.pendingCode) {
                guard let code = inviteRouter.pendingCode else { invite = nil; return }
                invite = await FriendsViewModel.publicPreview(code: code)
            }
        }
    }
}

/// "Dan invited you": shown on the welcome screen when the app was opened from an invite before signing up.
private struct InvitedBanner: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            OttoAvatarCircle(name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) invited you")
                    .font(OttoFont.ui(16, .semibold))
                    .foregroundStyle(OttoColor.ink)
                Text("create your account to start sharing photos with \(name).")
                    .font(OttoFont.ui(13))
                    .foregroundStyle(OttoColor.bark)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(OttoColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(OttoColor.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome.invitedBy")
    }
}

#Preview {
    WelcomeView().environmentObject(AuthManager()).environmentObject(InviteRouter())
}
