import BrokBotCore
import Foundation
import SwiftUI

/// Observable coordinator bridging the SwiftUI workspace to BrokBotCore actors, Vault, Persistence, and BYOK SSE streaming.
@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published var personas: [BotPersona] = BotPersona.presets
    @Published var selectedPersona: BotPersona = .chiefOfStaff
    @Published var threads: [ConversationThread] = []
    @Published var activeThreadID: UUID?
    @Published var messages: [ChatMessage] = []
    @Published var draftInput: String = ""
    @Published var workingTokenCount: Int = 0
    @Published var workingSummary: String?
    @Published var memoryEntries: [MemoryEntry] = []
    @Published var isShowingSettings: Bool = false

    @Published var computeConfig: ComputeConfiguration
    @Published var effectiveThreadCount: Int
    @Published var byokConfig: BYOKConfiguration = BYOKConfiguration()
    @Published var statusBanner: String?

    @Published private(set) var isVaultUnlocked: Bool = false
    @Published private(set) var isUnlockingVault: Bool = false
    @Published private(set) var configuredProviders: [BYOKProviderKind] = []
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var vaultErrorMessage: String?
    @Published private(set) var lastInjectedMemoryCount: Int = 0
    @Published private(set) var lastPromptTokenEstimate: Int = 0

    let workingContextStore: WorkingContextStore
    let vaultManager: BrokVaultManager
    let permanentMemoryManager: PermanentContextEnclaveManager
    let persistenceStore: WorkspacePersistenceStore
    let computeEngine: BrokComputeEngine
    let byokClient: BYOKModelClient

    private var streamingTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?

    var workingTokenBudget: Int {
        workingContextStore.maxTokenBudget
    }

    var activeThread: ConversationThread? {
        guard let activeThreadID else { return threads.first }
        return threads.first(where: { $0.id == activeThreadID })
    }

    init(
        workingContextStore: WorkingContextStore = WorkingContextStore(),
        vaultManager: BrokVaultManager = BrokVaultManager(
            vaultURL: BrokVaultManager.defaultVaultURL,
            keyProvider: KeychainBiometricKeyProvider()
        ),
        persistenceStore: WorkspacePersistenceStore = WorkspacePersistenceStore(),
        computeEngine: BrokComputeEngine = .shared,
        byokClient: BYOKModelClient = BYOKModelClient()
    ) {
        self.workingContextStore = workingContextStore
        self.vaultManager = vaultManager
        self.permanentMemoryManager = PermanentContextEnclaveManager(vault: vaultManager)
        self.persistenceStore = persistenceStore
        self.computeEngine = computeEngine
        self.byokClient = byokClient
        self.computeConfig = computeEngine.configuration
        self.effectiveThreadCount = computeEngine.maxConcurrentOperationCount

        Task {
            await loadInitialWorkspace()
        }
    }

    // MARK: - Initial Hydration & Persistence

    func loadInitialWorkspace() async {
        do {
            if let snapshot = try await persistenceStore.load() {
                personas = mergePersonas(custom: snapshot.customPersonas)

                computeEngine.setThreadAllocation(snapshot.computeConfig.threadAllocation)
                computeEngine.setHardwareAccelerationEnabled(snapshot.computeConfig.hardwareAccelerationEnabled)
                computeConfig = computeEngine.configuration
                effectiveThreadCount = computeEngine.maxConcurrentOperationCount

                byokConfig = snapshot.byokConfig

                if snapshot.threads.isEmpty {
                    let initial = ConversationThread(
                        personaID: snapshot.selectedPersonaID,
                        title: "New Conversation"
                    )
                    threads = [initial]
                    activeThreadID = initial.id
                } else {
                    threads = snapshot.threads
                    if let savedActiveID = snapshot.activeThreadID,
                       snapshot.threads.contains(where: { $0.id == savedActiveID }) {
                        activeThreadID = savedActiveID
                    } else {
                        activeThreadID = snapshot.threads.first?.id
                    }
                }

                let resolvedPersonaID = activeThread?.personaID ?? snapshot.selectedPersonaID
                selectedPersona = personas.first(where: { $0.id == resolvedPersonaID })
                    ?? personas.first
                    ?? .chiefOfStaff

                await hydrateWorkingContext(from: activeThread?.messages ?? [])
            } else {
                let initial = ConversationThread(
                    personaID: selectedPersona.id,
                    title: "New Conversation"
                )
                threads = [initial]
                activeThreadID = initial.id
            }
        } catch {
            let fallback = ConversationThread(
                personaID: selectedPersona.id,
                title: "New Conversation"
            )
            threads = [fallback]
            activeThreadID = fallback.id
            statusBanner = "Failed to load saved workspace: \(error.localizedDescription)"
        }

        await refreshState()
    }

    private func hydrateWorkingContext(from savedMessages: [ChatMessage]) async {
        await workingContextStore.reset()
        for message in savedMessages {
            let sanitized = ChatMessage(
                id: message.id,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                memoryNotice: message.memoryNotice,
                isStreaming: false,
                promptTokens: message.promptTokens,
                completionTokens: message.completionTokens
            )
            await workingContextStore.append(sanitized)
        }
    }

    private func mergePersonas(custom: [BotPersona]) -> [BotPersona] {
        let customByID = Dictionary(uniqueKeysWithValues: custom.map { ($0.id, $0) })
        let presetIDs = Set(BotPersona.presets.map(\.id))

        var merged = BotPersona.presets.map { preset -> BotPersona in
            if let override = customByID[preset.id], !preset.isDefault {
                return override
            }
            return preset
        }

        for persona in custom where !presetIDs.contains(persona.id) {
            merged.append(persona)
        }
        return merged
    }

    private func buildSnapshot() -> WorkspaceSnapshot {
        let presetByID = Dictionary(uniqueKeysWithValues: BotPersona.presets.map { ($0.id, $0) })
        let customToPersist = personas.filter { persona in
            guard let preset = presetByID[persona.id] else {
                return true
            }
            return persona != preset
        }

        return WorkspaceSnapshot(
            threads: threads,
            customPersonas: customToPersist,
            activeThreadID: activeThreadID,
            selectedPersonaID: selectedPersona.id,
            computeConfig: computeConfig,
            byokConfig: byokConfig
        )
    }

    func saveWorkspaceNow() async {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        do {
            try await persistenceStore.save(buildSnapshot())
        } catch {
            statusBanner = "Workspace save error: \(error.localizedDescription)"
        }
    }

    private func scheduleWorkspaceSave() {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.saveWorkspaceNow()
        }
    }

    // MARK: - State Refresh

    func refreshState() async {
        let msgs = await workingContextStore.messages()
        let tokens = await workingContextStore.estimatedTokenCount()
        let summary = await workingContextStore.rollingSummary()

        messages = msgs
        workingTokenCount = tokens
        workingSummary = summary

        await refreshVaultState()
    }

    func refreshVaultState() async {
        let unlocked = await vaultManager.isUnlocked()
        isVaultUnlocked = unlocked

        if unlocked {
            configuredProviders = (try? await vaultManager.configuredProviders()) ?? []
            memoryEntries = (try? await permanentMemoryManager.listEntries()) ?? []
        } else {
            configuredProviders = []
            memoryEntries = []
        }
    }

    // MARK: - Vault & BYOK Key Management

    @discardableResult
    func unlockVault(reason: String = "Unlock Brok Bot Vault") async -> Bool {
        isUnlockingVault = true
        defer { isUnlockingVault = false }
        vaultErrorMessage = nil

        do {
            try await vaultManager.unlock(reason: reason)
            await refreshVaultState()
            statusBanner = "Vault unlocked."
            return true
        } catch {
            await refreshVaultState()
            vaultErrorMessage = error.localizedDescription
            statusBanner = error.localizedDescription
            return false
        }
    }

    func lockVault() {
        Task {
            await lockVaultAsync()
        }
    }

    func lockVaultAsync() async {
        await vaultManager.lock()
        await refreshVaultState()
        statusBanner = "Vault locked."
    }

    @discardableResult
    func saveAPIKey(_ key: String, for provider: BYOKProviderKind) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return await deleteAPIKey(for: provider)
        }

        if !(await vaultManager.isUnlocked()) {
            let unlocked = await unlockVault(reason: "Unlock Vault to save \(provider.displayName) API key")
            guard unlocked else { return false }
        }

        do {
            try await vaultManager.setAPIKey(trimmed, for: provider)
            await refreshVaultState()
            statusBanner = "Saved \(provider.displayName) API key in vault.enc."
            return true
        } catch {
            statusBanner = "Failed to save API key: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteAPIKey(for provider: BYOKProviderKind) async -> Bool {
        if !(await vaultManager.isUnlocked()) {
            let unlocked = await unlockVault(reason: "Unlock Vault to remove \(provider.displayName) API key")
            guard unlocked else { return false }
        }

        do {
            try await vaultManager.deleteAPIKey(for: provider)
            await refreshVaultState()
            statusBanner = "Cleared \(provider.displayName) API key from vault.enc."
            return true
        } catch {
            statusBanner = "Failed to clear API key: \(error.localizedDescription)"
            return false
        }
    }

    func isProviderConfigured(_ provider: BYOKProviderKind) -> Bool {
        configuredProviders.contains(provider)
    }

    // MARK: - Persona Management

    func selectPersona(_ persona: BotPersona) {
        selectedPersona = persona
        if let index = activeThreadIndex(), threads[index].messages.isEmpty {
            threads[index].personaID = persona.id
        }
        scheduleWorkspaceSave()
    }

    func addPersona(_ persona: BotPersona) {
        personas.append(persona)
        selectPersona(persona)
        Task {
            await saveWorkspaceNow()
        }
    }

    func updatePersona(_ persona: BotPersona) {
        guard let index = personas.firstIndex(where: { $0.id == persona.id }) else {
            addPersona(persona)
            return
        }
        personas[index] = persona
        if selectedPersona.id == persona.id {
            selectedPersona = persona
        }
        Task {
            await saveWorkspaceNow()
        }
    }

    func deletePersona(_ persona: BotPersona) {
        guard !persona.isDefault else { return }
        personas.removeAll { $0.id == persona.id }

        let fallbackPersona = personas.first(where: { $0.isDefault }) ?? personas.first ?? .chiefOfStaff
        for idx in threads.indices where threads[idx].personaID == persona.id {
            threads[idx].personaID = fallbackPersona.id
        }

        if selectedPersona.id == persona.id {
            selectedPersona = fallbackPersona
        }

        Task {
            await saveWorkspaceNow()
        }
    }

    // MARK: - Multi-Thread Management

    func createNewThread() {
        cancelStreaming()
        let newThread = ConversationThread(
            personaID: selectedPersona.id,
            title: "New Conversation"
        )
        threads.insert(newThread, at: 0)
        activeThreadID = newThread.id

        Task {
            await workingContextStore.reset()
            await refreshState()
            await saveWorkspaceNow()
        }
    }

    func selectThread(_ thread: ConversationThread) {
        guard thread.id != activeThreadID else { return }
        cancelStreaming()
        activeThreadID = thread.id
        if let persona = personas.first(where: { $0.id == thread.personaID }) {
            selectedPersona = persona
        }

        Task {
            await hydrateWorkingContext(from: thread.messages)
            await refreshState()
            await saveWorkspaceNow()
        }
    }

    func deleteThread(_ thread: ConversationThread) {
        let deletingActive = thread.id == activeThreadID
        if deletingActive {
            cancelStreaming()
        }

        threads.removeAll { $0.id == thread.id }

        if threads.isEmpty {
            let replacement = ConversationThread(
                personaID: selectedPersona.id,
                title: "New Conversation"
            )
            threads = [replacement]
            activeThreadID = replacement.id
            Task {
                await workingContextStore.reset()
                await refreshState()
                await saveWorkspaceNow()
            }
            return
        }

        if deletingActive, let nextThread = threads.first {
            activeThreadID = nextThread.id
            if let persona = personas.first(where: { $0.id == nextThread.personaID }) {
                selectedPersona = persona
            }
            Task {
                await hydrateWorkingContext(from: nextThread.messages)
                await refreshState()
                await saveWorkspaceNow()
            }
        } else {
            Task {
                await saveWorkspaceNow()
            }
        }
    }

    // MARK: - Messaging & Dual-Space BYOK Streaming

    func sendCurrentDraft() {
        let trimmed = draftInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }
        draftInput = ""

        Task {
            await submitMessage(trimmed)
        }
    }

    func submitSuggestion(_ prompt: String) {
        guard !isStreaming else { return }
        Task {
            await submitMessage(prompt)
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
    }

    func submitMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return }

        ensureActiveThreadExists()
        updateActiveThreadTitleIfNeeded(with: trimmed)

        let userMessage = ChatMessage(role: .user, content: trimmed)
        await workingContextStore.append(userMessage)
        await syncActiveThreadMessagesFromWorkingContext()
        await refreshState()

        if MemoryCommandParser.parse(trimmed) != nil {
            await handleMemoryCommand(trimmed)
            return
        }

        await handleNormalChatMessage(trimmed)
    }

    private func handleMemoryCommand(_ text: String) async {
        if !(await vaultManager.isUnlocked()) {
            let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to access Permanent Memory")
            if !unlocked {
                let lockedMessage = ChatMessage(
                    role: .assistant,
                    content: "The Brok Bot Vault is locked. Unlock it in the sidebar or **Settings → Permanent Memory Enclave** to store, update, or forget durable facts.",
                    memoryNotice: "Vault Locked"
                )
                await workingContextStore.append(lockedMessage)
                await syncActiveThreadMessagesFromWorkingContext()
                await refreshState()
                await saveWorkspaceNow()
                return
            }
        }

        do {
            if let memoryResult = try await permanentMemoryManager.executeMemoryCommand(text) {
                let noticeMessage = ChatMessage(
                    role: .assistant,
                    content: memoryResult,
                    memoryNotice: "Space 2 Enclave"
                )
                await workingContextStore.append(noticeMessage)
            }
        } catch {
            let errorMessage = ChatMessage(
                role: .system,
                content: "Memory Enclave error: \(error.localizedDescription)"
            )
            await workingContextStore.append(errorMessage)
        }

        await syncActiveThreadMessagesFromWorkingContext()
        await refreshState()
        await saveWorkspaceNow()
    }

    private func handleNormalChatMessage(_ latestQuery: String) async {
        let vaultFileExists = FileManager.default.fileExists(atPath: vaultManager.vaultURL.path)

        if !(await vaultManager.isUnlocked()) {
            if vaultFileExists {
                let unlocked = await unlockVault(
                    reason: "Unlock Brok Bot Vault to read your \(byokConfig.provider.displayName) API key and Permanent Memory"
                )
                if !unlocked {
                    let lockedGuidance = ChatMessage(
                        role: .assistant,
                        content: "The Brok Bot Vault is locked. Click **Unlock Vault** in the sidebar or open **Settings → BYOK Engine & Vault Keys** to unlock `vault.enc` and stream responses with **\(byokConfig.provider.displayName)**."
                    )
                    await workingContextStore.append(lockedGuidance)
                    await syncActiveThreadMessagesFromWorkingContext()
                    await refreshState()
                    await saveWorkspaceNow()
                    return
                }
            } else {
                await appendMissingAPIKeyGuidance()
                return
            }
        }

        let storedKey: String?
        do {
            storedKey = try await vaultManager.apiKey(for: byokConfig.provider)
        } catch {
            let vaultErr = ChatMessage(
                role: .system,
                content: "Unable to read API key from Vault: \(error.localizedDescription)"
            )
            await workingContextStore.append(vaultErr)
            await syncActiveThreadMessagesFromWorkingContext()
            await refreshState()
            await saveWorkspaceNow()
            return
        }

        guard let apiKey = storedKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            await appendMissingAPIKeyGuidance()
            return
        }

        let permanentEntries = (try? await permanentMemoryManager.listEntries()) ?? []
        let contextMessages = await workingContextStore.messages()
        let summary = await workingContextStore.rollingSummary()

        let assembled = DualSpacePromptAssembler.assemble(
            persona: selectedPersona,
            permanentEntries: permanentEntries,
            workingMessages: contextMessages,
            rollingSummary: summary,
            latestUserQuery: latestQuery
        )

        lastInjectedMemoryCount = assembled.injectedMemoryCount
        lastPromptTokenEstimate = assembled.estimatedTotalTokens

        let requestMessages: [BYOKChatMessage] = assembled.messages.compactMap { msg in
            let trimmedContent = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedContent.isEmpty else { return nil }
            let role: BYOKChatRole
            switch msg.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            return BYOKChatMessage(role: role, content: msg.content)
        }

        let noticeLabel = assembled.injectedMemoryCount > 0
            ? "Space 2 · \(assembled.injectedMemoryCount) fact(s)"
            : nil

        let assistantPlaceholder = ChatMessage(
            role: .assistant,
            content: "",
            memoryNotice: noticeLabel,
            isStreaming: true
        )
        await workingContextStore.append(assistantPlaceholder)
        await syncActiveThreadMessagesFromWorkingContext()
        await refreshState()

        let request = BYOKChatRequest(
            configuration: byokConfig,
            apiKey: apiKey,
            systemPrompt: assembled.systemPrompt,
            messages: requestMessages
        )

        let assistantID = assistantPlaceholder.id
        let streamLiveUpdates = byokConfig.streamingEnabled
        isStreaming = true

        let task = Task { [weak self] in
            guard let self else { return }
            var accumulatedContent = ""
            var latestPromptTokens: Int?
            var latestCompletionTokens: Int?
            var streamError: Error?

            do {
                for try await event in self.byokClient.streamChat(request) {
                    try Task.checkCancellation()

                    switch event {
                    case .textDelta(let delta):
                        accumulatedContent.append(delta)
                        if streamLiveUpdates {
                            self.updatePublishedStreamingMessage(id: assistantID, content: accumulatedContent)
                        }
                    case .toolCall(let record):
                        let toolNote = "\n\n`[Tool call: \(record.name)]`"
                        accumulatedContent.append(toolNote)
                        if streamLiveUpdates {
                            self.updatePublishedStreamingMessage(id: assistantID, content: accumulatedContent)
                        }
                    case .usage(let usage):
                        latestPromptTokens = usage.promptTokens
                        latestCompletionTokens = usage.completionTokens
                    case .finished:
                        break
                    }
                }
            } catch is CancellationError {
                if accumulatedContent.isEmpty {
                    accumulatedContent = "_Generation stopped._"
                }
            } catch {
                streamError = error
            }

            let finalContent: String
            if let streamError {
                if accumulatedContent.isEmpty {
                    finalContent = "BYOK request failed (\(self.byokConfig.provider.displayName) · \(self.byokConfig.modelID)): \(streamError.localizedDescription)"
                } else {
                    finalContent = "\(accumulatedContent)\n\n_Stream interrupted: \(streamError.localizedDescription)_"
                }
                self.statusBanner = streamError.localizedDescription
            } else if accumulatedContent.isEmpty {
                finalContent = "_No text returned by \(self.byokConfig.provider.displayName)._"
            } else {
                finalContent = accumulatedContent
            }

            await self.workingContextStore.replaceMessage(
                id: assistantID,
                content: finalContent,
                isStreaming: false,
                promptTokens: latestPromptTokens,
                completionTokens: latestCompletionTokens
            )
            await self.syncActiveThreadMessagesFromWorkingContext()
            self.isStreaming = false
            self.streamingTask = nil
            await self.refreshState()
            await self.saveWorkspaceNow()
        }

        streamingTask = task
        await task.value
    }

    private func appendMissingAPIKeyGuidance() async {
        let guidance = """
        No BYOK API key is configured in `vault.enc` for **\(byokConfig.provider.displayName)** (`\(byokConfig.modelID)`).

        Open **Settings → BYOK Engine & Vault Keys** to store your `\(byokConfig.provider.apiKeyPlaceholder)` key securely, or run natural-language memory commands such as `Store this in your memory: ...`.
        """
        let guidanceMessage = ChatMessage(
            role: .assistant,
            content: guidance
        )
        await workingContextStore.append(guidanceMessage)
        await syncActiveThreadMessagesFromWorkingContext()
        await refreshState()
        await saveWorkspaceNow()
    }

    private func updatePublishedStreamingMessage(id: UUID, content: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].content = content
        messages[index].isStreaming = true
    }

    private func ensureActiveThreadExists() {
        if let activeThreadID, threads.contains(where: { $0.id == activeThreadID }) {
            return
        }
        let thread = ConversationThread(personaID: selectedPersona.id, title: "New Conversation")
        threads.insert(thread, at: 0)
        activeThreadID = thread.id
    }

    private func activeThreadIndex() -> Int? {
        guard let activeThreadID else { return threads.indices.first }
        return threads.firstIndex(where: { $0.id == activeThreadID })
    }

    private func updateActiveThreadTitleIfNeeded(with userInput: String) {
        guard let index = activeThreadIndex() else { return }
        if threads[index].title == "New Conversation" {
            let singleLine = userInput
                .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
                .joined(separator: " ")
            if !singleLine.isEmpty {
                let capped = singleLine.count > 36
                    ? "\(singleLine.prefix(35))…"
                    : singleLine
                threads[index].title = capped
            }
        }
        threads[index].personaID = selectedPersona.id
        threads[index].updatedAt = Date()
    }

    private func syncActiveThreadMessagesFromWorkingContext() async {
        let workingMessages = await workingContextStore.messages()
        guard let index = activeThreadIndex() else { return }
        threads[index].messages = workingMessages
        threads[index].updatedAt = Date()
    }

    // MARK: - Working Context Reset

    func resetWorkingContext() {
        cancelStreaming()
        Task {
            await workingContextStore.reset()
            if let index = activeThreadIndex() {
                threads[index].messages = []
                threads[index].title = "New Conversation"
                threads[index].updatedAt = Date()
            }
            await refreshState()
            await saveWorkspaceNow()
        }
    }

    // MARK: - Compute & BYOK Configuration

    func updateThreadAllocation(_ allocation: ThreadAllocation) {
        computeEngine.setThreadAllocation(allocation)
        computeConfig = computeEngine.configuration
        effectiveThreadCount = computeEngine.maxConcurrentOperationCount
        scheduleWorkspaceSave()
    }

    func updateHardwareAcceleration(_ enabled: Bool) {
        computeEngine.setHardwareAccelerationEnabled(enabled)
        computeConfig = computeEngine.configuration
        scheduleWorkspaceSave()
    }

    func selectBYOKProvider(_ provider: BYOKProviderKind) {
        byokConfig.provider = provider
        byokConfig.modelID = provider.defaultModelID
        scheduleWorkspaceSave()
    }

    func updateBYOKModelID(_ modelID: String) {
        byokConfig.modelID = modelID
        scheduleWorkspaceSave()
    }

    func updateBYOKCustomEndpoint(_ endpointString: String) {
        let trimmed = endpointString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            byokConfig.customBaseURL = nil
            scheduleWorkspaceSave()
            return
        }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           (scheme == "https" || scheme == "http"),
           url.host != nil {
            byokConfig.customBaseURL = url
            scheduleWorkspaceSave()
        }
    }

    func updateBYOKStreamingEnabled(_ enabled: Bool) {
        byokConfig.streamingEnabled = enabled
        scheduleWorkspaceSave()
    }

    // MARK: - Permanent Memory Inspector Actions

    @discardableResult
    func quickStorePermanentMemory(_ rawText: String) async -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Enter a fact to store."
        }

        if !(await vaultManager.isUnlocked()) {
            let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to save Permanent Memory")
            if !unlocked {
                return vaultErrorMessage ?? "Vault is locked."
            }
        }

        do {
            if let commandResult = try await permanentMemoryManager.executeMemoryCommand(trimmed) {
                await refreshVaultState()
                statusBanner = commandResult
                return commandResult
            } else {
                try await permanentMemoryManager.saveFact(trimmed, category: nil)
                await refreshVaultState()
                let notice = "Saved to Space 2 Permanent Enclave."
                statusBanner = notice
                return notice
            }
        } catch {
            let message = "Failed to save memory: \(error.localizedDescription)"
            statusBanner = message
            return message
        }
    }

    func updateMemoryEntry(id: UUID, content: String, category: String?) {
        Task {
            if !(await vaultManager.isUnlocked()) {
                let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to edit Permanent Memory")
                guard unlocked else { return }
            }
            do {
                let updated = try await permanentMemoryManager.updateFact(
                    id: id,
                    content: content,
                    category: category
                )
                statusBanner = updated ? "Updated permanent memory record." : "Memory record not found."
                await refreshVaultState()
            } catch {
                statusBanner = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    func compactPermanentMemory() {
        Task {
            if !(await vaultManager.isUnlocked()) {
                let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to compact Permanent Memory")
                guard unlocked else { return }
            }
            do {
                let removed = try await permanentMemoryManager.autoCompact()
                statusBanner = removed > 0
                    ? "Auto-compacted \(removed) redundant memory entry(s)."
                    : "Permanent memory is already compact."
                await refreshVaultState()
            } catch {
                statusBanner = "Compaction failed: \(error.localizedDescription)"
            }
        }
    }

    func deleteMemoryEntry(_ entry: MemoryEntry) {
        Task {
            if !(await vaultManager.isUnlocked()) {
                let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to purge Permanent Memory")
                guard unlocked else { return }
            }
            do {
                _ = try await permanentMemoryManager.purgeFact(id: entry.id)
                statusBanner = "Cryptographically purged memory record."
                await refreshVaultState()
            } catch {
                statusBanner = "Delete failed: \(error.localizedDescription)"
            }
        }
    }
}
