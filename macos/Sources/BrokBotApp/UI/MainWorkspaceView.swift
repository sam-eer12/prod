import AppKit
import BrokBotCore
import SwiftUI

/// Helper loading bundled macOS app resources safely from `Bundle.module`.
enum BrokAppResources {
    static func loadLogoImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "logo", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Loads `brok-menubar-template.svg` as a template `NSImage` with a clean AppKit vector/SF Symbol fallback.
    static func loadMenuBarTemplateImage() -> NSImage {
        if let url = Bundle.module.url(forResource: "brok-menubar-template", withExtension: "svg"),
           let svgImage = NSImage(contentsOf: url),
           svgImage.isValid,
           !svgImage.representations.isEmpty {
            svgImage.size = NSSize(width: 18, height: 18)
            svgImage.isTemplate = true
            return svgImage
        }

        if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Brok Bot") {
            symbol.isTemplate = true
            return symbol
        }

        let fallback = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3))
            ring.lineWidth = 1.6
            ring.stroke()
            return true
        }
        fallback.isTemplate = true
        return fallback
    }
}

/// Clean Minimal Liquid Glass main workspace featuring persona/thread sidebar, streaming markdown feed, and floating pill composer.
struct MainWorkspaceView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var loginItemController: LoginItemController
    @ObservedObject var notificationManager: LocalNotificationManager
    @ObservedObject var hotkeyManager: GlobalHotkeyManager

    @State private var isShowingNewPersonaSheet: Bool = false
    @State private var personaBeingEdited: BotPersona?
    @State private var isSummaryExpanded: Bool = false

    private var accentColor: Color {
        Color(hex: viewModel.selectedPersona.accentHex)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color(red: 0.05, green: 0.055, blue: 0.075)
                .opacity(0.68)
                .ignoresSafeArea()

            RadialGradient(
                colors: [accentColor.opacity(0.16), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.35), value: viewModel.selectedPersona.id)

            HStack(spacing: 14) {
                sidebar
                chatWorkspace
            }
            .padding(14)
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $viewModel.isShowingSettings) {
            SettingsSheetView(
                viewModel: viewModel,
                loginItemController: loginItemController,
                notificationManager: notificationManager,
                hotkeyManager: hotkeyManager
            )
        }
        .sheet(isPresented: $isShowingNewPersonaSheet) {
            PersonaEditorSheet { newPersona in
                viewModel.addPersona(newPersona)
            }
        }
        .sheet(item: $personaBeingEdited) { persona in
            PersonaEditorSheet(existingPersona: persona) { updatedPersona in
                viewModel.updatePersona(updatedPersona)
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Brand header with logo.png
            HStack(spacing: 10) {
                brandAvatar(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brok Bot")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Local-First AI")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
            .padding(.top, 18)
            .padding(.horizontal, 4)

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Teammates (Personas)
            HStack {
                Text("TEAMMATES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    isShowingNewPersonaSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.80))
                        .padding(4)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Add custom specialist persona")
            }
            .padding(.horizontal, 4)

            VStack(spacing: 5) {
                ForEach(viewModel.personas) { persona in
                    personaRow(persona)
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.08))

            // Conversation Threads
            HStack {
                Text("THREADS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    viewModel.createNewThread()
                } label: {
                    Label("New Thread", systemImage: "plus")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(viewModel.threads) { thread in
                        threadRow(thread)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Vault Lock/Unlock Status Pill
            vaultStatusPill

            // Dual-Space Context summary badges
            VStack(alignment: .leading, spacing: 8) {
                Text("DUAL-SPACE CONTEXT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))

                contextBadge(
                    icon: "bolt.horizontal.circle",
                    title: "Working Context",
                    detail: "\(viewModel.workingTokenCount) / \(viewModel.workingTokenBudget) tok",
                    tint: .cyan
                )

                contextBadge(
                    icon: "lock.shield",
                    title: "Permanent Enclave",
                    detail: viewModel.isVaultUnlocked
                        ? "\(viewModel.memoryEntries.count) fact(s)"
                        : "Locked · Tap to unlock",
                    tint: Color(red: 0.85, green: 0.70, blue: 0.25)
                )
            }
            .padding(10)
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Footer controls
            HStack(spacing: 8) {
                Button {
                    viewModel.resetWorkingContext()
                } label: {
                    Label("Clear", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    viewModel.isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(accentColor.opacity(0.22))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .frame(width: 248)
        .liquidGlass(cornerRadius: 20, glowColor: accentColor, material: .sidebar)
    }

    private func personaRow(_ persona: BotPersona) -> some View {
        let isSelected = persona.id == viewModel.selectedPersona.id
        let color = Color(hex: persona.accentHex)

        return Button {
            viewModel.selectPersona(persona)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: persona.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 26, height: 26)
                    .background(color.opacity(0.14))
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(persona.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(persona.role)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.45) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !persona.isDefault {
                Button {
                    personaBeingEdited = persona
                } label: {
                    Label("Edit Persona", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    viewModel.deletePersona(persona)
                } label: {
                    Label("Delete Persona", systemImage: "trash")
                }
            }
        }
    }

    private func threadRow(_ thread: ConversationThread) -> some View {
        let isSelected = thread.id == viewModel.activeThread?.id
        let threadPersona = viewModel.personas.first(where: { $0.id == thread.personaID })
        let threadColor = Color(hex: threadPersona?.accentHex ?? viewModel.selectedPersona.accentHex)

        return HStack(spacing: 8) {
            Button {
                viewModel.selectThread(thread)
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(threadColor.opacity(isSelected ? 1.0 : 0.45))
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.78))
                            .lineLimit(1)
                        Text("\(thread.messages.count) msg · \(thread.updatedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Button {
                viewModel.deleteThread(thread)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.40))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Delete thread")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? threadColor.opacity(0.35) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteThread(thread)
            } label: {
                Label("Delete Thread", systemImage: "trash")
            }
        }
    }

    private var vaultStatusPill: some View {
        Button {
            if viewModel.isVaultUnlocked {
                viewModel.lockVault()
            } else {
                Task {
                    await viewModel.unlockVault()
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: viewModel.isVaultUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(viewModel.isVaultUnlocked ? Color.green : Color.orange)

                Text(
                    viewModel.isUnlockingVault
                        ? "Unlocking Vault…"
                        : (viewModel.isVaultUnlocked ? "Vault Unlocked" : "Vault Locked")
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Text(viewModel.isVaultUnlocked ? "Lock" : "Unlock")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                (viewModel.isVaultUnlocked ? Color.green : Color.orange).opacity(0.14)
            )
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        (viewModel.isVaultUnlocked ? Color.green : Color.orange).opacity(0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isUnlockingVault)
    }

    private func contextBadge(icon: String, title: String, detail: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    // MARK: - Chat Workspace

    private var chatWorkspace: some View {
        VStack(spacing: 12) {
            headerBar
            if let summary = viewModel.workingSummary, !summary.isEmpty {
                rollingSummaryBadge(summary)
            }
            messageStream
            floatingComposer
        }
        .padding(.top, 8)
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accentColor)
                .frame(width: 9, height: 9)
                .shadow(color: accentColor.opacity(0.8), radius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.selectedPersona.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(viewModel.selectedPersona.role)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.60))
            }

            Spacer()

            if viewModel.isStreaming {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Streaming")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(accentColor.opacity(0.20))
                .clipShape(Capsule())
            }

            // Active BYOK pill
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(accentColor)
                Text("\(viewModel.byokConfig.provider.displayName) · \(viewModel.effectiveThreadCount)T")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                if viewModel.isProviderConfigured(viewModel.byokConfig.provider) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())

            // Working context meter pill
            Text("Working \(viewModel.workingTokenCount)/\(viewModel.workingTokenBudget)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.05))
                .clipShape(Capsule())

            Button {
                viewModel.isShowingSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(7)
                    .background(Color.white.opacity(0.07))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Open Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlass(cornerRadius: 18, glowColor: accentColor, material: .hudWindow)
    }

    private func rollingSummaryBadge(_ summary: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSummaryExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("Rolling Context Summary Active")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.90))
                    Spacer()
                    Image(systemName: isSummaryExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                }

                if isSummaryExpanded {
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.70))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .liquidGlass(cornerRadius: 12, glowColor: .cyan, material: .hudWindow)
        }
        .buttonStyle(.plain)
    }

    private var messageStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    emptyStateView
                        .frame(maxWidth: .infinity, minHeight: 340)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 4)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                scrollToLastMessage(using: proxy)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if viewModel.isStreaming {
                    scrollToLastMessage(using: proxy)
                }
            }
        }
    }

    private func scrollToLastMessage(using proxy: ScrollViewProxy) {
        guard let lastID = viewModel.messages.last?.id else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            brandAvatar(size: 74)
                .shadow(color: accentColor.opacity(0.30), radius: 18)

            VStack(spacing: 6) {
                Text("Good day. \(viewModel.selectedPersona.name) standing by.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Test Dual-Space Memory live or chat with your configured BYOK engine.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.60))
            }

            VStack(spacing: 8) {
                suggestionChip("Store this in your memory: My preferred flight seat is aisle")
                suggestionChip("Update my memory about flight seat to window")
                suggestionChip("Forget about flight seat")
            }
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func suggestionChip(_ text: String) -> some View {
        Button {
            viewModel.submitSuggestion(text)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(accentColor)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(cornerRadius: 14, glowColor: accentColor, material: .hudWindow)
        }
        .buttonStyle(.plain)
    }

    private func messageBubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user

        return HStack {
            if isUser { Spacer(minLength: 80) }

            VStack(alignment: .leading, spacing: 6) {
                if message.memoryNotice != nil || message.isStreaming {
                    HStack(spacing: 8) {
                        if let notice = message.memoryNotice {
                            Label(notice, systemImage: "lock.shield.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Color(red: 0.96, green: 0.80, blue: 0.32))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(red: 0.96, green: 0.80, blue: 0.32).opacity(0.14))
                                .clipShape(Capsule())
                        }

                        if message.isStreaming {
                            HStack(spacing: 5) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text("Streaming...")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(accentColor)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(accentColor.opacity(0.14))
                            .clipShape(Capsule())
                        }
                    }
                }

                if message.content.isEmpty && message.isStreaming {
                    Text("Thinking…")
                        .font(.system(size: 13.5))
                        .italic()
                        .foregroundStyle(.white.opacity(0.55))
                } else {
                    markdownMessageText(message.content)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.95))
                        .tint(accentColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let tokenLabel = tokenUsageText(for: message) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(accentColor.opacity(0.85))
                        Text(tokenLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .if(isUser) { view in
                view
                    .background(accentColor.opacity(0.20))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(accentColor.opacity(0.42), lineWidth: 1)
                    )
            }
            .if(!isUser) { view in
                view.liquidGlass(cornerRadius: 16, glowColor: accentColor, material: .hudWindow)
            }

            if !isUser { Spacer(minLength: 80) }
        }
    }

    private func markdownMessageText(_ content: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: content,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return Text(attributed)
        }
        return Text(content)
    }

    private func tokenUsageText(for message: ChatMessage) -> String? {
        switch (message.promptTokens, message.completionTokens) {
        case let (.some(prompt), .some(completion)):
            return "↑ \(prompt) · ↓ \(completion) tok"
        case let (.some(prompt), .none):
            return "↑ \(prompt) tok"
        case let (.none, .some(completion)):
            return "↓ \(completion) tok"
        case (.none, .none):
            return nil
        }
    }

    // MARK: - Floating Pill Composer

    private var floatingComposer: some View {
        HStack(spacing: 10) {
            TextField(
                "Message \(viewModel.selectedPersona.name) or type 'Store this in your memory: ...'",
                text: $viewModel.draftInput
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13.5))
            .foregroundStyle(.white)
            .disabled(viewModel.isStreaming)
            .onSubmit {
                viewModel.sendCurrentDraft()
            }

            if viewModel.isStreaming {
                Button {
                    viewModel.cancelStreaming()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                        Text("Stop")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.75))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stop streaming response")
            } else {
                Button {
                    viewModel.sendCurrentDraft()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(
                            viewModel.draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.white.opacity(0.30)
                                : accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.draftInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 24, glowColor: accentColor, material: .hudWindow)
    }

    @ViewBuilder
    private func brandAvatar(size: CGFloat) -> some View {
        if let nsImage = BrokAppResources.loadLogoImage() {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 1)
                )
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
