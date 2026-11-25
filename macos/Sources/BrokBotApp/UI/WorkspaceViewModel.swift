import AppKit
import BrokBotCore
import Foundation
import SwiftUI

/// Observable coordinator bridging the SwiftUI workspace to BrokBotCore actors, Vault, MCP, Persistence, and BYOK SSE streaming.
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
    @Published var isShowingMCPServers: Bool = false

    @Published var computeConfig: ComputeConfiguration
    @Published var effectiveThreadCount: Int
    @Published var byokConfig: BYOKConfiguration = BYOKConfiguration()
    @Published var statusBanner: String?

    @Published var mcpConnections: [MCPServerConnection] = []
    @Published var pendingElicitations: [MCPElicitationRequest] = []
    @Published var mcpStatusMessage: String?
    @Published var marketplaceEntries: [MarketplaceCatalogEntry] = []
    @Published var marketplaceCatalogURL: String = ""
    @Published var allowUnsignedTemplates: Bool = true
    @Published private(set) var isLoadingMarketplace: Bool = false
    @Published private(set) var configuredMCPConnectionIDs: Set<String> = []
    @Published private(set) var dailyRequestCounts: [String: Int] = [:]
    @Published private(set) var authenticatingConnectionID: String?
    @Published private(set) var discoveringConnectionID: String?
    @Published private(set) var activeToolCallStatus: String?

    @Published private(set) var isVaultUnlocked: Bool = false
    @Published private(set) var isUnlockingVault: Bool = false
    @Published private(set) var configuredProviders: [BYOKProviderKind] = []
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var vaultErrorMessage: String?
    @Published private(set) var lastInjectedMemoryCount: Int = 0
    @Published private(set) var lastPromptTokenEstimate: Int = 0

    @Published var firebaseUser: FirebaseAuthUser?
    @Published private(set) var isAuthenticatingAccount: Bool = false
    @Published var authStatusMessage: String?

    @Published var desktopBrowserConfig: DesktopBrowserConfig = DesktopBrowserConfig()
    @Published private(set) var lastOpenedBrowserURL: String?
    @Published private(set) var activeBrowserTab: BrowserActiveTab?
    @Published var browserStatusMessage: String?

    let workingContextStore: WorkingContextStore
    let vaultManager: BrokVaultManager
    let permanentMemoryManager: PermanentContextEnclaveManager
    let persistenceStore: WorkspacePersistenceStore
    let computeEngine: BrokComputeEngine
    let byokClient: BYOKModelClient
    let mcpManager: MCPConnectionManager
    let marketplaceRegistry: MarketplaceRegistry
    let firebaseConfig: FirebaseAppConfig?
    let firebaseAuthClient: FirebaseAuthClient
    let browserBridge: DesktopBrowserBridge
    let attentionCoordinator = PendingAttentionCoordinator()
    private let macAuthCoordinator = MacAuthCoordinator()

    var onNotifyAttention: ((LocalNotificationPayload) -> Void)?
    var onDismissNotification: ((UUID) -> Void)?

    private var streamingTask: Task<Void, Never>?
    private var debouncedSaveTask: Task<Void, Never>?
    private var activeLoopbackServer: LoopbackOAuthServer?

    var workingTokenBudget: Int {
        workingContextStore.maxTokenBudget
    }

    var activeMCPServerCount: Int {
        mcpConnections.filter(\.isEnabled).count
    }

    var activeMCPToolCount: Int {
        mcpManager.buildActiveToolDefinitions(from: mcpConnections).definitions.count
    }

    var activeBrowserToolCount: Int {
        desktopBrowserConfig.isEnabled ? DesktopBrowserBridge.toolDefinitions.count : 0
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
        byokClient: BYOKModelClient = BYOKModelClient(),
        mcpManager: MCPConnectionManager? = nil,
        marketplaceRegistry: MarketplaceRegistry = MarketplaceRegistry(),
        firebaseConfig: FirebaseAppConfig? = BrokAppResources.loadFirebaseAppConfig(),
        firebaseAuthClient: FirebaseAuthClient = FirebaseAuthClient(),
        browserBridge: DesktopBrowserBridge = DesktopBrowserBridge()
    ) {
        self.workingContextStore = workingContextStore
        self.vaultManager = vaultManager
        self.permanentMemoryManager = PermanentContextEnclaveManager(vault: vaultManager)
        self.persistenceStore = persistenceStore
        self.computeEngine = computeEngine
        self.byokClient = byokClient
        self.mcpManager = mcpManager ?? MCPConnectionManager(vault: vaultManager)
        self.marketplaceRegistry = marketplaceRegistry
        self.firebaseConfig = firebaseConfig
        self.firebaseAuthClient = firebaseAuthClient
        self.browserBridge = browserBridge
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
                mcpConnections = snapshot.mcpConnections
                marketplaceCatalogURL = snapshot.marketplaceCatalogURL ?? ""
                firebaseUser = snapshot.firebaseUser
                desktopBrowserConfig = snapshot.desktopBrowserConfig

                let expiredRecords = await attentionCoordinator.expirePersistedOnRelaunch(snapshot.pendingAttentionRecords)
                if !expiredRecords.isEmpty {
                    for expired in expiredRecords {
                        if let threadID = expired.threadID,
                           let idx = threads.firstIndex(where: { $0.id == threadID }) {
                            threads[idx].messages.append(
                                ChatMessage(
                                    role: .system,
                                    content: "Pending request '\(expired.actionSummary)' expired after app relaunch."
                                )
                            )
                        }
                    }
                    await hydrateWorkingContext(from: activeThread?.messages ?? [])
                }

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
        await refreshMarketplaceCatalog(remoteURLString: nil)
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
            if let override = customByID[preset.id] {
                var preserved = override
                preserved.isDefault = preset.isDefault
                return preserved
            }
            return preset
        }

        for persona in custom where !presetIDs.contains(persona.id) {
            merged.append(persona)
        }
        return merged
    }

    private func buildSnapshot() async -> WorkspaceSnapshot {
        let presetByID = Dictionary(uniqueKeysWithValues: BotPersona.presets.map { ($0.id, $0) })
        let customToPersist = personas.filter { persona in
            guard let preset = presetByID[persona.id] else {
                return true
            }
            return persona != preset
        }

        let trimmedCatalogURL = marketplaceCatalogURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingRecords = await attentionCoordinator.pendingRecords()
        return WorkspaceSnapshot(
            threads: threads,
            customPersonas: customToPersist,
            activeThreadID: activeThreadID,
            selectedPersonaID: selectedPersona.id,
            computeConfig: computeConfig,
            byokConfig: byokConfig,
            marketplaceCatalogURL: trimmedCatalogURL.isEmpty ? nil : trimmedCatalogURL,
            mcpConnections: mcpConnections,
            firebaseUser: firebaseUser,
            desktopBrowserConfig: desktopBrowserConfig,
            pendingAttentionRecords: pendingRecords
        )
    }

    func saveWorkspaceNow() async {
        debouncedSaveTask?.cancel()
        debouncedSaveTask = nil
        do {
            let snapshot = await buildSnapshot()
            try await persistenceStore.save(snapshot)
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

        await refreshMCPCredentialStatus()
    }

    func refreshMCPCredentialStatus() async {
        var configuredIDs: Set<String> = []
        for connection in mcpConnections {
            if await mcpManager.hasStoredCredential(for: connection) {
                configuredIDs.insert(connection.id)
            }
        }
        configuredMCPConnectionIDs = configuredIDs
        dailyRequestCounts = await mcpManager.dailyRequestCountsSnapshot()
    }

    func hasCredential(for connection: MCPServerConnection) -> Bool {
        if connection.authMode == .none {
            return true
        }
        return configuredMCPConnectionIDs.contains(connection.id)
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

    // MARK: - Firebase Auth (Google & Apple Sign-In)

    func signInWithGoogle() async {
        guard !isAuthenticatingAccount else { return }
        guard let config = firebaseConfig else {
            authStatusMessage = FirebaseAuthError.missingConfiguration.localizedDescription
            return
        }

        isAuthenticatingAccount = true
        authStatusMessage = "Opening Google Sign-In…"
        defer { isAuthenticatingAccount = false }

        do {
            let pkce = try PKCEChallenge.generate()
            let code = try await macAuthCoordinator.authorizeGoogle(
                config: config,
                pkce: pkce,
                authClient: firebaseAuthClient
            )
            let tokens = try await firebaseAuthClient.exchangeGoogleCodeForTokens(
                config: config,
                code: code,
                codeVerifier: pkce.codeVerifier
            )
            let session = try await firebaseAuthClient.signInWithGoogleIDToken(
                config: config,
                idToken: tokens.idToken,
                accessToken: tokens.accessToken
            )
            await applyFirebaseSession(session)
        } catch {
            authStatusMessage = error.localizedDescription
        }
    }

    func signInWithApple() async {
        guard !isAuthenticatingAccount else { return }
        guard let config = firebaseConfig else {
            authStatusMessage = FirebaseAuthError.missingConfiguration.localizedDescription
            return
        }

        isAuthenticatingAccount = true
        authStatusMessage = "Starting Sign in with Apple…"
        defer { isAuthenticatingAccount = false }

        do {
            let nonce = try AppleSignInNonce.generate()
            let appleResult = try await macAuthCoordinator.authorizeApple(nonce: nonce)
            let session = try await firebaseAuthClient.signInWithAppleIDToken(
                config: config,
                idToken: appleResult.idToken,
                rawNonce: nonce.rawNonce,
                displayName: appleResult.fullName
            )
            await applyFirebaseSession(session)
        } catch {
            authStatusMessage = error.localizedDescription
        }
    }

    func signOutFirebase() async {
        firebaseUser = nil
        if await vaultManager.isUnlocked() {
            try? await vaultManager.deleteConnectorSecrets(for: FirebaseAuthVaultKeys.connectorID)
        }
        await saveWorkspaceNow()
        authStatusMessage = "Signed out of Brok Bot."
    }

    private func applyFirebaseSession(_ session: FirebaseAuthSession) async {
        firebaseUser = session.user
        if await vaultManager.isUnlocked() {
            try? await vaultManager.setConnectorSecrets([
                FirebaseAuthVaultKeys.idToken: session.idToken,
                FirebaseAuthVaultKeys.refreshToken: session.refreshToken,
                FirebaseAuthVaultKeys.expiresAt: String(session.expiresAt.timeIntervalSince1970)
            ], for: FirebaseAuthVaultKeys.connectorID)
        }
        await saveWorkspaceNow()
        let label = session.user.displayName ?? session.user.email ?? session.user.uid
        authStatusMessage = "Signed in as \(label) via \(session.user.providerLabel)."
    }

    // MARK: - Desktop Browser Integration

    func updateDesktopBrowserConfig(_ updated: DesktopBrowserConfig) {
        desktopBrowserConfig = updated
        scheduleWorkspaceSave()
    }

    func inspectActiveDesktopBrowserTab() async {
        do {
            let tab = try await browserBridge.getActiveTab(target: desktopBrowserConfig.preferredBrowser)
            activeBrowserTab = tab
            browserStatusMessage = "Active tab (\(tab.browserName)): \(tab.title)"
        } catch {
            browserStatusMessage = error.localizedDescription
        }
    }

    func grabActiveBrowserTabIntoDraft() async {
        do {
            let tab = try await browserBridge.getActiveTab(target: desktopBrowserConfig.preferredBrowser)
            activeBrowserTab = tab
            browserStatusMessage = "Captured tab from \(tab.browserName)."
            let contextSnippet = "Context from \(tab.browserName) tab \"\(tab.title)\" (\(tab.url)):\n"
            if draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftInput = contextSnippet
            } else {
                draftInput = "\(draftInput)\n\n\(contextSnippet)"
            }
        } catch {
            browserStatusMessage = error.localizedDescription
            statusBanner = error.localizedDescription
        }
    }

    func openURLInDesktopBrowser(_ urlString: String) async {
        do {
            let opened = try await browserBridge.openURL(
                urlString: urlString,
                target: desktopBrowserConfig.preferredBrowser
            )
            lastOpenedBrowserURL = opened
            browserStatusMessage = "Opened \(opened) in \(desktopBrowserConfig.preferredBrowser.displayName)."
        } catch {
            browserStatusMessage = error.localizedDescription
        }
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
        selectedPersona = persona
        let initialThread = ConversationThread(
            personaID: persona.id,
            title: "\(persona.name) Chat"
        )
        threads.insert(initialThread, at: 0)
        activeThreadID = initialThread.id
        Task {
            await workingContextStore.reset()
            await refreshState()
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
        activeToolCallStatus = nil
        pendingElicitations.removeAll()
        Task {
            await mcpManager.cancelAllPendingElicitations()
        }
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

        let (mcpTools, toolRoutes) = mcpManager.buildActiveToolDefinitions(from: mcpConnections)
        let activeBrowserConfig = desktopBrowserConfig
        var activeTools = mcpTools
        if activeBrowserConfig.isEnabled {
            activeTools.append(contentsOf: DesktopBrowserBridge.toolDefinitions)
        }
        let activeConfig = byokConfig
        let activeConnections = mcpConnections
        let assembledSystemPrompt = assembled.systemPrompt
        let assistantID = assistantPlaceholder.id
        let streamLiveUpdates = byokConfig.streamingEnabled
        isStreaming = true

        let task = Task { [weak self] in
            guard let self else { return }
            var conversationHistory = requestMessages
            var accumulatedDisplay = ""
            var collectedAttachments: [ChatAttachment] = []
            var totalPromptTokens = 0
            var totalCompletionTokens = 0
            var observedUsage = false
            var streamError: Error?

            do {
                for round in 0..<6 {
                    try Task.checkCancellation()

                    let roundRequest = BYOKChatRequest(
                        configuration: activeConfig,
                        apiKey: apiKey,
                        systemPrompt: assembledSystemPrompt,
                        messages: conversationHistory,
                        tools: activeTools
                    )

                    var roundText = ""
                    var roundToolCalls: [ToolCallRecord] = []

                    for try await event in self.byokClient.streamChat(roundRequest) {
                        try Task.checkCancellation()

                        switch event {
                        case .textDelta(let delta):
                            roundText.append(delta)
                            let preview = self.composeStreamingDisplay(
                                previousDisplay: accumulatedDisplay,
                                currentRoundText: roundText,
                                roundIndex: round
                            )
                            if streamLiveUpdates {
                                self.updatePublishedStreamingMessage(id: assistantID, content: preview)
                            }
                        case .toolCall(let record):
                            roundToolCalls.append(record)
                        case .usage(let usage):
                            observedUsage = true
                            totalPromptTokens += usage.promptTokens
                            totalCompletionTokens += usage.completionTokens
                        case .finished:
                            break
                        }
                    }

                    accumulatedDisplay = self.composeStreamingDisplay(
                        previousDisplay: accumulatedDisplay,
                        currentRoundText: roundText,
                        roundIndex: round
                    )

                    if roundToolCalls.isEmpty {
                        break
                    }

                    conversationHistory.append(
                        BYOKChatMessage(
                            role: .assistant,
                            content: roundText,
                            toolCalls: roundToolCalls
                        )
                    )

                    for toolCall in roundToolCalls {
                        try Task.checkCancellation()

                        if toolCall.name.hasPrefix(DesktopBrowserBridge.toolPrefix) {
                            self.activeToolCallStatus = "Running \(toolCall.name)…"
                            let toolNotice = "\n\n`[Browser: \(toolCall.name)]`"
                            accumulatedDisplay.append(toolNotice)
                            if streamLiveUpdates {
                                self.updatePublishedStreamingMessage(id: assistantID, content: accumulatedDisplay)
                            }

                            var approved = true
                            if toolCall.name == "browser_open_url" && activeBrowserConfig.requireApprovalToOpenLinks {
                                let args = JSONValue.decodeObject(from: toolCall.argumentsJSON)
                                let targetURL = args["url"]?.stringValue ?? ""
                                let approvalReq = MCPElicitationRequest(
                                    connectionID: "desktop-browser",
                                    serverName: "Desktop Browser (\(activeBrowserConfig.preferredBrowser.displayName))",
                                    toolName: toolCall.name,
                                    mode: .clientApproval,
                                    message: "Open '\(targetURL)' in \(activeBrowserConfig.preferredBrowser.displayName)?",
                                    argumentsPreview: toolCall.argumentsJSON,
                                    isReadOperation: false
                                )
                                let decision = await self.mcpManager.requestClientApproval(
                                    approvalReq,
                                    onElicitationRequested: { [weak self] elicitation in
                                        Task { @MainActor [weak self] in
                                            self?.enqueueElicitation(elicitation)
                                        }
                                    }
                                )
                                approved = (decision.action == .accept)
                            }

                            let toolOutput: String
                            if approved {
                                let browserResult = await self.browserBridge.executeToolCall(
                                    record: toolCall,
                                    config: activeBrowserConfig
                                )
                                toolOutput = browserResult.outputText
                                if let openedURL = browserResult.openedURL {
                                    self.lastOpenedBrowserURL = openedURL
                                    self.browserStatusMessage = "Opened \(openedURL)"
                                }
                                if let activeTab = browserResult.activeTab {
                                    self.activeBrowserTab = activeTab
                                    self.browserStatusMessage = "Read tab from \(activeTab.browserName)"
                                }
                            } else {
                                toolOutput = "User declined opening URL in desktop browser."
                            }

                            conversationHistory.append(
                                BYOKChatMessage(
                                    role: .tool,
                                    content: toolOutput,
                                    toolCallID: toolCall.id
                                )
                            )
                            continue
                        }

                        let displayToolName = toolRoutes[toolCall.name]?.tool.name ?? toolCall.name
                        self.activeToolCallStatus = "Running \(displayToolName)…"

                        let toolNotice = "\n\n`[MCP: \(displayToolName)]`"
                        accumulatedDisplay.append(toolNotice)
                        if streamLiveUpdates {
                            self.updatePublishedStreamingMessage(id: assistantID, content: accumulatedDisplay)
                        }

                        let executionResult = await self.mcpManager.executeToolCall(
                            record: toolCall,
                            routes: toolRoutes,
                            connections: activeConnections,
                            onElicitationRequested: { [weak self] elicitation in
                                Task { @MainActor [weak self] in
                                    self?.enqueueElicitation(elicitation)
                                }
                            }
                        )

                        if !executionResult.attachments.isEmpty {
                            collectedAttachments.append(contentsOf: executionResult.attachments)
                        }

                        conversationHistory.append(
                            BYOKChatMessage(
                                role: .tool,
                                content: executionResult.outputText,
                                toolCallID: toolCall.id
                            )
                        )
                    }

                    self.activeToolCallStatus = nil
                    self.dailyRequestCounts = await self.mcpManager.dailyRequestCountsSnapshot()
                }
            } catch is CancellationError {
                if accumulatedDisplay.isEmpty {
                    accumulatedDisplay = "_Generation stopped._"
                }
            } catch {
                streamError = error
            }

            let finalContent: String
            if let streamError {
                if accumulatedDisplay.isEmpty {
                    finalContent = "BYOK request failed (\(self.byokConfig.provider.displayName) · \(self.byokConfig.modelID)): \(streamError.localizedDescription)"
                } else {
                    finalContent = "\(accumulatedDisplay)\n\n_Stream interrupted: \(streamError.localizedDescription)_"
                }
                self.statusBanner = streamError.localizedDescription
            } else if accumulatedDisplay.isEmpty {
                finalContent = "_No text returned by \(self.byokConfig.provider.displayName)._"
            } else {
                finalContent = accumulatedDisplay
            }

            await self.workingContextStore.replaceMessage(
                id: assistantID,
                content: finalContent,
                isStreaming: false,
                promptTokens: observedUsage ? totalPromptTokens : nil,
                completionTokens: observedUsage ? totalCompletionTokens : nil,
                attachments: collectedAttachments
            )
            await self.syncActiveThreadMessagesFromWorkingContext()
            self.activeToolCallStatus = nil
            self.isStreaming = false
            self.streamingTask = nil
            await self.refreshState()
            await self.saveWorkspaceNow()
        }

        streamingTask = task
        await task.value
    }

    private func composeStreamingDisplay(
        previousDisplay: String,
        currentRoundText: String,
        roundIndex: Int
    ) -> String {
        guard roundIndex > 0, !previousDisplay.isEmpty else {
            return currentRoundText
        }
        if currentRoundText.isEmpty {
            return previousDisplay
        }
        return "\(previousDisplay)\n\n\(currentRoundText)"
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

    // MARK: - MCP Server Connections, OAuth 2.1 PKCE & Elicitation

    func saveMCPConnection(
        _ connection: MCPServerConnection,
        bearerToken: String?,
        clientSecret: String?
    ) async {
        let cleanBearer = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !cleanBearer.isEmpty || !cleanSecret.isEmpty {
            if !(await vaultManager.isUnlocked()) {
                let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to store MCP credentials")
                guard unlocked else {
                    mcpStatusMessage = vaultErrorMessage ?? "Vault is locked; credentials were not saved."
                    return
                }
            }
        }

        do {
            if !cleanBearer.isEmpty {
                try await mcpManager.saveBearerToken(cleanBearer, for: connection.id)
            }
            if !cleanSecret.isEmpty {
                try await mcpManager.saveClientSecret(cleanSecret, for: connection.id)
            }
        } catch {
            mcpStatusMessage = "Failed to store MCP secret: \(error.localizedDescription)"
            return
        }

        upsertMCPConnection(connection)
        await refreshMCPCredentialStatus()
        await saveWorkspaceNow()
        mcpStatusMessage = "Saved '\(connection.name)'."

        if connection.authMode == .none || !cleanBearer.isEmpty {
            await connectAndDiscoverTools(for: connection)
        }
    }

    func toggleMCPConnection(_ connection: MCPServerConnection, enabled: Bool) {
        var updated = connection
        updated.isEnabled = enabled
        upsertMCPConnection(updated)
        scheduleWorkspaceSave()
    }

    func deleteMCPConnection(_ connection: MCPServerConnection) async {
        mcpConnections.removeAll { $0.id == connection.id }
        try? await mcpManager.deleteSecrets(for: connection.id)
        await refreshMCPCredentialStatus()
        await saveWorkspaceNow()
        mcpStatusMessage = "Removed '\(connection.name)'."
    }

    func connectAndDiscoverTools(for connection: MCPServerConnection) async {
        discoveringConnectionID = connection.id
        defer { discoveringConnectionID = nil }

        let vaultCurrentlyUnlocked = await vaultManager.isUnlocked()
        if connection.authMode != .none && !vaultCurrentlyUnlocked {
            let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to read MCP credentials")
            guard unlocked else {
                mcpStatusMessage = "Vault locked. Unlock to connect '\(connection.name)'."
                return
            }
        }

        do {
            let (updated, handshake) = try await mcpManager.connectAndDiscoverTools(for: connection)
            upsertMCPConnection(updated)
            await refreshMCPCredentialStatus()
            await saveWorkspaceNow()
            let serverLabel = handshake.serverName ?? updated.name
            mcpStatusMessage = "Connected to \(serverLabel): discovered \(updated.discoveredTools.count) tool(s)."
        } catch {
            mcpStatusMessage = "Sync failed for '\(connection.name)': \(error.localizedDescription)"
        }
    }

    func startOAuthSignIn(for connection: MCPServerConnection) async {
        guard authenticatingConnectionID == nil else { return }
        authenticatingConnectionID = connection.id
        defer { authenticatingConnectionID = nil }

        if !(await vaultManager.isUnlocked()) {
            let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to store OAuth tokens")
            guard unlocked else {
                mcpStatusMessage = "Vault locked. Unlock before signing in."
                return
            }
        }

        guard let endpointURL = URL(string: connection.endpointURL) else {
            mcpStatusMessage = "Invalid MCP server endpoint URL."
            return
        }

        do {
            let authEndpoint: URL
            let tokenEndpoint: URL
            var registrationEndpoint: URL?
            var resourceURL: URL?
            var resolvedScopes = connection.scopes

            if let explicitAuth = connection.authorizationEndpoint,
               let explicitToken = connection.tokenEndpoint,
               let aURL = URL(string: explicitAuth),
               let tURL = URL(string: explicitToken) {
                authEndpoint = aURL
                tokenEndpoint = tURL
            } else {
                let discovered = try await mcpManager.oauthClient.discoverMetadata(for: endpointURL)
                authEndpoint = discovered.authorizationEndpoint
                tokenEndpoint = discovered.tokenEndpoint
                registrationEndpoint = discovered.registrationEndpoint
                resourceURL = discovered.resourceURL
                if resolvedScopes.isEmpty && !discovered.supportedScopes.isEmpty {
                    resolvedScopes = discovered.supportedScopes
                }
            }

            let redirectURL = URL(string: connection.redirectURI)
            let callbackPort = UInt16(redirectURL?.port ?? 48912)
            let callbackPath = redirectURL?.path ?? "/callback"

            let pkce = try PKCEChallenge.generate()
            let loopback = LoopbackOAuthServer()
            activeLoopbackServer = loopback
            let boundPort = try await loopback.start(
                port: callbackPort,
                callbackPath: callbackPath,
                expectedState: pkce.state
            )

            let effectiveRedirectURI: String
            if let redirectURL, var comps = URLComponents(url: redirectURL, resolvingAgainstBaseURL: false) {
                comps.port = Int(boundPort)
                effectiveRedirectURI = comps.url?.absoluteString ?? connection.redirectURI
            } else {
                effectiveRedirectURI = "http://127.0.0.1:\(boundPort)/callback"
            }

            var effectiveClientID = connection.clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if effectiveClientID.isEmpty {
                guard let regEndpoint = registrationEndpoint else {
                    await loopback.stop()
                    activeLoopbackServer = nil
                    mcpStatusMessage = "Enter a Client ID in Edit Setup (this server did not advertise Dynamic Client Registration)."
                    return
                }
                effectiveClientID = try await mcpManager.oauthClient.registerDynamicClient(
                    registrationEndpoint: regEndpoint,
                    redirectURI: effectiveRedirectURI
                )
            }

            let authURL = try mcpManager.oauthClient.buildAuthorizationURL(
                authorizationEndpoint: authEndpoint,
                clientID: effectiveClientID,
                redirectURI: effectiveRedirectURI,
                scopes: resolvedScopes,
                pkce: pkce,
                resourceURL: resourceURL
            )

            mcpStatusMessage = "Opening browser for \(connection.name) sign-in…"
            NSWorkspace.shared.open(authURL)

            let code = try await loopback.awaitAuthorizationCode(timeoutSeconds: 180)
            activeLoopbackServer = nil

            let storedSecret = try? await vaultManager.connectorSecret(
                connectorID: connection.id,
                key: MCPVaultSecretKeys.clientSecret
            )

            let tokenSet = try await mcpManager.oauthClient.exchangeAuthorizationCode(
                tokenEndpoint: tokenEndpoint,
                code: code,
                codeVerifier: pkce.codeVerifier,
                clientID: effectiveClientID,
                clientSecret: storedSecret,
                redirectURI: effectiveRedirectURI,
                resourceURL: resourceURL
            )

            try await mcpManager.saveOAuthCredentials(
                tokens: tokenSet,
                clientID: effectiveClientID,
                clientSecret: storedSecret,
                authorizationEndpoint: authEndpoint,
                tokenEndpoint: tokenEndpoint,
                for: connection.id
            )

            var updated = connection
            updated.clientID = effectiveClientID
            updated.authorizationEndpoint = authEndpoint.absoluteString
            updated.tokenEndpoint = tokenEndpoint.absoluteString
            updated.redirectURI = effectiveRedirectURI
            upsertMCPConnection(updated)

            await refreshMCPCredentialStatus()
            await saveWorkspaceNow()
            await connectAndDiscoverTools(for: updated)
        } catch {
            await activeLoopbackServer?.stop()
            activeLoopbackServer = nil
            mcpStatusMessage = "OAuth sign-in failed for '\(connection.name)': \(error.localizedDescription)"
        }
    }

    func enqueueElicitation(_ request: MCPElicitationRequest) {
        guard !pendingElicitations.contains(where: { $0.id == request.id }) else { return }
        pendingElicitations.append(request)

        let bot = selectedPersona
        let threadID = activeThreadID
        let kind: PendingAttentionKind = (request.mode == .clientApproval) ? .yesNoApproval : .reviewInApp
        let fingerprint = PendingAttentionRecord.computeFingerprint(
            connectionID: request.connectionID,
            toolName: request.toolName,
            argumentsJSON: request.argumentsPreview
        )
        let record = PendingAttentionRecord(
            id: request.id,
            botID: bot.id,
            botName: bot.name,
            threadID: threadID,
            kind: kind,
            actionSummary: request.message,
            actionFingerprint: fingerprint,
            connectionID: request.connectionID,
            toolName: request.toolName,
            isPrivate: request.codePreview != nil,
            requiresVaultOrSignIn: !isVaultUnlocked && request.connectionID != "desktop-browser",
            requiresExtraInput: request.mode == .form || request.mode == .url
        )

        Task {
            await attentionCoordinator.register(record)
            await saveWorkspaceNow()
            if let payload = await attentionCoordinator.buildNotificationPayload(
                for: record.id,
                botNotificationsEnabled: bot.notificationsEnabled
            ) {
                onNotifyAttention?(payload)
            }
        }
    }

    func respondToElicitation(
        requestID: UUID,
        action: MCPElicitationAction,
        content: [String: JSONValue]? = nil
    ) {
        let pendingRequest = pendingElicitations.first(where: { $0.id == requestID })
        let decision: PendingAttentionDecision = switch action {
        case .accept: .allowOnce
        case .decline: .deny
        case .cancel: .cancel
        }

        Task {
            let expectedFingerprint = pendingRequest.map {
                PendingAttentionRecord.computeFingerprint(
                    connectionID: $0.connectionID,
                    toolName: $0.toolName,
                    argumentsJSON: $0.argumentsPreview
                )
            }
            let vaultUnlocked = await vaultManager.isUnlocked()
            let connectorAccessValid: Bool = {
                guard let connID = pendingRequest?.connectionID,
                      connID != "desktop-browser",
                      connID != "attention-test" else {
                    return true
                }
                return mcpConnections.first(where: { $0.id == connID })?.isEnabled ?? true
            }()

            let resolution = await attentionCoordinator.resolve(
                requestID: requestID,
                decision: decision,
                expectedFingerprint: expectedFingerprint,
                vaultUnlocked: vaultUnlocked,
                connectorAccessValid: connectorAccessValid
            )

            switch resolution {
            case .resolved(let resolvedDecision, let record):
                pendingElicitations.removeAll { $0.id == requestID }
                onDismissNotification?(requestID)
                let label: String = switch resolvedDecision {
                case .allowOnce: "Allowed once: \(record.actionSummary)"
                case .deny: "Denied: \(record.actionSummary)"
                case .cancel: "Cancelled: \(record.actionSummary)"
                }
                await workingContextStore.append(ChatMessage(role: .system, content: label))
                await syncActiveThreadMessagesFromWorkingContext()
                await refreshState()
                await saveWorkspaceNow()
                await mcpManager.respondToElicitation(
                    requestID: requestID,
                    response: MCPElicitationResponse(action: action, content: content)
                )

            case .expired(let record):
                pendingElicitations.removeAll { $0.id == requestID }
                onDismissNotification?(requestID)
                await workingContextStore.append(
                    ChatMessage(role: .system, content: "Expired request could not run: \(record.actionSummary)")
                )
                await syncActiveThreadMessagesFromWorkingContext()
                await refreshState()
                await saveWorkspaceNow()
                await mcpManager.respondToElicitation(
                    requestID: requestID,
                    response: MCPElicitationResponse(action: .cancel)
                )

            case .accessCheckFailed(let reason, _):
                statusBanner = reason
                await openAttentionRequest(requestID: requestID)

            case .fingerprintMismatch:
                pendingElicitations.removeAll { $0.id == requestID }
                onDismissNotification?(requestID)
                statusBanner = "Action changed before approval; cancelled for safety."
                await mcpManager.respondToElicitation(
                    requestID: requestID,
                    response: MCPElicitationResponse(action: .cancel)
                )

            case .alreadyResolved:
                pendingElicitations.removeAll { $0.id == requestID }
                onDismissNotification?(requestID)

            case .notFound:
                pendingElicitations.removeAll { $0.id == requestID }
                onDismissNotification?(requestID)
                await mcpManager.respondToElicitation(
                    requestID: requestID,
                    response: MCPElicitationResponse(action: action, content: content)
                )
            }
        }
    }

    func openAttentionRequest(requestID: UUID) async {
        guard let record = await attentionCoordinator.record(for: requestID) else { return }
        if let persona = personas.first(where: { $0.id == record.botID }) {
            selectedPersona = persona
        }
        if let threadID = record.threadID,
           let thread = threads.first(where: { $0.id == threadID }) {
            selectThread(thread)
        }
        if record.state == .expired {
            statusBanner = "Request expired: \(record.actionSummary)"
        }
    }

    func triggerSampleAttentionAlert(requiresApproval: Bool) {
        let bot = selectedPersona
        if requiresApproval {
            let sample = MCPElicitationRequest(
                connectionID: "attention-test",
                serverName: bot.name,
                toolName: "sample_action",
                mode: .clientApproval,
                message: "Allow \(bot.name) to run a sample workspace check?",
                argumentsPreview: #"{"check":"status"}"#,
                isReadOperation: false
            )
            enqueueElicitation(sample)
        } else {
            let record = PendingAttentionRecord(
                botID: bot.id,
                botName: bot.name,
                threadID: activeThreadID,
                kind: .taskReady,
                actionSummary: "\(bot.name) task is ready for review.",
                actionFingerprint: PendingAttentionRecord.computeFingerprint(connectionID: nil, toolName: "task_ready", argumentsJSON: nil)
            )
            Task {
                await attentionCoordinator.register(record)
                if let payload = await attentionCoordinator.buildNotificationPayload(
                    for: record.id,
                    botNotificationsEnabled: bot.notificationsEnabled
                ) {
                    onNotifyAttention?(payload)
                }
            }
        }
    }

    private func upsertMCPConnection(_ connection: MCPServerConnection) {
        if let idx = mcpConnections.firstIndex(where: { $0.id == connection.id }) {
            mcpConnections[idx] = connection
        } else {
            mcpConnections.append(connection)
        }
    }

    // MARK: - Marketplace Registry & Dynamic Setup Installation

    func refreshMarketplaceCatalog(remoteURLString: String? = nil) async {
        isLoadingMarketplace = true
        defer { isLoadingMarketplace = false }

        let targetString = (remoteURLString ?? marketplaceCatalogURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteURL = targetString.isEmpty ? nil : URL(string: targetString)
        let fallbackData = BrokAppResources.loadBundledCatalogData()

        do {
            marketplaceEntries = try await marketplaceRegistry.loadCatalog(
                remoteURL: remoteURL,
                bundledFallbackData: fallbackData
            )
            if let remoteURLString {
                marketplaceCatalogURL = remoteURLString
                scheduleWorkspaceSave()
            }
        } catch {
            mcpStatusMessage = "Marketplace catalog error: \(error.localizedDescription)"
        }
    }

    func installMarketplaceEntry(
        _ entry: MarketplaceCatalogEntry,
        configValues: [String: String],
        secretValues: [String: String]
    ) async {
        do {
            try await marketplaceRegistry.validateForInstallation(
                entry.manifest,
                allowUnsignedTemplates: allowUnsignedTemplates
            )
        } catch {
            mcpStatusMessage = error.localizedDescription
            return
        }

        let nonEmptySecrets = secretValues.filter {
            !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !nonEmptySecrets.isEmpty {
            if !(await vaultManager.isUnlocked()) {
                let unlocked = await unlockVault(reason: "Unlock Brok Bot Vault to store connector secrets")
                guard unlocked else {
                    mcpStatusMessage = vaultErrorMessage ?? "Vault is locked; connector secrets could not be saved."
                    return
                }
            }
            do {
                try await vaultManager.setConnectorSecrets(nonEmptySecrets, for: entry.manifest.id)
            } catch {
                mcpStatusMessage = "Failed to vault connector secrets: \(error.localizedDescription)"
                return
            }
        }

        let connection = marketplaceRegistry.makeConnection(
            from: entry.manifest,
            configValues: configValues
        )
        upsertMCPConnection(connection)
        await refreshMCPCredentialStatus()
        await saveWorkspaceNow()
        mcpStatusMessage = "Installed '\(entry.manifest.name)' (\(entry.verification.badgeLabel))."
    }
}
