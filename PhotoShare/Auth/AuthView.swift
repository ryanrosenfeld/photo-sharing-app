import GoogleSignInSwift
import SwiftUI

struct AuthView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var showEmailAuth = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.primary)
                    Text("PhotoShare")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                }

                Spacer()

                // Sign-in options
                VStack(spacing: 12) {
                    // Google
                    Button {
                        Task { await authManager.signInWithGoogle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image("google_logo") // add to Assets; falls back gracefully if missing
                                .resizable()
                                .scaledToFit()
                                .frame(width: 20, height: 20)
                            Text("Continue with Google")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Color(.systemBackground))
                        .foregroundStyle(.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                    }

                    // Divider
                    HStack {
                        Rectangle().frame(height: 1).foregroundStyle(Color(.separator))
                        Text("or").font(.footnote).foregroundStyle(.secondary)
                        Rectangle().frame(height: 1).foregroundStyle(Color(.separator))
                    }
                    .padding(.vertical, 4)

                    // Email
                    Button {
                        showEmailAuth = true
                    } label: {
                        Text("Continue with Email")
                            .font(.system(size: 17, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color(.secondarySystemBackground))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 48)
            }
            .navigationDestination(isPresented: $showEmailAuth) {
                EmailAuthView()
            }
            .alert("Sign In Error", isPresented: Binding(
                get: { authManager.error != nil },
                set: { if !$0 { authManager.clearError() } }
            )) {
                Button("OK") { authManager.clearError() }
            } message: {
                Text(authManager.error?.localizedDescription ?? "")
            }
        }
    }
}

#Preview {
    AuthView().environmentObject(AuthManager())
}
