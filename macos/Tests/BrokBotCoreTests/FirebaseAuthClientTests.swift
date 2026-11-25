import Foundation
import XCTest
@testable import BrokBotCore

private final class AuthMockRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    static let shared = AuthMockRegistry()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlers[host] = handler
    }

    func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[host]
    }
}

private final class AuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = AuthMockRegistry.shared.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        let bodyData = Self.readBody(from: request)
        do {
            let (response, data) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody { return httpBody }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read > 0 { data.append(buf, count: read) } else { break }
        }
        return data
    }
}

final class FirebaseAuthClientTests: XCTestCase {
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testDecodeBundledGoogleServiceInfoPlistAndBuildGoogleOAuthURL() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("macos/Sources/BrokBotApp/Resources/GoogleService-Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let config = try FirebaseAppConfig.decode(fromPlistData: plistData)

        XCTAssertEqual(config.projectID, "brokbot-auth-2026")
        XCTAssertEqual(config.bundleID, "org.brokbot.mac")
        XCTAssertFalse(config.apiKey.isEmpty)
        XCTAssertFalse(config.clientID.isEmpty)
        XCTAssertTrue(config.reversedClientID.hasPrefix("com.googleusercontent.apps."))
        XCTAssertEqual(config.googleRedirectURI, "\(config.reversedClientID):/oauth2redirect/google")

        let client = FirebaseAuthClient(urlSession: makeMockedSession())
        let pkce = try PKCEChallenge.generate()
        let authURL = try client.buildGoogleAuthorizationURL(config: config, pkce: pkce)
        let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        let params = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(params["client_id"], config.clientID)
        XCTAssertEqual(params["redirect_uri"], config.googleRedirectURI)
        XCTAssertEqual(params["state"], pkce.state)
        XCTAssertEqual(params["code_challenge"], pkce.codeChallenge)
        XCTAssertEqual(params["code_challenge_method"], "S256")
        XCTAssertEqual(params["scope"], "openid email profile")
    }

    func testGoogleCodeExchangeFirebaseSignInAppleSignInAndTokenRefresh() async throws {
        let googleTokenHost = "oauth2.googleapis.com"
        let identityHost = "identitytoolkit.googleapis.com"
        let secureTokenHost = "securetoken.googleapis.com"

        defer {
            AuthMockRegistry.shared.unregister(host: googleTokenHost)
            AuthMockRegistry.shared.unregister(host: identityHost)
            AuthMockRegistry.shared.unregister(host: secureTokenHost)
        }

        AuthMockRegistry.shared.register(host: googleTokenHost) { request, _ in
            let data = try JSONSerialization.data(withJSONObject: [
                "id_token": "google-id-token-123",
                "access_token": "google-access-token-456",
                "token_type": "Bearer"
            ])
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, data)
        }

        AuthMockRegistry.shared.register(host: identityHost) { request, bodyData in
            let bodyObj = (try? JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]) ?? [:]
            let postBody = bodyObj["postBody"] as? String ?? ""
            let isApple = postBody.contains("providerId=apple.com")
            let payload: [String: Any] = [
                "localId": isApple ? "apple-uid-99" : "google-uid-42",
                "email": isApple ? "user@privaterelay.appleid.com" : "user@gmail.com",
                "displayName": isApple ? "" : "Brok Tester",
                "providerId": isApple ? "apple.com" : "google.com",
                "idToken": isApple ? "fb-apple-jwt" : "fb-google-jwt",
                "refreshToken": isApple ? "fb-apple-refresh" : "fb-google-refresh",
                "expiresIn": "3600"
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, data)
        }

        AuthMockRegistry.shared.register(host: secureTokenHost) { request, _ in
            let data = try JSONSerialization.data(withJSONObject: [
                "id_token": "fb-refreshed-jwt",
                "refresh_token": "fb-refresh-2",
                "user_id": "google-uid-42",
                "expires_in": "3600"
            ])
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, data)
        }

        let config = FirebaseAppConfig(
            apiKey: "test-api-key",
            clientID: "123-client.apps.googleusercontent.com",
            reversedClientID: "com.googleusercontent.apps.123-client",
            projectID: "brokbot-auth-2026",
            googleAppID: "1:123:ios:abc"
        )
        let client = FirebaseAuthClient(urlSession: makeMockedSession())
        let pkce = try PKCEChallenge.generate()

        let tokens = try await client.exchangeGoogleCodeForTokens(
            config: config,
            code: "auth-code",
            codeVerifier: pkce.codeVerifier
        )
        XCTAssertEqual(tokens.idToken, "google-id-token-123")

        let googleSession = try await client.signInWithGoogleIDToken(
            config: config,
            idToken: tokens.idToken,
            accessToken: tokens.accessToken
        )
        XCTAssertEqual(googleSession.user.uid, "google-uid-42")
        XCTAssertEqual(googleSession.user.providerLabel, "Google")
        XCTAssertEqual(googleSession.idToken, "fb-google-jwt")

        let nonce = try AppleSignInNonce.generate()
        XCTAssertEqual(nonce.sha256Hex.count, 64)
        let appleSession = try await client.signInWithAppleIDToken(
            config: config,
            idToken: "apple-identity-jwt",
            rawNonce: nonce.rawNonce,
            displayName: "Apple User"
        )
        XCTAssertEqual(appleSession.user.uid, "apple-uid-99")
        XCTAssertEqual(appleSession.user.displayName, "Apple User")
        XCTAssertEqual(appleSession.user.providerLabel, "Apple")

        let refreshed = try await client.refreshSession(
            config: config,
            refreshToken: googleSession.refreshToken,
            existingUser: googleSession.user
        )
        XCTAssertEqual(refreshed.idToken, "fb-refreshed-jwt")
        XCTAssertEqual(refreshed.refreshToken, "fb-refresh-2")
        XCTAssertEqual(refreshed.user.email, "user@gmail.com")

        // Verify WorkspaceSnapshot round-trips firebaseUser and decodes legacy snapshots cleanly
        let snapshot = WorkspaceSnapshot(firebaseUser: googleSession.user)
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.firebaseUser, googleSession.user)
    }
}
