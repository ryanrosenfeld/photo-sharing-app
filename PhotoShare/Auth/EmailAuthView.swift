import SwiftUI

struct EmailAuthView: View {
    @EnvironmentObject var authManager: AuthManager
    @Environment(\.dismiss) var dismiss

    @State private var isSignUp = false
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false

    private var isFormValid: Bool {
        let base = !email.isEmpty && password.count >= 8
        return isSignUp ? base && !displayName.isEmpty : base
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
                .padding(.top, 8)

                VStack(spacing: 14) {
                    if isSignUp {
                        TextField("Name", text: $displayName)
                            .textContentType(.name)
                            .autocorrectionDisabled()
                            .styledField()
                    }

                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .autocapitalization(.none)
                        .styledField()

                    SecureField("Password \(isSignUp ? "(8+ characters)" : "")", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)
                        .styledField()
                }

                Button {
                    Task {
                        isLoading = true
                        if isSignUp {
                            await authManager.signUp(
                                email: email,
                                password: password,
                                displayName: displayName
                            )
                        } else {
                            await authManager.signIn(email: email, password: password)
                        }
                        isLoading = false
                    }
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
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
        }
        .navigationTitle(isSignUp ? "Create Account" : "Sign In")
        .navigationBarTitleDisplayMode(.inline)
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
