import GoogleSignInSwift
import SwiftUI

struct AuthView: View {
    @EnvironmentObject var authManager: AuthManager
    @State private var isSignUp: Bool
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isSigningIn = false
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    init(startInSignUp: Bool = false) {
        _isSignUp = State(initialValue: startInSignUp)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespaces) }
    private var isFormValid: Bool {
        let base = trimmedEmail.contains("@") && trimmedEmail.contains(".") && password.count >= 8
        return isSignUp ? base && !trimmedName.isEmpty : base
    }

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 24)

                    // heading
                    VStack(alignment: .leading, spacing: 10) {
                        Text(isSignUp ? "Join otto." : "Sign in to otto.")
                            .font(OttoFont.serifBold(size: 30))
                            .foregroundStyle(OttoColor.ink)

                        Text(isSignUp ? "Just your name, an email, and a password. Then a quick photo setup." : "Welcome back.")
                            .font(.system(size: 15))
                            .foregroundStyle(OttoColor.bark)
                            .lineSpacing(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)

                    // email + password
                    VStack(spacing: 12) {
                        if isSignUp { nameField }
                        emailField
                        passwordField

                        if isSignUp {
                            Text("At least 8 characters")
                                .font(.system(size: 12))
                                .foregroundStyle(password.isEmpty || password.count >= 8 ? OttoColor.barkSoft : OttoColor.wax)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task { await submit() }
                        } label: {
                            Group {
                                if isSigningIn {
                                    ProgressView().tint(.white)
                                } else {
                                    Text(isSignUp ? "Create account" : "Sign in")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .accessibilityIdentifier("emailAuth.submit")
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(isFormValid ? OttoColor.ink : OttoColor.chip)
                            .foregroundStyle(isFormValid ? OttoColor.canvas : OttoColor.barkSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .disabled(!isFormValid || isSigningIn)

                        Button {
                            isSignUp.toggle()
                        } label: {
                            Text(isSignUp ? "Already have an account? " : "New to otto? ")
                                .foregroundStyle(OttoColor.barkSoft) +
                            Text(isSignUp ? "Sign in" : "Create an account")
                                .foregroundStyle(OttoColor.sage).fontWeight(.medium)
                        }
                        .font(.system(size: 14))
                        .padding(.top, 4)
                        .accessibilityIdentifier("emailAuth.toggleMode")
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

                    termsLabel
                        .padding(.top, 28)
                }
                .font(.system(size: 13))
                .padding(.top, 0)
                .padding(.bottom, 40)
                .padding(.horizontal, 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .alert("Check your email", isPresented: Binding(
            get: { authManager.awaitingEmailConfirmation != nil },
            set: { if !$0 { authManager.awaitingEmailConfirmation = nil } }
        )) {
            Button("OK") { authManager.awaitingEmailConfirmation = nil; isSignUp = false }
        } message: {
            Text("We sent a confirmation link to \(authManager.awaitingEmailConfirmation ?? ""). Tap it, then come back and sign in.")
        }
        .alert(isSignUp ? "Couldn't create account" : "Couldn't sign in", isPresented: Binding(
            get: { authManager.error != nil },
            set: { if !$0 { authManager.clearError() } }
        )) {
            Button("OK") { authManager.clearError() }
        } message: {
            Text(authManager.error?.localizedDescription ?? "")
        }
    }

    // MARK: - Sub-views

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(OttoColor.barkSoft)
            HStack(spacing: 10) {
                Image(systemName: "person")
                    .font(.system(size: 14))
                    .foregroundStyle(OttoColor.barkSoft)
                TextField("What friends call you", text: $displayName)
                    .accessibilityIdentifier("emailAuth.name")
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .email }
                    .font(.system(size: 16))
                    .foregroundStyle(OttoColor.ink)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(OttoColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(displayName.isEmpty ? OttoColor.line : OttoColor.sage, lineWidth: displayName.isEmpty ? 1 : 1.5)
            )
        }
    }

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
                    .accessibilityIdentifier("emailAuth.email")
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
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
                if !isSignUp {
                    Button("Forgot?") {}
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OttoColor.sage)
                }
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
                .accessibilityIdentifier("emailAuth.password")
                .textContentType(isSignUp ? .newPassword : .password)
                .autocorrectionDisabled()
                .autocapitalization(.none)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit { if isFormValid { Task { await submit() } } }
                .font(.system(size: 16))
                .foregroundStyle(OttoColor.ink)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(.system(size: 15))
                        .foregroundStyle(OttoColor.barkSoft)
                }
                .accessibilityIdentifier("emailAuth.showPassword")
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

    private func submit() async {
        focus = nil
        isSigningIn = true
        defer { isSigningIn = false }
        if isSignUp {
            await authManager.signUp(email: trimmedEmail, password: password, displayName: trimmedName)
        } else {
            await authManager.signIn(email: trimmedEmail, password: password)
        }
    }
}

#Preview {
    NavigationStack { AuthView() }.environmentObject(AuthManager())
}
