import XCTest
@testable import BrokBotCore

final class BrokBotCoreTests: XCTestCase {
    func testWorkingContextRollingWindowAndReset() async {
        // Each message below is 40 chars -> 10 tokens. Budget 25 allows at most 2 messages (20 tokens).
        let store = WorkingContextStore(maxTokenBudget: 25)

        let msg1 = ChatMessage(role: .user, content: String(repeating: "a", count: 40))
        let msg2 = ChatMessage(role: .assistant, content: String(repeating: "b", count: 40))
        let msg3 = ChatMessage(role: .user, content: String(repeating: "c", count: 40))

        await store.append(msg1)
        await store.append(msg2)
        var initialTokens = await store.estimatedTokenCount()
        var currentMessages = await store.messages()
        XCTAssertEqual(currentMessages.count, 2)
        XCTAssertEqual(initialTokens, 20)

        await store.append(msg3)
        currentMessages = await store.messages()
        initialTokens = await store.estimatedTokenCount()
        XCTAssertEqual(currentMessages.count, 2)
        XCTAssertEqual(currentMessages.map(\.id), [msg2.id, msg3.id])
        XCTAssertLessThanOrEqual(initialTokens, 25)

        await store.reset()
        let afterReset = await store.messages()
        let tokensAfterReset = await store.estimatedTokenCount()
        XCTAssertTrue(afterReset.isEmpty)
        XCTAssertEqual(tokensAfterReset, 0)
    }

    func testPermanentMemoryNaturalLanguageCommandsAndPassthrough() async throws {
        let manager = PermanentContextEnclaveManager(vault: InMemoryVaultStore())

        // Normal conversational prompts must pass through without mutating permanent memory
        let normalReply = try await manager.executeMemoryCommand("How many planets are in the solar system?")
        XCTAssertNil(normalReply)
        let normalReply2 = try await manager.executeMemoryCommand("Please don't forget to summarize the meeting.")
        XCTAssertNil(normalReply2)

        // Store commands
        let storeNotice1 = try await manager.executeMemoryCommand("Store this in your memory: My preferred flight seat is aisle")
        XCTAssertNotNil(storeNotice1)
        let storeNotice2 = try await manager.executeMemoryCommand("Remember: Frequent flyer number is UA-98421")
        XCTAssertNotNil(storeNotice2)

        var entries = try await manager.listEntries()
        XCTAssertEqual(entries.count, 2)

        // Update command
        let updateNotice = try await manager.executeMemoryCommand("Update my memory about flight seat to My preferred flight seat is window")
        XCTAssertNotNil(updateNotice)
        entries = try await manager.listEntries()
        XCTAssertTrue(entries.contains(where: { $0.content == "My preferred flight seat is window" }))
        XCTAssertFalse(entries.contains(where: { $0.content.contains("aisle") }))

        // Forget / Delete commands
        let forgetNotice = try await manager.executeMemoryCommand("Forget about flight seat")
        XCTAssertNotNil(forgetNotice)
        entries = try await manager.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.content, "Frequent flyer number is UA-98421")

        let deleteNotice = try await manager.executeMemoryCommand("Delete UA-98421 from your memory")
        XCTAssertNotNil(deleteNotice)
        entries = try await manager.listEntries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testMemoryCommandParserPatterns() {
        XCTAssertEqual(
            MemoryCommandParser.parse("store memory: Dark mode preferred"),
            .store("Dark mode preferred")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("Store this in your memory: Coffee black"),
            .store("Coffee black")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("remember: Timezone is America/Los_Angeles"),
            .store("Timezone is America/Los_Angeles")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("update memory timezone with America/New_York"),
            .update(target: "timezone", replacement: "America/New_York")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("forget Coffee"),
            .delete(target: "Coffee")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("delete Coffee from memory"),
            .delete(target: "Coffee")
        )
        XCTAssertNil(MemoryCommandParser.parse("Can you update the draft email for me?"))
    }

    func testSemanticCompactorDeduplication() async throws {
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_010_000)

        let older = MemoryEntry(category: "travel", content: "  Prefers   AISLE seat ", lastUpdated: olderDate, confidence: 0.8)
        let newer = MemoryEntry(category: "travel", content: "prefers aisle seat", lastUpdated: newerDate, confidence: 1.0)
        let distinct = MemoryEntry(category: "diet", content: "Vegetarian", lastUpdated: olderDate, confidence: 1.0)

        let vault = InMemoryVaultStore(initialEntries: [older, newer, distinct])
        let manager = PermanentContextEnclaveManager(vault: vault)

        let removed = try await manager.autoCompact()
        XCTAssertEqual(removed, 1)

        let entries = try await manager.listEntries()
        XCTAssertEqual(entries.count, 2)
        let travelEntry = try XCTUnwrap(entries.first(where: { $0.category == "travel" }))
        XCTAssertEqual(travelEntry.id, newer.id)
        XCTAssertEqual(travelEntry.lastUpdated, newerDate)
    }

    func testBrokComputeEngineThreadClampingAndHardwareAccelToggle() {
        // Simulate a 2-core host to verify clamping for .four and .auto, plus lower-bound clamping
        let engine = BrokComputeEngine(
            configuration: ComputeConfiguration(threadAllocation: .one, hardwareAccelerationEnabled: true),
            processorCountProvider: { 2 }
        )

        XCTAssertEqual(engine.maxConcurrentOperationCount, 1)
        XCTAssertTrue(engine.hardwareAccelerationEnabled)

        engine.setThreadAllocation(.four)
        XCTAssertEqual(engine.maxConcurrentOperationCount, 2)

        engine.setThreadCount(0)
        XCTAssertEqual(engine.maxConcurrentOperationCount, 1)

        engine.setThreadCount(99)
        XCTAssertEqual(engine.maxConcurrentOperationCount, 2)

        engine.setHardwareAccelerationEnabled(false)
        XCTAssertFalse(engine.hardwareAccelerationEnabled)
        XCTAssertFalse(engine.configuration.hardwareAccelerationEnabled)

        // Verify system-level engine respects 1...ProcessInfo.processInfo.processorCount
        let systemEngine = BrokComputeEngine(processorCountProvider: { ProcessInfo.processInfo.processorCount })
        systemEngine.setThreadAllocation(.four)
        XCTAssertGreaterThanOrEqual(systemEngine.maxConcurrentOperationCount, 1)
        XCTAssertLessThanOrEqual(systemEngine.maxConcurrentOperationCount, max(1, ProcessInfo.processInfo.processorCount))
    }

    func testConnectorCatalogDecoding() throws {
        let sampleJSON = """
        {
          "schemaVersion": "1.0.0",
          "updatedAt": "2026-11-24T00:00:00Z",
          "connectors": [
            {
              "id": "blender-3d",
              "name": "Blender 3D Bridge",
              "version": "1.0.0",
              "description": "Local TCP JSON-RPC 2.0 bridge for Blender.",
              "manifestPath": "manifests/blender-3d.json",
              "platforms": ["macos"],
              "transport": {
                "type": "tcp_jsonrpc",
                "host": "127.0.0.1",
                "port": 9876
              },
              "auth": {
                "type": "none",
                "scopes": []
              },
              "permissions": ["local_socket", "execute_bpy_script"],
              "tools": [
                {
                  "name": "blender_get_scene_info",
                  "description": "Inspect active Blender objects.",
                  "requiresApproval": false
                },
                {
                  "name": "blender_execute_script",
                  "description": "Execute a generated Python (bpy) script.",
                  "requiresApproval": true
                }
              ],
              "signature": {
                "algorithm": "ed25519",
                "keyId": "brokbot-marketplace-dev-2026",
                "value": "unsigned-starter-template"
              }
            },
            {
              "id": "google-workspace",
              "name": "Google Workspace",
              "version": "1.0.0",
              "description": "Client-side Gmail and Google Calendar integration.",
              "manifestPath": "manifests/google-workspace.json",
              "platforms": ["macos", "android"],
              "transport": {
                "type": "rest_http",
                "baseUrl": "https://www.googleapis.com",
                "pollingIntervalSeconds": 300
              },
              "auth": {
                "type": "oauth2_pkce",
                "authorizationEndpoint": "https://accounts.google.com/o/oauth2/v2/auth",
                "tokenEndpoint": "https://oauth2.googleapis.com/token",
                "redirectUri": "http://127.0.0.1:48912/callback",
                "scopes": ["https://www.googleapis.com/auth/gmail.readonly"]
              },
              "permissions": ["gmail.readonly"],
              "tools": [
                {
                  "name": "gmail_list_messages",
                  "description": "Query primary unread messages.",
                  "requiresApproval": false
                },
                {
                  "name": "gmail_send_message",
                  "description": "Send an email reply after explicit approval.",
                  "requiresApproval": true
                }
              ],
              "signature": {
                "algorithm": "ed25519",
                "keyId": "brokbot-marketplace-dev-2026",
                "value": "unsigned-starter-template"
              }
            }
          ]
        }
        """

        let data = Data(sampleJSON.utf8)
        let catalog = try ConnectorCatalog.decode(from: data)

        XCTAssertEqual(catalog.schemaVersion, "1.0.0")
        XCTAssertEqual(catalog.connectors.count, 2)

        let blender = try XCTUnwrap(catalog.connectors.first(where: { $0.id == "blender-3d" }))
        XCTAssertEqual(blender.transport.type, "tcp_jsonrpc")
        XCTAssertEqual(blender.transport.host, "127.0.0.1")
        XCTAssertEqual(blender.transport.port, 9876)
        XCTAssertEqual(blender.tools.count, 2)
        XCTAssertFalse(blender.tools[0].requiresApproval)
        XCTAssertTrue(blender.tools[1].requiresApproval)
        XCTAssertEqual(blender.signature.algorithm, "ed25519")

        let google = try XCTUnwrap(catalog.connectors.first(where: { $0.id == "google-workspace" }))
        XCTAssertEqual(google.transport.type, "rest_http")
        XCTAssertEqual(google.transport.pollingIntervalSeconds, 300)
        XCTAssertEqual(google.auth.type, "oauth2_pkce")
        XCTAssertEqual(google.tools.count, 2)
        XCTAssertTrue(google.tools[1].requiresApproval)
    }
}
