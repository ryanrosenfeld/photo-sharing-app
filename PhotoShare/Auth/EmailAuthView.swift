import SwiftUI

struct EmailAuthView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var isSignUp: Bool
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var showPassword = false
    @FocusState private var focus: Field?

    private enum Field { case name, email, password }

    init(startInSignUp: Bool = false) {
        _isSignUp = State(initialValue: startInSignUp)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var emailLooksValid: Bool { trimmedEmail.contains("@") && trimmedEmail.contains(".") }

    private var isFormValid: Bool {
        let base = emailLooksValid && password.count >= 8
        return isSignUp ? base && !displayName.trimmingCharacters(in: .whitespaces).isEmpty : base
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Mode toggle
                Picker("Mode", selection: $isSignUp) {
                    Text("Sign In").tag(false)
                    Text("Create Account").tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("emailAuth.mode")
                .padding(.top, 8)

                VStack(spacing: 14) {
                    if isSignUp {
                        TextField("Name", text: $displayName)
                            .textContentType(.name)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { focus = .email }
                            .styledField()
                            .accessibilityIdentifier("emailAuth.name")
                    }

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .styledField()
                        .accessibilityIdentifier("emailAuth.email")

                    HStack {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                            } else {
                                SecureField("Password", text: $password)
                            }
                        }
                        .textContentType(isSignUp ? .newPassword : .password)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { if isFormValid { submit() } }
                        .accessibilityIdentifier("emailAuth.password")

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                    }
                    .styledField()

                    if isSignUp {
                        Text("At least 8 characters")
                            .font(.footnote)
                            .foregroundStyle(password.isEmpty || password.count >= 8 ? Color.secondary : Color.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button {
                    submit()
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text(isSignUp ? "Create Account" : "Sign In")
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(isFormValid ? Color.primary : Color.secondary.opacity(0.3))
                    .foregroundStyle(isFormValid ? Color(UIColor.systemBackground) : .secondary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(!isFormValid || isLoading)
                .accessibilityIdentifier("emailAuth.submit")
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(isSignUp ? "Create Account" : "Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Check your email", isPresented: Binding(
            get: { authManager.awaitingEmailConfirmation != nil },
            set: { if !$0 { authManager.awaitingEmailConfirmation = nil } }
        )) {
            Button("OK") { authManager.awaitingEmailConfirmation = nil; isSignUp = false }
        } message: {
            Text("We sent a confirmation link to \(authManager.awaitingEmailConfirmation ?? ""). Tap it, then come back and sign in.")
        }
        .alert("Error", isPresented: Binding(
            get: { authManager.error != nil },
            set: { if !$0 { authManager.clearError() } }
        )) {
            Button("OK") { authManager.clearError() }
        } message: {
            Text(authManager.error?.localizedDescription ?? "")
        }
    }
}

extension EmailAuthView {
    fileprivate func submit() {
        focus = nil
        Task {
            isLoading = true
            if isSignUp {
                await authManager.signUp(email: trimmedEmail, password: password,
                                         displayName: displayName.trimmingCharacters(in: .whitespaces))
            } else {
                await authManager.signIn(email: trimmedEmail, password: password)
            }
            isLoading = false
        }
    }
}

// MARK: - Field style helper

private extension View {
    func styledField() -> some View {
        self
            .padding(14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NavigationStack {
        EmailAuthView().environmentObject(AuthManager())
    }
}
