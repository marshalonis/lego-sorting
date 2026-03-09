import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthService
    @State private var email = ""
    @State private var password = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("🧱").font(.system(size: 64))
            Text("LEGO Sorter")
                .font(.largeTitle.bold())

            if auth.isNewPasswordRequired {
                newPasswordForm
            } else {
                loginForm
            }
            Spacer()
        }
        .padding(24)
    }

    private var loginForm: some View {
        VStack(spacing: 12) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Button(action: login) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Sign In")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || email.isEmpty || password.isEmpty)
            .controlSize(.large)
        }
    }

    private var newPasswordForm: some View {
        VStack(spacing: 12) {
            Text("First login — please set a new password.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            SecureField("New Password", text: $newPassword)
                .textFieldStyle(.roundedBorder)

            SecureField("Confirm Password", text: $confirmPassword)
                .textFieldStyle(.roundedBorder)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Button(action: submitNewPassword) {
                Group {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Set Password")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading || newPassword.isEmpty || confirmPassword.isEmpty)
            .controlSize(.large)
        }
    }

    private func login() {
        errorMessage = ""
        isLoading = true
        Task {
            do {
                try await auth.login(email: email, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func submitNewPassword() {
        guard newPassword == confirmPassword else {
            errorMessage = "Passwords do not match"
            return
        }
        errorMessage = ""
        isLoading = true
        Task {
            do {
                try await auth.submitNewPassword(newPassword)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}
