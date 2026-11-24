import CryptoKit
import Foundation
import XCTest
@testable import BrokBotCore

final class VaultAndContextTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brokbot-vault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Phase 1B: BrokVaultManager

    func testVaultAES256GCMRoundTripPermissionsAndLockState() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vaultURL = tempDir.appendingPathComponent("vault.enc")
        let keyProvider = PassphraseVaultKeyProvider(passphrase: "brok-vault-test-passphrase-2026")
        let vault = BrokVaultManager(vaultURL: vaultURL, keyProvider: keyProvider)

        // Locked initially
        let initialUnlocked = await vault.isUnlocked()
        XCTAssertFalse(initialUnlocked)

        do {
            _ = try await vault.loadEntries()
            XCTFail("Expected BrokVaultError.vaultLocked when reading locked vault")
        } catch let error as BrokVaultError {
            XCTAssertEqual(error, .vaultLocked)
        }

        // Unlock and persist entries + BYOK keys
        try await vault.unlock(reason: "Unit test unlock")
        let unlockedNow = await vault.isUnlocked()
        XCTAssertTrue(unlockedNow)

        let entryDate = Date(timeIntervalSince1970: 1_700_123_456.789)
        let entry = MemoryEntry(
            category: "travel",
            content: "My preferred flight seat is window",
            lastUpdated: entryDate,
            confidence: 0.95
        )
        try await vault.saveEntries([entry])
        try await vault.setAPIKey("sk-openai-secret-token-xyz", for: .openAI)
        try await vault.setAPIKey("or-openrouter-secret-abc", for: .openRouter)

        // Verify disk artifact exists, has 0600 permissions, and hides plaintext secrets
        XCTAssertTrue(FileManager.default.fileExists(atPath: vaultURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
        let posixPermissions = attributes[.posixPermissions] as? Int
        XCTAssertEqual(posixPermissions, 0o600)

        let rawBytes = try Data(contentsOf: vaultURL)
        XCTAssertEqual(rawBytes.prefix(4), Data("BRKV".utf8))
        XCTAssertEqual(rawBytes[4], 1)
        XCTAssertGreaterThanOrEqual(rawBytes.count, 4 + 1 + 32 + 12 + 16)
        XCTAssertNil(rawBytes.range(of: Data("My preferred flight seat is window".utf8)))
        XCTAssertNil(rawBytes.range(of: Data("sk-openai-secret-token-xyz".utf8)))

        // Round-trip from a fresh BrokVaultManager instance reading vault.enc from disk
        let reloadedVault = BrokVaultManager(vaultURL: vaultURL, keyProvider: keyProvider)
        try await reloadedVault.unlock(reason: "Reload test")

        let loadedEntries = try await reloadedVault.loadEntries()
        XCTAssertEqual(loadedEntries, [entry])
        let loadedOpenAI = try await reloadedVault.apiKey(for: .openAI)
        let loadedOpenRouter = try await reloadedVault.apiKey(for: .openRouter)
        let loadedGemini = try await reloadedVault.apiKey(for: .gemini)
        XCTAssertEqual(loadedOpenAI, "sk-openai-secret-token-xyz")
        XCTAssertEqual(loadedOpenRouter, "or-openrouter-secret-abc")
        XCTAssertNil(loadedGemini)

        // Lock clears in-memory master key and blocks subsequent access
        await reloadedVault.lock()
        let unlockedAfterLock = await reloadedVault.isUnlocked()
        XCTAssertFalse(unlockedAfterLock)
        do {
            _ = try await reloadedVault.apiKey(for: .openAI)
            XCTFail("Expected BrokVaultError.vaultLocked after lock()")
        } catch let error as BrokVaultError {
            XCTAssertEqual(error, .vaultLocked)
        }
    }

    func testVaultTamperDetectionAndWrongPassphrase() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vaultURL = tempDir.appendingPathComponent("vault.enc")
        let keyProvider = PassphraseVaultKeyProvider(passphrase: "correct-horse-battery-staple")
        let vault = BrokVaultManager(vaultURL: vaultURL, keyProvider: keyProvider)
        try await vault.unlock(reason: "Initial write")
        try await vault.saveEntries([MemoryEntry(category: "identity", content: "Timezone is UTC")])

        // Wrong passphrase must fail integrity check on unlock and remain locked
        let wrongProvider = PassphraseVaultKeyProvider(passphrase: "wrong-passphrase")
        let wrongVault = BrokVaultManager(vaultURL: vaultURL, keyProvider: wrongProvider)
        do {
            try await wrongVault.unlock(reason: "Wrong key test")
            XCTFail("Expected BrokVaultError.integrityCheckFailed for wrong passphrase")
        } catch let error as BrokVaultError {
            XCTAssertEqual(error, .integrityCheckFailed)
        }
        let wrongUnlocked = await wrongVault.isUnlocked()
        XCTAssertFalse(wrongUnlocked)

        // Tamper ciphertext byte on disk -> integrityCheckFailed
        var tamperedCipher = try Data(contentsOf: vaultURL)
        let targetIndex = tamperedCipher.count - 5
        tamperedCipher[targetIndex] ^= 0xFF
        try tamperedCipher.write(to: vaultURL)

        let freshVault = BrokVaultManager(vaultURL: vaultURL, keyProvider: keyProvider)
        do {
            try await freshVault.unlock(reason: "Tampered cipher test")
            XCTFail("Expected BrokVaultError.integrityCheckFailed for tampered ciphertext")
        } catch let error as BrokVaultError {
            XCTAssertEqual(error, .integrityCheckFailed)
        }

        // Tamper salt byte -> integrityCheckFailed
        let originalVault = BrokVaultManager(vaultURL: tempDir.appendingPathComponent("vault2.enc"), keyProvider: keyProvider)
        try await originalVault.unlock(reason: "Write valid vault2")
        try await originalVault.setAPIKey("sk-ant-123", for: .claude)

        var tamperedSalt = try Data(contentsOf: originalVault.vaultURL)
        tamperedSalt[10] ^= 0x01
        try tamperedSalt.write(to: originalVault.vaultURL)

        let checkSaltVault = BrokVaultManager(vaultURL: originalVault.vaultURL, keyProvider: keyProvider)
        do {
            try await checkSaltVault.unlock(reason: "Tampered salt test")
            XCTFail("Expected BrokVaultError.integrityCheckFailed for tampered salt")
        } catch let error as BrokVaultError {
            XCTAssertEqual(error, .integrityCheckFailed)
        }
    }

    func testVaultBYOKKeyCRUDAndPurgeRewritesVaultWithoutPlaintext() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let vaultURL = tempDir.appendingPathComponent("vault.enc")
        let staticProvider = StaticVaultKeyProvider(seed: "unit-test-static-seed")
        let vault = BrokVaultManager(vaultURL: vaultURL, keyProvider: staticProvider)
        try await vault.unlock(reason: "CRUD test")

        try await vault.setAPIKey("sk-claude-111", for: .claude)
        try await vault.setAPIKey("nvapi-222", for: .nvidiaNIM)
        let providersAfterAdd = try await vault.configuredProviders()
        XCTAssertEqual(providersAfterAdd, [.claude, .nvidiaNIM])

        try await vault.deleteAPIKey(for: .claude)
        let claudeKeyAfterDelete = try await vault.apiKey(for: .claude)
        let providersAfterDelete = try await vault.configuredProviders()
        XCTAssertNil(claudeKeyAfterDelete)
        XCTAssertEqual(providersAfterDelete, [.nvidiaNIM])

        // Integrate PermanentContextEnclaveManager + purge rewrite check
        let enclave = PermanentContextEnclaveManager(vault: vault)
        let storeNotice = try await enclave.executeMemoryCommand(
            "Remember that my frequent flyer code is SECRET-FLYER-9911"
        )
        XCTAssertNotNil(storeNotice)

        let beforePurgeBytes = try Data(contentsOf: vaultURL)
        let beforeSalt = beforePurgeBytes.subdata(in: 5..<37)
        XCTAssertNil(beforePurgeBytes.range(of: Data("SECRET-FLYER-9911".utf8)))

        let forgetNotice = try await enclave.executeMemoryCommand("Forget about SECRET-FLYER-9911")
        XCTAssertEqual(forgetNotice, "Removed 1 record(s) from your permanent memory.")

        let afterPurgeBytes = try Data(contentsOf: vaultURL)
        let afterSalt = afterPurgeBytes.subdata(in: 5..<37)
        XCTAssertNotEqual(beforePurgeBytes, afterPurgeBytes)
        XCTAssertNotEqual(beforeSalt, afterSalt)
        XCTAssertNil(afterPurgeBytes.range(of: Data("SECRET-FLYER-9911".utf8)))

        let remainingEntries = try await enclave.listEntries()
        XCTAssertTrue(remainingEntries.isEmpty)
        let nimStillPresent = try await vault.apiKey(for: .nvidiaNIM)
        XCTAssertEqual(nimStillPresent, "nvapi-222")
    }

    // MARK: - Phase 1C: WorkingContextStore

    func testWorkingContextRollingSummaryAndReplaceMessage() async {
        // Budget 30 tokens (~120 chars total). Summary cap is max(120, 30 / 6) = 120 chars.
        let store = WorkingContextStore(maxTokenBudget: 30)

        let msg1 = ChatMessage(role: .user, content: "First turn about quarterly roadmap and hiring priorities")
        let msg2 = ChatMessage(role: .assistant, content: "Second turn summarizing hiring budget and engineering scope", isStreaming: true)
        let msg3 = ChatMessage(role: .user, content: "Third turn requesting final action items for Friday")

        await store.append(msg1)
        let summaryBeforeEviction = await store.rollingSummary()
        XCTAssertNil(summaryBeforeEviction)

        await store.append(msg2)
        await store.append(msg3)

        let summary = await store.rollingSummary()
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary?.count ?? 0, 120)
        XCTAssertTrue(summary?.contains("First turn") == true || summary?.contains("Second turn") == true)

        let windowMessages = await store.contextWindowMessages()
        let rawMessages = await store.messages()
        XCTAssertEqual(windowMessages.first?.role, .system)
        XCTAssertTrue(windowMessages.first?.content.contains(summary ?? "") == true)
        XCTAssertEqual(Array(windowMessages.dropFirst()), rawMessages)

        // Append many long messages to verify rolling summary stays strictly capped at max(120, budget/6)
        for index in 0..<8 {
            await store.append(
                ChatMessage(
                    role: .user,
                    content: "Long message \(index) " + String(repeating: "x", count: 80)
                )
            )
        }
        let boundedSummary = await store.rollingSummary()
        XCTAssertNotNil(boundedSummary)
        XCTAssertLessThanOrEqual(boundedSummary?.count ?? 0, 120)

        // Test replaceMessage updating streaming state and token usage
        let streamingMsg = ChatMessage(role: .assistant, content: "Partial...", isStreaming: true)
        await store.append(streamingMsg)

        let replaced = await store.replaceMessage(
            id: streamingMsg.id,
            content: "Completed final answer.",
            isStreaming: false,
            promptTokens: 210,
            completionTokens: 48
        )
        XCTAssertTrue(replaced)

        let updatedMessages = await store.messages()
        let updated = updatedMessages.first(where: { $0.id == streamingMsg.id })
        XCTAssertEqual(updated?.content, "Completed final answer.")
        XCTAssertEqual(updated?.isStreaming, false)
        XCTAssertEqual(updated?.promptTokens, 210)
        XCTAssertEqual(updated?.completionTokens, 48)

        let missingReplaced = await store.replaceMessage(
            id: UUID(),
            content: "Missing",
            isStreaming: false,
            promptTokens: nil,
            completionTokens: nil
        )
        XCTAssertFalse(missingReplaced)

        await store.reset()
        let summaryAfterReset = await store.rollingSummary()
        let windowAfterReset = await store.contextWindowMessages()
        XCTAssertNil(summaryAfterReset)
        XCTAssertTrue(windowAfterReset.isEmpty)
    }

    // MARK: - Phase 1C: PermanentMemoryStore & SemanticCompactor

    func testCategoryInferenceExtraPhrasingAndUpdateByID() async throws {
        let manager = PermanentContextEnclaveManager(vault: InMemoryVaultStore())

        XCTAssertEqual(
            MemoryCommandParser.parse("Remember that my preferred flight seat is aisle"),
            .store("my preferred flight seat is aisle")
        )
        XCTAssertEqual(
            MemoryCommandParser.parse("Save to memory: Morning briefing at 8am on weekdays"),
            .store("Morning briefing at 8am on weekdays")
        )

        _ = try await manager.executeMemoryCommand("Remember that my preferred flight seat is aisle")
        _ = try await manager.executeMemoryCommand("Save to memory: My timezone is America/Los_Angeles")
        _ = try await manager.executeMemoryCommand("Store this in your memory: Morning briefing at 8am on weekdays")
        _ = try await manager.executeMemoryCommand("Remember: Project deadline is Friday for VIP client")
        _ = try await manager.executeMemoryCommand("Save to memory: I prefer dark mode and black coffee")
        _ = try await manager.executeMemoryCommand("Remember: Blue folder stays on desk")

        let entries = try await manager.listEntries()
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries[0].category, "travel")
        XCTAssertEqual(entries[1].category, "identity")
        XCTAssertEqual(entries[2].category, "routine")
        XCTAssertEqual(entries[3].category, "work")
        XCTAssertEqual(entries[4].category, "preference")
        XCTAssertEqual(entries[5].category, "user_preference")

        let targetID = entries[4].id
        let didUpdate = try await manager.updateFact(
            id: targetID,
            content: "Prefers light mode and espresso",
            category: "preference"
        )
        XCTAssertTrue(didUpdate)

        let missingUpdate = try await manager.updateFact(
            id: UUID(),
            content: "Non-existent",
            category: nil
        )
        XCTAssertFalse(missingUpdate)

        let updatedEntries = try await manager.listEntries()
        XCTAssertEqual(updatedEntries.first(where: { $0.id == targetID })?.content, "Prefers light mode and espresso")
    }

    func testSemanticCompactorCosineDeduplicationSupersedingAndRanking() {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_010_000)
        let t3 = Date(timeIntervalSince1970: 1_700_020_000)

        // 1. Cosine similarity >= 0.78 within same category merges keeping newest
        let dupOlder = MemoryEntry(
            category: "preference",
            content: "User prefers concise bulleted executive summaries",
            lastUpdated: t1,
            confidence: 0.8
        )
        let dupNewer = MemoryEntry(
            category: "preference",
            content: "User prefers concise bulleted summaries",
            lastUpdated: t2,
            confidence: 1.0
        )
        XCTAssertGreaterThanOrEqual(
            SemanticCompactor.cosineSimilarity(dupOlder.content, dupNewer.content),
            0.78
        )

        // 2. Different category with overlapping words should NOT merge via cosine threshold alone
        let crossCategory = MemoryEntry(
            category: "work",
            content: "User prefers concise bulleted reports",
            lastUpdated: t1,
            confidence: 0.9
        )

        // 3. Superseding subject-fact consolidation
        let seatOld = MemoryEntry(
            category: "travel",
            content: "My preferred flight seat is aisle",
            lastUpdated: t1,
            confidence: 1.0
        )
        let seatNew = MemoryEntry(
            category: "travel",
            content: "My preferred flight seat is window",
            lastUpdated: t3,
            confidence: 1.0
        )
        let tzOld = MemoryEntry(
            category: "identity",
            content: "Timezone is America/Los_Angeles",
            lastUpdated: t1,
            confidence: 0.9
        )
        let tzNew = MemoryEntry(
            category: "identity",
            content: "Timezone is America/New_York",
            lastUpdated: t2,
            confidence: 1.0
        )

        let consolidated = SemanticCompactor.consolidate([
            dupOlder,
            dupNewer,
            crossCategory,
            seatOld,
            seatNew,
            tzOld,
            tzNew
        ])

        XCTAssertEqual(consolidated.count, 4)
        XCTAssertTrue(consolidated.contains(where: { $0.id == dupNewer.id }))
        XCTAssertFalse(consolidated.contains(where: { $0.id == dupOlder.id }))
        XCTAssertTrue(consolidated.contains(where: { $0.id == crossCategory.id }))
        XCTAssertTrue(consolidated.contains(where: { $0.id == seatNew.id }))
        XCTAssertFalse(consolidated.contains(where: { $0.id == seatOld.id }))
        XCTAssertTrue(consolidated.contains(where: { $0.id == tzNew.id }))
        XCTAssertFalse(consolidated.contains(where: { $0.id == tzOld.id }))

        // 4. Relevance ranking by token overlap + recency + confidence
        let coffee = MemoryEntry(category: "preference", content: "Drinks black coffee", lastUpdated: t3, confidence: 1.0)
        let airline = MemoryEntry(category: "travel", content: "Preferred airline is United", lastUpdated: t2, confidence: 0.9)
        let ranked = SemanticCompactor.relevantEntries(
            for: "Book a flight seat on United",
            from: [coffee, seatNew, airline],
            limit: 2
        )
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(Set(ranked.map(\.id)), Set([seatNew.id, airline.id]))
    }

    // MARK: - Phase 1C: DualSpacePromptAssembler

    func testDualSpacePromptAssemblerCombinesSpacesAndEstimatesTokens() {
        var persona = BotPersona.chiefOfStaff
        persona.pinnedToolIDs = ["gmail_list_messages", "gcal_list_events"]

        let now = Date()
        let travelFact = MemoryEntry(
            category: "travel",
            content: "My preferred flight seat is window",
            lastUpdated: now,
            confidence: 1.0
        )
        let routineFact = MemoryEntry(
            category: "routine",
            content: "Morning briefing at 8am on weekdays",
            lastUpdated: now.addingTimeInterval(-3600),
            confidence: 0.9
        )
        let unrelatedFact = MemoryEntry(
            category: "preference",
            content: "Prefers dark mode in IDE",
            lastUpdated: now.addingTimeInterval(-86_400),
            confidence: 0.7
        )

        let workingTurns = [
            ChatMessage(role: .user, content: "Check my United flight confirmation."),
            ChatMessage(role: .assistant, content: "Checking your itinerary now.")
        ]

        let assembled = DualSpacePromptAssembler.assemble(
            persona: persona,
            permanentEntries: [unrelatedFact, routineFact, travelFact],
            workingMessages: workingTurns,
            rollingSummary: "User asked about SFO trip earlier.",
            latestUserQuery: "Reserve my preferred flight seat",
            maxMemoryEntries: 2
        )

        XCTAssertTrue(assembled.systemPrompt.contains(persona.systemPrompt))
        XCTAssertTrue(assembled.systemPrompt.contains("gmail_list_messages"))
        XCTAssertTrue(assembled.systemPrompt.contains("My preferred flight seat is window"))
        XCTAssertTrue(assembled.systemPrompt.contains("User asked about SFO trip earlier."))
        XCTAssertEqual(assembled.injectedMemoryCount, 2)
        XCTAssertEqual(assembled.messages, workingTurns)

        let expectedTokens = WorkingContextStore.estimateTokens(for: assembled.systemPrompt)
            + workingTurns.reduce(0) { $0 + WorkingContextStore.estimateTokens(for: $1.content) }
        XCTAssertEqual(assembled.estimatedTotalTokens, expectedTokens)
    }

    // MARK: - Phase 1C: WorkspacePersistenceStore & Backward-Compatible Codable

    func testWorkspacePersistenceStoreRoundTripAndLegacyModelDecoding() async throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("workspace.json")
        let store = WorkspacePersistenceStore(fileURL: fileURL)

        let initialLoad = try await store.load()
        XCTAssertNil(initialLoad)

        let threadID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_500_000.125)
        let customPersona = BotPersona(
            id: "research-lead",
            name: "Research Lead",
            role: "Deep Literature Analyst",
            systemPrompt: "Synthesize technical papers concisely.",
            symbolName: "doc.text.magnifyingglass",
            accentHex: "#A855F7",
            isDefault: false,
            pinnedToolIDs: ["web_search", "pdf_reader"]
        )
        let thread = ConversationThread(
            id: threadID,
            personaID: customPersona.id,
            title: "Phase 1 Architecture Review",
            messages: [
                ChatMessage(role: .user, content: "Review our vault design."),
                ChatMessage(
                    role: .assistant,
                    content: "AES-256-GCM with per-write salt looks solid.",
                    timestamp: created,
                    memoryNotice: "Space 2 Enclave",
                    isStreaming: false,
                    promptTokens: 320,
                    completionTokens: 95
                )
            ],
            createdAt: created,
            updatedAt: created
        )
        let snapshot = WorkspaceSnapshot(
            threads: [thread],
            customPersonas: [customPersona],
            activeThreadID: threadID,
            selectedPersonaID: customPersona.id,
            computeConfig: ComputeConfiguration(threadAllocation: .two, hardwareAccelerationEnabled: false),
            byokConfig: BYOKConfiguration(provider: .claude, modelID: "claude-sonnet-4-20250514", streamingEnabled: true)
        )

        try await store.save(snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        let reloadedStore = WorkspacePersistenceStore(fileURL: fileURL)
        let loaded = try await reloadedStore.load()
        XCTAssertEqual(loaded, snapshot)

        // Verify legacy Phase 0 JSON (without new optional fields) decodes cleanly
        let legacyMessageJSON = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "role": "assistant",
          "content": "Legacy message",
          "timestamp": 1000.0
        }
        """
        let decodedMessage = try JSONDecoder().decode(ChatMessage.self, from: Data(legacyMessageJSON.utf8))
        XCTAssertEqual(decodedMessage.content, "Legacy message")
        XCTAssertFalse(decodedMessage.isStreaming)
        XCTAssertNil(decodedMessage.promptTokens)
        XCTAssertNil(decodedMessage.completionTokens)

        let legacyPersonaJSON = """
        {
          "id": "legacy-bot",
          "name": "Legacy Bot",
          "role": "Helper",
          "systemPrompt": "Be helpful.",
          "symbolName": "sparkles",
          "accentHex": "#00E5FF"
        }
        """
        let decodedPersona = try JSONDecoder().decode(BotPersona.self, from: Data(legacyPersonaJSON.utf8))
        XCTAssertEqual(decodedPersona.id, "legacy-bot")
        XCTAssertFalse(decodedPersona.isDefault)
        XCTAssertTrue(decodedPersona.pinnedToolIDs.isEmpty)
    }
}
