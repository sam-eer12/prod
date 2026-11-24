import BrokBotCore
import SwiftUI

/// Minimal Liquid Glass menu bar popover surfacing status, vault lock, quick memory capture, and workspace actions.
struct MenuBarPopoverView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var notificationManager: LocalNotificationManager
    let onOpenWorkspace: () -> Void
    let onQuit: () -> Void

    @State private var quickMemoryInput: String = ""
    @State private var quickMemoryFeedback: String?
    @State private var isSavingMemory: Bool = false

    private var accentColor: Color {
        Color(hex: viewModel.selectedPersona.accentHex)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color(red: 0.05, green: 0.055, blue: 0.075)
                .opacity(0.76)
                .ignoresSafeArea()

            RadialGradient(
                colors: [accentColor.opacity(0.16), Color.clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 280
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 12) {
                headerSection
                statusBadgesSection
                quickMemorySection
                actionButtonsSection
            }
            .padding(14)
        }
        .frame(width: 336)
    }

    // MARK: - Header & Status

    private var headerSection: some View {
        HStack(spacing: 10) {
            if let nsImage = BrokAppResources.loadLogoImage() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Brok Bot")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isStreaming ? Color.orange : Color.green)
                            .frame(width: 6, height: 6)
                        Text(viewModel.isStreaming ? "Streaming" : "Ready")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }

                HStack(spacing: 5) {
                    Image(systemName: viewModel.selectedPersona.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(accentColor)
                    Text("\(viewModel.selectedPersona.name) · \(viewModel.byokConfig.provider.displayName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(1)
                }
            }

            Spacer()
        }
    }

    private var statusBadgesSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    if viewModel.isVaultUnlocked {
                        viewModel.lockVault()
                    } else {
                        Task {
                            await viewModel.unlockVault()
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: viewModel.isVaultUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(viewModel.isVaultUnlocked ? Color.green : Color.orange)
                        Text(viewModel.isVaultUnlocked ? "Vault Unlocked" : "Vault Locked")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.90))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        (viewModel.isVaultUnlocked ? Color.green : Color.orange).opacity(0.14)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke((viewModel.isVaultUnlocked ? Color.green : Color.orange).opacity(0.35), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(viewModel.isVaultUnlocked ? "Click to lock vault" : "Click to unlock vault")

                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10.5))
                        .foregroundStyle(accentColor)
                    Text("\(viewModel.effectiveThreadCount)T · \(viewModel.configuredProviders.count) Key(s)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.80))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 8) {
                metricTile(
                    icon: "bolt.horizontal.circle",
                    title: "Working",
                    value: "\(viewModel.workingTokenCount) / \(viewModel.workingTokenBudget) tok",
                    tint: .cyan
                )

                metricTile(
                    icon: "lock.shield",
                    title: "Permanent",
                    value: viewModel.isVaultUnlocked
                        ? "\(viewModel.memoryEntries.count) fact(s)"
                        : "Locked",
                    tint: Color(red: 0.90, green: 0.74, blue: 0.28)
                )
            }
        }
    }

    private func metricTile(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
            }
            Spacer()
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Quick Store in Memory

    private var quickMemorySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUICK STORE IN MEMORY")
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.45))

            HStack(spacing: 6) {
                TextField("e.g. My preferred seat is window", text: $quickMemoryInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onSubmit {
                        submitQuickMemory()
                    }

                Button {
                    submitQuickMemory()
                } label: {
                    if isSavingMemory {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(
                                quickMemoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color.white.opacity(0.30)
                                    : accentColor
                            )
                            .frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    isSavingMemory ||
                    quickMemoryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if let feedback = quickMemoryFeedback {
                Text(feedback)
                    .font(.system(size: 10.5))
                    .foregroundStyle(accentColor)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func submitQuickMemory() {
        let text = quickMemoryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSavingMemory else { return }
        isSavingMemory = true

        Task {
            let result = await viewModel.quickStorePermanentMemory(text)
            quickMemoryFeedback = result
            if viewModel.isVaultUnlocked {
                quickMemoryInput = ""
            }
            isSavingMemory = false
        }
    }

    // MARK: - Actions

    private var actionButtonsSection: some View {
        VStack(spacing: 7) {
            Button {
                onOpenWorkspace()
            } label: {
                HStack {
                    Label("Open Workspace", systemImage: "macwindow")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("⌘⇧B")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accentColor.opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(accentColor.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    Task {
                        _ = await notificationManager.sendTestNotification()
                    }
                } label: {
                    Label("Test Notification", systemImage: "bell.badge")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .foregroundStyle(.white.opacity(0.88))
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    onQuit()
                } label: {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(.red.opacity(0.92))
                        .background(Color.red.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let noteStatus = notificationManager.lastStatusMessage {
                Text(noteStatus)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
