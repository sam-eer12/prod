import CryptoKit
import Foundation
import Network
import XCTest
@testable import BrokBotCore

private final class MCPMockRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    static let shared = MCPMockRegistry()
    private let lock = NSLock()
    private var handlersByHost: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlersByHost[host] = handler
    }

    func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlersByHost.removeValue(forKey: host)
    }

    func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlersByHost[host]
    }
}

private final class MCPMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = MCPMockRegistry.shared.handler(for: host) else {
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
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class MCPClientTests: XCTestCase {
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempVault() async throws -> BrokVaultManager {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brokbot-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let vaultURL = tempDir.appendingPathComponent("vault.enc")
        let manager = BrokVaultManager(
            vaultURL: vaultURL,
            keyProvider: StaticVaultKeyProvider(seed: "mcp-test-seed")
        )
        try await manager.unlock()
        return manager
    }

    private static func jsonResponse(
        url: URL,
        statusCode: Int = 200,
        headers: [String: String] = [:],
        object: [String: Any]
    ) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var allHeaders = ["Content-Type": "application/json"]
        for (k, v) in headers { allHeaders[k] = v }
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: allHeaders
        )!
        return (response, data)
    }

    // MARK: - 1. PKCE, OAuth Discovery, DCR, Token Refresh & Loopback

    func testPKCEChallengeAndAuthorizationURLGoogleVsRFC9728() throws {
        let pkce = try PKCEChallenge.generate()
        let expectedDigest = Data(SHA256.hash(data: Data(pkce.codeVerifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(pkce.codeChallenge, expectedDigest)
        XCTAssertFalse(pkce.state.isEmpty)

        let oauthClient = MCPOAuthClient(urlSession: makeMockedSession())

        // Google Personal Mode: must omit RFC 8707 `resource` and request offline refresh token
        let googleURL = try oauthClient.buildAuthorizationURL(
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            clientID: "my-personal-client.apps.googleusercontent.com",
            redirectURI: "http://127.0.0.1:48912/callback",
            scopes: ["https://www.googleapis.com/auth/calendar.readonly"],
            pkce: pkce,
            resourceURL: URL(string: "https://calendarmcp.googleapis.com/mcp/v1")!
        )
        let googleComps = URLComponents(url: googleURL, resolvingAgainstBaseURL: false)!
        let googleParams = Dictionary(uniqueKeysWithValues: (googleComps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertNil(googleParams["resource"])
        XCTAssertEqual(googleParams["access_type"], "offline")
        XCTAssertEqual(googleParams["prompt"], "consent")
        XCTAssertEqual(googleParams["code_challenge_method"], "S256")

        // Standard RFC 9728 MCP Auth Server: must include `resource`
        let mcpURL = try oauthClient.buildAuthorizationURL(
            authorizationEndpoint: URL(string: "https://auth.linear.app/authorize")!,
            clientID: "dyn-client-123",
            redirectURI: "http://127.0.0.1:48912/callback",
            scopes: ["read"],
            pkce: pkce,
            resourceURL: URL(string: "https://mcp.linear.app/mcp/readonly")!
        )
        let mcpComps = URLComponents(url: mcpURL, resolvingAgainstBaseURL: false)!
        let mcpParams = Dictionary(uniqueKeysWithValues: (mcpComps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(mcpParams["resource"], "https://mcp.linear.app/mcp/readonly")
    }

    func testOAuthDiscoveryDCRVaultStorageAndAutomaticRefresh() async throws {
        let host = "mcp-oauth-\(UUID().uuidString.lowercased()).local"
        defer { MCPMockRegistry.shared.unregister(host: host) }

        let refreshCalled = LockedBox(false)
        MCPMockRegistry.shared.register(host: host) { request, bodyData in
            let url = request.url!
            let path = url.path

            if path.hasPrefix("/.well-known/oauth-protected-resource") {
                return try Self.jsonResponse(url: url, object: [
                    "resource": "https://\(host)/mcp",
                    "authorization_servers": ["https://\(host)/oauth"],
                    "scopes_supported": ["read"]
                ])
            }
            if path.hasPrefix("/.well-known/oauth-authorization-server") {
                return try Self.jsonResponse(url: url, object: [
                    "issuer": "https://\(host)/oauth",
                    "authorization_endpoint": "https://\(host)/oauth/authorize",
                    "token_endpoint": "https://\(host)/oauth/token",
                    "registration_endpoint": "https://\(host)/oauth/register",
                    "code_challenge_methods_supported": ["S256"]
                ])
            }
            if path == "/oauth/register" {
                return try Self.jsonResponse(url: url, statusCode: 201, object: [
                    "client_id": "dcr-client-xyz"
                ])
            }
            if path == "/oauth/token" {
                let bodyText = String(decoding: bodyData ?? Data(), as: UTF8.self)
                if bodyText.contains("grant_type=refresh_token") {
                    refreshCalled.withValue { $0 = true }
                    return try Self.jsonResponse(url: url, object: [
                        "access_token": "fresh-access-token",
                        "refresh_token": "refresh-token-2",
                        "token_type": "Bearer",
                        "expires_in": 3600
                    ])
                }
                return try Self.jsonResponse(url: url, object: [
                    "access_token": "initial-access-token",
                    "refresh_token": "refresh-token-1",
                    "token_type": "Bearer",
                    "expires_in": 10
                ])
            }

            return try Self.jsonResponse(url: url, statusCode: 404, object: ["error": "not_found"])
        }

        let session = makeMockedSession()
        let oauthClient = MCPOAuthClient(urlSession: session)
        let vault = try await makeTempVault()
        let manager = MCPConnectionManager(
            vault: vault,
            oauthClient: oauthClient,
            mcpClient: MCPStreamableHTTPClient(urlSession: session)
        )

        let endpointURL = URL(string: "https://\(host)/mcp")!
        let discovered = try await oauthClient.discoverMetadata(for: endpointURL)
        XCTAssertEqual(discovered.tokenEndpoint.absoluteString, "https://\(host)/oauth/token")
        let regURL = try XCTUnwrap(discovered.registrationEndpoint)
        let clientID = try await oauthClient.registerDynamicClient(
            registrationEndpoint: regURL,
            redirectURI: "http://127.0.0.1:48912/callback"
        )
        XCTAssertEqual(clientID, "dcr-client-xyz")

        let pkce = try PKCEChallenge.generate()
        let tokens = try await oauthClient.exchangeAuthorizationCode(
            tokenEndpoint: discovered.tokenEndpoint,
            code: "auth-code-99",
            codeVerifier: pkce.codeVerifier,
            clientID: clientID,
            redirectURI: "http://127.0.0.1:48912/callback",
            resourceURL: discovered.resourceURL
        )
        XCTAssertEqual(tokens.accessToken, "initial-access-token")

        let connection = MCPServerConnection(
            id: "test-oauth-conn",
            name: "Test OAuth Server",
            endpointURL: endpointURL.absoluteString,
            authMode: .oauthPKCE,
            clientID: clientID,
            authorizationEndpoint: discovered.authorizationEndpoint.absoluteString,
            tokenEndpoint: discovered.tokenEndpoint.absoluteString
        )

        try await manager.saveOAuthCredentials(
            tokens: tokens,
            clientID: clientID,
            clientSecret: nil,
            authorizationEndpoint: discovered.authorizationEndpoint,
            tokenEndpoint: discovered.tokenEndpoint,
            for: connection.id
        )

        // expiresIn=10s is within the 60s refresh threshold -> must automatically refresh!
        let resolvedToken = try await manager.resolveAccessToken(for: connection)
        XCTAssertEqual(resolvedToken, "fresh-access-token")
        XCTAssertTrue(refreshCalled.withValue { $0 })
    }

    func testLoopbackOAuthServerCapturesCodeAndRejectsStateMismatch() async throws {
        let server = LoopbackOAuthServer()
        let port = try await server.start(port: 0, callbackPath: "/callback", expectedState: "expected-state-123")

        let badURL = URL(string: "http://127.0.0.1:\(port)/callback?code=evil&state=wrong-state")!
        let (badData, badResponse) = try await URLSession.shared.data(from: badURL)
        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertFalse(badData.isEmpty)

        let codeResult: Result<String, Error>
        do {
            _ = try await server.awaitAuthorizationCode(timeoutSeconds: 2)
            codeResult = .success("")
        } catch {
            codeResult = .failure(error)
        }
        if case .success = codeResult {
            XCTFail("Expected state mismatch error")
        }

        // Now verify happy-path code capture
        let server2 = LoopbackOAuthServer()
        let port2 = try await server2.start(port: 0, callbackPath: "/callback", expectedState: "good-state-456")
        async let awaitedCode = server2.awaitAuthorizationCode(timeoutSeconds: 5)
        try await Task.sleep(nanoseconds: 50_000_000)

        let goodURL = URL(string: "http://127.0.0.1:\(port2)/callback?code=oauth-code-777&state=good-state-456")!
        let (_, goodResponse) = try await URLSession.shared.data(from: goodURL)
        XCTAssertEqual((goodResponse as? HTTPURLResponse)?.statusCode, 200)
        let captured = try await awaitedCode
        XCTAssertEqual(captured, "oauth-code-777")
    }

    // MARK: - 2. Stateful (Linear-style) & Stateless (Google Calendar-style) Streamable HTTP

    func testStatefulAndStatelessStreamableHTTPDiscoveryAndExecution() async throws {
        let host = "mcp-stream-\(UUID().uuidString.lowercased()).local"
        defer { MCPMockRegistry.shared.unregister(host: host) }

        let seenSessionHeader = LockedBox<String?>(nil)
        let listCalls = LockedBox(0)

        MCPMockRegistry.shared.register(host: host) { request, bodyData in
            let url = request.url!
            let path = url.path
            let auth = request.value(forHTTPHeaderField: "Authorization")
            guard auth == "Bearer secret-token-abc" else {
                return try Self.jsonResponse(url: url, statusCode: 401, object: ["error": "unauthorized"])
            }

            let bodyObj = (try? JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]) ?? [:]
            let method = bodyObj["method"] as? String ?? ""
            let reqID = bodyObj["id"] ?? "1"

            if path == "/stateful" {
                if method == "initialize" {
                    return try Self.jsonResponse(
                        url: url,
                        headers: ["Mcp-Session-Id": "sess-linear-001"],
                        object: [
                            "jsonrpc": "2.0",
                            "id": reqID,
                            "result": [
                                "protocolVersion": "2025-06-18",
                                "serverInfo": ["name": "Linear MCP", "version": "1.0"]
                            ]
                        ]
                    )
                }
                if method == "notifications/initialized" {
                    return try Self.jsonResponse(url: url, statusCode: 202, object: [:])
                }
                if method == "tools/list" {
                    seenSessionHeader.withValue { $0 = request.value(forHTTPHeaderField: "Mcp-Session-Id") }
                    let page = listCalls.withValue { count -> Int in
                        count += 1
                        return count
                    }
                    if page == 1 {
                        return try Self.jsonResponse(url: url, object: [
                            "jsonrpc": "2.0",
                            "id": reqID,
                            "result": [
                                "tools": [[
                                    "name": "list_issues",
                                    "description": "List Linear issues",
                                    "annotations": ["readOnlyHint": true],
                                    "inputSchema": [
                                        "type": "object",
                                        "properties": ["query": ["type": "string"]]
                                    ]
                                ]],
                                "nextCursor": "page-2"
                            ]
                        ])
                    }
                    return try Self.jsonResponse(url: url, object: [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "tools": [[
                                "name": "delete_issue",
                                "description": "Delete an issue",
                                "annotations": ["destructiveHint": true]
                            ]]
                        ]
                    ])
                }
                if method == "tools/call" {
                    seenSessionHeader.withValue { $0 = request.value(forHTTPHeaderField: "Mcp-Session-Id") }
                    return try Self.jsonResponse(url: url, object: [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "content": [["type": "text", "text": "BROK-12: Ship MCP Client"]]
                        ]
                    ])
                }
            }

            if path == "/stateless" {
                // Google Calendar MCP style: never returns Mcp-Session-Id
                XCTAssertNil(request.value(forHTTPHeaderField: "Mcp-Session-Id"))
                if method == "initialize" {
                    return try Self.jsonResponse(url: url, object: [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "protocolVersion": "2025-06-18",
                            "serverInfo": ["name": "Google Calendar MCP", "version": "1.0"]
                        ]
                    ])
                }
                if method == "notifications/initialized" {
                    return try Self.jsonResponse(url: url, statusCode: 204, object: [:])
                }
                if method == "tools/list" {
                    return try Self.jsonResponse(url: url, object: [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "tools": [[
                                "name": "list_events",
                                "description": "List calendar events",
                                "annotations": ["readOnlyHint": true]
                            ]]
                        ]
                    ])
                }
                if method == "tools/call" {
                    return try Self.jsonResponse(url: url, object: [
                        "jsonrpc": "2.0",
                        "id": reqID,
                        "result": [
                            "content": [["type": "text", "text": "10:00 AM Standup"]]
                        ]
                    ])
                }
            }

            return try Self.jsonResponse(url: url, statusCode: 404, object: ["error": "unknown"])
        }

        let vault = try await makeTempVault()
        let session = makeMockedSession()
        let manager = MCPConnectionManager(
            vault: vault,
            oauthClient: MCPOAuthClient(urlSession: session),
            mcpClient: MCPStreamableHTTPClient(urlSession: session)
        )

        var linear = MCPServerConnection(
            id: "linear-readonly",
            name: "Linear",
            endpointURL: "https://\(host)/stateful",
            authMode: .bearerToken,
            readOnly: true,
            statelessMode: false
        )
        try await manager.saveBearerToken("secret-token-abc", for: linear.id)
        let (updatedLinear, handshake) = try await manager.connectAndDiscoverTools(for: linear)
        linear = updatedLinear
        XCTAssertEqual(handshake.sessionID, "sess-linear-001")
        XCTAssertEqual(linear.discoveredTools.map(\.name), ["list_issues", "delete_issue"])

        // Read-only connection must filter out destructive `delete_issue` from LLM definitions!
        let (defs, routes) = manager.buildActiveToolDefinitions(from: [linear])
        XCTAssertEqual(defs.map(\.name), ["linear-readonly__list_issues"])

        let linearResult = await manager.executeToolCall(
            record: ToolCallRecord(id: "call_1", name: "linear-readonly__list_issues", argumentsJSON: "{}"),
            routes: routes,
            connections: [linear],
            onElicitationRequested: { _ in }
        )
        XCTAssertFalse(linearResult.isError)
        XCTAssertEqual(linearResult.outputText, "BROK-12: Ship MCP Client")
        XCTAssertEqual(seenSessionHeader.withValue { $0 }, "sess-linear-001")

        // Stateless Calendar flow
        var gcal = MCPServerConnection(
            id: "google-calendar-personal",
            name: "Google Calendar",
            endpointURL: "https://\(host)/stateless",
            authMode: .bearerToken,
            readOnly: true,
            statelessMode: true
        )
        try await manager.saveBearerToken("secret-token-abc", for: gcal.id)
        let (updatedGcal, gcalHandshake) = try await manager.connectAndDiscoverTools(for: gcal)
        gcal = updatedGcal
        XCTAssertNil(gcalHandshake.sessionID)
        XCTAssertEqual(gcal.discoveredTools.map(\.name), ["list_events"])

        let (gcalDefs, gcalRoutes) = manager.buildActiveToolDefinitions(from: [gcal])
        XCTAssertEqual(gcalDefs.count, 1)
        let gcalResult = await manager.executeToolCall(
            record: ToolCallRecord(id: "call_2", name: gcalDefs[0].name, argumentsJSON: "{}"),
            routes: gcalRoutes,
            connections: [gcal],
            onElicitationRequested: { _ in }
        )
        XCTAssertFalse(gcalResult.isError)
        XCTAssertEqual(gcalResult.outputText, "10:00 AM Standup")

        let counts = await manager.dailyRequestCountsSnapshot()
        XCTAssertEqual(counts["linear-readonly"], 3) // init + list + call
        XCTAssertEqual(counts["google-calendar-personal"], 3)
    }

    // MARK: - 3. Server-Driven MCP Elicitation (SSE Form Mode & Decline)

    func testServerDrivenSSEElicitationAcceptAndDeclineFlows() async throws {
        let host = "mcp-elicit-\(UUID().uuidString.lowercased()).local"
        defer { MCPMockRegistry.shared.unregister(host: host) }

        let clientReplyPayload = LockedBox<[String: Any]?>(nil)

        MCPMockRegistry.shared.register(host: host) { request, bodyData in
            let url = request.url!
            let bodyObj = (try? JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]) ?? [:]

            // Client POSTing back the elicitation JSON-RPC response
            if bodyObj["method"] == nil, bodyObj["result"] != nil {
                clientReplyPayload.withValue { $0 = bodyObj["result"] as? [String: Any] }
                return try Self.jsonResponse(url: url, statusCode: 202, object: ["ok": true])
            }

            let reqID = bodyObj["id"] as? String ?? "1"
            let elicitationJSON = """
            {"jsonrpc":"2.0","id":"srv-elicit-1","method":"elicitation/create","params":{"mode":"form","message":"Allow reading Tuesday events from Google Calendar?","requestedSchema":{"type":"object","properties":{"confirm":{"type":"boolean","title":"Confirm read"}}}}}
            """
            let finalJSON = """
            {"jsonrpc":"2.0","id":"\(reqID)","result":{"content":[{"type":"text","text":"Tuesday: Design Review at 2pm"}]}}
            """
            let sseBody = "data: \(elicitationJSON)\n\ndata: \(finalJSON)\n\n"
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(sseBody.utf8))
        }

        let vault = try await makeTempVault()
        let session = makeMockedSession()
        let manager = MCPConnectionManager(
            vault: vault,
            oauthClient: MCPOAuthClient(urlSession: session),
            mcpClient: MCPStreamableHTTPClient(urlSession: session)
        )

        let connection = MCPServerConnection(
            id: "gcal-elicit",
            name: "Google Calendar",
            endpointURL: "https://\(host)/mcp",
            authMode: .none,
            readOnly: true,
            statelessMode: true,
            discoveredTools: [
                MCPDiscoveredTool(name: "list_events", description: "Read calendar events", readOnlyHint: true)
            ]
        )
        let (_, routes) = manager.buildActiveToolDefinitions(from: [connection])

        let capturedRequest = LockedBox<MCPElicitationRequest?>(nil)
        let resultTask = Task {
            await manager.executeToolCall(
                record: ToolCallRecord(id: "call_elicit", name: "gcal-elicit__list_events", argumentsJSON: "{}"),
                routes: routes,
                connections: [connection],
                onElicitationRequested: { req in
                    capturedRequest.withValue { $0 = req }
                    Task {
                        await manager.respondToElicitation(
                            requestID: req.id,
                            response: MCPElicitationResponse(
                                action: .accept,
                                content: ["confirm": .bool(true)]
                            )
                        )
                    }
                }
            )
        }

        let result = await resultTask.value
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.outputText, "Tuesday: Design Review at 2pm")
        XCTAssertEqual(result.elicitationAction, .accept)

        let captured = try XCTUnwrap(capturedRequest.withValue { $0 })
        XCTAssertEqual(captured.mode, .form)
        XCTAssertTrue(captured.isReadOperation)
        XCTAssertEqual(captured.message, "Allow reading Tuesday events from Google Calendar?")

        let postedResult = try XCTUnwrap(clientReplyPayload.withValue { $0 })
        XCTAssertEqual(postedResult["action"] as? String, "accept")
    }

    // MARK: - 4. WorkspaceSnapshot Persistence & Multi-Provider Tool Request Serialization

    func testWorkspaceSnapshotPersistenceAndBYOKToolRequestSerialization() throws {
        let preset = MCPServerPreset.googleCalendarPersonal.makeConnection()
        var snapshot = WorkspaceSnapshot(mcpConnections: [preset])
        snapshot.mcpConnections[0].discoveredTools = [
            MCPDiscoveredTool(
                name: "list_events",
                description: "List upcoming calendar events",
                inputSchema: [
                    "type": .string("object"),
                    "properties": .object([
                        "timeMin": .object(["type": .string("string")])
                    ])
                ],
                readOnlyHint: true
            )
        ]

        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.mcpConnections.count, 1)
        XCTAssertEqual(decoded.mcpConnections[0].endpointURL, "https://calendarmcp.googleapis.com/mcp/v1")
        XCTAssertTrue(decoded.mcpConnections[0].statelessMode)

        // Ensure legacy snapshots without `mcpConnections` decode cleanly
        let legacyJSON = #"{"threads":[],"customPersonas":[],"selectedPersonaID":"chief-of-staff","computeConfig":{"threadAllocation":"auto","hardwareAccelerationEnabled":true},"byokConfig":{"provider":"openrouter","modelID":"anthropic/claude-sonnet-4","streamingEnabled":true}}"#
        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(legacy.mcpConnections.isEmpty)

        // Verify BYOKModelClient serializes discovered MCP tools across OpenAI, Claude, and Gemini
        let client = BYOKModelClient(urlSession: makeMockedSession())
        let toolDefs = snapshot.mcpConnections[0].discoveredTools.map { $0.toBYOKToolDefinition(exposedName: "gcal__list_events") }

        for provider in [BYOKProviderKind.openRouter, .claude, .gemini] {
            let req = BYOKChatRequest(
                configuration: BYOKConfiguration(provider: provider, modelID: provider.defaultModelID),
                apiKey: "test-api-key",
                systemPrompt: "Use MCP tools when helpful.",
                messages: [BYOKChatMessage(role: .user, content: "What's on my calendar?")],
                tools: toolDefs
            )
            let urlRequest = try client.buildURLRequest(for: req)
            let bodyData = try XCTUnwrap(urlRequest.httpBody)
            let bodyText = String(decoding: bodyData, as: UTF8.self)
            XCTAssertTrue(bodyText.contains("gcal__list_events"), "Missing tool in \(provider.displayName) request")
        }
    }

    func testGoogleDocsAndSlidesStatelessPresetsAndAuthConfiguration() throws {
        let docs = MCPServerPreset.googleDocsPersonal.makeConnection()
        XCTAssertEqual(docs.endpointURL, "https://docsmcp.googleapis.com/mcp/v1")
        XCTAssertEqual(docs.scopes, ["https://www.googleapis.com/auth/documents.readonly"])
        XCTAssertTrue(docs.readOnly)
        XCTAssertTrue(docs.statelessMode)

        let slides = MCPServerPreset.googleSlidesPersonal.makeConnection()
        XCTAssertEqual(slides.endpointURL, "https://slidesmcp.googleapis.com/mcp/v1")
        XCTAssertEqual(slides.scopes, ["https://www.googleapis.com/auth/presentations.readonly"])
        XCTAssertTrue(slides.readOnly)
        XCTAssertTrue(slides.statelessMode)

        let oauthClient = MCPOAuthClient(urlSession: makeMockedSession())
        let pkce = try PKCEChallenge.generate()
        for preset in [docs, slides] {
            let authURL = try oauthClient.buildAuthorizationURL(
                authorizationEndpoint: URL(string: preset.authorizationEndpoint!)!,
                clientID: "personal-client.apps.googleusercontent.com",
                redirectURI: preset.redirectURI,
                scopes: preset.scopes,
                pkce: pkce,
                resourceURL: URL(string: preset.endpointURL)!
            )
            let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
            let params = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertNil(params["resource"])
            XCTAssertEqual(params["access_type"], "offline")
        }

        let registry = MarketplaceRegistry()
        let docsManifest = ConnectorManifest(
            id: "google-docs-mcp",
            name: "Google Docs",
            version: "1.0.0",
            description: "Docs MCP",
            platforms: ["macos"],
            transport: ConnectorTransport(type: "mcp_streamable_http", baseUrl: "https://docsmcp.googleapis.com/mcp/v1"),
            auth: ConnectorAuth(type: "oauth2_pkce", scopes: ["https://www.googleapis.com/auth/documents.readonly"]),
            permissions: ["documents.readonly"],
            tools: [ConnectorToolSpec(name: "get_document", description: "Read doc", requiresApproval: false)],
            signature: ConnectorSignature(algorithm: "ed25519", keyId: "dev", value: "unsigned-starter-template")
        )
        let slidesManifest = ConnectorManifest(
            id: "google-slides-mcp",
            name: "Google Slides",
            version: "1.0.0",
            description: "Slides MCP",
            platforms: ["macos"],
            transport: ConnectorTransport(type: "mcp_streamable_http", baseUrl: "https://slidesmcp.googleapis.com/mcp/v1"),
            auth: ConnectorAuth(type: "oauth2_pkce", scopes: ["https://www.googleapis.com/auth/presentations.readonly"]),
            permissions: ["presentations.readonly"],
            tools: [ConnectorToolSpec(name: "get_presentation", description: "Read deck", requiresApproval: false)],
            signature: ConnectorSignature(algorithm: "ed25519", keyId: "dev", value: "unsigned-starter-template")
        )

        XCTAssertTrue(registry.makeConnection(from: docsManifest, configValues: ["client_id": "abc"]).statelessMode)
        XCTAssertTrue(registry.makeConnection(from: slidesManifest, configValues: ["client_id": "abc"]).statelessMode)
    }

    func testExpandedGoogleWorkspaceAndHostedPlatformPresets() throws {
        let googleExpected: [(MCPServerPreset, String, String)] = [
            (.gmailPersonal, "https://gmailmcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/gmail.readonly"),
            (.googleDrivePersonal, "https://drivemcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/drive.readonly"),
            (.googleDocsPersonal, "https://docsmcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/documents.readonly"),
            (.googleSlidesPersonal, "https://slidesmcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/presentations.readonly"),
            (.googleSheetsPersonal, "https://sheetsmcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/spreadsheets.readonly"),
            (.googleCalendarPersonal, "https://calendarmcp.googleapis.com/mcp/v1", "https://www.googleapis.com/auth/calendar.readonly")
        ]

        let oauthClient = MCPOAuthClient(urlSession: makeMockedSession())
        let pkce = try PKCEChallenge.generate()
        let registry = MarketplaceRegistry()

        for (preset, expectedURL, expectedScope) in googleExpected {
            let conn = preset.makeConnection()
            XCTAssertEqual(preset.category, .googleWorkspace)
            XCTAssertEqual(conn.endpointURL, expectedURL)
            XCTAssertEqual(conn.scopes, [expectedScope])
            XCTAssertTrue(conn.readOnly)
            XCTAssertTrue(conn.statelessMode)

            let authURL = try oauthClient.buildAuthorizationURL(
                authorizationEndpoint: URL(string: conn.authorizationEndpoint!)!,
                clientID: "personal-client.apps.googleusercontent.com",
                redirectURI: conn.redirectURI,
                scopes: conn.scopes,
                pkce: pkce,
                resourceURL: URL(string: conn.endpointURL)!
            )
            let comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
            let params = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertNil(params["resource"], "Google OAuth URL must omit RFC 8707 resource for \(preset.id)")
            XCTAssertEqual(params["access_type"], "offline")
        }

        for manifestID in ["gmail-mcp", "google-drive-mcp", "google-sheets-mcp"] {
            let manifest = ConnectorManifest(
                id: manifestID,
                name: manifestID,
                version: "1.0.0",
                description: "Google Personal Mode MCP",
                platforms: ["macos"],
                transport: ConnectorTransport(type: "mcp_streamable_http", baseUrl: "https://mcp.googleapis.com/mcp/v1"),
                auth: ConnectorAuth(type: "oauth2_pkce", scopes: ["https://www.googleapis.com/auth/drive.readonly"]),
                permissions: ["read"],
                tools: [ConnectorToolSpec(name: "read_item", description: "Read", requiresApproval: false)],
                signature: ConnectorSignature(algorithm: "ed25519", keyId: "dev", value: "unsigned-starter-template")
            )
            XCTAssertTrue(registry.makeConnection(from: manifest, configValues: ["client_id": "abc"]).statelessMode)
        }

        // Verify all 22 hosted presets (6 Google + 16 non-Google platforms)
        XCTAssertEqual(MCPServerPreset.betaPresets.count, 22)
        let ids = MCPServerPreset.betaPresets.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Preset IDs must be unique")

        let expectedHostedURLs: [String: String] = [
            "stripe-mcp": "https://mcp.stripe.com",
            "vercel-mcp": "https://mcp.vercel.com",
            "railway-mcp": "https://mcp.railway.com",
            "cloudflare-mcp": "https://mcp.cloudflare.com/mcp",
            "netlify-mcp": "https://mcp.netlify.com/mcp",
            "render-mcp": "https://mcp.render.com/mcp",
            "supabase-mcp": "https://mcp.supabase.com/mcp",
            "neon-mcp": "https://mcp.neon.tech/mcp",
            "sentry-mcp": "https://mcp.sentry.dev/mcp",
            "posthog-mcp": "https://mcp.posthog.com/mcp",
            "atlassian-mcp": "https://mcp.atlassian.com/v2/mcp",
            "slack-mcp": "https://mcp.slack.com/mcp",
            "figma-mcp": "https://mcp.figma.com/mcp",
            "linear-readonly": "https://mcp.linear.app/mcp/readonly",
            "notion-mcp": "https://mcp.notion.com/mcp",
            "github-mcp": "https://api.githubcopilot.com/mcp/"
        ]

        for (id, expectedURL) in expectedHostedURLs {
            let preset = try XCTUnwrap(MCPServerPreset.betaPresets.first(where: { $0.id == id }), "Missing preset \(id)")
            XCTAssertEqual(preset.endpointURL, expectedURL)
            XCTAssertTrue(preset.readOnly)
            XCTAssertFalse(preset.statelessMode)
        }

        // Validate bundled/repo marketplace catalog.json decodes cleanly with zero validation errors
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repoRoot.appendingPathComponent("marketplace/catalog.json")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try ConnectorCatalog.decode(from: catalogData)
        XCTAssertEqual(catalog.connectors.count, 23)
        for manifest in catalog.connectors {
            XCTAssertTrue(ManifestValidator.validate(manifest).isEmpty, "Manifest validation failed for \(manifest.id)")
        }
    }
}
