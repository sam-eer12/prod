import CryptoKit
import Foundation
import Security

/// Vault keys used when persisting Firebase Auth session tokens in `BrokVaultManager.connectorSecrets`.
public enum FirebaseAuthVaultKeys {
    public static let connectorID = "firebase-auth"
    public static let idToken = "id_token"
    public static let refreshToken = "refresh_token"
    public static let expiresAt = "expires_at"
}

/// Decoded Firebase configuration parsed from `GoogleService-Info.plist`.
public struct FirebaseAppConfig: Codable, Sendable, Equatable {
    public let apiKey: String
    public let clientID: String
    public let reversedClientID: String
    public let projectID: String
    public let googleAppID: String
    public let gcmSenderID: String?
    public let bundleID: String?

    enum CodingKeys: String, CodingKey {
        case apiKey = "API_KEY"
        case clientID = "CLIENT_ID"
        case reversedClientID = "REVERSED_CLIENT_ID"
        case projectID = "PROJECT_ID"
        case googleAppID = "GOOGLE_APP_ID"
        case gcmSenderID = "GCM_SENDER_ID"
        case bundleID = "BUNDLE_ID"
    }

    public init(
        apiKey: String,
        clientID: String,
        reversedClientID: String,
        projectID: String,
        googleAppID: String,
        gcmSenderID: String? = nil,
        bundleID: String? = nil
    ) {
        self.apiKey = apiKey
        self.clientID = clientID
        self.reversedClientID = reversedClientID
        self.projectID = projectID
        self.googleAppID = googleAppID
        self.gcmSenderID = gcmSenderID
        self.bundleID = bundleID
    }

    public var authDomain: String {
        "\(projectID).firebaseapp.com"
    }

    public var googleRedirectURI: String {
        "\(reversedClientID):/oauth2redirect/google"
    }

    public static func decode(fromPlistData data: Data) throws -> FirebaseAppConfig {
        let decoder = PropertyListDecoder()
        return try decoder.decode(FirebaseAppConfig.self, from: data)
    }
}

/// Supported Firebase Auth sign-in providers for Brok Bot.
public enum FirebaseAuthProviderKind: String, Codable, Sendable, Equatable {
    case google = "google.com"
    case apple = "apple.com"

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .apple: return "Apple"
        }
    }
}

/// Signed-in Firebase user profile stored in `WorkspaceSnapshot` (non-secret metadata only).
public struct FirebaseAuthUser: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uid }
    public let uid: String
    public var email: String?
    public var displayName: String?
    public var photoURL: String?
    public var providerID: String

    public init(
        uid: String,
        email: String? = nil,
        displayName: String? = nil,
        photoURL: String? = nil,
        providerID: String
    ) {
        self.uid = uid
        self.email = email
        self.displayName = displayName
        self.photoURL = photoURL
        self.providerID = providerID
    }

    public var providerLabel: String {
        switch providerID {
        case FirebaseAuthProviderKind.google.rawValue:
            return "Google"
        case FirebaseAuthProviderKind.apple.rawValue:
            return "Apple"
        default:
            return providerID
        }
    }
}

/// Active Firebase Auth session containing user profile and short-lived / refresh tokens.
public struct FirebaseAuthSession: Codable, Sendable, Equatable {
    public let user: FirebaseAuthUser
    public let idToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(
        user: FirebaseAuthUser,
        idToken: String,
        refreshToken: String,
        expiresAt: Date
    ) {
        self.user = user
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Errors emitted by `FirebaseAuthClient` and `MacAuthCoordinator`.
public enum FirebaseAuthError: Error, LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case invalidURL(String)
    case cancelled
    case stateMismatch
    case missingAuthorizationCode
    case httpError(statusCode: Int, message: String)
    case decodingError(String)
    case providerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Firebase GoogleService-Info.plist configuration is missing or incomplete."
        case .invalidURL(let value):
            return "Invalid Firebase Auth URL: \(value)"
        case .cancelled:
            return "Sign-in was cancelled."
        case .stateMismatch:
            return "OAuth callback state validation failed."
        case .missingAuthorizationCode:
            return "Google sign-in callback did not return an authorization code."
        case .httpError(let statusCode, let message):
            return message.isEmpty ? "Firebase Auth HTTP error \(statusCode)." : "Firebase Auth error (\(statusCode)): \(message)"
        case .decodingError(let details):
            return "Failed to parse Firebase Auth response: \(details)"
        case .providerUnavailable(let reason):
            return reason
        }
    }
}

/// Cryptographically random nonce + SHA-256 hex digest for Sign in with Apple + Firebase Auth.
public struct AppleSignInNonce: Sendable, Equatable {
    public let rawNonce: String
    public let sha256Hex: String

    public init(rawNonce: String) {
        self.rawNonce = rawNonce
        let digest = SHA256.hash(data: Data(rawNonce.utf8))
        self.sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func generate(length: Int = 32) throws -> AppleSignInNonce {
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var randomBytes = [UInt8](repeating: 0, count: max(16, length))
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        guard status == errSecSuccess else {
            throw FirebaseAuthError.providerUnavailable("Unable to generate secure Apple sign-in nonce (\(status)).")
        }
        let raw = String(randomBytes.map { charset[Int($0) % charset.count] })
        return AppleSignInNonce(rawNonce: raw)
    }
}

/// Zero-dependency Firebase Auth REST client supporting Google OAuth 2.0 + PKCE and Sign in with Apple.
public final class FirebaseAuthClient: Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Builds Google OAuth 2.0 authorization URL using the Firebase iOS/macOS `CLIENT_ID` and `REVERSED_CLIENT_ID` scheme.
    public func buildGoogleAuthorizationURL(
        config: FirebaseAppConfig,
        pkce: PKCEChallenge,
        redirectURI: String? = nil
    ) throws -> URL {
        guard !config.clientID.isEmpty, !config.reversedClientID.isEmpty else {
            throw FirebaseAuthError.missingConfiguration
        }
        guard var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth") else {
            throw FirebaseAuthError.invalidURL("https://accounts.google.com/o/oauth2/v2/auth")
        }

        let effectiveRedirect = redirectURI ?? config.googleRedirectURI
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: effectiveRedirect),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account")
        ]

        guard let url = components.url else {
            throw FirebaseAuthError.invalidURL("Google OAuth URL")
        }
        return url
    }

    /// Exchanges Google OAuth authorization code + PKCE `code_verifier` for Google ID & access tokens.
    public func exchangeGoogleCodeForTokens(
        config: FirebaseAppConfig,
        code: String,
        codeVerifier: String,
        redirectURI: String? = nil
    ) async throws -> (idToken: String, accessToken: String?) {
        guard !config.clientID.isEmpty else {
            throw FirebaseAuthError.missingConfiguration
        }
        guard let tokenURL = URL(string: "https://oauth2.googleapis.com/token") else {
            throw FirebaseAuthError.invalidURL("https://oauth2.googleapis.com/token")
        }

        let effectiveRedirect = redirectURI ?? config.googleRedirectURI
        let params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": config.clientID,
            "redirect_uri": effectiveRedirect,
            "code_verifier": codeVerifier
        ]

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formURLEncodedString(params).utf8)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validateHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String,
              !idToken.isEmpty else {
            throw FirebaseAuthError.decodingError("Google token response missing id_token.")
        }
        let accessToken = json["access_token"] as? String
        return (idToken: idToken, accessToken: accessToken)
    }

    /// Exchanges a Google ID token (and optional access token) for a Firebase Auth session via `accounts:signInWithIdp`.
    public func signInWithGoogleIDToken(
        config: FirebaseAppConfig,
        idToken: String,
        accessToken: String? = nil
    ) async throws -> FirebaseAuthSession {
        var components = [
            "id_token=\(Self.urlEncodeComponent(idToken))",
            "providerId=google.com"
        ]
        if let accessToken, !accessToken.isEmpty {
            components.append("access_token=\(Self.urlEncodeComponent(accessToken))")
        }
        return try await signInWithIdp(
            config: config,
            postBody: components.joined(separator: "&"),
            provider: .google,
            fallbackDisplayName: nil
        )
    }

    /// Exchanges an Apple identity token + raw nonce for a Firebase Auth session via `accounts:signInWithIdp`.
    public func signInWithAppleIDToken(
        config: FirebaseAppConfig,
        idToken: String,
        rawNonce: String,
        displayName: String? = nil
    ) async throws -> FirebaseAuthSession {
        let postBody = [
            "id_token=\(Self.urlEncodeComponent(idToken))",
            "nonce=\(Self.urlEncodeComponent(rawNonce))",
            "providerId=apple.com"
        ].joined(separator: "&")

        return try await signInWithIdp(
            config: config,
            postBody: postBody,
            provider: .apple,
            fallbackDisplayName: displayName
        )
    }

    /// Refreshes a Firebase Auth ID token using a stored refresh token.
    public func refreshSession(
        config: FirebaseAppConfig,
        refreshToken: String,
        existingUser: FirebaseAuthUser? = nil
    ) async throws -> FirebaseAuthSession {
        guard !config.apiKey.isEmpty else {
            throw FirebaseAuthError.missingConfiguration
        }
        guard var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token") else {
            throw FirebaseAuthError.invalidURL("https://securetoken.googleapis.com/v1/token")
        }
        components.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        guard let url = components.url else {
            throw FirebaseAuthError.invalidURL("securetoken")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formURLEncodedString([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]).utf8)

        let (data, response) = try await urlSession.data(for: request)
        try Self.validateHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String,
              let newRefresh = json["refresh_token"] as? String,
              let userID = json["user_id"] as? String else {
            throw FirebaseAuthError.decodingError("Token refresh response missing required fields.")
        }

        let expiresIn = (json["expires_in"] as? String).flatMap(TimeInterval.init)
            ?? (json["expires_in"] as? NSNumber)?.doubleValue
            ?? 3600

        let user = existingUser ?? FirebaseAuthUser(uid: userID, providerID: "firebase")
        return FirebaseAuthSession(
            user: user,
            idToken: idToken,
            refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - Private Helpers

    private func signInWithIdp(
        config: FirebaseAppConfig,
        postBody: String,
        provider: FirebaseAuthProviderKind,
        fallbackDisplayName: String?
    ) async throws -> FirebaseAuthSession {
        guard !config.apiKey.isEmpty else {
            throw FirebaseAuthError.missingConfiguration
        }
        guard var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp") else {
            throw FirebaseAuthError.invalidURL("accounts:signInWithIdp")
        }
        components.queryItems = [URLQueryItem(name: "key", value: config.apiKey)]
        guard let url = components.url else {
            throw FirebaseAuthError.invalidURL("accounts:signInWithIdp")
        }

        let payload: [String: Any] = [
            "postBody": postBody,
            "requestUri": "http://localhost",
            "returnIdpCredential": true,
            "returnSecureToken": true
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let (data, response) = try await urlSession.data(for: request)
        try Self.validateHTTPResponse(response, data: data)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uid = json["localId"] as? String,
              let idToken = json["idToken"] as? String,
              let refreshToken = json["refreshToken"] as? String else {
            throw FirebaseAuthError.decodingError("Firebase signInWithIdp response missing localId, idToken, or refreshToken.")
        }

        let expiresIn = (json["expiresIn"] as? String).flatMap(TimeInterval.init)
            ?? (json["expiresIn"] as? NSNumber)?.doubleValue
            ?? 3600

        let resolvedDisplayName = (json["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveName: String? = {
            if let resolvedDisplayName, !resolvedDisplayName.isEmpty {
                return resolvedDisplayName
            }
            let fallback = fallbackDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (fallback?.isEmpty == false) ? fallback : nil
        }()

        let user = FirebaseAuthUser(
            uid: uid,
            email: json["email"] as? String,
            displayName: effectiveName,
            photoURL: json["photoUrl"] as? String,
            providerID: (json["providerId"] as? String) ?? provider.rawValue
        )

        return FirebaseAuthSession(
            user: user,
            idToken: idToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    private static func validateHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FirebaseAuthError.httpError(statusCode: -1, message: "Non-HTTP response received.")
        }
        guard (200...299).contains(http.statusCode) else {
            var message = String(decoding: data, as: UTF8.self)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDict = json["error"] as? [String: Any],
               let errMsg = errorDict["message"] as? String {
                message = errMsg
            } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let desc = json["error_description"] as? String ?? json["error"] as? String {
                message = desc
            }
            throw FirebaseAuthError.httpError(statusCode: http.statusCode, message: message)
        }
    }

    private static func urlEncodeComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func formURLEncodedString(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncodeComponent(key))=\(urlEncodeComponent(value))"
            }
            .joined(separator: "&")
    }
}
