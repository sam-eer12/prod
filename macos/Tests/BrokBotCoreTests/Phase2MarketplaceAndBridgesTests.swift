import CryptoKit
import Foundation
import Network
import XCTest
@testable import BrokBotCore

private final class Phase2MockRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)

    static let shared = Phase2MockRegistry()
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

private final class Phase2MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = Phase2MockRegistry.shared.handler(for: host) else {
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
        if let body = request.httpBody { return body }
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

private final class Phase2LockedBox<Value>: @unchecked Sendable {
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

private final class Phase2LockedFlag: @unchecked Sendable {
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

/// Ephemeral loopback TCP JSON-RPC 2.0 mock server simulating `brokbot_blender_bridge.py`.
private actor MockBlenderSocketServer {
    private var listener: NWListener?
    private(set) var executedMethods: [String] = []
    // Valid 1x1 transparent PNG
    static let samplePNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

    func start() async throws -> Int {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let flag = Phase2LockedFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let assigned = listener.port?.rawValue, flag.claim() {
                        cont.resume(returning: assigned)
                    }
                case .failed(let error):
                    if flag.claim() {
                        cont.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task {
                    await self?.handleConnection(conn)
                }
            }
            listener.start(queue: DispatchQueue(label: "org.brokbot.tests.mockblender"))
        }
        return Int(port)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func recordMethod(_ method: String) {
        executedMethods.append(method)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "org.brokbot.tests.mockblender.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            Task {
                await self.processRequest(data, over: connection)
            }
        }
    }

    private func processRequest(_ data: Data, over connection: NWConnection) {
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lineData = line.data(using: .utf8),
              let req = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let method = req["method"] as? String else {
            connection.cancel()
            return
        }
        recordMethod(method)
        let reqID = req["id"] ?? "1"

        let result: [String: Any]
        switch method {
        case "blender_get_scene_info":
            result = [
                "scene": "Scene",
                "objectCount": 3,
                "objects": [["name": "Cube", "type": "MESH"]]
            ]
        case "blender_render_preview":
            result = [
                "status": "ok",
                "mimeType": "image/png",
                "width": 640,
                "height": 360,
                "imageBase64": Self.samplePNGBase64
            ]
        case "blender_execute_script":
            let params = req["params"] as? [String: Any]
            let code = params?["code"] as? String ?? ""
            result = [
                "status": "ok",
                "stdout": "Executed \(code.count) chars"
            ]
        default:
            result = ["status": "unknown"]
        }

        let responseObj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": reqID,
            "result": result
        ]
        var outData = (try? JSONSerialization.data(withJSONObject: responseObj)) ?? Data()
        outData.append(0x0A)
        connection.send(content: outData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

final class Phase2MarketplaceAndBridgesTests: XCTestCase {
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase2MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brokbot-phase2-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeTempVault() async throws -> BrokVaultManager {
        let dir = try makeTempDir()
        let manager = BrokVaultManager(
            vaultURL: dir.appendingPathComponent("vault.enc"),
            keyProvider: StaticVaultKeyProvider(seed: "phase2-test-seed")
        )
        try await manager.unlock()
        return manager
    }

    // MARK: - 1. Ed25519 Manifest Signing, Tamper Rejection & Marketplace Registry

    func testEd25519ManifestSigningTamperRejectionAndRegistryLoad() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let keyId = "brokbot-prod-2026"
        let baseManifest = ConnectorManifest(
            id: "linear-readonly",
            name: "Linear (Read-Only MCP)",
            version: "1.0.0",
            description: "Official Linear MCP connector.",
            platforms: ["macos"],
            transport: ConnectorTransport(type: "mcp_streamable_http", baseUrl: "https://mcp.linear.app/mcp/readonly"),
            auth: ConnectorAuth(type: "oauth2_pkce", scopes: ["read"]),
            permissions: ["linear.issues.read"],
            tools: [
                ConnectorToolSpec(name: "list_issues", description: "List issues", requiresApproval: false)
            ],
            signature: ConnectorSignature(algorithm: "ed25519", keyId: keyId, value: "unsigned-starter-template")
        )

        let signedManifest = try ManifestSignatureVerifier.sign(
            manifest: baseManifest,
            privateKey: privateKey,
            keyId: keyId
        )

        let trustedKeys = [keyId: privateKey.publicKey.rawRepresentation]
        XCTAssertEqual(
            ManifestSignatureVerifier.verify(manifest: signedManifest, trustedPublicKeys: trustedKeys),
            .verified(keyId: keyId)
        )

        // Tamper a single field -> must fail with .invalidSignature and throw on install
        var tampered = signedManifest
        tampered.tools[0].requiresApproval = true
        XCTAssertEqual(
            ManifestSignatureVerifier.verify(manifest: tampered, trustedPublicKeys: trustedKeys),
            .invalidSignature
        )

        let dir = try makeTempDir()
        let catalogHost = "marketplace-\(UUID().uuidString.lowercased()).local"
        defer { Phase2MockRegistry.shared.unregister(host: catalogHost) }

        let catalog = ConnectorCatalog(
            schemaVersion: "1.0.0",
            updatedAt: "2026-11-25T00:00:00Z",
            connectors: [signedManifest, tampered]
        )
        let catalogData = try JSONEncoder().encode(catalog)
        Phase2MockRegistry.shared.register(host: catalogHost) { request, _ in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, catalogData)
        }

        let registry = MarketplaceRegistry(
            urlSession: makeMockedSession(),
            cacheURL: dir.appendingPathComponent("cache.json"),
            trustedPublicKeys: trustedKeys
        )

        let entries = try await registry.loadCatalog(remoteURL: URL(string: "https://\(catalogHost)/catalog.json")!)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].verification.isVerified)
        XCTAssertEqual(entries[1].verification, .invalidSignature)

        try await registry.validateForInstallation(signedManifest, allowUnsignedTemplates: false)
        do {
            try await registry.validateForInstallation(tampered, allowUnsignedTemplates: true)
            XCTFail("Tampered manifest must ALWAYS be rejected even when allowUnsignedTemplates is true")
        } catch let err as MarketplaceError {
            XCTAssertEqual(err, .signatureRejected(.invalidSignature))
        }

        // ManifestValidator rejects invalid kebab-case ID and empty tools
        var invalidManifest = signedManifest
        invalidManifest.id = "Bad_ID!"
        invalidManifest.tools = []
        let validationErrors = ManifestValidator.validate(invalidManifest)
        XCTAssertGreaterThanOrEqual(validationErrors.count, 2)
    }

    // MARK: - 2. Local Stdio MCP Process Runner

    func testLocalStdioMCPDiscoveryAndToolCall() async throws {
        let pythonScript = """
        import json, sys
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get("method")
            req_id = msg.get("id")
            if method == "initialize":
                print(json.dumps({"jsonrpc":"2.0","id":req_id,"result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"LocalPyMCP","version":"1.0"}}}), flush=True)
            elif method == "tools/list":
                print(json.dumps({"jsonrpc":"2.0","id":req_id,"result":{"tools":[{"name":"echo_note","description":"Echo a note","annotations":{"readOnlyHint":True}}]}}), flush=True)
            elif method == "tools/call":
                args = msg.get("params", {}).get("arguments", {})
                print(json.dumps({"jsonrpc":"2.0","id":req_id,"result":{"content":[{"type":"text","text":"Stdio echo: " + str(args.get("text", ""))}]}}), flush=True)
        """

        let stdioClient = MCPStdioClient()
        let (handshake, tools) = try await stdioClient.initializeAndListTools(
            command: "/usr/bin/python3",
            arguments: ["-u", "-c", pythonScript]
        )
        XCTAssertEqual(handshake.serverName, "LocalPyMCP")
        XCTAssertEqual(tools.map(\.name), ["echo_note"])

        let vault = try await makeTempVault()
        let manager = MCPConnectionManager(vault: vault, stdioClient: stdioClient)
        let connection = MCPServerConnection(
            id: "local-py",
            name: "Local Python MCP",
            transportKind: .stdio,
            endpointURL: "",
            stdioCommand: "/usr/bin/python3",
            stdioArgs: ["-u", "-c", pythonScript],
            authMode: .none,
            readOnly: true,
            discoveredTools: tools
        )
        let (_, routes) = manager.buildActiveToolDefinitions(from: [connection])
        let result = await manager.executeToolCall(
            record: ToolCallRecord(id: "call_stdio", name: "local-py__echo_note", argumentsJSON: #"{"text":"hello stdio"}"#),
            routes: routes,
            connections: [connection],
            onElicitationRequested: { _ in }
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.outputText, "Stdio echo: hello stdio")
    }

    // MARK: - 3. Blender 3D TCP Socket Bridge & Client-Side Write Approval Gate

    func testBlenderBridgeRenderPreviewAndWriteApprovalGate() async throws {
        let server = MockBlenderSocketServer()
        let port = try await server.start()
        defer {
            Task { await server.stop() }
        }

        let vault = try await makeTempVault()
        let registry = MarketplaceRegistry()
        let manager = MCPConnectionManager(vault: vault)

        let blenderManifest = ConnectorManifest(
            id: "blender-3d",
            name: "Blender 3D Bridge",
            version: "1.0.0",
            description: "Local TCP bridge",
            platforms: ["macos"],
            transport: ConnectorTransport(type: "tcp_jsonrpc", host: "127.0.0.1", port: port),
            auth: ConnectorAuth(type: "none"),
            permissions: ["local_socket", "execute_bpy_script"],
            tools: [
                ConnectorToolSpec(name: "blender_get_scene_info", description: "Inspect scene", requiresApproval: false),
                ConnectorToolSpec(name: "blender_execute_script", description: "Run bpy script", requiresApproval: true),
                ConnectorToolSpec(name: "blender_render_preview", description: "Render PNG", requiresApproval: false)
            ],
            signature: ConnectorSignature(algorithm: "ed25519", keyId: "dev", value: "unsigned-starter-template")
        )

        var connection = registry.makeConnection(from: blenderManifest)
        let (connected, handshake) = try await manager.connectAndDiscoverTools(for: connection)
        connection = connected
        XCTAssertTrue(handshake.serverName?.contains("Blender 3D Bridge") ?? false)

        let (_, routes) = manager.buildActiveToolDefinitions(from: [connection])

        // 1. Render preview returns inline PNG attachment with PNG magic header
        let renderResult = await manager.executeToolCall(
            record: ToolCallRecord(id: "call_render", name: "blender-3d__blender_render_preview", argumentsJSON: #"{"width":640,"height":360}"#),
            routes: routes,
            connections: [connection],
            onElicitationRequested: { _ in }
        )
        XCTAssertFalse(renderResult.isError)
        XCTAssertEqual(renderResult.attachments.count, 1)
        let pngData = try XCTUnwrap(renderResult.attachments.first?.decodedData)
        XCTAssertEqual(Array(pngData.prefix(4)), [0x89, 0x50, 0x4E, 0x47]) // \x89PNG

        // 2. Denied `blender_execute_script` MUST NOT hit the TCP server
        let deniedPrompt = Phase2LockedBox<MCPElicitationRequest?>(nil)
        let deniedResult = await manager.executeToolCall(
            record: ToolCallRecord(
                id: "call_bpy_deny",
                name: "blender-3d__blender_execute_script",
                argumentsJSON: #"{"code":"import bpy\nbpy.ops.mesh.primitive_cube_add()"}"#
            ),
            routes: routes,
            connections: [connection],
            onElicitationRequested: { req in
                deniedPrompt.withValue { $0 = req }
                Task {
                    await manager.respondToElicitation(requestID: req.id, response: MCPElicitationResponse(action: .decline))
                }
            }
        )
        XCTAssertTrue(deniedResult.isError)
        XCTAssertEqual(deniedResult.elicitationAction, .decline)
        let capturedPrompt = try XCTUnwrap(deniedPrompt.withValue { $0 })
        XCTAssertEqual(capturedPrompt.mode, .clientApproval)
        XCTAssertTrue(capturedPrompt.codePreview?.contains("primitive_cube_add") ?? false)
        let methodsBeforeApprove = await server.executedMethods
        XCTAssertFalse(methodsBeforeApprove.contains("blender_execute_script"))

        // 3. Approved `blender_execute_script` executes over TCP JSON-RPC
        let approvedResult = await manager.executeToolCall(
            record: ToolCallRecord(
                id: "call_bpy_ok",
                name: "blender-3d__blender_execute_script",
                argumentsJSON: #"{"code":"import bpy\nbpy.ops.mesh.primitive_cube_add()"}"#
            ),
            routes: routes,
            connections: [connection],
            onElicitationRequested: { req in
                Task {
                    await manager.respondToElicitation(requestID: req.id, response: MCPElicitationResponse(action: .accept))
                }
            }
        )
        XCTAssertFalse(approvedResult.isError)
        XCTAssertEqual(approvedResult.elicitationAction, .accept)
        let methodsAfterApprove = await server.executedMethods
        XCTAssertTrue(methodsAfterApprove.contains("blender_execute_script"))
    }

    // MARK: - 4. Multi-Turn BYOKModelClient + MCPConnectionManager Round-Trip & Decline Flow

    func testMultiTurnBYOKWithMCPToolExecutionAndDeclineElicitation() async throws {
        let llmHost = "llm-phase2-\(UUID().uuidString.lowercased()).local"
        let mcpHost = "mcp-phase2-\(UUID().uuidString.lowercased()).local"
        defer {
            Phase2MockRegistry.shared.unregister(host: llmHost)
            Phase2MockRegistry.shared.unregister(host: mcpHost)
        }

        let llmRound = Phase2LockedBox(0)
        let sawToolMessageInRound2 = Phase2LockedBox(false)

        Phase2MockRegistry.shared.register(host: llmHost) { request, bodyData in
            let round = llmRound.withValue { val -> Int in
                val += 1
                return val
            }
            if round == 1 {
                let sse = """
                data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_mcp_1","type":"function","function":{"name":"linear-ro__list_issues","arguments":"{\\"limit\\":1}"}}]}}]}

                data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

                data: [DONE]

                """
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!
                return (resp, Data(sse.utf8))
            }

            let bodyText = String(decoding: bodyData ?? Data(), as: UTF8.self)
            if bodyText.contains("BROK-42: Launch Phase 2") {
                sawToolMessageInRound2.withValue { $0 = true }
            }
            let sse2 = """
            data: {"choices":[{"delta":{"content":"You have 1 Linear issue: BROK-42."},"finish_reason":"stop"}]}

            data: [DONE]

            """
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (resp, Data(sse2.utf8))
        }

        Phase2MockRegistry.shared.register(host: mcpHost) { request, bodyData in
            let obj = (try? JSONSerialization.jsonObject(with: bodyData ?? Data()) as? [String: Any]) ?? [:]
            let reqID = obj["id"] ?? "1"
            let payload = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": reqID,
                "result": [
                    "content": [["type": "text", "text": "BROK-42: Launch Phase 2"]]
                ]
            ])
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, payload)
        }

        let session = makeMockedSession()
        let byokClient = BYOKModelClient(urlSession: session)
        let vault = try await makeTempVault()
        let mcpManager = MCPConnectionManager(
            vault: vault,
            oauthClient: MCPOAuthClient(urlSession: session),
            mcpClient: MCPStreamableHTTPClient(urlSession: session)
        )

        let connection = MCPServerConnection(
            id: "linear-ro",
            name: "Linear",
            endpointURL: "https://\(mcpHost)/mcp",
            authMode: .none,
            readOnly: true,
            statelessMode: true,
            discoveredTools: [
                MCPDiscoveredTool(name: "list_issues", description: "List issues", readOnlyHint: true)
            ]
        )
        let (toolDefs, routes) = mcpManager.buildActiveToolDefinitions(from: [connection])
        let byokConfig = BYOKConfiguration(
            provider: .openAI,
            modelID: "gpt-4.1",
            customBaseURL: URL(string: "https://\(llmHost)/v1")!
        )

        var history = [BYOKChatMessage(role: .user, content: "What Linear issues are open?")]
        var finalAssistantText = ""

        for _ in 0..<4 {
            let req = BYOKChatRequest(
                configuration: byokConfig,
                apiKey: "test-key",
                messages: history,
                tools: toolDefs
            )
            var roundText = ""
            var roundCalls: [ToolCallRecord] = []
            for try await event in byokClient.streamChat(req) {
                switch event {
                case .textDelta(let delta): roundText.append(delta)
                case .toolCall(let call): roundCalls.append(call)
                case .usage, .finished: break
                }
            }
            if roundCalls.isEmpty {
                finalAssistantText = roundText
                break
            }
            history.append(BYOKChatMessage(role: .assistant, content: roundText, toolCalls: roundCalls))
            for call in roundCalls {
                let res = await mcpManager.executeToolCall(
                    record: call,
                    routes: routes,
                    connections: [connection],
                    onElicitationRequested: { _ in }
                )
                history.append(BYOKChatMessage(role: .tool, content: res.outputText, toolCallID: call.id))
            }
        }

        XCTAssertTrue(sawToolMessageInRound2.withValue { $0 })
        XCTAssertEqual(finalAssistantText, "You have 1 Linear issue: BROK-42.")
    }
}
