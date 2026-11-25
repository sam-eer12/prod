import Foundation

/// Maps an LLM-exposed tool name back to its owning `MCPServerConnection` and original MCP tool.
public struct MCPToolRoute: Sendable, Equatable {
    public let exposedName: String
    public let connectionID: String
    public let tool: MCPDiscoveredTool

    public init(exposedName: String, connectionID: String, tool: MCPDiscoveredTool) {
        self.exposedName = exposedName
        self.connectionID = connectionID
        self.tool = tool
    }
}

/// Coordinates MCP server discovery (Streamable HTTP, Local Stdio, and Blender TCP JSON-RPC),
/// vaulted token retrieval/refresh, LLM tool routing, client-side & server-driven approval/elicitation gates,
/// and per-connection daily request metering.
public actor MCPConnectionManager {
    private let vault: any BrokVaultStoring
    public nonisolated let oauthClient: MCPOAuthClient
    public nonisolated let mcpClient: MCPStreamableHTTPClient
    public nonisolated let stdioClient: MCPStdioClient
    public nonisolated let blenderClient: BlenderBridgeClient

    private var sessionIDs: [String: String] = [:]
    private var pendingElicitations: [UUID: CheckedContinuation<MCPElicitationResponse, Never>] = [:]
    private var dailyCountsByDayAndConnection: [String: [String: Int]] = [:]

    public init(
        vault: any BrokVaultStoring,
        oauthClient: MCPOAuthClient = MCPOAuthClient(),
        mcpClient: MCPStreamableHTTPClient = MCPStreamableHTTPClient(),
        stdioClient: MCPStdioClient = MCPStdioClient(),
        blenderClient: BlenderBridgeClient = BlenderBridgeClient()
    ) {
        self.vault = vault
        self.oauthClient = oauthClient
        self.mcpClient = mcpClient
        self.stdioClient = stdioClient
        self.blenderClient = blenderClient
    }

    // MARK: - Vault Credential Management

    public func saveBearerToken(_ token: String, for connectionID: String) async throws {
        guard let vaultManager = vault as? BrokVaultManager,
              await vaultManager.isUnlocked() else {
            throw MCPClientError.vaultRequired
        }
        try await vaultManager.setConnectorSecrets(
            [MCPVaultSecretKeys.bearerToken: token],
            for: connectionID
        )
    }

    public func saveOAuthCredentials(
        tokens: OAuthTokenSet,
        clientID: String?,
        clientSecret: String?,
        authorizationEndpoint: URL?,
        tokenEndpoint: URL?,
        for connectionID: String
    ) async throws {
        guard let vaultManager = vault as? BrokVaultManager,
              await vaultManager.isUnlocked() else {
            throw MCPClientError.vaultRequired
        }

        var updates: [String: String] = [
            MCPVaultSecretKeys.accessToken: tokens.accessToken
        ]
        if let refresh = tokens.refreshToken, !refresh.isEmpty {
            updates[MCPVaultSecretKeys.refreshToken] = refresh
        }
        if let expiresIn = tokens.expiresIn {
            let expiryDate = Date().addingTimeInterval(max(10, expiresIn))
            updates[MCPVaultSecretKeys.expiresAt] = String(expiryDate.timeIntervalSince1970)
        }
        if let clientID, !clientID.isEmpty {
            updates[MCPVaultSecretKeys.registeredClientID] = clientID
        }
        if let clientSecret, !clientSecret.isEmpty {
            updates[MCPVaultSecretKeys.clientSecret] = clientSecret
        }
        if let authorizationEndpoint {
            updates[MCPVaultSecretKeys.authorizationEndpoint] = authorizationEndpoint.absoluteString
        }
        if let tokenEndpoint {
            updates[MCPVaultSecretKeys.tokenEndpoint] = tokenEndpoint.absoluteString
        }

        try await vaultManager.setConnectorSecrets(updates, for: connectionID)
    }

    public func saveClientSecret(_ secret: String, for connectionID: String) async throws {
        guard let vaultManager = vault as? BrokVaultManager,
              await vaultManager.isUnlocked() else {
            throw MCPClientError.vaultRequired
        }
        try await vaultManager.setConnectorSecrets(
            [MCPVaultSecretKeys.clientSecret: secret],
            for: connectionID
        )
    }

    public func deleteSecrets(for connectionID: String) async throws {
        sessionIDs.removeValue(forKey: connectionID)
        guard let vaultManager = vault as? BrokVaultManager else { return }
        if await vaultManager.isUnlocked() {
            try await vaultManager.deleteConnectorSecrets(for: connectionID)
        }
    }

    public func hasStoredCredential(for connection: MCPServerConnection) async -> Bool {
        guard connection.transportKind == .streamableHTTP, connection.authMode != .none else {
            return true
        }
        guard let vaultManager = vault as? BrokVaultManager,
              await vaultManager.isUnlocked() else {
            return false
        }
        let secrets = (try? await vaultManager.connectorSecrets(for: connection.id)) ?? [:]
        switch connection.authMode {
        case .none:
            return true
        case .bearerToken:
            return !(secrets[MCPVaultSecretKeys.bearerToken]?.isEmpty ?? true)
        case .oauthPKCE:
            return !(secrets[MCPVaultSecretKeys.accessToken]?.isEmpty ?? true)
                || !(secrets[MCPVaultSecretKeys.bearerToken]?.isEmpty ?? true)
        }
    }

    /// Resolves a valid Bearer/OAuth access token from `vault.enc`, transparently refreshing when expired.
    public func resolveAccessToken(for connection: MCPServerConnection) async throws -> String? {
        switch connection.authMode {
        case .none:
            return nil

        case .bearerToken:
            guard let vaultManager = vault as? BrokVaultManager,
                  await vaultManager.isUnlocked() else {
                throw MCPClientError.vaultRequired
            }
            return try await vaultManager.connectorSecret(
                connectorID: connection.id,
                key: MCPVaultSecretKeys.bearerToken
            )

        case .oauthPKCE:
            guard let vaultManager = vault as? BrokVaultManager,
                  await vaultManager.isUnlocked() else {
                throw MCPClientError.vaultRequired
            }
            let secrets = try await vaultManager.connectorSecrets(for: connection.id)
            if let bearerOverride = secrets[MCPVaultSecretKeys.bearerToken], !bearerOverride.isEmpty {
                return bearerOverride
            }

            let accessToken = secrets[MCPVaultSecretKeys.accessToken]
            let expiryTimestamp = secrets[MCPVaultSecretKeys.expiresAt].flatMap(Double.init)
            let isExpired = expiryTimestamp.map { Date().timeIntervalSince1970 >= ($0 - 60) } ?? false

            if !isExpired, let accessToken, !accessToken.isEmpty {
                return accessToken
            }

            if let refreshToken = secrets[MCPVaultSecretKeys.refreshToken],
               !refreshToken.isEmpty,
               let tokenEndpointString = secrets[MCPVaultSecretKeys.tokenEndpoint] ?? connection.tokenEndpoint,
               let tokenEndpoint = URL(string: tokenEndpointString),
               let clientID = connection.clientID ?? secrets[MCPVaultSecretKeys.registeredClientID],
               !clientID.isEmpty {
                let refreshed = try await oauthClient.refreshAccessToken(
                    tokenEndpoint: tokenEndpoint,
                    refreshToken: refreshToken,
                    clientID: clientID,
                    clientSecret: secrets[MCPVaultSecretKeys.clientSecret]
                )
                try await saveOAuthCredentials(
                    tokens: refreshed,
                    clientID: clientID,
                    clientSecret: secrets[MCPVaultSecretKeys.clientSecret],
                    authorizationEndpoint: (secrets[MCPVaultSecretKeys.authorizationEndpoint] ?? connection.authorizationEndpoint).flatMap(URL.init(string:)),
                    tokenEndpoint: tokenEndpoint,
                    for: connection.id
                )
                return refreshed.accessToken
            }

            return accessToken
        }
    }

    // MARK: - Discovery & Tool Routing

    /// Connects to an MCP server or local bridge and returns updated connection metadata + handshake.
    public func connectAndDiscoverTools(
        for connection: MCPServerConnection
    ) async throws -> (MCPServerConnection, MCPServerHandshake) {
        switch connection.transportKind {
        case .streamableHTTP:
            let token = try await resolveAccessToken(for: connection)
            let handshake = try await mcpClient.initialize(connection: connection, accessToken: token)
            incrementDailyRequestCount(for: connection.id)

            if let sessionID = handshake.sessionID, !connection.statelessMode {
                sessionIDs[connection.id] = sessionID
            } else {
                sessionIDs.removeValue(forKey: connection.id)
            }

            var workingConnection = connection
            workingConnection.protocolVersion = handshake.protocolVersion
            if let serverName = handshake.serverName, !serverName.isEmpty {
                workingConnection.serverName = serverName
            }

            let tools = try await mcpClient.listTools(
                connection: workingConnection,
                accessToken: token,
                sessionID: handshake.sessionID
            )
            incrementDailyRequestCount(for: connection.id)

            workingConnection.discoveredTools = tools
            workingConnection.lastConnectedAt = Date()
            return (workingConnection, handshake)

        case .stdio:
            guard let command = connection.stdioCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                throw MCPClientError.processError("Stdio MCP connection requires a command executable.")
            }
            let env = await stdioEnvironment(for: connection)
            let (handshake, tools) = try await stdioClient.initializeAndListTools(
                command: command,
                arguments: connection.stdioArgs,
                environment: env
            )
            incrementDailyRequestCount(for: connection.id)

            var workingConnection = connection
            workingConnection.protocolVersion = handshake.protocolVersion
            workingConnection.serverName = handshake.serverName ?? connection.name
            workingConnection.discoveredTools = tools
            workingConnection.lastConnectedAt = Date()
            return (workingConnection, handshake)

        case .tcpJSONRPC:
            let host = connection.tcpHost ?? "127.0.0.1"
            let port = connection.tcpPort ?? 9876
            _ = try await blenderClient.callMethod(
                host: host,
                port: port,
                method: "blender_get_scene_info",
                arguments: ["includeMaterials": .bool(true)]
            )
            incrementDailyRequestCount(for: connection.id)

            var workingConnection = connection
            workingConnection.protocolVersion = "jsonrpc-2.0"
            workingConnection.serverName = "Blender 3D Bridge (\(host):\(port))"
            workingConnection.lastConnectedAt = Date()
            return (workingConnection, MCPServerHandshake(
                protocolVersion: "jsonrpc-2.0",
                sessionID: nil,
                serverName: workingConnection.serverName,
                supportsElicitation: false
            ))
        }
    }

    /// Exposes enabled discovered tools to `BYOKModelClient`, enforcing read-only filtering.
    public nonisolated func buildActiveToolDefinitions(
        from connections: [MCPServerConnection]
    ) -> (definitions: [ToolDefinition], routes: [String: MCPToolRoute]) {
        var definitions: [ToolDefinition] = []
        var routes: [String: MCPToolRoute] = [:]
        var usedNames: Set<String> = []

        for connection in connections where connection.isEnabled {
            let slug = Self.sanitizeIdentifier(connection.id, maxLength: 20)
            for tool in connection.discoveredTools {
                if connection.readOnly && tool.destructiveHint == true {
                    continue
                }

                let toolSlug = Self.sanitizeIdentifier(tool.name, maxLength: 40)
                var candidate = "\(slug)__\(toolSlug)"
                if candidate.count > 64 {
                    candidate = String(candidate.prefix(64))
                }
                var suffix = 2
                while usedNames.contains(candidate) {
                    let tag = "_\(suffix)"
                    candidate = "\(String(candidate.prefix(max(1, 64 - tag.count))))\(tag)"
                    suffix += 1
                }
                usedNames.insert(candidate)

                definitions.append(tool.toBYOKToolDefinition(exposedName: candidate))
                routes[candidate] = MCPToolRoute(
                    exposedName: candidate,
                    connectionID: connection.id,
                    tool: tool
                )
            }
        }

        return (definitions, routes)
    }

    /// Executes an LLM-emitted `ToolCallRecord`, enforcing the Client-Side Write Approval Gate
    /// and bridging any server-driven `MCPElicitationRequest`.
    public func executeToolCall(
        record: ToolCallRecord,
        routes: [String: MCPToolRoute],
        connections: [MCPServerConnection],
        onElicitationRequested: @escaping @Sendable (MCPElicitationRequest) -> Void
    ) async -> MCPToolExecutionResult {
        guard let route = routes[record.name],
              let connection = connections.first(where: { $0.id == route.connectionID && $0.isEnabled }) else {
            return MCPToolExecutionResult(
                toolCallID: record.id,
                toolName: record.name,
                connectionID: "",
                outputText: "Tool '\(record.name)' is not available or its connector is disabled.",
                isError: true
            )
        }

        if connection.readOnly && route.tool.destructiveHint == true {
            return MCPToolExecutionResult(
                toolCallID: record.id,
                toolName: route.tool.name,
                connectionID: connection.id,
                outputText: MCPClientError.readOnlyBlocked(route.tool.name).localizedDescription,
                isError: true
            )
        }

        let arguments = JSONValue.decodeObject(from: record.argumentsJSON)

        // Client-Side Approval Gate for write / destructive / code-execution tools
        let needsClientApproval = route.tool.requiresApproval == true
            || (connection.requireApprovalForWrites && route.tool.destructiveHint == true)
        var gateAction: MCPElicitationAction?

        if needsClientApproval {
            let preview = arguments.isEmpty ? nil : JSONValue.encodeObjectString(arguments)
            let codePreview = arguments["code"]?.stringValue
            let approvalRequest = MCPElicitationRequest(
                connectionID: connection.id,
                serverName: connection.name,
                toolName: route.tool.name,
                mode: .clientApproval,
                message: "Approve executing '\(route.tool.name)' on \(connection.name)?",
                argumentsPreview: preview,
                codePreview: codePreview,
                isReadOperation: false
            )
            let decision = await awaitUserElicitation(approvalRequest, notify: onElicitationRequested)
            gateAction = decision.action
            guard decision.action == .accept else {
                return MCPToolExecutionResult(
                    toolCallID: record.id,
                    toolName: route.tool.name,
                    connectionID: connection.id,
                    outputText: "User denied execution of '\(route.tool.name)' (\(decision.action.rawValue)).",
                    isError: true,
                    elicitationAction: decision.action
                )
            }
        }

        do {
            switch connection.transportKind {
            case .streamableHTTP:
                let token = try await resolveAccessToken(for: connection)
                let sessionID = connection.statelessMode ? nil : sessionIDs[connection.id]
                incrementDailyRequestCount(for: connection.id)

                let payload = try await mcpClient.callTool(
                    connection: connection,
                    toolName: route.tool.name,
                    arguments: arguments,
                    accessToken: token,
                    sessionID: sessionID,
                    onElicitation: { [weak self] request in
                        guard let self else {
                            return MCPElicitationResponse(action: .cancel)
                        }
                        return await self.awaitUserElicitation(request, notify: onElicitationRequested)
                    }
                )

                return MCPToolExecutionResult(
                    toolCallID: record.id,
                    toolName: route.tool.name,
                    connectionID: connection.id,
                    outputText: payload.outputText,
                    isError: payload.isError,
                    attachments: payload.attachments,
                    elicitationAction: payload.elicitationAction ?? gateAction
                )

            case .stdio:
                guard let command = connection.stdioCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else {
                    throw MCPClientError.processError("Stdio MCP connection missing command.")
                }
                let env = await stdioEnvironment(for: connection)
                incrementDailyRequestCount(for: connection.id)

                let payload = try await stdioClient.callTool(
                    command: command,
                    arguments: connection.stdioArgs,
                    environment: env,
                    toolName: route.tool.name,
                    toolArguments: arguments,
                    connectionName: connection.name
                )

                return MCPToolExecutionResult(
                    toolCallID: record.id,
                    toolName: route.tool.name,
                    connectionID: connection.id,
                    outputText: payload.outputText,
                    isError: payload.isError,
                    attachments: payload.attachments,
                    elicitationAction: gateAction
                )

            case .tcpJSONRPC:
                let host = connection.tcpHost ?? "127.0.0.1"
                let port = connection.tcpPort ?? 9876
                incrementDailyRequestCount(for: connection.id)

                let payload = try await blenderClient.callMethod(
                    host: host,
                    port: port,
                    method: route.tool.name,
                    arguments: arguments
                )

                return MCPToolExecutionResult(
                    toolCallID: record.id,
                    toolName: route.tool.name,
                    connectionID: connection.id,
                    outputText: payload.outputText,
                    isError: payload.isError,
                    attachments: payload.attachments,
                    elicitationAction: gateAction
                )
            }
        } catch {
            return MCPToolExecutionResult(
                toolCallID: record.id,
                toolName: route.tool.name,
                connectionID: connection.id,
                outputText: "Tool call failed (\(connection.name) · \(route.tool.name)): \(error.localizedDescription)",
                isError: true,
                elicitationAction: gateAction
            )
        }
    }

    // MARK: - Elicitation Continuations & Daily Request Metering

    private func stdioEnvironment(for connection: MCPServerConnection) async -> [String: String] {
        guard let vaultManager = vault as? BrokVaultManager,
              await vaultManager.isUnlocked() else {
            return [:]
        }
        let secrets = (try? await vaultManager.connectorSecrets(for: connection.id)) ?? [:]
        var env: [String: String] = [:]
        if let bearer = secrets[MCPVaultSecretKeys.bearerToken], !bearer.isEmpty {
            env["MCP_BEARER_TOKEN"] = bearer
            env["API_KEY"] = bearer
        }
        return env
    }

    public func requestClientApproval(
        _ request: MCPElicitationRequest,
        onElicitationRequested: @escaping @Sendable (MCPElicitationRequest) -> Void
    ) async -> MCPElicitationResponse {
        await awaitUserElicitation(request, notify: onElicitationRequested)
    }

    private func awaitUserElicitation(
        _ request: MCPElicitationRequest,
        notify: @Sendable (MCPElicitationRequest) -> Void
    ) async -> MCPElicitationResponse {
        await withCheckedContinuation { continuation in
            pendingElicitations[request.id] = continuation
            notify(request)
        }
    }

    public func respondToElicitation(
        requestID: UUID,
        response: MCPElicitationResponse
    ) {
        guard let continuation = pendingElicitations.removeValue(forKey: requestID) else {
            return
        }
        continuation.resume(returning: response)
    }

    public func cancelAllPendingElicitations() {
        let pending = pendingElicitations
        pendingElicitations.removeAll()
        for (_, continuation) in pending {
            continuation.resume(returning: MCPElicitationResponse(action: .cancel))
        }
    }

    public func dailyRequestCountsSnapshot() -> [String: Int] {
        let key = Self.dayKey()
        return dailyCountsByDayAndConnection[key] ?? [:]
    }

    private func incrementDailyRequestCount(for connectionID: String) {
        let key = Self.dayKey()
        var dayMap = dailyCountsByDayAndConnection[key] ?? [:]
        dayMap[connectionID, default: 0] += 1
        dailyCountsByDayAndConnection = [key: dayMap]
    }

    private static func dayKey(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sanitizeIdentifier(_ raw: String, maxLength: Int) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                return Character(scalar)
            }
            return "_"
        }
        let cleaned = String(scalars)
        if cleaned.isEmpty { return "tool" }
        return String(cleaned.prefix(maxLength))
    }
}
