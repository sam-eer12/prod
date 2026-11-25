import CryptoKit
import Foundation
import Network
import Security

/// Vault secret keys stored per `connection.id` inside `BrokVaultManager.connectorSecrets`.
public enum MCPVaultSecretKeys {
    public static let bearerToken = "bearer_token"
    public static let accessToken = "access_token"
    public static let refreshToken = "refresh_token"
    public static let expiresAt = "expires_at"
    public static let clientSecret = "client_secret"
    public static let registeredClientID = "registered_client_id"
    public static let tokenEndpoint = "token_endpoint"
    public static let authorizationEndpoint = "authorization_endpoint"
}

/// OAuth 2.1 PKCE challenge (RFC 7636 S256) + CSRF `state`.
public struct PKCEChallenge: Sendable, Equatable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String

    public init(codeVerifier: String, codeChallenge: String, state: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.state = state
    }

    public static func generate() throws -> PKCEChallenge {
        let verifier = try randomBase64URL(byteCount: 32)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        let state = try randomBase64URL(byteCount: 24)
        return PKCEChallenge(codeVerifier: verifier, codeChallenge: challenge, state: state)
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buf -> OSStatus in
            guard let ptr = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, ptr)
        }
        guard status == errSecSuccess else {
            throw MCPClientError.oauthFailed("Unable to generate secure random PKCE bytes (\(status)).")
        }
        return bytes.base64URLEncodedString()
    }
}

/// RFC 9728 Protected Resource Metadata document.
public struct OAuthProtectedResourceMetadata: Codable, Sendable, Equatable {
    public var resource: String?
    public var authorizationServers: [String]?
    public var scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

/// RFC 8414 / OIDC Authorization Server Metadata document.
public struct OAuthAuthorizationServerMetadata: Codable, Sendable, Equatable {
    public var issuer: String?
    public var authorizationEndpoint: String?
    public var tokenEndpoint: String?
    public var registrationEndpoint: String?
    public var scopesSupported: [String]?
    public var codeChallengeMethodsSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

/// Combined OAuth endpoints discovered for an MCP server.
public struct DiscoveredOAuthConfig: Sendable, Equatable {
    public var resourceURL: URL?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var registrationEndpoint: URL?
    public var supportedScopes: [String]

    public init(
        resourceURL: URL? = nil,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        registrationEndpoint: URL? = nil,
        supportedScopes: [String] = []
    ) {
        self.resourceURL = resourceURL
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.supportedScopes = supportedScopes
    }
}

/// OAuth token payload persisted into `BrokVaultManager`.
public struct OAuthTokenSet: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var expiresIn: TimeInterval?
    public var scope: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresIn: TimeInterval? = nil,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.scope = scope
    }
}

/// Handles MCP OAuth 2.1 authorization discovery (RFC 9728 / RFC 8414),
/// RFC 7591 Dynamic Client Registration, PKCE authorization URL construction,
/// and token exchange / refresh.
public final class MCPOAuthClient: Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Parses `resource_metadata="..."` from an HTTP `WWW-Authenticate` header.
    public static func parseWWWAuthenticateResourceMetadata(_ header: String) -> URL? {
        guard let range = header.range(
            of: #"resource_metadata="([^"]+)""#,
            options: .regularExpression
        ) else {
            return nil
        }
        let matched = String(header[range])
        let stripped = matched
            .replacingOccurrences(of: "resource_metadata=\"", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return URL(string: stripped)
    }

    /// Returns `true` for Google OAuth endpoints that reject unknown RFC 8707 `resource` params.
    public static func isGoogleOAuthEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "accounts.google.com"
            || host == "oauth2.googleapis.com"
            || host.hasSuffix(".google.com")
            || host.hasSuffix(".googleapis.com")
    }

    /// Discovers OAuth 2.1 authorization & token endpoints for an MCP server via RFC 9728 + RFC 8414.
    public func discoverMetadata(
        for endpointURL: URL,
        resourceMetadataHint: URL? = nil
    ) async throws -> DiscoveredOAuthConfig {
        let protectedResource = try await fetchProtectedResourceMetadata(
            for: endpointURL,
            hint: resourceMetadataHint
        )

        let authServerBase: URL
        if let firstAuthServer = protectedResource?.authorizationServers?.first,
           let parsed = URL(string: firstAuthServer) {
            authServerBase = parsed
        } else {
            authServerBase = rootOriginURL(for: endpointURL)
        }

        let authMetadata = try await fetchAuthorizationServerMetadata(for: authServerBase)
        guard let authEndpointStr = authMetadata.authorizationEndpoint,
              let authEndpoint = URL(string: authEndpointStr),
              let tokenEndpointStr = authMetadata.tokenEndpoint,
              let tokenEndpoint = URL(string: tokenEndpointStr) else {
            throw MCPClientError.oauthFailed("Authorization server metadata missing authorization_endpoint or token_endpoint.")
        }

        let registrationEndpoint = authMetadata.registrationEndpoint.flatMap(URL.init(string:))
        let resourceURL = protectedResource?.resource.flatMap(URL.init(string:)) ?? endpointURL
        let scopes = protectedResource?.scopesSupported ?? authMetadata.scopesSupported ?? []

        return DiscoveredOAuthConfig(
            resourceURL: resourceURL,
            authorizationEndpoint: authEndpoint,
            tokenEndpoint: tokenEndpoint,
            registrationEndpoint: registrationEndpoint,
            supportedScopes: scopes
        )
    }

    /// Executes RFC 7591 public-client Dynamic Client Registration (`token_endpoint_auth_method: "none"`).
    public func registerDynamicClient(
        registrationEndpoint: URL,
        redirectURI: String,
        clientName: String = "Brok Bot (macOS)"
    ) async throws -> String {
        let payload: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        var request = URLRequest(url: registrationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = bodyData

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            throw MCPClientError.oauthFailed("Dynamic client registration failed (HTTP \(status)): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = json["client_id"] as? String,
              !clientID.isEmpty else {
            throw MCPClientError.oauthFailed("Dynamic client registration response missing client_id.")
        }
        return clientID
    }

    /// Builds an OAuth 2.1 + PKCE authorization URL.
    public func buildAuthorizationURL(
        authorizationEndpoint: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        pkce: PKCEChallenge,
        resourceURL: URL? = nil,
        includeResourceIndicator: Bool? = nil
    ) throws -> URL {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw MCPClientError.oauthFailed("Invalid authorization endpoint URL.")
        }

        let useResource = includeResourceIndicator ?? !Self.isGoogleOAuthEndpoint(authorizationEndpoint)
        var queryItems = components.queryItems ?? []
        queryItems.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ])

        if !scopes.isEmpty {
            queryItems.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        if useResource, let resourceURL {
            queryItems.append(URLQueryItem(name: "resource", value: resourceURL.absoluteString))
        }
        if Self.isGoogleOAuthEndpoint(authorizationEndpoint) {
            queryItems.append(URLQueryItem(name: "access_type", value: "offline"))
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw MCPClientError.oauthFailed("Failed to construct OAuth authorization URL.")
        }
        return url
    }

    /// Exchanges an authorization code + PKCE `code_verifier` for access/refresh tokens.
    public func exchangeAuthorizationCode(
        tokenEndpoint: URL,
        code: String,
        codeVerifier: String,
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: String,
        resourceURL: URL? = nil,
        includeResourceIndicator: Bool? = nil
    ) async throws -> OAuthTokenSet {
        var params: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier
        ]
        if let clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        let useResource = includeResourceIndicator ?? !Self.isGoogleOAuthEndpoint(tokenEndpoint)
        if useResource, let resourceURL {
            params["resource"] = resourceURL.absoluteString
        }
        return try await postTokenForm(to: tokenEndpoint, parameters: params)
    }

    /// Refreshes an expired access token using a vaulted `refresh_token`.
    public func refreshAccessToken(
        tokenEndpoint: URL,
        refreshToken: String,
        clientID: String,
        clientSecret: String? = nil
    ) async throws -> OAuthTokenSet {
        var params: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        if let clientSecret, !clientSecret.isEmpty {
            params["client_secret"] = clientSecret
        }
        return try await postTokenForm(to: tokenEndpoint, parameters: params)
    }

    // MARK: - Private Helpers

    private func fetchProtectedResourceMetadata(
        for endpointURL: URL,
        hint: URL?
    ) async throws -> OAuthProtectedResourceMetadata? {
        var candidates: [URL] = []
        if let hint {
            candidates.append(hint)
        }

        let origin = rootOriginURL(for: endpointURL)
        let path = endpointURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            candidates.append(
                origin.appendingPathComponent(".well-known/oauth-protected-resource/\(path)")
            )
        }
        candidates.append(origin.appendingPathComponent(".well-known/oauth-protected-resource"))

        for url in candidates {
            if let decoded = try? await getJSON(OAuthProtectedResourceMetadata.self, from: url) {
                return decoded
            }
        }
        return nil
    }

    private func fetchAuthorizationServerMetadata(for authServerURL: URL) async throws -> OAuthAuthorizationServerMetadata {
        let origin = rootOriginURL(for: authServerURL)
        let path = authServerURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var candidates: [URL] = []
        if !path.isEmpty {
            candidates.append(origin.appendingPathComponent(".well-known/oauth-authorization-server/\(path)"))
            candidates.append(origin.appendingPathComponent(".well-known/openid-configuration/\(path)"))
        }
        candidates.append(origin.appendingPathComponent(".well-known/oauth-authorization-server"))
        candidates.append(origin.appendingPathComponent(".well-known/openid-configuration"))

        for candidate in candidates {
            if let metadata = try? await getJSON(OAuthAuthorizationServerMetadata.self, from: candidate),
               metadata.authorizationEndpoint != nil,
               metadata.tokenEndpoint != nil {
                return metadata
            }
        }

        throw MCPClientError.oauthFailed("Could not discover OAuth metadata at \(authServerURL.absoluteString).")
    }

    private func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MCPClientError.oauthFailed("Metadata request failed at \(url.absoluteString)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postTokenForm(to tokenEndpoint: URL, parameters: [String: String]) async throws -> OAuthTokenSet {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formURLEncodedString(parameters).utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data, as: UTF8.self)
            throw MCPClientError.oauthFailed("Token endpoint returned HTTP \(status): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty else {
            throw MCPClientError.oauthFailed("Token response missing access_token.")
        }

        let refreshToken = json["refresh_token"] as? String
        let tokenType = (json["token_type"] as? String) ?? "Bearer"
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        let scope = json["scope"] as? String
        return OAuthTokenSet(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresIn: expiresIn,
            scope: scope
        )
    }

    private func rootOriginURL(for url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme ?? "https"
        components.host = url.host
        components.port = url.port
        return components.url ?? url
    }

    private static func formURLEncodedString(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}

// MARK: - Loopback OAuth Callback Listener

/// Ephemeral `127.0.0.1` HTTP callback server capturing the OAuth authorization code and verifying `state`.
public actor LoopbackOAuthServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, Error>?
    private var expectedState: String = ""
    private var expectedPath: String = "/callback"
    private(set) public var boundPort: UInt16 = 0

    public init() {}

    /// Starts listening on `127.0.0.1:port` (or ephemeral port when `port == 0`).
    public func start(port: UInt16 = 48912, callbackPath: String = "/callback", expectedState: String) async throws -> UInt16 {
        stop()
        self.expectedState = expectedState
        self.expectedPath = callbackPath.isEmpty ? "/callback" : callbackPath

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener

        let actualPort: UInt16 = try await withCheckedThrowingContinuation { readyCont in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let assignedPort = listener.port?.rawValue, resumed.claim() {
                        readyCont.resume(returning: assignedPort)
                    }
                case .failed(let error):
                    if resumed.claim() {
                        readyCont.resume(throwing: MCPClientError.oauthFailed("Loopback OAuth listener failed: \(error.localizedDescription)"))
                    }
                case .cancelled:
                    if resumed.claim() {
                        readyCont.resume(throwing: MCPClientError.oauthFailed("Loopback OAuth listener was cancelled."))
                    }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task {
                    await self?.handleIncomingConnection(connection)
                }
            }

            listener.start(queue: DispatchQueue(label: "org.brokbot.oauth.loopback"))
        }

        self.boundPort = actualPort
        return actualPort
    }

    /// Waits for a valid authorization callback matching `expectedState`, or times out.
    public func awaitAuthorizationCode(timeoutSeconds: TimeInterval = 180) async throws -> String {
        let code: String = try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds) * 1_000_000_000))
                await self?.failPending(with: MCPClientError.oauthFailed("Timed out waiting for OAuth browser callback."))
            }
        }
        stop()
        return code
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if let pending = continuation {
            continuation = nil
            pending.resume(throwing: MCPClientError.oauthFailed("OAuth flow cancelled."))
        }
    }

    private func failPending(with error: Error) {
        if let pending = continuation {
            continuation = nil
            pending.resume(throwing: error)
        }
        listener?.cancel()
        listener = nil
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "org.brokbot.oauth.connection"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            Task {
                await self?.processHTTPRequestData(data ?? Data(), over: connection)
            }
        }
    }

    private func processHTTPRequestData(_ data: Data, over connection: NWConnection) {
        let raw = String(decoding: data, as: UTF8.self)
        guard let firstLine = raw.components(separatedBy: "\r\n").first ?? raw.components(separatedBy: "\n").first else {
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>Invalid OAuth callback request.</h3>")
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>Malformed HTTP request.</h3>")
            return
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else {
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>Invalid callback URL.</h3>")
            return
        }

        if components.path != expectedPath && expectedPath != "/" {
            sendHTTPResponse(over: connection, status: "404 Not Found", html: "<h3>Not Found</h3>")
            return
        }

        let items = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            },
            uniquingKeysWith: { _, latest in latest }
        )

        if let oauthError = items["error"] {
            let desc = items["error_description"] ?? oauthError
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>Authorization failed</h3><p>\(desc)</p>")
            failPending(with: MCPClientError.oauthFailed(desc))
            return
        }

        guard let returnedState = items["state"], returnedState == expectedState else {
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>State mismatch</h3><p>Security validation failed.</p>")
            failPending(with: MCPClientError.oauthFailed("OAuth callback state parameter did not match."))
            return
        }

        guard let code = items["code"], !code.isEmpty else {
            sendHTTPResponse(over: connection, status: "400 Bad Request", html: "<h3>Missing authorization code</h3>")
            failPending(with: MCPClientError.oauthFailed("OAuth callback did not include an authorization code."))
            return
        }

        sendHTTPResponse(
            over: connection,
            status: "200 OK",
            html: """
            <!doctype html><html><body style="font-family:-apple-system,sans-serif;background:#0d0e12;color:#f4f6fb;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;">
            <div style="padding:28px 32px;border-radius:18px;background:rgba(255,255,255,0.06);border:1px solid rgba(255,255,255,0.16);text-align:center;">
            <h2 style="margin:0 0 8px 0;color:#00E5FF;">Connected to Brok Bot</h2>
            <p style="margin:0;opacity:0.78;">Authorization complete. You may close this browser tab.</p>
            </div></body></html>
            """
        )

        if let pending = continuation {
            continuation = nil
            pending.resume(returning: code)
        }
    }

    private func sendHTTPResponse(over connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
