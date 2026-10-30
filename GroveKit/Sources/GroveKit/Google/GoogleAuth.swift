import CryptoKit
import Foundation
import Security

/// The app's Google OAuth client, read from Info.plist.
///
/// An "iOS" type client from Google Cloud Console: it needs no client secret,
/// and redirects to the reversed client ID as a URL scheme, which
/// `ASWebAuthenticationSession` catches without the app registering anything.
/// That is how Google's own sign-in SDK works on macOS.
public struct GoogleConfig: Sendable, Equatable {
    public let clientID: String

    public init?(clientID: String?) {
        guard let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
            clientID.hasSuffix(".apps.googleusercontent.com")
        else { return nil }
        self.clientID = clientID
    }

    /// From the `GroveGoogleClientID` key `bundle.sh` writes into Info.plist.
    public static var fromBundle: GoogleConfig? {
        GoogleConfig(clientID: Bundle.main.object(forInfoDictionaryKey: "GroveGoogleClientID") as? String)
    }

    /// `com.googleusercontent.apps.<id>` — the client ID back to front.
    public var callbackScheme: String {
        "com.googleusercontent.apps."
            + clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
    }

    public var redirectURI: String { "\(callbackScheme):/oauth2redirect" }

    /// Read-only calendar, send-only mail. Grove never reads your inbox.
    public static let scopes = [
        "openid", "email", "profile",
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ]
}

public struct GoogleAccount: Codable, Sendable, Equatable {
    public let email: String
    public let name: String?

    public init(email: String, name: String?) {
        self.email = email
        self.name = name
    }

    public var firstName: String? { name?.split(separator: " ").first.map(String.init) }
}

public struct GoogleTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isFresh: Bool { expiresAt.timeIntervalSinceNow > 60 }
}

public enum GoogleError: Error, LocalizedError {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google sign-in isn't set up in this build of Grove."
        case .notSignedIn: return "Sign in with Google first."
        case .stateMismatch: return "The sign-in response didn't match the request. Try again."
        case .server(let message): return message
        }
    }
}

/// PKCE (RFC 7636): proves the app that finishes sign-in is the one that
/// started it, which is what replaces a client secret for a native app.
public enum PKCE {
    public static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The HTTP half of Google sign-in. The browser half — showing Google's page —
/// belongs to the app, because it needs a window.
public enum GoogleOAuth {
    public static func authorizationURL(config: GoogleConfig, challenge: String, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Without these Google returns no refresh token, and the user would
            // be signed out again within the hour.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        return components.url!
    }

    /// The `code` from the redirect, after checking it answers our request.
    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw GoogleError.server("Google sign-in failed: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GoogleError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw GoogleError.server("Google didn't return a sign-in code.")
        }
        return code
    }

    public static func exchange(code: String, verifier: String, config: GoogleConfig) async throws -> GoogleTokens {
        let response = try await tokenRequest([
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": config.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refresh = response.refresh_token else {
            throw GoogleError.server("Google didn't grant offline access. Try signing in again.")
        }
        return GoogleTokens(
            accessToken: response.access_token, refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(response.expires_in))
    }

    public static func refresh(_ tokens: GoogleTokens, config: GoogleConfig) async throws -> GoogleTokens {
        let response = try await tokenRequest([
            "client_id": config.clientID,
            "refresh_token": tokens.refreshToken,
            "grant_type": "refresh_token",
        ])
        return GoogleTokens(
            accessToken: response.access_token,
            refreshToken: response.refresh_token ?? tokens.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expires_in))
    }

    public static func account(accessToken: String) async throws -> GoogleAccount {
        struct UserInfo: Decodable { let email: String; let name: String? }
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let info: UserInfo = try await GoogleHTTP.decode(request)
        return GoogleAccount(email: info.email, name: info.name)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: TimeInterval
        let refresh_token: String?
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(form).data(using: .utf8)
        return try await GoogleHTTP.decode(request)
    }

    static func formEncoded(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.sorted { $0.key < $1.key }
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }
}

enum GoogleHTTP {
    /// Sends a request and decodes the JSON reply, turning Google's error
    /// bodies into a message a person can act on.
    static func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            struct Failure: Decodable {
                struct Detail: Decodable { let message: String? }
                let error: Detail?
                let error_description: String?
            }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let message = failure?.error?.message ?? failure?.error_description ?? "HTTP \(status)"
            throw GoogleError.server("Google: \(message)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// The refresh token lives in the Keychain, never in a file next to the
/// meetings: the library may be synced, and a token there would travel with it.
public enum GoogleKeychain {
    private static let service = "app.grove.Grove.google"
    private static let account = "tokens"

    public static func save(_ tokens: GoogleTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func load() -> GoogleTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
