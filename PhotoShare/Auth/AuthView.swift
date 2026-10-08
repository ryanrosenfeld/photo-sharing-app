import GoogleSignInSwift
import SwiftUI

struct AuthView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSigningIn = false

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // nav step label
                    HStack {
                        Spacer()
                        Text("Step 2 of 6")
                            .font(.system(size: 13))
                            .foregroundStyle(OttoColor.barkSoft)
                        Spacer()
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 32)

                    // heading
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Sign in to otto.")
                            .font(OttoFont.serifBold(size: 30))
                            .foregroundStyle(OttoColor.ink)

                        Text("Welcome back. We only need your name and email.")
                            .font(.system(size: 15))
                            .foregroundStyle(OttoColor.bark)
                            .lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)

                    // email + password
                    VStack(spacing: 12) {
                        emailField
                        passwordField

                        Button {
                            Task { await signIn() }
                        } label: {
                            Group {
                                if isSigningIn {
                                    ProgressView().tint(.white)
                                } else {
                                    Text("Sign in")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(OttoColor.ink)
                            .foregroundStyle(OttoColor.canvas)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(isSigningIn)
                    }
                    .padding(.horizontal, 28)

                    // divider
                    HStack(spacing: 12) {
                        Rectangle().frame(height: 1).foregroundStyle(OttoColor.line)
                        Text("or continue with")
                            .font(.system(size: 12))
                            .foregroundStyle(OttoColor.barkSoft)
                            .kerning(0.4)
                            .fixedSize()
                        Rectangle().frame(height: 1).foregroundStyle(OttoColor.line)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)

                    // SSO options
                    VStack(spacing: 10) {
                        ssoButton(label: "Apple") {
                            // Apple Sign In — not yet implemented
                        } icon: {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 17))
                        }

                        ssoButton(label: "Google") {
                            Task { await authManager.signInWithGoogle() }
                        } icon: {
                            // simple multi-color G
                            Text("G")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color(hex: "#4285F4"))
                        }
                    }
                    .padding(.horizontal, 28)

                }
                .font(.system(size: 13))
                .padding(.top, 0)
                .padding(.bottom, 80)
                .padding(.horizontal, 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            termsLabel
                .padding(.bottom, 28)
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

    // MARK: - Sub-views

    private var emailField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EMAIL")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(OttoColor.barkSoft)

            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.barkSoft)
                TextField("sam@example.com", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .font(.system(size: 16))
                    .foregroundStyle(OttoColor.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(email.isEmpty ? OttoColor.line : OttoColor.sage, lineWidth: email.isEmpty ? 1 : 1.5)
            )
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PASSWORD")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(1.2)
                    .foregroundStyle(OttoColor.barkSoft)
                Spacer()
                Button("Forgot?") {}
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OttoColor.sage)
            }

            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.barkSoft)
                Group {
                    if showPassword {
                        TextField("••••••••", text: $password)
                    } else {
                        SecureField("••••••••", text: $password)
                    }
                }
                .textContentType(.password)
                .font(.system(size: 16))
                .foregroundStyle(OttoColor.ink)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(OttoColor.barkSoft)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(OttoColor.line, lineWidth: 1)
            )
        }
    }

    private func ssoButton<Icon: View>(label: String, action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon()
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(OttoColor.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(OttoColor.line, lineWidth: 1)
            )
        }
    }

    private var termsLabel: some View {
        (Text("By continuing, you agree to otto's ")
            .foregroundStyle(OttoColor.barkSoft) +
        Text("Terms").foregroundStyle(OttoColor.sage) +
        Text(" and ").foregroundStyle(OttoColor.barkSoft) +
        Text("Privacy Policy").foregroundStyle(OttoColor.sage))
            .font(.system(size: 13))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }

    // MARK: - Actions

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        await authManager.signIn(email: email, password: password)
    }
}

#Preview {
    NavigationStack { AuthView() }.environmentObject(AuthManager())
}
