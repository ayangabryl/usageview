import Foundation
import Security
import CryptoKit
import AppKit
import os

private let authLogger = Logger(subsystem: "com.ayangabryl.usage", category: "AnthropicAuth")

struct ClaudeAccountInfo: Sendable {
    var email: String?
    var name: String?
}

/// Credentials read from the Claude Code CLI's macOS Keychain entry.
struct ClaudeCLICredentials: Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Double? // seconds since 1970
}

@Observable
@MainActor
final class AnthropicAuthService: Sendable {
    var isLoading: Bool = false
    private static let allowCLIKeychainAccessDefaultsKey = "allowClaudeCLIKeychainAccess"
    private var suppressCLIKeychainReadsThisSession = false
    var isCLIKeychainReadSuppressed: Bool { suppressCLIKeychainReadsThisSession }

    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    /// Official token endpoint used by Claude Code CLI
    private let tokenRefreshURL = "https://platform.claude.com/v1/oauth/token"

    private var pkceVerifiers: [UUID: String] = [:]

    // MARK: - Multi-Account Auth

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: refreshKey(for: accountId)) != nil
            || loadToken(key: apiKeyKey(for: accountId)) != nil
    }

    // MARK: - Claude Code CLI Credentials

    /// Read OAuth credentials stored by Claude Code CLI in macOS Keychain
    func readClaudeCLICredentials() -> ClaudeCLICredentials? {
        // Prefer file credentials first to avoid macOS keychain permission prompts.
        if let fileCreds = readClaudeFileCredentials() {
            return fileCreds
        }

        guard UserDefaults.standard.bool(forKey: Self.allowCLIKeychainAccessDefaultsKey) else {
            authLogger.debug("Claude CLI keychain access disabled by preference")
            return nil
        }

        guard !suppressCLIKeychainReadsThisSession else {
            authLogger.debug("Skipping Claude CLI keychain read for this session")
            return nil
        }

        let serviceNames = [
            "Claude Code-credentials",
            // Fallback: hashed config dir variant
        ]

        for serviceName in serviceNames {
            if let creds = readKeychainGenericPassword(service: serviceName) {
                return creds
            }
        }

        return nil
    }

    func resetCLIKeychainReadSuppression() {
        suppressCLIKeychainReadsThisSession = false
    }

    private func readKeychainGenericPassword(service: String) -> ClaudeCLICredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
                suppressCLIKeychainReadsThisSession = true
                authLogger.info("Suppressing Claude CLI keychain reads for this session (status \(status))")
            }
            authLogger.debug("Keychain read for '\(service)' returned status \(status)")
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            authLogger.debug("Keychain data for '\(service)' is not valid JSON")
            return nil
        }

        // Claude Code stores credentials under "claudeAiOauth" nested key
        let creds = (json["claudeAiOauth"] as? [String: Any]) ?? json

        guard let accessToken = creds["accessToken"] as? String, !accessToken.isEmpty else {
            authLogger.debug("No accessToken in Keychain entry '\(service)'")
            return nil
        }

        let refreshToken = creds["refreshToken"] as? String
        let expiresAt = creds["expiresAt"] as? Double

        authLogger.info("Read Claude CLI credentials from Keychain '\(service)'")
        return ClaudeCLICredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt
        )
    }

    private func readClaudeFileCredentials() -> ClaudeCLICredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credPath = home.appendingPathComponent(".claude/.credentials.json")

        guard let data = try? Data(contentsOf: credPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let creds = (json["claudeAiOauth"] as? [String: Any]) ?? json

        guard let accessToken = creds["accessToken"] as? String, !accessToken.isEmpty else {
            return nil
        }

        authLogger.info("Read Claude CLI credentials from file")
        return ClaudeCLICredentials(
            accessToken: accessToken,
            refreshToken: creds["refreshToken"] as? String,
            expiresAt: creds["expiresAt"] as? Double
        )
    }

    /// Refresh a Claude CLI token using the official platform.claude.com endpoint
    func refreshCLIToken(_ refreshToken: String) async -> ClaudeCLICredentials? {
        guard let url = URL(string: tokenRefreshURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken)",
            "client_id=\(clientId)"
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccess = json["access_token"] as? String
            else {
                authLogger.error("CLI token refresh failed")
                return nil
            }

            let newRefresh = json["refresh_token"] as? String ?? refreshToken
            let expiresIn = json["expires_in"] as? Double
            let expiresAt = expiresIn.map { Date.now.timeIntervalSince1970 + $0 }

            authLogger.info("CLI token refreshed successfully")
            return ClaudeCLICredentials(
                accessToken: newAccess,
                refreshToken: newRefresh,
                expiresAt: expiresAt
            )
        } catch {
            authLogger.error("CLI token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Get a valid access token for usage API, preferring Claude CLI credentials
    func getValidTokenPreferCLI(for accountId: UUID) async -> String? {
        // First, try Claude Code CLI credentials (most accurate usage data)
        if let cliCreds = readClaudeCLICredentials() {
            let now = Date.now.timeIntervalSince1970

            // Check if token is still valid
            if let expiresAt = cliCreds.expiresAt, expiresAt > now {
                authLogger.info("Using valid Claude CLI token for usage")
                return cliCreds.accessToken
            }

            // Token expired, try to refresh
            if let refreshToken = cliCreds.refreshToken {
                if let refreshed = await refreshCLIToken(refreshToken) {
                    authLogger.info("Using refreshed Claude CLI token for usage")
                    return refreshed.accessToken
                }
            }

            // Token might still work even if we can't verify expiry
            if cliCreds.expiresAt == nil {
                authLogger.info("Using Claude CLI token (no expiry info) for usage")
                return cliCreds.accessToken
            }
        }

        // Fall back to our own OAuth token
        return await getValidToken(for: accountId)
    }

    // MARK: - API Key Auth

    /// Store a user-provided Anthropic API key
    func saveAPIKey(_ key: String, for accountId: UUID) -> ClaudeAccountInfo {
        saveToken(key: apiKeyKey(for: accountId), value: key)
        let masked = key.count > 8
            ? String(key.prefix(8)) + "..."
            : key
        return ClaudeAccountInfo(email: nil, name: masked)
    }

    /// Retrieve the stored API key
    func getAPIKey(for accountId: UUID) -> String? {
        loadToken(key: apiKeyKey(for: accountId))
    }

    /// Verify an Anthropic API key is valid by calling /v1/models
    func verifyAPIKey(for accountId: UUID) async -> Bool {
        guard let key = getAPIKey(for: accountId) else { return false }

        let url = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    /// Step 1: Generate PKCE and open browser for authorization
    func startOAuth(for accountId: UUID) {
        let verifier = generateCodeVerifier()
        pkceVerifiers[accountId] = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Step 2: Exchange the authorization code for tokens, then fetch profile
    func exchangeCode(_ rawCode: String, for accountId: UUID) async -> ClaudeAccountInfo? {
        guard let verifier = pkceVerifiers[accountId] else { return nil }
        isLoading = true
        defer { isLoading = false }

        let code = rawCode.split(separator: "#").first.map(String.init) ?? rawCode
        let state = rawCode.contains("#") ? String(rawCode.split(separator: "#").last ?? "") : nil

        let url = URL(string: tokenRefreshURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = [
            "code": code,
            "grant_type": "authorization_code",
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        if let state { body["state"] = state }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newAccess = json["access_token"] as? String,
               let newRefresh = json["refresh_token"] as? String,
               let expiresIn = json["expires_in"] as? Double {
                saveToken(key: accessKey(for: accountId), value: newAccess)
                saveToken(key: refreshKey(for: accountId), value: newRefresh)
                UserDefaults.standard.set(
                    Date.now.timeIntervalSince1970 + expiresIn,
                    forKey: expiresKey(for: accountId)
                )
                pkceVerifiers.removeValue(forKey: accountId)

                // 1) Check for user info embedded directly in the token response
                var info = extractUserFromTokenResponse(json)

                // 2) Try id_token JWT decode
                if info == nil, let idToken = json["id_token"] as? String {
                    info = extractJWTClaims(from: idToken)
                }

                // 3) Try access_token JWT decode
                if info == nil {
                    info = extractJWTClaims(from: newAccess)
                }

                // 4) Try userinfo endpoints
                if info == nil {
                    info = await fetchUserProfile(token: newAccess)
                }

                // 5) Try console session endpoint
                if info == nil {
                    info = await fetchConsoleIdentity(token: newAccess)
                }

                return info ?? ClaudeAccountInfo()
            }
        } catch {}
        return nil
    }

    /// Extract user info from the token exchange response body itself
    private func extractUserFromTokenResponse(_ json: [String: Any]) -> ClaudeAccountInfo? {
        // Check for inline user info fields
        let email = json["email"] as? String
        let name = json["name"] as? String
            ?? json["full_name"] as? String
            ?? json["display_name"] as? String
            ?? json["preferred_username"] as? String

        // Check for nested user object
        if let user = json["user"] as? [String: Any] {
            let uEmail = user["email"] as? String ?? email
            let uName = user["name"] as? String
                ?? user["full_name"] as? String
                ?? user["display_name"] as? String
                ?? name
            if uEmail != nil || uName != nil {
                return ClaudeAccountInfo(email: uEmail, name: uName)
            }
        }

        if email != nil || name != nil {
            return ClaudeAccountInfo(email: email, name: name)
        }
        return nil
    }

    /// Try the console session endpoint for identity
    private func fetchConsoleIdentity(token: String) async -> ClaudeAccountInfo? {
        let endpoints = [
            "https://console.anthropic.com/api/account",
            "https://console.anthropic.com/api/auth/session"
        ]

        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let email = json["email"] as? String
                    ?? (json["user"] as? [String: Any])?["email"] as? String
                let name = json["name"] as? String
                    ?? json["full_name"] as? String
                    ?? (json["user"] as? [String: Any])?["name"] as? String
                    ?? (json["user"] as? [String: Any])?["full_name"] as? String

                if email != nil || name != nil {
                    return ClaudeAccountInfo(email: email, name: name)
                }
            } catch { continue }
        }
        return nil
    }

    /// Fetch user profile info from Anthropic
    func fetchUserProfile(for accountId: UUID) async -> ClaudeAccountInfo? {
        guard let token = await getValidToken(for: accountId) else { return nil }
        return await fetchUserProfile(token: token)
    }

    private func fetchUserProfile(token: String) async -> ClaudeAccountInfo? {
        // Try multiple userinfo endpoints
        let urls = [
            "https://api.anthropic.com/api/oauth/userinfo",
            "https://claude.ai/api/auth/current_account"
        ]

        for urlStr in urls {
            guard let url = URL(string: urlStr) else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                // Standard OIDC claims + common alternatives
                let email = json["email"] as? String
                    ?? json["email_address"] as? String
                let name = json["name"] as? String
                    ?? json["full_name"] as? String
                    ?? json["display_name"] as? String
                    ?? json["preferred_username"] as? String
                    ?? json["given_name"] as? String

                // Also check nested account object
                if let account = json["account"] as? [String: Any] {
                    let aEmail = account["email_address"] as? String ?? email
                    let aName = account["name"] as? String
                        ?? account["full_name"] as? String
                        ?? name
                    if aEmail != nil || aName != nil {
                        return ClaudeAccountInfo(email: aEmail, name: aName)
                    }
                }

                if email != nil || name != nil {
                    return ClaudeAccountInfo(email: email, name: name)
                }
            } catch { continue }
        }
        return nil
    }

    /// Refresh the access token if expired, returns a valid access token
    func getValidToken(for accountId: UUID) async -> String? {
        guard let refresh = loadToken(key: refreshKey(for: accountId)) else { return nil }

        let expiresAt = UserDefaults.standard.double(forKey: expiresKey(for: accountId))
        // Use cached token only if it exists AND has a valid future expiry
        if expiresAt > 0,
           let access = loadToken(key: accessKey(for: accountId)),
           Date.now.timeIntervalSince1970 < expiresAt {
            return access
        }

        // Token expired, refresh it
        let url = URL(string: tokenRefreshURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientId
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newAccess = json["access_token"] as? String,
               let newRefresh = json["refresh_token"] as? String,
               let expiresIn = json["expires_in"] as? Double {
                saveToken(key: accessKey(for: accountId), value: newAccess)
                saveToken(key: refreshKey(for: accountId), value: newRefresh)
                UserDefaults.standard.set(
                    Date.now.timeIntervalSince1970 + expiresIn,
                    forKey: expiresKey(for: accountId)
                )
                return newAccess
            }
        } catch {}
        return nil
    }

    func disconnect(accountId: UUID) {
        removeToken(key: accessKey(for: accountId))
        removeToken(key: refreshKey(for: accountId))
        removeToken(key: apiKeyKey(for: accountId))
        UserDefaults.standard.removeObject(forKey: expiresKey(for: accountId))
        pkceVerifiers.removeValue(forKey: accountId)
    }

    // MARK: - Per-Account Key Helpers

    private func accessKey(for id: UUID) -> String {
        "com.ayangabryl.usage.anthropic-access-\(id.uuidString)"
    }

    private func refreshKey(for id: UUID) -> String {
        "com.ayangabryl.usage.anthropic-refresh-\(id.uuidString)"
    }

    private func expiresKey(for id: UUID) -> String {
        "anthropic_token_expires_\(id.uuidString)"
    }

    private func apiKeyKey(for id: UUID) -> String {
        "com.ayangabryl.usage.anthropic-apikey-\(id.uuidString)"
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - JWT Identity Extraction

    private func extractJWTClaims(from jwt: String) -> ClaudeAccountInfo? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let email = json["email"] as? String
            ?? json["email_address"] as? String
        let name = json["name"] as? String
            ?? json["full_name"] as? String
            ?? json["preferred_username"] as? String
            ?? json["given_name"] as? String

        // Use 'sub' claim as a last-resort identifier
        let sub = json["sub"] as? String

        if email != nil || name != nil {
            return ClaudeAccountInfo(email: email, name: name)
        } else if let sub {
            // sub might be an email or user ID
            let displaySub = sub.contains("@") ? sub : nil
            return ClaudeAccountInfo(email: displaySub, name: displaySub == nil ? sub : nil)
        }
        return nil
    }

    // MARK: - Token Storage

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
