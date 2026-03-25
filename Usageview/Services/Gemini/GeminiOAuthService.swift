import Foundation
import Security
import CryptoKit
import AppKit
import os

private let geminiOAuthLogger = Logger(subsystem: "com.ayangabryl.usage", category: "GeminiOAuth")

// MARK: - Data Models

struct GeminiOAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresAt: Double? // seconds since 1970
}

struct GeminiTokenClaims: Sendable {
    let email: String?
    let hostedDomain: String?
}

enum GeminiUserTier: String, Sendable {
    case free = "free-tier"
    case legacy = "legacy-tier"
    case standard = "standard-tier"
}

struct GeminiModelQuota: Sendable {
    let modelId: String
    let percentLeft: Double
    let resetTime: Date?
    let resetDescription: String?
}

struct GeminiQuotaSnapshot: Sendable {
    let modelQuotas: [GeminiModelQuota]
    let accountEmail: String?
    let accountPlan: String?

    var lowestPercentLeft: Double? {
        modelQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.percentLeft
    }

    var proQuotas: [GeminiModelQuota] {
        modelQuotas.filter { $0.modelId.lowercased().contains("pro") }
    }

    var flashQuotas: [GeminiModelQuota] {
        modelQuotas.filter { $0.modelId.lowercased().contains("flash") }
    }

    var proPercentLeft: Double? {
        proQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.percentLeft
    }

    var flashPercentLeft: Double? {
        flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })?.percentLeft
    }

    var earliestReset: Date? {
        modelQuotas.compactMap(\.resetTime).min()
    }

    var proResetTime: Date? {
        proQuotas.compactMap(\.resetTime).min()
    }

    var flashResetTime: Date? {
        flashQuotas.compactMap(\.resetTime).min()
    }
}

enum GeminiOAuthError: LocalizedError {
    case notLoggedIn
    case unsupportedAuthType(String)
    case tokenExpiredNoRefresh
    case apiError(String)
    case parseFailed(String)
    case oauthFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            "Not logged in to Gemini. Sign in with your Google account."
        case .unsupportedAuthType(let type):
            "Gemini \(type) auth not supported. Use Google account (OAuth) instead."
        case .tokenExpiredNoRefresh:
            "Session expired. Please sign in again."
        case .apiError(let msg):
            "Gemini API error: \(msg)"
        case .parseFailed(let msg):
            "Could not parse Gemini response: \(msg)"
        case .oauthFailed(let msg):
            "OAuth failed: \(msg)"
        case .cancelled:
            "Authentication was cancelled."
        }
    }
}

// MARK: - OAuth Service (Direct Google OAuth)

@MainActor
final class GeminiOAuthService: Sendable {
    private static let allowCLIKeychainAccessDefaultsKey = "allowGeminiCLIKeychainAccess"
    private var suppressCLIKeychainReadsThisSession = false
    var isCLIKeychainReadSuppressed: Bool { suppressCLIKeychainReadsThisSession }

    // Same OAuth client ID/secret used by Gemini CLI (public installed-app credentials)
    // See: https://developers.google.com/identity/protocols/oauth2#installed
    static let oauthClientId = "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    static let oauthClientSecret = "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"

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let userInfoURL = "https://www.googleapis.com/oauth2/v2/userinfo"

    private static let scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile",
    ]

    static let successRedirectURL = "https://developers.google.com/gemini-code-assist/auth_success_gemini"
    static let failureRedirectURL = "https://developers.google.com/gemini-code-assist/auth_failure_gemini"

    private static let quotaEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let projectsEndpoint = "https://cloudresourcemanager.googleapis.com/v1/projects"
    private static let timeout: TimeInterval = 10.0

    var callbackServer: GeminiOAuthCallbackServer?

    // MARK: - Direct Google OAuth Flow

    /// Start the Google OAuth flow: opens browser, starts local callback server
    func startOAuthFlow() async throws -> (code: String, codeVerifier: String, redirectURI: String) {
        // Generate PKCE
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(from: codeVerifier)
        let state = generateState()

        // Start local callback server
        let server = try GeminiOAuthCallbackServer()
        self.callbackServer = server

        let redirectURI = "http://127.0.0.1:\(server.port)/oauth2callback"

        // Build auth URL
        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.oauthClientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let authURL = components.url else {
            throw GeminiOAuthError.oauthFailed("Could not construct auth URL")
        }

        // Open browser
        geminiOAuthLogger.info("Opening Google OAuth in browser")
        NSWorkspace.shared.open(authURL)

        // Wait for the callback (with 5-minute timeout)
        let code = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await server.waitForCode()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                throw GeminiOAuthError.oauthFailed("Authentication timed out after 5 minutes")
            }

            guard let result = try await group.next() else {
                throw GeminiOAuthError.oauthFailed("No result from OAuth flow")
            }
            group.cancelAll()
            return result
        }

        return (code, codeVerifier, redirectURI)
    }

    /// Exchange the authorization code for tokens
    func exchangeCodeForTokens(
        code: String,
        codeVerifier: String,
        redirectURI: String,
        for accountId: UUID
    ) async throws -> GeminiAccountInfo {
        guard let url = URL(string: Self.tokenURL) else {
            throw GeminiOAuthError.oauthFailed("Invalid token URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout

        let body = [
            "code=\(code)",
            "client_id=\(Self.oauthClientId)",
            "client_secret=\(Self.oauthClientSecret)",
            "redirect_uri=\(redirectURI)",
            "grant_type=authorization_code",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            geminiOAuthLogger.error("Token exchange failed: \(bodyStr)")
            throw GeminiOAuthError.oauthFailed("Token exchange failed")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else {
            throw GeminiOAuthError.parseFailed("Could not parse token response")
        }

        let refreshToken = json["refresh_token"] as? String
        let idToken = json["id_token"] as? String
        let expiresIn = json["expires_in"] as? Double
        let expiresAt = expiresIn.map { Date.now.timeIntervalSince1970 + $0 }

        // Store tokens in keychain
        saveToken(key: accessTokenKey(for: accountId), value: accessToken)
        if let refreshToken {
            saveToken(key: refreshTokenKey(for: accountId), value: refreshToken)
        }
        if let expiresAt {
            UserDefaults.standard.set(expiresAt, forKey: expiresAtKey(for: accountId))
        }

        // Extract email from ID token or fetch user info
        var email: String?
        if let idToken {
            let claims = extractClaimsFromToken(idToken)
            email = claims.email
        }
        if email == nil {
            email = await fetchUserEmail(accessToken: accessToken)
        }

        geminiOAuthLogger.info("Google OAuth tokens stored for account \(accountId.uuidString)")

        // Clean up server
        callbackServer?.stop()
        callbackServer = nil

        return GeminiAccountInfo(
            name: email ?? "Google Account",
            email: email,
            isOAuth: true
        )
    }

    /// Cancel any in-progress OAuth flow
    func cancelOAuth() {
        callbackServer?.stop()
        callbackServer = nil
    }

    // MARK: - Token Management

    /// Get a valid access token, refreshing if needed. Also tries CLI credentials as fallback.
    func getValidToken(for accountId: UUID) async -> String? {
        // Check our stored tokens first
        if let access = loadToken(key: accessTokenKey(for: accountId)) {
            let expiresAt = UserDefaults.standard.double(forKey: expiresAtKey(for: accountId))
            if expiresAt == 0 || Date.now.timeIntervalSince1970 < expiresAt {
                return access
            }

            // Token expired, try refresh
            if let refresh = loadToken(key: refreshTokenKey(for: accountId)) {
                if let newAccess = await refreshAccessToken(refreshToken: refresh, for: accountId) {
                    return newAccess
                }
            }
        }

        // Fallback: try Gemini CLI credentials from keychain or file
        if let cliToken = await getTokenFromCLI(for: accountId) {
            return cliToken
        }

        return nil
    }

    /// Try to read credentials from Gemini CLI (keychain or file)
    private func getTokenFromCLI(for accountId: UUID) async -> String? {
        // Try ~/.gemini/oauth_creds.json file
        if let fileCreds = readCLICredentialsFromFile() {
            if let expiryMs = fileCreds.expiresAt,
               Date(timeIntervalSince1970: expiryMs / 1000) < Date() {
                if let refreshToken = fileCreds.refreshToken {
                    if let newAccess = await refreshAccessToken(refreshToken: refreshToken, for: accountId) {
                        return newAccess
                    }
                }
            } else {
                return fileCreds.accessToken
            }
        }

        guard UserDefaults.standard.bool(forKey: Self.allowCLIKeychainAccessDefaultsKey) else {
            geminiOAuthLogger.debug("Gemini CLI keychain access disabled by preference")
            return nil
        }

        guard !suppressCLIKeychainReadsThisSession else {
            geminiOAuthLogger.debug("Skipping Gemini CLI keychain read for this session")
            return nil
        }

        // Try macOS Keychain (gemini-cli-oauth service)
        if let keychainCreds = readCLICredentialsFromKeychain() {
            if let expiresAt = keychainCreds.expiresAt,
               expiresAt <= Date.now.timeIntervalSince1970 * 1000 {
                if let refreshToken = keychainCreds.refreshToken {
                    if let newAccess = await refreshAccessToken(refreshToken: refreshToken, for: accountId) {
                        return newAccess
                    }
                }
            } else {
                return keychainCreds.accessToken
            }
        }

        return nil
    }

    private func readCLICredentialsFromKeychain() -> GeminiOAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini-cli-oauth",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecAuthFailed || status == errSecUserCanceled || status == errSecInteractionNotAllowed {
                suppressCLIKeychainReadsThisSession = true
                geminiOAuthLogger.info("Suppressing Gemini CLI keychain reads for this session (status \(status))")
            }
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let tokenData = (json["main-account"] as? [String: Any])
            ?? (json["token"] as? [String: Any])
            ?? json

        guard let accessToken = tokenData["accessToken"] as? String
            ?? tokenData["access_token"] as? String,
              !accessToken.isEmpty
        else { return nil }

        geminiOAuthLogger.info("Read Gemini CLI credentials from Keychain")
        return GeminiOAuthCredentials(
            accessToken: accessToken,
            refreshToken: tokenData["refreshToken"] as? String ?? tokenData["refresh_token"] as? String,
            idToken: tokenData["id_token"] as? String,
            expiresAt: tokenData["expiresAt"] as? Double ?? tokenData["expiry_date"] as? Double
        )
    }

    private func readCLICredentialsFromFile() -> GeminiOAuthCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let credsPaths = [
            home.appendingPathComponent(".gemini/oauth_creds.json"),
            home.appendingPathComponent(".gemini/.credentials.json"),
        ]

        for credsPath in credsPaths {
            guard let data = try? Data(contentsOf: credsPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else { continue }

            geminiOAuthLogger.info("Read Gemini CLI credentials from \(credsPath.lastPathComponent)")
            return GeminiOAuthCredentials(
                accessToken: accessToken,
                refreshToken: json["refresh_token"] as? String,
                idToken: json["id_token"] as? String,
                expiresAt: json["expiry_date"] as? Double
            )
        }

        return nil
    }

    func resetCLIKeychainReadSuppression() {
        suppressCLIKeychainReadsThisSession = false
    }

    func hasCredentials(for accountId: UUID) -> Bool {
        loadToken(key: refreshTokenKey(for: accountId)) != nil
            || loadToken(key: accessTokenKey(for: accountId)) != nil
    }

    func removeTokens(for accountId: UUID) {
        removeToken(key: accessTokenKey(for: accountId))
        removeToken(key: refreshTokenKey(for: accountId))
        UserDefaults.standard.removeObject(forKey: expiresAtKey(for: accountId))
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(refreshToken: String, for accountId: UUID) async -> String? {
        guard let url = URL(string: Self.tokenURL) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout

        let body = [
            "client_id=\(Self.oauthClientId)",
            "client_secret=\(Self.oauthClientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newAccessToken = json["access_token"] as? String
            else { return nil }

            saveToken(key: accessTokenKey(for: accountId), value: newAccessToken)
            if let expiresIn = json["expires_in"] as? Double {
                let expiresAt = Date.now.timeIntervalSince1970 + expiresIn
                UserDefaults.standard.set(expiresAt, forKey: expiresAtKey(for: accountId))
            }
            if let newRefresh = json["refresh_token"] as? String {
                saveToken(key: refreshTokenKey(for: accountId), value: newRefresh)
            }

            geminiOAuthLogger.info("Gemini OAuth: token refreshed successfully")
            return newAccessToken
        } catch {
            geminiOAuthLogger.error("Gemini token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - User Info

    private func fetchUserEmail(accessToken: String) async -> String? {
        guard let url = URL(string: Self.userInfoURL) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            return json["email"] as? String
        } catch {
            return nil
        }
    }

    // MARK: - Fetch Quota

    func fetchQuota(for accountId: UUID) async throws -> GeminiQuotaSnapshot {
        guard let accessToken = await getValidToken(for: accountId) else {
            throw GeminiOAuthError.notLoggedIn
        }

        let email = await fetchUserEmail(accessToken: accessToken)
        let caStatus = await loadCodeAssistStatus(accessToken: accessToken)

        var projectId = caStatus.projectId
        if projectId == nil {
            projectId = try? await discoverGeminiProjectId(accessToken: accessToken)
        }

        let snapshot = try await fetchQuotaAPI(accessToken: accessToken, projectId: projectId, email: email)

        let plan: String? = switch (caStatus.tier, email?.contains("@gmail.com")) {
        case (.standard, _): "Paid"
        case (.free, .some(false)): "Workspace"
        case (.free, _): "Free"
        case (.legacy, _): "Legacy"
        case (.none, _): nil
        }

        return GeminiQuotaSnapshot(
            modelQuotas: snapshot.modelQuotas,
            accountEmail: snapshot.accountEmail,
            accountPlan: plan ?? snapshot.accountPlan
        )
    }

    // MARK: - Code Assist Status

    private struct CodeAssistStatus {
        let tier: GeminiUserTier?
        let projectId: String?
        static let empty = CodeAssistStatus(tier: nil, projectId: nil)
    }

    private func loadCodeAssistStatus(accessToken: String) async -> CodeAssistStatus {
        guard let url = URL(string: Self.loadCodeAssistEndpoint) else { return .empty }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        request.timeoutInterval = Self.timeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return .empty }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .empty }

            let rawProjectId: String? = {
                if let project = json["cloudaicompanionProject"] as? String { return project }
                if let project = json["cloudaicompanionProject"] as? [String: Any] {
                    if let projectId = project["id"] as? String { return projectId }
                    if let projectId = project["projectId"] as? String { return projectId }
                }
                return nil
            }()
            let projectId: String? = {
                guard let raw = rawProjectId?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw
            }()

            let tierId = (json["currentTier"] as? [String: Any])?["id"] as? String
            let tier = tierId.flatMap { GeminiUserTier(rawValue: $0) }

            geminiOAuthLogger.info("Gemini loadCodeAssist: tier=\(tierId ?? "nil"), project=\(projectId ?? "nil")")
            return CodeAssistStatus(tier: tier, projectId: projectId)
        } catch {
            geminiOAuthLogger.warning("Gemini loadCodeAssist failed: \(error)")
            return .empty
        }
    }

    // MARK: - Project Discovery

    private func discoverGeminiProjectId(accessToken: String) async throws -> String? {
        guard let url = URL(string: Self.projectsEndpoint) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]]
        else { return nil }

        for project in projects {
            guard let projectId = project["projectId"] as? String else { continue }
            if projectId.hasPrefix("gen-lang-client") { return projectId }
            if let labels = project["labels"] as? [String: String],
               labels["generative-language"] != nil { return projectId }
        }
        return nil
    }

    // MARK: - Quota API

    private func fetchQuotaAPI(accessToken: String, projectId: String?, email: String?) async throws -> GeminiQuotaSnapshot {
        guard let url = URL(string: Self.quotaEndpoint) else {
            throw GeminiOAuthError.apiError("Invalid endpoint URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = Self.timeout

        if let projectId {
            request.httpBody = Data("{\"project\": \"\(projectId)\"}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiOAuthError.apiError("Invalid response")
        }

        if http.statusCode == 401 { throw GeminiOAuthError.notLoggedIn }
        guard http.statusCode == 200 else {
            throw GeminiOAuthError.apiError("HTTP \(http.statusCode)")
        }

        return try parseQuotaResponse(data, email: email)
    }

    // MARK: - Response Parsing

    private struct QuotaBucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let modelId: String?
        let tokenType: String?
    }

    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private func parseQuotaResponse(_ data: Data, email: String?) throws -> GeminiQuotaSnapshot {
        let response = try JSONDecoder().decode(QuotaResponse.self, from: data)
        guard let buckets = response.buckets, !buckets.isEmpty else {
            throw GeminiOAuthError.parseFailed("No quota buckets in response")
        }

        var modelQuotaMap: [String: (fraction: Double, resetString: String?)] = [:]
        for bucket in buckets {
            guard let modelId = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = modelQuotaMap[modelId] {
                if fraction < existing.fraction {
                    modelQuotaMap[modelId] = (fraction, bucket.resetTime)
                }
            } else {
                modelQuotaMap[modelId] = (fraction, bucket.resetTime)
            }
        }

        let quotas = modelQuotaMap
            .sorted { $0.key < $1.key }
            .map { modelId, info in
                let resetDate = info.resetString.flatMap { parseResetTime($0) }
                return GeminiModelQuota(
                    modelId: modelId,
                    percentLeft: info.fraction * 100,
                    resetTime: resetDate,
                    resetDescription: info.resetString.flatMap { formatResetTime($0) }
                )
            }

        return GeminiQuotaSnapshot(modelQuotas: quotas, accountEmail: email, accountPlan: nil)
    }

    // MARK: - Time Formatting

    private func parseResetTime(_ isoString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }

    private func formatResetTime(_ isoString: String) -> String {
        guard let resetDate = parseResetTime(isoString) else { return "Resets soon" }
        let interval = resetDate.timeIntervalSince(Date())
        if interval <= 0 { return "Resets soon" }
        let hours = Int(interval / 3600)
        let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
        return "Resets in \(minutes)m"
    }

    // MARK: - JWT Claims

    private func extractClaimsFromToken(_ idToken: String?) -> GeminiTokenClaims {
        guard let token = idToken else { return GeminiTokenClaims(email: nil, hostedDomain: nil) }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return GeminiTokenClaims(email: nil, hostedDomain: nil) }

        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }

        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return GeminiTokenClaims(email: nil, hostedDomain: nil) }

        return GeminiTokenClaims(
            email: json["email"] as? String,
            hostedDomain: json["hd"] as? String
        )
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

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Keychain Helpers

    private func accessTokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.gemini-oauth-access-\(id.uuidString)"
    }

    private func refreshTokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.gemini-oauth-refresh-\(id.uuidString)"
    }

    private func expiresAtKey(for id: UUID) -> String {
        "gemini_oauth_expires_\(id.uuidString)"
    }

    // MARK: - Keychain Storage

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}

// MARK: - Local OAuth Callback Server (POSIX sockets)

/// A minimal HTTP server on localhost using Darwin sockets to receive the Google OAuth callback.
/// Uses POSIX sockets instead of Network framework to avoid entitlement/permission issues.
final class GeminiOAuthCallbackServer: @unchecked Sendable {
    private var serverSocket: Int32 = -1
    private var assignedPort: UInt16 = 0
    private let serverQueue = DispatchQueue(label: "com.ayangabryl.usage.gemini-oauth-server")
    private var continuation: CheckedContinuation<String, Error>?
    private var isResolved = false
    private var isStopped = false
    private let lock = NSLock()

    init() throws {
        // Create TCP socket
        serverSocket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw GeminiOAuthError.oauthFailed("Could not create socket")
        }

        // Allow port reuse
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to 127.0.0.1 on port 0 (let OS assign)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverSocket)
            throw GeminiOAuthError.oauthFailed("Could not bind socket (errno \(errno))")
        }

        // Get the assigned port
        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverSocket, sockPtr, &addrLen)
            }
        }
        assignedPort = UInt16(bigEndian: boundAddr.sin_port)

        // Start listening
        guard Darwin.listen(serverSocket, 1) == 0 else {
            Darwin.close(serverSocket)
            throw GeminiOAuthError.oauthFailed("Could not listen on socket")
        }
    }

    var port: UInt16 { assignedPort }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            self.continuation = cont
            lock.unlock()

            serverQueue.async { [weak self] in
                self?.acceptLoop()
            }
        }
    }

    func stop() {
        lock.lock()
        isStopped = true
        lock.unlock()
        if serverSocket >= 0 {
            Darwin.close(serverSocket)
            serverSocket = -1
        }
    }

    private func resolve(with result: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return }
        isResolved = true
        switch result {
        case .success(let code): continuation?.resume(returning: code)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    private func acceptLoop() {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.accept(serverSocket, sockPtr, &addrLen)
            }
        }

        lock.lock()
        let stopped = isStopped
        lock.unlock()

        guard clientSocket >= 0 else {
            if !stopped {
                resolve(with: .failure(GeminiOAuthError.oauthFailed("Accept failed (errno \(errno))")))
            }
            return
        }

        // Read the HTTP request
        var buffer = [UInt8](repeating: 0, count: 8192)
        let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)

        guard bytesRead > 0, let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) else {
            sendResponse(socket: clientSocket, statusCode: 400, redirect: nil)
            Darwin.close(clientSocket)
            return
        }

        guard let firstLine = requestStr.components(separatedBy: "\r\n").first,
              let urlPart = firstLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(urlPart)")
        else {
            sendResponse(socket: clientSocket, statusCode: 400, redirect: nil)
            Darwin.close(clientSocket)
            return
        }

        let queryItems = components.queryItems ?? []

        if let errorParam = queryItems.first(where: { $0.name == "error" })?.value {
            let desc = queryItems.first(where: { $0.name == "error_description" })?.value ?? errorParam
            sendResponse(socket: clientSocket, statusCode: 302, redirect: GeminiOAuthService.failureRedirectURL)
            Darwin.close(clientSocket)
            stop()
            resolve(with: .failure(GeminiOAuthError.oauthFailed(desc)))
            return
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value else {
            sendResponse(socket: clientSocket, statusCode: 400, redirect: nil)
            Darwin.close(clientSocket)
            resolve(with: .failure(GeminiOAuthError.oauthFailed("No authorization code received")))
            return
        }

        sendResponse(socket: clientSocket, statusCode: 302, redirect: GeminiOAuthService.successRedirectURL)
        Darwin.close(clientSocket)
        stop()
        resolve(with: .success(code))
    }

    private func sendResponse(socket: Int32, statusCode: Int, redirect: String?) {
        var headers = "HTTP/1.1 \(statusCode) \(statusCode == 302 ? "Found" : "Bad Request")\r\n"
        if let redirect { headers += "Location: \(redirect)\r\n" }
        headers += "Content-Length: 0\r\nConnection: close\r\n\r\n"
        let data = Array(headers.utf8)
        _ = Darwin.write(socket, data, data.count)
    }
}
