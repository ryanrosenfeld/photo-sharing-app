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
        ZStack {
            OttoColor.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Picker("Mode", selection: $isSignUp) {
                        Text("Sign In").tag(false)
                        Text("Create Account").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 8)

                    VStack(spacing: 12) {
                        if isSignUp {
                            ottoField("Name", text: $displayName, contentType: .name)
                        }
                        ottoField("Email", text: $email, contentType: .emailAddress, keyboard: .emailAddress)
                        ottoField("Password", text: $password, contentType: isSignUp ? .newPassword : .password, isSecure: true)
                    }

                    Button {
                        Task {
                            isLoading = true
                            if isSignUp {
                                await authManager.signUp(email: email, password: password, displayName: displayName)
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
                                Text(isSignUp ? "Create account" : "Sign in")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(isFormValid ? OttoColor.ink : OttoColor.chip)
                        .foregroundStyle(isFormValid ? OttoColor.canvas : OttoColor.barkSoft)
                        .clipShape(Capsule())
                    }
                    .disabled(!isFormValid || isLoading)
                    .accessibilityIdentifier("emailAuth.submit")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
            }
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

    private func ottoField(
        _ placeholder: String,
        text: Binding<String>,
        contentType: UITextContentType,
        keyboard: UIKeyboardType = .default,
        isSecure: Bool = false
    ) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
                    .textContentType(contentType)
            } else {
                TextField(placeholder, text: text)
                    .textContentType(contentType)
                    .keyboardType(keyboard)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
        }
        .accessibilityIdentifier("emailAuth.\(placeholder.lowercased())")
        .font(.system(size: 16))
        .foregroundStyle(OttoColor.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(OttoColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(OttoColor.line, lineWidth: 1))
    }
}

#Preview {
    NavigationStack { EmailAuthView() }.environmentObject(AuthManager())
}
