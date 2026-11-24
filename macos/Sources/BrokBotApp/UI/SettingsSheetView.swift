import BrokBotCore
import SwiftUI

/// Minimal Liquid Glass settings sheet covering BYOK Engine & Vault Keys, Permanent Memory Inspector,
/// and Compute, Startup & Local Notifications.
struct SettingsSheetView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var loginItemController: LoginItemController
    @ObservedObject var notificationManager: LocalNotificationManager
    @ObservedObject var hotkeyManager: GlobalHotkeyManager
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyDrafts: [BYOKProviderKind: String] = [:]
    @State private var customEndpointInput: String = ""
    @State private var memorySearchQuery: String = ""
    @State private var editingMemoryID: UUID?
    @State private var editingMemoryContent: String = ""
    @State private var editingMemoryCategory: String = ""

    private var accentColor: Color {
        Color(hex: viewModel.selectedPersona.accentHex)
    }

    private var filteredMemoryEntries: [MemoryEntry] {
        let query = memorySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.memoryEntries }
        return viewModel.memoryEntries.filter { entry in
            entry.content.localizedCaseInsensitiveContains(query)
                || entry.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color(red: 0.05, green: 0.055, blue: 0.075)
                .opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Brok Bot Settings")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("BYOK Engine & Vault Keys, Permanent Enclave, Compute, Startup & Notifications")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(accentColor.opacity(0.24))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }

                ScrollView {
                    VStack(spacing: 14) {
                        byokSection
                        permanentMemorySection
                        computeAndStartupSection
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 660, minHeight: 580)
        .onAppear {
            customEndpointInput = viewModel.byokConfig.customBaseURL?.absoluteString ?? ""
        }
    }

    // MARK: - BYOK Engine & Vault Keys

    private var byokSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("BYOK Engine & Vault Keys", systemImage: "key.fill")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                vaultLockButton
            }

            // Configured Provider Indicators
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BYOKProviderKind.allCases) { provider in
                        let configured = viewModel.isProviderConfigured(provider)
                        let isActive = viewModel.byokConfig.provider == provider
                        HStack(spacing: 5) {
                            Circle()
                                .fill(configured ? Color.green : Color.white.opacity(0.25))
                                .frame(width: 6, height: 6)
                            Text(provider.displayName)
                                .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                                .foregroundStyle(.white.opacity(configured || isActive ? 0.92 : 0.55))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(isActive ? accentColor.opacity(0.20) : Color.white.opacity(0.05))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isActive ? accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                        )
                    }
                }
            }

            HStack {
                Text("Active Provider")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Picker(
                    "Provider",
                    selection: Binding(
                        get: { viewModel.byokConfig.provider },
                        set: { viewModel.selectBYOKProvider($0) }
                    )
                ) {
                    ForEach(BYOKProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }

            HStack {
                Text("Model ID")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                TextField(
                    "Model ID",
                    text: Binding(
                        get: { viewModel.byokConfig.modelID },
                        set: { viewModel.updateBYOKModelID($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)

                Button("Reset") {
                    viewModel.updateBYOKModelID(viewModel.byokConfig.provider.defaultModelID)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Endpoint (Optional)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Effective: \(viewModel.byokConfig.effectiveBaseURL.absoluteString)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.50))
                        .lineLimit(1)
                }
                Spacer()
                TextField(
                    viewModel.byokConfig.provider.baseURL.absoluteString,
                    text: $customEndpointInput
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onChange(of: customEndpointInput) { _, newValue in
                    viewModel.updateBYOKCustomEndpoint(newValue)
                }
            }

            Toggle(
                isOn: Binding(
                    get: { viewModel.byokConfig.streamingEnabled },
                    set: { viewModel.updateBYOKStreamingEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live SSE Token Streaming")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Stream incremental assistant tokens in real time as they arrive.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)

            Divider()
                .overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ENCRYPTED VAULT KEYS (`vault.enc`)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.50))
                    Spacer()
                    Text("AES-256-GCM · HKDF-SHA256")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }

                ForEach(BYOKProviderKind.allCases) { provider in
                    providerKeyRow(provider)
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 16, glowColor: accentColor, material: .hudWindow)
    }

    private func providerKeyRow(_ provider: BYOKProviderKind) -> some View {
        let isConfigured = viewModel.isProviderConfigured(provider)
        let draftBinding = Binding<String>(
            get: { apiKeyDrafts[provider] ?? "" },
            set: { apiKeyDrafts[provider] = $0 }
        )

        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Text(isConfigured ? "Stored" : "Not Set")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(isConfigured ? Color.green : .white.opacity(0.50))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConfigured ? Color.green.opacity(0.15) : Color.white.opacity(0.06))
                        .clipShape(Capsule())
                }
                Text(provider.keyHintURL)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(1)
            }
            .frame(width: 175, alignment: .leading)

            SecureField(provider.apiKeyPlaceholder, text: draftBinding)
                .textFieldStyle(.roundedBorder)

            Button("Save") {
                let rawKey = apiKeyDrafts[provider] ?? ""
                Task {
                    let saved = await viewModel.saveAPIKey(rawKey, for: provider)
                    if saved {
                        apiKeyDrafts[provider] = ""
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accentColor.opacity(0.24))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .disabled((apiKeyDrafts[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Clear") {
                apiKeyDrafts[provider] = ""
                Task {
                    _ = await viewModel.deleteAPIKey(for: provider)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isConfigured ? Color.red.opacity(0.90) : .white.opacity(0.40))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .disabled(!isConfigured && (apiKeyDrafts[provider] ?? "").isEmpty)
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Permanent Memory Inspector

    private var permanentMemorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Permanent Memory Enclave (Space 2)", systemImage: "lock.shield")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer()

                vaultLockButton

                Button {
                    viewModel.compactPermanentMemory()
                } label: {
                    Label("Auto-Compact", systemImage: "wand.and.stars")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.22))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }

            if let banner = viewModel.statusBanner {
                Text(banner)
                    .font(.system(size: 11))
                    .foregroundStyle(accentColor)
            }

            if !viewModel.isVaultUnlocked {
                HStack(spacing: 10) {
                    Image(systemName: "touchid")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permanent Enclave is Locked")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Unlock with Touch ID / Keychain to inspect, search, edit, or purge encrypted facts.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Spacer()
                    Button("Unlock Vault") {
                        Task {
                            await viewModel.unlockVault()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.24))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .padding(12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.50))
                    TextField("Search permanent memories by content or category...", text: $memorySearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)

                    if !memorySearchQuery.isEmpty {
                        Button {
                            memorySearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                if filteredMemoryEntries.isEmpty {
                    Text(
                        viewModel.memoryEntries.isEmpty
                            ? "No permanent memory records stored yet. Try \"Store this in your memory: ...\" in chat."
                            : "No permanent memory records match \"\(memorySearchQuery)\"."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach(filteredMemoryEntries) { entry in
                            memoryEntryRow(entry)
                        }
                    }
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 16, glowColor: accentColor, material: .hudWindow)
    }

    private func memoryEntryRow(_ entry: MemoryEntry) -> some View {
        let isEditing = editingMemoryID == entry.id

        return VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                HStack(spacing: 8) {
                    TextField("Memory content", text: $editingMemoryContent)
                        .textFieldStyle(.roundedBorder)
                    TextField("Category", text: $editingMemoryCategory)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                HStack {
                    Spacer()
                    Button("Cancel") {
                        editingMemoryID = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.70))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Capsule())

                    Button("Save") {
                        viewModel.updateMemoryEntry(
                            id: entry.id,
                            content: editingMemoryContent,
                            category: editingMemoryCategory
                        )
                        editingMemoryID = nil
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.28))
                    .clipShape(Capsule())
                    .disabled(editingMemoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.content)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.92))

                        HStack(spacing: 8) {
                            Text(entry.category)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(accentColor.opacity(0.14))
                                .clipShape(Capsule())

                            Text(entry.lastUpdated.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.white.opacity(0.50))
                        }
                    }

                    Spacer()

                    Button {
                        editingMemoryID = entry.id
                        editingMemoryContent = entry.content
                        editingMemoryCategory = entry.category
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.80))
                            .padding(6)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Edit memory record")

                    Button {
                        viewModel.deleteMemoryEntry(entry)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.red.opacity(0.85))
                            .padding(6)
                            .background(Color.white.opacity(0.06))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Cryptographically forget this memory record")
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var vaultLockButton: some View {
        Button {
            if viewModel.isVaultUnlocked {
                viewModel.lockVault()
            } else {
                Task {
                    await viewModel.unlockVault()
                }
            }
        } label: {
            Label(
                viewModel.isVaultUnlocked ? "Lock Vault" : "Touch ID Unlock",
                systemImage: viewModel.isVaultUnlocked ? "lock.open.fill" : "touchid"
            )
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background((viewModel.isVaultUnlocked ? Color.green : Color.orange).opacity(0.18))
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isUnlockingVault)
    }

    // MARK: - Compute, Startup & Notifications

    private var computeAndStartupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Compute, Startup & Notifications", systemImage: "cpu")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Worker Threads")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("Active: \(viewModel.effectiveThreadCount) / \(ProcessInfo.processInfo.processorCount) cores")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Picker(
                    "Worker Threads",
                    selection: Binding(
                        get: { viewModel.computeConfig.threadAllocation },
                        set: { viewModel.updateThreadAllocation($0) }
                    )
                ) {
                    ForEach(ThreadAllocation.allCases) { allocation in
                        Text(allocation.displayName).tag(allocation)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(
                isOn: Binding(
                    get: { viewModel.computeConfig.hardwareAccelerationEnabled },
                    set: { viewModel.updateHardwareAcceleration($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Neural Engine (ANE) & Metal Acceleration")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Accelerates local WhisperKit dictation and on-device embeddings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)

            Divider()
                .overlay(Color.white.opacity(0.08))

            Toggle(
                isOn: Binding(
                    get: { loginItemController.isEnabled },
                    set: { loginItemController.setEnabled($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at Login (Silent Headless Mode)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Starts silently in the menu bar (`--background`) without opening the main window.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .toggleStyle(.switch)

            if let error = loginItemController.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Global Workspace Hotkey")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(
                        hotkeyManager.isRegistered
                            ? "Registered globally to toggle/reveal the workspace window."
                            : (hotkeyManager.registrationError ?? "Global hotkey inactive.")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("⌘⇧B")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hotkeyManager.isRegistered ? accentColor : .orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Notifications")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                        Text("Status: \(notificationManager.authorizationSummary)")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Button("Request Permission") {
                        Task {
                            _ = await notificationManager.requestAuthorization()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())

                    Button("Send Test Notification") {
                        Task {
                            _ = await notificationManager.sendTestNotification()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(accentColor.opacity(0.24))
                    .clipShape(Capsule())
                }

                if let status = notificationManager.lastStatusMessage {
                    Text(status)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.60))
                }
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 16, glowColor: accentColor, material: .hudWindow)
    }
}
