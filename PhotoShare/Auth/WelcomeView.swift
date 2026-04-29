import SwiftUI

struct WelcomeView: View {
    @State private var showGetStarted = false
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 16) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.primary)

                    Text("PhotoShare")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Photos with your friends,\nautomatically delivered.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showGetStarted = true
                    } label: {
                        Text("Get Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.primary)
                            .foregroundStyle(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        showSignIn = true
                    } label: {
                        Text("Sign In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.secondary.opacity(0.15))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
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
