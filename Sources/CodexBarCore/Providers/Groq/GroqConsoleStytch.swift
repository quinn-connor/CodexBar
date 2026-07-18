import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Exchanges the long-lived Groq console session cookie (`stytch_session`,
/// ~30 days) for a fresh, short-lived session JWT via Stytch's B2B frontend
/// SDK endpoint — the same call the console web app makes. This keeps
/// background polling working even when no console tab is open to refresh the
/// short-lived `stytch_session_jwt` cookie on its own.
enum GroqConsoleStytch {
    /// Public (publishable) token for Groq's Stytch B2B project. Publishable by
    /// design — it only authorizes SDK calls from the allowed `console.groq.com`
    /// origin. Overridable in case Groq rotates it.
    static let defaultPublicToken = "public-token-live-58df57a9-a1f5-4066-bc0c-2ff942db684f"
    static let publicTokenEnvironmentKey = "GROQ_STYTCH_PUBLIC_TOKEN"
    static let baseURLEnvironmentKey = "GROQ_STYTCH_URL"
    private static let defaultBaseURL = "https://api.stytchb2b.groq.com"
    private static let allowedHost = "api.stytchb2b.groq.com"
    private static let authenticatePath = "/sdk/v1/b2b/sessions/authenticate"
    private static let origin = "https://console.groq.com"
    private static let sdkVersion = "5.43.0"

    private struct AuthenticateResponse: Decodable {
        struct Payload: Decodable {
            let sessionJWT: String?
            enum CodingKeys: String, CodingKey { case sessionJWT = "session_jwt" }
        }

        let data: Payload?
    }

    static func refreshSessionJWT(
        sessionToken: String,
        environment: [String: String],
        transport: any ProviderHTTPTransport) async throws -> String
    {
        let token = sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw GroqConsoleError.missingSession }

        let publicToken = environment[self.publicTokenEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? self.defaultPublicToken
        let url = try self.authenticateURL(environment: environment)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        // Stytch SDK auth: Basic base64(publicToken:sessionToken).
        let credential = Data("\(publicToken):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.origin, forHTTPHeaderField: "Origin")
        request.setValue(self.origin, forHTTPHeaderField: "X-SDK-Parent-Host")
        request.setValue(self.sdkClientHeader(), forHTTPHeaderField: "X-SDK-Client")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "session_token": token,
            "session_duration_minutes": 30,
        ])

        // Revalidate immediately before crossing the transport boundary so a future
        // request-construction change cannot redirect the Basic credential.
        guard self.isAllowedAuthenticateURL(request.url) else {
            throw GroqConsoleError.invalidSession("invalid Stytch URL")
        }
        let response = try await transport.response(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let summary = String(bytes: response.data.prefix(300), encoding: .utf8) ?? ""
            if response.statusCode == 401 || response.statusCode == 403 {
                throw GroqConsoleError.accessDenied(summary)
            }
            throw GroqConsoleError.apiError("Stytch HTTP \(response.statusCode): \(summary)")
        }

        guard let jwt = (try? JSONDecoder().decode(AuthenticateResponse.self, from: response.data))?
            .data?.sessionJWT?.trimmingCharacters(in: .whitespacesAndNewlines), !jwt.isEmpty
        else {
            throw GroqConsoleError.parseFailed("Stytch response missing session_jwt")
        }
        return jwt
    }

    static func authenticateURL(environment: [String: String]) throws -> URL {
        let rawBase = environment[self.baseURLEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? self.defaultBaseURL
        let validator = ProviderEndpointOverrideValidator(allowedHosts: [self.allowedHost])
        guard let baseURL = validator.validatedURL(rawBase, policy: .providerOwnedOnly),
              let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              baseComponents.scheme?.lowercased() == "https",
              baseComponents.host?.lowercased() == self.allowedHost,
              baseComponents.port == nil || baseComponents.port == 443,
              baseComponents.user == nil,
              baseComponents.password == nil,
              baseComponents.query == nil,
              baseComponents.fragment == nil,
              baseComponents.path.isEmpty || baseComponents.path == "/"
        else {
            throw GroqConsoleError.invalidSession("invalid Stytch URL")
        }

        var components = baseComponents
        components.path = self.authenticatePath
        guard let url = components.url, self.isAllowedAuthenticateURL(url) else {
            throw GroqConsoleError.invalidSession("invalid Stytch URL")
        }
        return url
    }

    private static func isAllowedAuthenticateURL(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.lowercased() == self.allowedHost
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.query == nil
            && components.fragment == nil
            && components.path == self.authenticatePath
    }

    /// Base64 telemetry blob the Stytch SDK expects; identifies the calling app
    /// by hostname (matched against the project's allowed domains).
    private static func sdkClientHeader() -> String {
        let blob = "{\"app\":{\"identifier\":\"console.groq.com\"}," +
            "\"sdk\":{\"identifier\":\"Stytch.js Javascript SDK\",\"version\":\"\(self.sdkVersion)\"}}"
        return Data(blob.utf8).base64EncodedString()
    }
}

extension String {
    fileprivate var nonEmpty: String? {
        self.isEmpty ? nil : self
    }
}
