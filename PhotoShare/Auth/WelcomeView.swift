import SwiftUI

struct WelcomeView: View {
    @State private var showGetStarted = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            ZStack {
                OttoColor.canvas.ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 32) {
                        OttoMascot(pose: .hero, width: 220)

                        VStack(spacing: 14) {
                            Text("Shared photos,\nottomatically.")
                                .font(OttoFont.serifBoldItalic(size: 38))
                                .multilineTextAlignment(.center)
                                .lineSpacing(2)
                                .foregroundStyle(OttoColor.ink)

                            Text("When you're in the photo,\nyou get the photo.")
                                .font(.system(size: 17))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(OttoColor.bark)
                                .lineSpacing(2)
                        }
                    }

                    Spacer()

                    VStack(spacing: 12) {
                        OttoPillButton(title: "Get started") {
                            showGetStarted = true
                        }

                        Button {
                            showSignIn = true
                        } label: {
                            Text("Already have an account? ")
                                .foregroundStyle(OttoColor.barkSoft) +
                            Text("Sign in")
                                .foregroundStyle(OttoColor.sage)
                                .fontWeight(.medium)
                        }
                        .font(.system(size: 14))
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                }
            }
            .navigationDestination(isPresented: $showGetStarted) {
                AuthView()
            }
            .navigationDestination(isPresented: $showSignIn) {
                AuthView()
            }
        }
    }
}

#Preview {
    WelcomeView().environmentObject(AuthManager())
}
