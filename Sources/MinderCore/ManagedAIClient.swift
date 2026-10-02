import Foundation
import Security

public struct ManagedServiceConfiguration {
    public var url: URL; public var publishableKey: String
    public init(url: URL, publishableKey: String) { self.url = url; self.publishableKey = publishableKey }
    public static func configured() -> ManagedServiceConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let urlText = environment["NUDGE_SUPABASE_URL"] ?? Bundle.main.object(forInfoDictionaryKey: "NudgeSupabaseURL") as? String ?? ""
        let key = environment["NUDGE_SUPABASE_PUBLISHABLE_KEY"] ?? Bundle.main.object(forInfoDictionaryKey: "NudgeSupabasePublishableKey") as? String ?? ""
        guard let url = URL(string: urlText), url.scheme == "https", url.host != nil, key.hasPrefix("sb_publishable_") else { return nil }
        return ManagedServiceConfiguration(url: url, publishableKey: key)
    }
}
public struct ManagedSession: Codable {
    public struct User: Codable { public var id: String }
    public var access_token: String; public var refresh_token: String; public var expires_at: Double?; public var user: User
}
protocol ManagedSessionPersisting {
    func load() throws -> ManagedSession?
    func save(_ session: ManagedSession) throws
    func clear() throws
}

// One cache for the running app, shared by Settings and every refresh client.
// Keychain remains the only persistent credential store; its access rules are unchanged.
public final class ManagedSessionStore: @unchecked Sendable {
    public static let shared = ManagedSessionStore()
    private let persistence: ManagedSessionPersisting
    private let lock = NSLock()
    private var hasLoaded = false
    private var cachedSession: ManagedSession?

    public init(namespace: String = Bundle.main.bundleIdentifier ?? "com.nudge.development") {
        persistence = KeychainSessionPersistence(namespace: namespace)
    }
    init(persistence: ManagedSessionPersisting) { self.persistence = persistence }

    public func load() throws -> ManagedSession? {
        lock.lock(); defer { lock.unlock() }
        if !hasLoaded {
            cachedSession = try persistence.load()
            hasLoaded = true
        }
        return cachedSession
    }
    public func save(_ session: ManagedSession) throws {
        lock.lock(); defer { lock.unlock() }
        // A failed write must not authenticate an account only in memory.
        cachedSession = nil; hasLoaded = false
        try persistence.save(session)
        cachedSession = session; hasLoaded = true
    }
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        cachedSession = nil; hasLoaded = false
        try persistence.clear()
        hasLoaded = true
    }
}

private final class KeychainSessionPersistence: ManagedSessionPersisting {
    private let service: String
    init(namespace: String) { service = namespace + ".managed-ai-session" }
    func load() throws -> ManagedSession? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "session", kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ManagedAIError.unavailable("Could not read the sign-in session from Keychain.") }
        return try JSONDecoder().decode(ManagedSession.self, from: data)
    }
    func save(_ session: ManagedSession) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "session"]
        let data = try JSONEncoder().encode(session)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item[kSecValueData] = data; item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ManagedAIError.unavailable("Could not save the session in Keychain.") }
        } else if result != errSecSuccess { throw ManagedAIError.unavailable("Could not update the session in Keychain.") }
    }
    func clear() throws {
        let status = SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "session"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ManagedAIError.unavailable("Could not remove the sign-in session from Keychain.") }
    }
}
public struct ManagedAPIError: Error, LocalizedError {
    public var code: String; public var retryAfter: Double?
    public var errorDescription: String? {
        switch code {
        case "authentication_required": return "Sign in again to resume managed AI. Your queue is retained."
        case "access_denied": return "This account does not have invited alpha access."
        case "quota_exhausted": return "The $5 monthly AI allowance is exhausted. Analysis resumes next UTC month."
        case "global_quota_exhausted", "service_paused": return "Managed AI is paused by the owner. Your queue is retained."
        case "consent_required": return "Review the updated data-sharing disclosure in Settings."
        case "response_not_replayable": return "This request completed, but its response is unavailable. Refresh starts a new, billed assessment."
        case "provider_timeout", "provider_transient": return "The AI provider is temporarily unavailable. Your queue is retained."
        case "pricing_unavailable": return "Analysis is paused until the owner updates model pricing."
        case "rate_limit", "concurrency_limit": return "Analysis is temporarily rate limited. Try refreshing shortly."
        default: return "Managed analysis could not complete (\(code)). Your queue is retained."
        }
    }
}
public actor ManagedAIClient: ThreadAssessmentService {
    private let configuration: ManagedServiceConfiguration
    private let keychain: ManagedSessionStore
    private let session: URLSession
    private let consentVersion: Int
    private var lastInferenceAt: Date?
    public init(configuration: ManagedServiceConfiguration, keychain: ManagedSessionStore = .shared, consentVersion: Int = 1) {
        self.configuration = configuration; self.keychain = keychain; self.consentVersion = consentVersion
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 110; config.timeoutIntervalForResource = 120
        config.urlCache = nil; self.session = URLSession(configuration: config)
    }
    public func requestCode(email: String) async throws {
        _ = try await auth(path: "otp", body: ["email": email, "create_user": false])
    }
    public func verifyCode(email: String, code: String) async throws -> String {
        let data = try await auth(path: "verify", body: ["email": email, "token": code, "type": "email"])
        let session = try JSONDecoder().decode(ManagedSession.self, from: data); try keychain.save(session); return session.user.id
    }
    public func signOut() async throws {
        if let token = try? keychain.load()?.access_token {
            var request = URLRequest(url: configuration.url.appendingPathComponent("auth/v1/logout")); request.httpMethod = "POST"
            request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey"); request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)
        }
        try keychain.clear()
    }
    public func deleteAccount() async throws { _ = try await call("account", method: "DELETE", body: nil); try keychain.clear() }
    private func auth(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: configuration.url.appendingPathComponent("auth/v1/" + path)); request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ManagedAIError.unavailable("Sign-in failed. Check the email, code, and invitation, then try again.") }
        return data
    }
    private func token() async throws -> String {
        guard let saved = try keychain.load() else { throw ManagedAPIError(code: "authentication_required") }
        if (saved.expires_at ?? 0) > Date().timeIntervalSince1970 + 60 { return saved.access_token }
        // URL query must remain a query, not an escaped path component.
        var components = URLComponents(url: configuration.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!); request.httpMethod = "POST"
        request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": saved.refresh_token])
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ManagedAPIError(code: "authentication_required") }
        let fresh = try JSONDecoder().decode(ManagedSession.self, from: data); try keychain.save(fresh); return fresh.access_token
    }
    private func call(_ path: String, method: String, body: Data?) async throws -> Data {
        if path == "assess" || path == "rank" {
            if let previous = lastInferenceAt {
                let wait = 6 - Date().timeIntervalSince(previous)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            lastInferenceAt = Date()
        }
        let bearer = try await token()
        var request = URLRequest(url: configuration.url.appendingPathComponent("functions/v1/nudge-ai/v1/" + path)); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization"); request.setValue(configuration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue(String(consentVersion), forHTTPHeaderField: "x-nudge-consent-version")
        let (data,response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ManagedAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { struct Detail: Decodable { var code: String; var retryAfter: Double? }; var error: Detail }
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) { throw ManagedAPIError(code: failure.error.code, retryAfter: failure.error.retryAfter) }
            throw ManagedAPIError(code: http.statusCode == 401 ? "authentication_required" : "service_unavailable")
        }; return data
    }
    public func status() async throws -> ManagedAIStatus { try ManagedJSON.decoder().decode(ManagedAIStatus.self, from: await call("status", method: "GET", body: nil)) }
    public func assess(_ request: AssessmentRequest) async throws -> AssessmentResponse {
        let originalRequestId = request.requestId
        var request = request
        for attempt in 0...1 {
            do {
                var response = try ManagedJSON.decoder().decode(AssessmentResponse.self, from: await call("assess", method: "POST", body: ManagedJSON.wireData(request)))
                try ManagedContract.validate(response, for: request)
                response.requestId = originalRequestId
                return response
            }
            catch let error as ManagedAPIError where attempt == 0 && ["provider_transient", "provider_timeout", "rate_limit", "concurrency_limit"].contains(error.code) {
                guard (error.retryAfter ?? 5) <= 60 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(max(1,error.retryAfter ?? 5) * 1_000_000_000)); request.requestId = UUID().uuidString
                // Repeated attempts are fresh paid requests. Normalize the response to the caller's correlation ID below.
            }
        }; throw ManagedAIError.invalidResponse
    }
    public func rank(_ original: RankingRequest) async throws -> RankingResponse {
        var request = original
        for attempt in 0...1 {
            do {
                var response = try ManagedJSON.decoder().decode(RankingResponse.self, from: await call("rank", method: "POST", body: ManagedJSON.wireData(request)))
                guard response.requestId == request.requestId else { throw ManagedAIError.invalidResponse }
                response.requestId = original.requestId; return response
            } catch let error as ManagedAPIError where attempt == 0 && ["provider_transient", "provider_timeout", "rate_limit", "concurrency_limit"].contains(error.code) {
                guard (error.retryAfter ?? 5) <= 60 else { throw error }
                try await Task.sleep(nanoseconds: UInt64(max(1,error.retryAfter ?? 5) * 1_000_000_000)); request.requestId = UUID().uuidString
            }
        }; throw ManagedAIError.invalidResponse
    }
}
