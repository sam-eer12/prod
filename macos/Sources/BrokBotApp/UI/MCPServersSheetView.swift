import BrokBotCore
import Foundation
import SwiftUI

/// Clean Minimal Liquid Glass sheet for:
/// 1. Adding Streamable HTTP, Local Stdio, and Local TCP JSON-RPC (Blender 3D) MCP servers/bridges
/// 2. Launching hosted read-only presets (Google Workspace Personal Mode, Stripe, Vercel, Railway, Cloud/Data/Dev MCPs)
/// 3. Browsing & installing Ed25519-verified Marketplace connectors with Dynamic Setup UI
struct MCPServersSheetView: View {
    enum SheetTab: String, CaseIterable, Identifiable {
        case servers = "My Servers & Presets"
        case marketplace = "Marketplace Catalog"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var activeTab: SheetTab = .servers
    @State private var isShowingEditor: Bool = false
    @State private var editingConnectionID: String?
    @State private var draftName: String = ""
    @State private var draftTransportKind: MCPTransportKind = .streamableHTTP
    @State private var draftEndpointURL: String = ""
    @State private var draftStdioCommand: String = ""
    @State private var draftStdioArgsText: String = ""
    @State private var draftTCPHost: String = "127.0.0.1"
    @State private var draftTCPPort: String = "9876"
    @State private var draftAuthMode: MCPAuthMode = .oauthPKCE
    @State private var draftReadOnly: Bool = true
    @State private var draftStatelessMode: Bool = false
    @State private var draftRequireWriteApproval: Bool = true
    @State private var draftClientID: String = ""
    @State private var draftClientSecret: String = ""
    @State private var draftBearerToken: String = ""
    @State private var draftScopesText: String = ""
    @State private var draftRedirectURI: String = MCPServerConnection.defaultRedirectURI
    @State private var draftAuthEndpoint: String = ""
    @State private var draftTokenEndpoint: String = ""
    @State private var draftPresetID: String?
    @State private var draftNotes: String?
    @State private var expandedToolConnectionIDs: Set<String> = []

    // Dynamic Marketplace Setup UI state
    @State private var configuringMarketplaceEntry: MarketplaceCatalogEntry?
    @State private var setupFieldValues: [String: String] = [:]
    @State private var presetCategoryFilter: MCPServerPresetCategory?
    @State private var presetSearchQuery: String = ""
    @State private var marketplaceSearchQuery: String = ""

    private var accentColor: Color {
        Color(hex: viewModel.selectedPersona.accentHex)
    }

    private var canSaveDraft: Bool {
        let trimmedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }

        switch draftTransportKind {
        case .streamableHTTP:
            let trimmedURL = draftEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmedURL),
                  let scheme = parsed.scheme?.lowercased(),
                  (scheme == "https" || scheme == "http"),
                  parsed.host != nil else {
                return false
            }
            return true
        case .stdio:
            return !draftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .tcpJSONRPC:
            let hostOk = !draftTCPHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let portOk = Int(draftTCPPort.trimmingCharacters(in: .whitespacesAndNewlines))
                .map { (1...65535).contains($0) } ?? false
            return hostOk && portOk
        }
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color(red: 0.05, green: 0.055, blue: 0.075)
                .opacity(0.80)
                .ignoresSafeArea()

            RadialGradient(
                colors: [accentColor.opacity(0.16), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            VStack(spacing: 14) {
                headerBar

                Picker("Section", selection: $activeTab) {
                    ForEach(SheetTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let status = viewModel.mcpStatusMessage, !status.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(accentColor)
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.88))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .liquidGlass(cornerRadius: 12, glowColor: accentColor, material: .hudWindow)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if activeTab == .servers {
                            if isShowingEditor {
                                serverEditorCard
                            }
                            presetsSection
                            configuredServersSection
                        } else {
                            marketplaceSection
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 740, minHeight: 640)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("MCP Servers & Modular Marketplace")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Streamable HTTP · Local Stdio · Blender TCP Bridge · Ed25519 Verified Catalog")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.60))
            }

            Spacer()

            Button {
                activeTab = .servers
                beginNewCustomServer()
            } label: {
                Label("Add MCP Server", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.24))
            .foregroundStyle(.white)
            .clipShape(Capsule())
        }
    }

    // MARK: - Built-in Read-Only Presets

    private var filteredPresets: [MCPServerPreset] {
        let query = presetSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MCPServerPreset.betaPresets.filter { preset in
            if let filter = presetCategoryFilter, preset.category != filter {
                return false
            }
            if query.isEmpty {
                return true
            }
            return preset.name.lowercased().contains(query)
                || preset.id.lowercased().contains(query)
                || preset.subtitle.lowercased().contains(query)
                || preset.endpointURL.lowercased().contains(query)
                || preset.category.rawValue.lowercased().contains(query)
        }
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HOSTED MCP PRESETS (\(filteredPresets.count))")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
                Text("Zero polling · On-demand MCP calls")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
            }

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                    TextField("Search Gmail, Drive, Stripe, Vercel, Railway…", text: $presetSearchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white)
                    if !presetSearchQuery.isEmpty {
                        Button {
                            presetSearchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .frame(maxWidth: 260)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        presetFilterPill(title: "All", isSelected: presetCategoryFilter == nil) {
                            presetCategoryFilter = nil
                        }
                        ForEach(MCPServerPresetCategory.allCases) { category in
                            presetFilterPill(title: category.rawValue, isSelected: presetCategoryFilter == category) {
                                presetCategoryFilter = (presetCategoryFilter == category) ? nil : category
                            }
                        }
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(filteredPresets) { preset in
                    presetCard(preset)
                }
            }
        }
    }

    private func presetFilterPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(isSelected ? accentColor.opacity(0.28) : Color.white.opacity(0.06))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.72))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? accentColor.opacity(0.55) : Color.white.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func presetCard(_ preset: MCPServerPreset) -> some View {
        let existing = viewModel.mcpConnections.first(where: { $0.presetID == preset.id || $0.id == preset.id })

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(preset.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineLimit(2)
                }
                Spacer()
                Text(preset.readOnly ? "Read-Only" : "Read/Write")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.14))
                    .clipShape(Capsule())
            }

            Text(preset.endpointURL)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(accentColor.opacity(0.90))
                .lineLimit(1)

            HStack(spacing: 6) {
                if preset.statelessMode {
                    badgePill("Stateless", tint: .cyan)
                }
                badgePill(preset.authMode.displayName, tint: .white.opacity(0.75))

                Spacer()

                Button {
                    if let existing {
                        beginEditing(existing)
                    } else {
                        beginFromPreset(preset)
                    }
                } label: {
                    Text(existing == nil ? "Configure" : "Edit Setup")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.24))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(cornerRadius: 15, glowColor: accentColor, material: .hudWindow)
    }

    // MARK: - Add / Edit Server Card (Streamable HTTP, Local Stdio, Local TCP JSON-RPC)

    private var serverEditorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    editingConnectionID == nil ? "Add MCP Server / Bridge" : "Configure Connection",
                    systemImage: "network"
                )
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.white)

                Spacer()

                if editingConnectionID == nil && draftPresetID == nil {
                    Button {
                        draftTransportKind = .streamableHTTP
                        draftName = "Notion"
                        draftEndpointURL = MCPServerPreset.notionQuickFillURL
                        draftAuthMode = .oauthPKCE
                        draftReadOnly = true
                        draftStatelessMode = false
                        draftNotes = "Official Notion hosted MCP server using OAuth 2.1 + PKCE."
                    } label: {
                        Text("Quick-Fill Notion")
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.08))
                            .foregroundStyle(.white.opacity(0.88))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button("Cancel") {
                    isShowingEditor = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.70))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())
            }

            if let notes = draftNotes, !notes.isEmpty {
                Text(notes)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.68))
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accentColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    editorLabel("DISPLAY NAME")
                    TextField("e.g. Linear, Local Filesystem, Blender", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(width: 220)

                VStack(alignment: .leading, spacing: 4) {
                    editorLabel("TRANSPORT")
                    Picker("Transport", selection: $draftTransportKind) {
                        ForEach(MCPTransportKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            switch draftTransportKind {
            case .streamableHTTP:
                VStack(alignment: .leading, spacing: 4) {
                    editorLabel("STREAMABLE HTTP ENDPOINT (HTTPS)")
                    TextField("https://mcp.example.com/mcp", text: $draftEndpointURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("AUTHENTICATION")
                        Picker("Auth Mode", selection: $draftAuthMode) {
                            ForEach(MCPAuthMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 300)
                    }

                    Toggle("Read-Only", isOn: $draftReadOnly)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))

                    Toggle("Stateless", isOn: $draftStatelessMode)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))

                    Toggle("Approve Writes", isOn: $draftRequireWriteApproval)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))
                }

                if draftAuthMode == .bearerToken {
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("BEARER TOKEN / API KEY (VAULTED IN `vault.enc`)")
                        SecureField("Paste token (leave blank to keep existing stored token)", text: $draftBearerToken)
                            .textFieldStyle(.roundedBorder)
                    }
                } else if draftAuthMode == .oauthPKCE {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("OAUTH CLIENT ID (GOOGLE PERSONAL MODE OR LEAVE BLANK FOR DCR)")
                                TextField("Leave blank to use MCP Dynamic Client Registration", text: $draftClientID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("CLIENT SECRET (OPTIONAL · VAULTED)")
                                SecureField("Optional client secret", text: $draftClientSecret)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(width: 220)
                        }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("SCOPES")
                                TextField("e.g. https://www.googleapis.com/auth/calendar.readonly", text: $draftScopesText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("LOOPBACK REDIRECT URI")
                                TextField("http://127.0.0.1:48912/callback", text: $draftRedirectURI)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            .frame(width: 240)
                        }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("AUTHORIZATION ENDPOINT (OPTIONAL)")
                                TextField("Auto-discovered via RFC 9728 / 8414 if blank", text: $draftAuthEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                editorLabel("TOKEN ENDPOINT (OPTIONAL)")
                                TextField("Auto-discovered if blank", text: $draftTokenEndpoint)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }
                    }
                }

            case .stdio:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("EXECUTABLE COMMAND")
                        TextField("e.g. npx, uvx, /usr/bin/python3", text: $draftStdioCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(width: 230)

                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("ARGUMENTS (SPACE-SEPARATED)")
                        TextField("e.g. -y @modelcontextprotocol/server-filesystem ~/Desktop", text: $draftStdioArgsText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("OPTIONAL API TOKEN ENV (MCP_BEARER_TOKEN IN `vault.enc`)")
                        SecureField("Optional secret token", text: $draftBearerToken)
                            .textFieldStyle(.roundedBorder)
                    }
                    Toggle("Read-Only", isOn: $draftReadOnly)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))
                    Toggle("Approve Writes", isOn: $draftRequireWriteApproval)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))
                }

            case .tcpJSONRPC:
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("LOCAL HOST")
                        TextField("127.0.0.1", text: $draftTCPHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("TCP PORT")
                        TextField("9876", text: $draftTCPPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(width: 110)

                    Toggle("Approve Write/Script Calls", isOn: $draftRequireWriteApproval)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.90))
                }
            }

            HStack {
                Spacer()
                Button {
                    saveDraft()
                } label: {
                    Text(editingConnectionID == nil ? "Save Connection" : "Update Connection")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(canSaveDraft ? accentColor.opacity(0.28) : Color.white.opacity(0.08))
                        .foregroundStyle(canSaveDraft ? .white : .white.opacity(0.45))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSaveDraft)
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 16, glowColor: accentColor, material: .hudWindow)
    }

    // MARK: - Configured Servers

    private var configuredServersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONFIGURED CONNECTIONS (\(viewModel.mcpConnections.count))")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.50))

            if viewModel.mcpConnections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No MCP servers or bridges configured yet.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Pick a hosted preset above, install from the Marketplace Catalog tab, or click Add MCP Server for any Streamable HTTP, Local Stdio, or Blender TCP endpoint.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(cornerRadius: 14, glowColor: accentColor, material: .hudWindow)
            } else {
                ForEach(viewModel.mcpConnections) { connection in
                    configuredServerCard(connection)
                }
            }
        }
    }

    private func configuredServerCard(_ connection: MCPServerConnection) -> some View {
        let hasCred = viewModel.hasCredential(for: connection)
        let isAuthenticating = viewModel.authenticatingConnectionID == connection.id
        let isDiscovering = viewModel.discoveringConnectionID == connection.id
        let dailyRequests = viewModel.dailyRequestCounts[connection.id] ?? 0
        let isExpanded = expandedToolConnectionIDs.contains(connection.id)

        let subtitle: String = {
            switch connection.transportKind {
            case .streamableHTTP: return connection.endpointURL
            case .stdio: return "\(connection.stdioCommand ?? "") \(connection.stdioArgs.joined(separator: " "))"
            case .tcpJSONRPC: return "tcp://\(connection.tcpHost ?? "127.0.0.1"):\(connection.tcpPort ?? 9876)"
            }
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Circle()
                    .fill(connection.isEnabled && hasCred ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(connection.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(.white)

                        badgePill(connection.transportKind.displayName, tint: .cyan)
                        if connection.readOnly {
                            badgePill("Read-Only", tint: .green)
                        }
                        if connection.transportKind == .streamableHTTP {
                            if connection.statelessMode {
                                badgePill("Stateless", tint: .cyan)
                            }
                            if connection.authMode != .none {
                                badgePill(hasCred ? "Vaulted Creds" : "Needs Auth", tint: hasCred ? .green : .orange)
                            }
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer()

                Text("\(dailyRequests) req/day")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.60))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())

                Toggle(
                    "",
                    isOn: Binding(
                        get: { connection.isEnabled },
                        set: { viewModel.toggleMCPConnection(connection, enabled: $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            HStack(spacing: 8) {
                if connection.transportKind == .streamableHTTP && connection.authMode == .oauthPKCE {
                    Button {
                        Task {
                            await viewModel.startOAuthSignIn(for: connection)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if isAuthenticating {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.system(size: 11))
                            }
                            Text(isAuthenticating ? "Signing In…" : (hasCred ? "Re-Authorize" : "Sign In (PKCE)"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(accentColor.opacity(0.24))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAuthenticating || isDiscovering)
                }

                Button {
                    Task {
                        await viewModel.connectAndDiscoverTools(for: connection)
                    }
                } label: {
                    HStack(spacing: 5) {
                        if isDiscovering {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        let syncLabel = connection.transportKind == .tcpJSONRPC
                            ? "Test Socket (\(connection.discoveredTools.count))"
                            : "Sync Tools (\(connection.discoveredTools.count))"
                        Text(isDiscovering ? "Connecting…" : syncLabel)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white.opacity(0.92))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isDiscovering || isAuthenticating)

                if !connection.discoveredTools.isEmpty {
                    Button {
                        if isExpanded {
                            expandedToolConnectionIDs.remove(connection.id)
                        } else {
                            expandedToolConnectionIDs.insert(connection.id)
                        }
                    } label: {
                        Label(isExpanded ? "Hide Tools" : "Inspect Tools", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.06))
                            .foregroundStyle(.white.opacity(0.80))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button("Edit") {
                    beginEditing(connection)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.07))
                .clipShape(Capsule())

                Button("Remove") {
                    Task {
                        await viewModel.deleteMCPConnection(connection)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red.opacity(0.90))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.red.opacity(0.12))
                .clipShape(Capsule())
            }

            if isExpanded && !connection.discoveredTools.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(connection.discoveredTools) { tool in
                        let blockedByReadOnly = connection.readOnly && tool.destructiveHint == true
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: (tool.requiresApproval == true || blockedByReadOnly) ? "hand.raised.fill" : "wrench.and.screwdriver")
                                .font(.system(size: 10.5))
                                .foregroundStyle((tool.requiresApproval == true || blockedByReadOnly) ? .orange : accentColor)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.name)
                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.94))
                                    if tool.requiresApproval == true {
                                        badgePill("Approval Gate", tint: .orange)
                                    } else if tool.readOnlyHint == true {
                                        badgePill("readOnly", tint: .green)
                                    } else if tool.destructiveHint == true {
                                        badgePill(blockedByReadOnly ? "Blocked (Read-Only)" : "destructive", tint: .orange)
                                    }
                                }
                                if !tool.description.isEmpty {
                                    Text(tool.description)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.60))
                                }
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(13)
        .liquidGlass(cornerRadius: 15, glowColor: accentColor, material: .hudWindow)
    }

    // MARK: - Marketplace Catalog & Dynamic Setup UI

    private var filteredMarketplaceEntries: [MarketplaceCatalogEntry] {
        let query = marketplaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return viewModel.marketplaceEntries }
        return viewModel.marketplaceEntries.filter { entry in
            let m = entry.manifest
            return m.name.lowercased().contains(query)
                || m.id.lowercased().contains(query)
                || m.description.lowercased().contains(query)
                || m.permissions.contains(where: { $0.lowercased().contains(query) })
        }
    }

    private var marketplaceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        editorLabel("REMOTE CATALOG REGISTRY URL (OPTIONAL — DEFAULTS TO BUNDLED CATALOG)")
                        TextField("https://raw.githubusercontent.com/.../marketplace/catalog.json", text: $viewModel.marketplaceCatalogURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                    }

                    Button {
                        Task {
                            await viewModel.refreshMarketplaceCatalog()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if viewModel.isLoadingMarketplace {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            Text("Refresh")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(accentColor.opacity(0.24))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 14)
                }

                HStack(spacing: 10) {
                    Toggle("Allow Starter Dev Templates (`unsigned-starter-template`; tampered Ed25519 signatures are always rejected)", isOn: $viewModel.allowUnsignedTemplates)
                        .toggleStyle(.switch)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.78))

                    Spacer()

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                        TextField("Filter connectors…", text: $marketplaceSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                    .frame(width: 190)
                }
            }
            .padding(13)
            .liquidGlass(cornerRadius: 14, glowColor: accentColor, material: .hudWindow)

            if let entry = configuringMarketplaceEntry {
                dynamicMarketplaceSetupCard(entry)
            }

            ForEach(filteredMarketplaceEntries) { entry in
                marketplaceEntryCard(entry)
            }
        }
    }

    private func marketplaceEntryCard(_ entry: MarketplaceCatalogEntry) -> some View {
        let manifest = entry.manifest
        let installed = viewModel.mcpConnections.contains(where: { $0.id == manifest.id })
        let sigTint: Color = {
            switch entry.verification {
            case .verified: return .green
            case .unsignedTemplate: return .cyan
            case .untrustedKey: return .orange
            case .invalidSignature, .unsupportedAlgorithm: return .red
            }
        }()

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(manifest.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("v\(manifest.version)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        badgePill(entry.verification.badgeLabel, tint: sigTint)
                        if installed {
                            badgePill("Installed", tint: .green)
                        }
                    }

                    Text(manifest.description)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.68))
                }

                Spacer()

                Button {
                    beginDynamicMarketplaceSetup(entry)
                } label: {
                    Text(installed ? "Reconfigure" : "Setup & Install")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(entry.verification.isTamperedOrInvalid ? Color.red.opacity(0.20) : accentColor.opacity(0.26))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(entry.verification.isTamperedOrInvalid || !entry.validationErrors.isEmpty)
            }

            HStack(spacing: 6) {
                badgePill(manifest.transport.type, tint: .cyan)
                badgePill("auth: \(manifest.auth.type)", tint: .white.opacity(0.75))
                ForEach(manifest.permissions, id: \.self) { perm in
                    badgePill(perm, tint: .white.opacity(0.60))
                }
            }

            if !entry.validationErrors.isEmpty {
                Text("Schema errors: \(entry.validationErrors.joined(separator: ", "))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
            }
        }
        .padding(13)
        .liquidGlass(cornerRadius: 15, glowColor: sigTint, material: .hudWindow)
    }

    private func dynamicMarketplaceSetupCard(_ entry: MarketplaceCatalogEntry) -> some View {
        let fields = entry.manifest.auth.setupFields ?? []

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Dynamic Setup · \(entry.manifest.name)", systemImage: "slider.horizontal.3")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Close") {
                    configuringMarketplaceEntry = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.08))
                .clipShape(Capsule())
            }

            if fields.isEmpty {
                Text("No upfront setup fields required. Click Install to register tools and authorize via OAuth 2.1 + PKCE.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ForEach(fields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        editorLabel("\(field.label.uppercased())\(field.required ? " *" : "")\(field.secret ? " · VAULTED" : "")")
                        let binding = Binding<String>(
                            get: { setupFieldValues[field.key] ?? field.defaultValue ?? "" },
                            set: { setupFieldValues[field.key] = $0 }
                        )
                        if field.secret {
                            SecureField(field.placeholder ?? "", text: binding)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(field.placeholder ?? "", text: binding)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                }
            }

            HStack {
                Text("Permissions: \(entry.manifest.permissions.joined(separator: ", "))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Install Connector") {
                    var configVals: [String: String] = [:]
                    var secretVals: [String: String] = [:]
                    for field in fields {
                        let val = setupFieldValues[field.key] ?? field.defaultValue ?? ""
                        if field.secret {
                            secretVals[field.key] = val
                        } else {
                            configVals[field.key] = val
                        }
                    }
                    configuringMarketplaceEntry = nil
                    activeTab = .servers
                    Task {
                        await viewModel.installMarketplaceEntry(
                            entry,
                            configValues: configVals,
                            secretValues: secretVals
                        )
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(accentColor.opacity(0.28))
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
        }
        .padding(14)
        .liquidGlass(cornerRadius: 15, glowColor: accentColor, material: .hudWindow)
    }

    // MARK: - Helpers

    private func beginDynamicMarketplaceSetup(_ entry: MarketplaceCatalogEntry) {
        var initial: [String: String] = [:]
        for field in entry.manifest.auth.setupFields ?? [] {
            initial[field.key] = field.defaultValue ?? ""
        }
        setupFieldValues = initial
        configuringMarketplaceEntry = entry
    }

    private func beginNewCustomServer() {
        editingConnectionID = nil
        draftPresetID = nil
        draftName = ""
        draftTransportKind = .streamableHTTP
        draftEndpointURL = ""
        draftStdioCommand = ""
        draftStdioArgsText = ""
        draftTCPHost = "127.0.0.1"
        draftTCPPort = "9876"
        draftAuthMode = .oauthPKCE
        draftReadOnly = true
        draftStatelessMode = false
        draftRequireWriteApproval = true
        draftClientID = ""
        draftClientSecret = ""
        draftBearerToken = ""
        draftScopesText = ""
        draftRedirectURI = MCPServerConnection.defaultRedirectURI
        draftAuthEndpoint = ""
        draftTokenEndpoint = ""
        draftNotes = nil
        isShowingEditor = true
    }

    private func beginFromPreset(_ preset: MCPServerPreset) {
        let base = preset.makeConnection()
        editingConnectionID = base.id
        draftPresetID = preset.id
        draftName = base.name
        draftTransportKind = base.transportKind
        draftEndpointURL = base.endpointURL
        draftStdioCommand = ""
        draftStdioArgsText = ""
        draftTCPHost = "127.0.0.1"
        draftTCPPort = "9876"
        draftAuthMode = base.authMode
        draftReadOnly = base.readOnly
        draftStatelessMode = base.statelessMode
        draftRequireWriteApproval = base.requireApprovalForWrites
        draftClientID = base.clientID ?? ""
        draftClientSecret = ""
        draftBearerToken = ""
        draftScopesText = base.scopes.joined(separator: " ")
        draftRedirectURI = base.redirectURI
        draftAuthEndpoint = base.authorizationEndpoint ?? ""
        draftTokenEndpoint = base.tokenEndpoint ?? ""
        draftNotes = preset.setupInstructions
        isShowingEditor = true
    }

    private func beginEditing(_ connection: MCPServerConnection) {
        editingConnectionID = connection.id
        draftPresetID = connection.presetID
        draftName = connection.name
        draftTransportKind = connection.transportKind
        draftEndpointURL = connection.endpointURL
        draftStdioCommand = connection.stdioCommand ?? ""
        draftStdioArgsText = connection.stdioArgs.joined(separator: " ")
        draftTCPHost = connection.tcpHost ?? "127.0.0.1"
        draftTCPPort = String(connection.tcpPort ?? 9876)
        draftAuthMode = connection.authMode
        draftReadOnly = connection.readOnly
        draftStatelessMode = connection.statelessMode
        draftRequireWriteApproval = connection.requireApprovalForWrites
        draftClientID = connection.clientID ?? ""
        draftClientSecret = ""
        draftBearerToken = ""
        draftScopesText = connection.scopes.joined(separator: " ")
        draftRedirectURI = connection.redirectURI
        draftAuthEndpoint = connection.authorizationEndpoint ?? ""
        draftTokenEndpoint = connection.tokenEndpoint ?? ""
        draftNotes = connection.notes
        isShowingEditor = true
    }

    private func saveDraft() {
        let existing = editingConnectionID.flatMap { id in
            viewModel.mcpConnections.first(where: { $0.id == id })
        }
        let scopes = draftScopesText
            .split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }
        let stdioArgs = draftStdioArgsText
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
            .filter { !$0.isEmpty }

        let resolvedAuthMode: MCPAuthMode = {
            switch draftTransportKind {
            case .streamableHTTP: return draftAuthMode
            case .stdio: return draftBearerToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .bearerToken
            case .tcpJSONRPC: return .none
            }
        }()

        let connection = MCPServerConnection(
            id: existing?.id ?? editingConnectionID ?? Self.slugID(from: draftName),
            name: draftName.trimmingCharacters(in: .whitespacesAndNewlines),
            presetID: draftPresetID ?? existing?.presetID,
            transportKind: draftTransportKind,
            endpointURL: draftEndpointURL.trimmingCharacters(in: .whitespacesAndNewlines),
            stdioCommand: draftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftStdioCommand.trimmingCharacters(in: .whitespacesAndNewlines),
            stdioArgs: stdioArgs,
            tcpHost: draftTCPHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "127.0.0.1"
                : draftTCPHost.trimmingCharacters(in: .whitespacesAndNewlines),
            tcpPort: Int(draftTCPPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 9876,
            authMode: resolvedAuthMode,
            readOnly: draftTransportKind == .tcpJSONRPC ? false : draftReadOnly,
            statelessMode: draftStatelessMode,
            requireApprovalForWrites: draftRequireWriteApproval,
            isEnabled: existing?.isEnabled ?? true,
            clientID: draftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftClientID.trimmingCharacters(in: .whitespacesAndNewlines),
            scopes: scopes,
            authorizationEndpoint: draftAuthEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftAuthEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            tokenEndpoint: draftTokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : draftTokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            redirectURI: draftRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? MCPServerConnection.defaultRedirectURI
                : draftRedirectURI.trimmingCharacters(in: .whitespacesAndNewlines),
            discoveredTools: existing?.discoveredTools ?? [],
            lastConnectedAt: existing?.lastConnectedAt,
            protocolVersion: existing?.protocolVersion,
            serverName: existing?.serverName,
            notes: draftNotes
        )

        let bearer = draftBearerToken
        let secret = draftClientSecret
        isShowingEditor = false

        Task {
            await viewModel.saveMCPConnection(
                connection,
                bearerToken: bearer,
                clientSecret: secret
            )
        }
    }

    private static func slugID(from name: String) -> String {
        let lower = name.lowercased()
        let mapped = lower.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        return collapsed.isEmpty ? "mcp-\(suffix)" : "\(collapsed)-\(suffix)"
    }

    private func editorLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.50))
    }

    private func badgePill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .clipShape(Capsule())
    }
}
