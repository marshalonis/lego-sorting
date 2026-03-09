import Foundation
import Security

@MainActor
class AuthService: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isNewPasswordRequired = false

    private(set) var config: CognitoConfig?
    private var challengeSession: String?
    private var challengeEmail: String?

    private let baseURL = "https://bootiak.org"
    private let cognitoURL = "https://cognito-idp.us-east-1.amazonaws.com/"

    init() {
        isLoggedIn = accessToken != nil
        Task { await loadConfig() }
    }

    // MARK: - Config

    func loadConfig() async {
        guard let url = URL(string: "\(baseURL)/api/config") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            config = try JSONDecoder().decode(CognitoConfig.self, from: data)
        } catch {}
    }

    // MARK: - Login

    func login(email: String, password: String) async throws {
        guard let config else { throw AuthError.noConfig }

        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "AuthParameters": ["USERNAME": email, "PASSWORD": password],
            "ClientId": config.clientID,
        ]
        let data = try await cognitoCall("InitiateAuth", body: body)

        if let challenge = data["ChallengeName"] as? String,
           challenge == "NEW_PASSWORD_REQUIRED" {
            challengeSession = data["Session"] as? String
            challengeEmail = email
            isNewPasswordRequired = true
            return
        }

        if let result = data["AuthenticationResult"] as? [String: Any] {
            storeTokens(result)
            isLoggedIn = true
            return
        }

        throw AuthError.loginFailed(data["message"] as? String ?? "Login failed")
    }

    func submitNewPassword(_ newPassword: String) async throws {
        guard let config,
              let session = challengeSession,
              let email = challengeEmail else { throw AuthError.noConfig }

        let body: [String: Any] = [
            "ChallengeName": "NEW_PASSWORD_REQUIRED",
            "ClientId": config.clientID,
            "Session": session,
            "ChallengeResponses": ["USERNAME": email, "NEW_PASSWORD": newPassword],
        ]
        let data = try await cognitoCall("RespondToAuthChallenge", body: body)

        if let result = data["AuthenticationResult"] as? [String: Any] {
            storeTokens(result)
            isNewPasswordRequired = false
            isLoggedIn = true
            return
        }

        throw AuthError.loginFailed(data["message"] as? String ?? "Failed to set password")
    }

    func refreshAccessToken() async -> Bool {
        guard let rt = refreshToken, let config else { return false }

        let body: [String: Any] = [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "AuthParameters": ["REFRESH_TOKEN": rt],
            "ClientId": config.clientID,
        ]
        do {
            let data = try await cognitoCall("InitiateAuth", body: body)
            if let result = data["AuthenticationResult"] as? [String: Any],
               let token = result["AccessToken"] as? String {
                accessToken = token
                return true
            }
        } catch {}
        return false
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        isLoggedIn = false
    }

    // MARK: - Keychain

    var accessToken: String? {
        get { keychainGet("lego_access_token") }
        set {
            if let v = newValue { keychainSet("lego_access_token", value: v) }
            else { keychainDelete("lego_access_token") }
        }
    }

    var refreshToken: String? {
        get { keychainGet("lego_refresh_token") }
        set {
            if let v = newValue { keychainSet("lego_refresh_token", value: v) }
            else { keychainDelete("lego_refresh_token") }
        }
    }

    private func storeTokens(_ result: [String: Any]) {
        if let t = result["AccessToken"] as? String { accessToken = t }
        if let t = result["RefreshToken"] as? String { refreshToken = t }
    }

    private func keychainGet(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func keychainSet(_ key: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func keychainDelete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Cognito HTTP

    private func cognitoCall(_ target: String, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: cognitoURL)!)
        req.httpMethod = "POST"
        req.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "X-Amz-Target")
        req.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case noConfig
        case loginFailed(String)

        var errorDescription: String? {
            switch self {
            case .noConfig: return "Could not load app configuration"
            case .loginFailed(let msg): return msg
            }
        }
    }
}
