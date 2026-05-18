import Foundation
import Security
import CryptoKit
import AppKit
import os

private let logger = Logger(subsystem: "com.ayangabryl.usage", category: "OpenAIAuth")

struct OpenAIAccountInfo: Sendable {
    var email: String?
    var name: String?
    var accountId: String?
}

@Observable
@MainActor
final class OpenAIAuthService: Sendable {
    var isLoading: Bool = false
    var userCode: String?
    /// Set when a device flow completes (success or failure) while the window was closed
    var pendingResult: OpenAIAccountInfo?
    var flowFinished: Bool = false
    /// Which account the finished flow belongs to (prevents stale consumption by a different account)
    private(set) var finishedFlowAccountId: UUID?
    /// The account ID currently running the device flow
    private(set) var activeFlowAccountId: UUID?
    /// Human-readable error detail from the last failed flow
    var lastFlowError: String?
    private var flowTask: Task<Void, Never>?

    private let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let issuer = "https://auth.openai.com"
    private var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        return "Usageview/\(version) (macOS; \(arch))"
    }

    // MARK: - Multi-Account Auth

    func isAuthenticated(for accountId: UUID) -> Bool {
        loadToken(key: refreshKey(for: accountId)) != nil
            || loadToken(key: apiKeyKey(for: accountId)) != nil
    }

    // MARK: - API Key Auth

    /// Store a user-provided OpenAI API key
    func saveAPIKey(_ key: String, for accountId: UUID) -> OpenAIAccountInfo {
        saveToken(key: apiKeyKey(for: accountId), value: key)
        let masked = key.count > 8
            ? String(key.prefix(8)) + "..."
            : key
        return OpenAIAccountInfo(email: nil, name: masked, accountId: nil)
    }

    /// Retrieve the stored API key
    func getAPIKey(for accountId: UUID) -> String? {
        loadToken(key: apiKeyKey(for: accountId))
    }

    /// Verify an OpenAI API key is valid by calling /v1/models
    func verifyAPIKey(for accountId: UUID) async -> Bool {
        guard let key = getAPIKey(for: accountId) else { return false }

        let url = URL(string: "https://api.openai.com/v1/models")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }

    func token(for accountId: UUID) -> String? {
        loadToken(key: accessKey(for: accountId))
    }

    /// Whether a device flow is currently active for the given account
    func isFlowActive(for accountId: UUID) -> Bool {
        activeFlowAccountId == accountId && flowTask != nil
    }

    /// Start device flow in a background task owned by the service (survives window dismissals)
    func beginDeviceFlow(for accountId: UUID) {
        // Cancel any existing flow
        cancelDeviceFlow()
        activeFlowAccountId = accountId
        flowFinished = false
        finishedFlowAccountId = nil
        pendingResult = nil
        lastFlowError = nil
        flowTask = Task {
            let info = await startDeviceFlow(for: accountId)
            if Task.isCancelled { return }
            // Store result for the view to pick up
            self.pendingResult = info
            self.finishedFlowAccountId = accountId
            self.flowFinished = true
            self.activeFlowAccountId = nil
            self.flowTask = nil
        }
    }

    /// Cancel the active device flow
    func cancelDeviceFlow() {
        flowTask?.cancel()
        flowTask = nil
        activeFlowAccountId = nil
        flowFinished = false
        finishedFlowAccountId = nil
        pendingResult = nil
        lastFlowError = nil
        isLoading = false
        userCode = nil
    }

    /// Consume the pending result (resets it)
    func consumeResult() -> OpenAIAccountInfo? {
        let result = pendingResult
        pendingResult = nil
        flowFinished = false
        finishedFlowAccountId = nil
        return result
    }

    /// Start OpenAI device code flow
    private func startDeviceFlow(for accountId: UUID) async -> OpenAIAccountInfo? {
        isLoading = true
        defer {
            isLoading = false
            userCode = nil
        }

        // Step 1: Request device + user codes (retry on Cloudflare 429)
        let codeURL = URL(string: "\(issuer)/api/accounts/deviceauth/usercode")!
        var codeJSON: [String: Any]?

        for attempt in 0..<5 {
            if Task.isCancelled { return nil }
            if attempt > 0 {
                // Exponential backoff: 3s, 8s, 15s, 25s
                let delay = Double(attempt) * Double(attempt) + 2.0
                logger.info("OpenAI device flow: waiting \(delay)s before retry \(attempt + 1)")
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return nil }
            }

            var codeRequest = URLRequest(url: codeURL)
            codeRequest.httpMethod = "POST"
            codeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            codeRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            codeRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            codeRequest.timeoutInterval = 30
            codeRequest.httpBody = try? JSONSerialization.data(withJSONObject: [
                "client_id": clientId
            ])

            let codeData: Data
            let codeResponse: URLResponse
            do {
                (codeData, codeResponse) = try await URLSession.shared.data(for: codeRequest)
            } catch {
                logger.error("OpenAI device flow: network error: \(error.localizedDescription, privacy: .public)")
                continue
            }

            let httpStatus = (codeResponse as? HTTPURLResponse)?.statusCode ?? 0

            if httpStatus == 429 {
                logger.warning("OpenAI device flow: 429 (attempt \(attempt + 1)/5), retrying...")
                continue
            }

            let responseBody = String(data: codeData, encoding: .utf8) ?? ""
            logger.info("OpenAI usercode response (HTTP \(httpStatus)): \(responseBody.prefix(500), privacy: .public)")

            if let json = try? JSONSerialization.jsonObject(with: codeData) as? [String: Any],
               json["user_code"] is String {
                codeJSON = json
                break
            }

            logger.error("OpenAI device flow: unexpected response (HTTP \(httpStatus))")
        }

        guard let codeJSON,
              let uCode = codeJSON["user_code"] as? String
        else {
            logger.error("OpenAI device flow: failed to get user code after 5 attempts")
            lastFlowError = "Could not get device code from OpenAI (possible rate limit or network issue)"
            return nil
        }

        // device_auth_id is required for polling
        let deviceAuthId = codeJSON["device_auth_id"] as? String
            ?? codeJSON["device_code"] as? String
        if deviceAuthId == nil {
            logger.warning("OpenAI device flow: no device_auth_id in response, polling may fail")
        }

        if Task.isCancelled { return nil }

        userCode = uCode
        logger.info("OpenAI device flow: got user code, device_auth_id=\(deviceAuthId != nil)")

        // Step 2: Open browser for user to enter code
        if let url = URL(string: "\(issuer)/codex/device") {
            NSWorkspace.shared.open(url)
        }

        // Step 3: Poll for authorization (match opencode: device_auth_id + user_code only, no client_id)
        let rawInterval = codeJSON["interval"] as? Int
            ?? Int(codeJSON["interval"] as? String ?? "")
            ?? 5
        let pollingInterval = max(rawInterval, 1) + 3 // safety margin like opencode
        let tokenURL = URL(string: "\(issuer)/api/accounts/deviceauth/token")!

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(pollingInterval))
            if Task.isCancelled { return nil }

            var tokenRequest = URLRequest(url: tokenURL)
            tokenRequest.httpMethod = "POST"
            tokenRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
            tokenRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            tokenRequest.timeoutInterval = 30
            // opencode sends only device_auth_id + user_code (no client_id)
            var pollBody: [String: String] = [:]
            if let deviceAuthId {
                pollBody["device_auth_id"] = deviceAuthId
            }
            pollBody["user_code"] = uCode
            tokenRequest.httpBody = try? JSONSerialization.data(withJSONObject: pollBody)

            guard let (tokenData, tokenResponse) = try? await URLSession.shared.data(for: tokenRequest)
            else { continue }

            let pollStatus = (tokenResponse as? HTTPURLResponse)?.statusCode ?? 0

            // 403/404 = authorization pending (match opencode behavior)
            if pollStatus == 403 || pollStatus == 404 {
                continue
            }

            let pollResponseBody = String(data: tokenData, encoding: .utf8) ?? ""
            logger.info("OpenAI poll response (HTTP \(pollStatus)): \(pollResponseBody.prefix(300), privacy: .public)")

            guard let tokenJSON = try? JSONSerialization.jsonObject(with: tokenData) as? [String: Any]
            else { continue }

            // Device flow returns authorization_code + code_verifier
            if let authCode = tokenJSON["authorization_code"] as? String,
               let codeVerifier = tokenJSON["code_verifier"] as? String {
                logger.info("OpenAI device flow: received authorization code, exchanging for tokens")
                let info = await exchangeDeviceCode(
                    authCode: authCode,
                    codeVerifier: codeVerifier,
                    accountId: accountId
                )
                return info
            }

            // Standard OAuth: response might directly contain access_token
            if let accessToken = tokenJSON["access_token"] as? String {
                logger.info("OpenAI device flow: received access token directly")
                let refreshToken = tokenJSON["refresh_token"] as? String
                let expiresIn = tokenJSON["expires_in"] as? Double ?? 3600
                saveToken(key: accessKey(for: accountId), value: accessToken)
                if let refreshToken {
                    saveToken(key: refreshKey(for: accountId), value: refreshToken)
                }
                if let idTok = tokenJSON["id_token"] as? String, !idTok.isEmpty {
                    saveToken(key: idTokenKey(for: accountId), value: idTok)
                } else {
                    removeToken(key: idTokenKey(for: accountId))
                }
                UserDefaults.standard.set(
                    Date.now.timeIntervalSince1970 + expiresIn,
                    forKey: expiresKey(for: accountId)
                )
                let idToken = tokenJSON["id_token"] as? String
                return extractIdentity(from: idToken ?? accessToken)
            }

            if let error = tokenJSON["error"] as? String {
                if error == "authorization_pending" || error == "slow_down" { continue }
                logger.error("OpenAI device flow poll error: \(error, privacy: .public)")
                return nil
            }
        }

        return nil
    }

    /// Exchange device flow auth code for tokens (form-urlencoded, matching opencode)
    private func exchangeDeviceCode(authCode: String, codeVerifier: String, accountId: UUID) async -> OpenAIAccountInfo? {
        let url = URL(string: "\(issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code", value: authCode),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: "\(issuer)/deviceauth/callback")
        ]
        request.httpBody = components.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }

            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                logger.error("OpenAI token exchange failed (HTTP \(http.statusCode)): \(body.prefix(200), privacy: .public)")
                return nil
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let accessToken = json["access_token"] as? String,
               let refreshToken = json["refresh_token"] as? String {

                let expiresIn = json["expires_in"] as? Double ?? 3600
                saveToken(key: accessKey(for: accountId), value: accessToken)
                saveToken(key: refreshKey(for: accountId), value: refreshToken)
                if let idTok = json["id_token"] as? String, !idTok.isEmpty {
                    saveToken(key: idTokenKey(for: accountId), value: idTok)
                } else {
                    removeToken(key: idTokenKey(for: accountId))
                }
                UserDefaults.standard.set(
                    Date.now.timeIntervalSince1970 + expiresIn,
                    forKey: expiresKey(for: accountId)
                )

                logger.info("OpenAI token exchange successful")
                // Extract identity from JWT id_token or access_token
                let idToken = json["id_token"] as? String
                return extractIdentity(from: idToken ?? accessToken)
            }

            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("OpenAI token exchange: missing access/refresh tokens. Keys: \(body.prefix(200), privacy: .public)")
        } catch {
            logger.error("OpenAI token exchange error: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Get a valid access token, refreshing if needed
    func getValidToken(for accountId: UUID) async -> String? {
        guard let refresh = loadToken(key: refreshKey(for: accountId)) else {
            logger.info("OpenAI: no refresh token for account")
            return nil
        }

        let expiresAt = UserDefaults.standard.double(forKey: expiresKey(for: accountId))
        if let access = loadToken(key: accessKey(for: accountId)),
           Date.now.timeIntervalSince1970 < expiresAt {
            return access
        }

        // Refresh (form-urlencoded, matching opencode)
        let url = URL(string: "\(issuer)/oauth/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        request.httpBody = components.query?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newAccess = json["access_token"] as? String {
                if let newRefresh = json["refresh_token"] as? String {
                    saveToken(key: refreshKey(for: accountId), value: newRefresh)
                }
                let expiresIn = json["expires_in"] as? Double ?? 3600
                saveToken(key: accessKey(for: accountId), value: newAccess)
                UserDefaults.standard.set(
                    Date.now.timeIntervalSince1970 + expiresIn,
                    forKey: expiresKey(for: accountId)
                )
                return newAccess
            }
        } catch {
            logger.error("OpenAI token refresh error: \(error.localizedDescription, privacy: .public)")
        }
        logger.error("OpenAI: failed to refresh access token")
        return nil
    }

    /// Get the ChatGPT account ID (for API requests header)
    func chatgptAccountId(for accountId: UUID) -> String? {
        guard let token = loadToken(key: accessKey(for: accountId)) else { return nil }
        let info = extractIdentity(from: token)
        return info?.accountId
    }

    func disconnect(accountId: UUID) {
        removeToken(key: accessKey(for: accountId))
        removeToken(key: refreshKey(for: accountId))
        removeToken(key: idTokenKey(for: accountId))
        removeToken(key: apiKeyKey(for: accountId))
        UserDefaults.standard.removeObject(forKey: expiresKey(for: accountId))
    }

    /// Read OAuth material after a successful device flow (before `disconnect` clears it). Used to build a Codex `auth.json` snapshot.
    func oauthTokensForCodexBridge(accountId: UUID) -> (access: String, refresh: String, idToken: String?)? {
        guard let access = loadToken(key: accessKey(for: accountId)),
              let refresh = loadToken(key: refreshKey(for: accountId))
        else { return nil }
        let idTok = loadToken(key: idTokenKey(for: accountId))
        return (access, refresh, idTok)
    }

    // MARK: - JWT Identity Extraction

    /// Decode JWT payload to get email/name/account_id
    private func extractIdentity(from jwt: String) -> OpenAIAccountInfo? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        // Pad base64 string
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        // Convert base64url to base64
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let email = json["email"] as? String
        let name = json["name"] as? String
        let accountId = json["chatgpt_account_id"] as? String
            ?? json["https://api.openai.com/auth.chatgpt_account_id"] as? String

        return OpenAIAccountInfo(email: email, name: name, accountId: accountId)
    }

    // MARK: - Key Helpers

    private func accessKey(for id: UUID) -> String {
        "com.ayangabryl.usage.openai-access-\(id.uuidString)"
    }

    private func refreshKey(for id: UUID) -> String {
        "com.ayangabryl.usage.openai-refresh-\(id.uuidString)"
    }

    private func expiresKey(for id: UUID) -> String {
        "openai_token_expires_\(id.uuidString)"
    }

    private func apiKeyKey(for id: UUID) -> String {
        "com.ayangabryl.usage.openai-apikey-\(id.uuidString)"
    }

    private func idTokenKey(for id: UUID) -> String {
        "com.ayangabryl.usage.openai-id-token-\(id.uuidString)"
    }

    // MARK: - Token Storage (Keychain)

    private func saveToken(key: String, value: String) { KeychainHelper.save(value, forKey: key) }
    private func loadToken(key: String) -> String? { KeychainHelper.load(forKey: key) }
    private func removeToken(key: String) { KeychainHelper.remove(forKey: key) }
}
