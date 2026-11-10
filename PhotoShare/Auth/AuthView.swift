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
    @State private var showReset = false
    @State private var resetEmail = ""
    @State private var resetResult: String?
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
                        Text(isSignUp ? "join otto." : "sign in to otto.")
                            .font(OttoFont.serifBold(size: 30))
                            .foregroundStyle(OttoColor.ink)

                        Text(isSignUp ? "just your name, an email, and a password. then a quick photo setup." : "welcome back.")
                            .font(OttoFont.ui(15))
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
                            Text("at least 8 characters")
                                .font(OttoFont.ui(12))
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
                                    Text(isSignUp ? "create account" : "sign in")
                                        .font(OttoFont.ui(16, .semibold))
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
                            Text(isSignUp ? "already have an account? " : "new to otto? ")
                                .foregroundStyle(OttoColor.barkSoft) +
                            Text(isSignUp ? "sign in" : "create an account")
                                .foregroundStyle(OttoColor.sageDark).fontWeight(.medium)
                        }
                        .font(OttoFont.ui(14))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityIdentifier("emailAuth.toggleMode")
                    }
                    .padding(.horizontal, 28)

                    // divider
                    HStack(spacing: 12) {
                        Rectangle().frame(height: 1).foregroundStyle(OttoColor.line)
                        Text("or continue with")
                            .font(OttoFont.ui(12))
                            .foregroundStyle(OttoColor.barkSoft)
                            .kerning(0.4)
                            .fixedSize()
                        Rectangle().frame(height: 1).foregroundStyle(OttoColor.line)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)

                    // SSO options
                    // Sign in with Apple is not built yet (pending Ryan's call on third-party sign-in in v1), so no button:
                    // a button that does nothing is worse than none.
                    VStack(spacing: 10) {
                        ssoButton(label: "google") {
                            Task { await authManager.signInWithGoogle() }
                        } icon: {
                            // simple multi-color G
                            Text("G")
                                .font(OttoFont.ui(16, .semibold))
                                .foregroundStyle(OttoColor.ink)
                        }
                    }
                    .padding(.horizontal, 28)

                    termsLabel
                        .padding(.top, 28)
                }
                .font(OttoFont.ui(13))
                .padding(.top, 0)
                .padding(.bottom, 40)
                .padding(.horizontal, 0)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .alert("check your email", isPresented: Binding(
            get: { authManager.awaitingEmailConfirmation != nil },
            set: { if !$0 { authManager.awaitingEmailConfirmation = nil } }
        )) {
            Button("ok") { authManager.awaitingEmailConfirmation = nil; isSignUp = false }
        } message: {
            Text("we sent a confirmation link to \(authManager.awaitingEmailConfirmation ?? ""). tap it, then come back and sign in.")
        }
        .alert("reset your password", isPresented: $showReset) {
            TextField("email", text: $resetEmail)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("reset.email")
            Button("send link") {
                Task {
                    let address = resetEmail.trimmingCharacters(in: .whitespaces)
                    let failure = await authManager.sendPasswordReset(email: address)
                    resetResult = failure ?? "if there's an account for \(address), a reset link is on its way."
                }
            }
            .accessibilityIdentifier("reset.send")
            Button("cancel", role: .cancel) {}
        } message: {
            Text("we'll email you a link to choose a new one.")
        }
        .alert("password reset", isPresented: Binding(
            get: { resetResult != nil },
            set: { if !$0 { resetResult = nil } }
        )) {
            Button("ok") { resetResult = nil }
        } message: {
            Text(resetResult ?? "")
        }
        .alert(isSignUp ? "couldn't create account" : "couldn't sign in", isPresented: Binding(
            get: { authManager.error != nil },
            set: { if !$0 { authManager.clearError() } }
        )) {
            Button("ok") { authManager.clearError() }
        } message: {
            Text(authManager.error?.localizedDescription ?? "")
        }
    }

    // MARK: - Sub-views

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("name")
                .font(OttoFont.ui(11, .semibold))
                .tracking(1.2)
                .foregroundStyle(OttoColor.barkSoft)
            HStack(spacing: 10) {
                Image(systemName: "person")
                    .font(OttoFont.ui(14))
                    .foregroundStyle(OttoColor.barkSoft)
                TextField("what friends call you", text: $displayName)
                    .accessibilityIdentifier("emailAuth.name")
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .email }
                    .font(OttoFont.ui(16))
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
            Text("email")
                .font(OttoFont.ui(11, .semibold))
                .tracking(1.2)
                .foregroundStyle(OttoColor.barkSoft)

            HStack(spacing: 10) {
                Image(systemName: "envelope")
                    .font(OttoFont.ui(14))
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
                    .font(OttoFont.ui(16))
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
                Text("password")
                    .font(OttoFont.ui(11, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(OttoColor.barkSoft)
                Spacer()
                if !isSignUp {
                    Button("forgot?") {
                        resetEmail = trimmedEmail
                        showReset = true
                    }
                        .font(OttoFont.ui(12, .medium))
                        .foregroundStyle(OttoColor.sageDark)
                        .accessibilityIdentifier("emailAuth.forgot")
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "lock")
                    .font(OttoFont.ui(14))
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
                .font(OttoFont.ui(16))
                .foregroundStyle(OttoColor.ink)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .font(OttoFont.ui(15))
                        .foregroundStyle(OttoColor.barkSoft)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(showPassword ? "hide password" : "show password")
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
                    .font(OttoFont.ui(15, .medium))
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
        (Text("by continuing, you agree to otto's ")
            .foregroundStyle(OttoColor.barkSoft) +
        Text("terms").foregroundStyle(OttoColor.bark) +
        Text(" and ").foregroundStyle(OttoColor.barkSoft) +
        Text("privacy policy").foregroundStyle(OttoColor.bark))
            .font(OttoFont.ui(13))
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
