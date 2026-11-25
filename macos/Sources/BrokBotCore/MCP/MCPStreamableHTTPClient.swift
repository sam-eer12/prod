import Foundation

/// Handshake metadata returned by an MCP server's `initialize` response.
public struct MCPServerHandshake: Sendable, Equatable {
    public var protocolVersion: String
    public var sessionID: String?
    public var serverName: String?
    public var serverVersion: String?
    public var supportsElicitation: Bool

    public init(
        protocolVersion: String,
        sessionID: String? = nil,
        serverName: String? = nil,
        serverVersion: String? = nil,
        supportsElicitation: Bool = true
    ) {
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.supportsElicitation = supportsElicitation
    }
}

/// Decoded result of an MCP `tools/call` invocation.
public struct MCPToolCallPayload: Sendable, Equatable {
    public var outputText: String
    public var isError: Bool
    public var attachments: [ChatAttachment]
    public var elicitationAction: MCPElicitationAction?

    public init(
        outputText: String,
        isError: Bool = false,
        attachments: [ChatAttachment] = [],
        elicitationAction: MCPElicitationAction? = nil
    ) {
        self.outputText = outputText
        self.isError = isError
        self.attachments = attachments
        self.elicitationAction = elicitationAction
    }
}

/// Standards-compliant MCP Streamable HTTP (`2025-06-18`) client supporting both stateful
/// (`Mcp-Session-Id`) and stateless servers, SSE + JSON responses, and server-driven
/// `elicitation/create` interactive approval/form/URL flows.
public final class MCPStreamableHTTPClient: Sendable {
    public static let defaultProtocolVersion = "2025-06-18"
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - Initialize & Tool Discovery

    public func initialize(
        connection: MCPServerConnection,
        accessToken: String?
    ) async throws -> MCPServerHandshake {
        let requestID = JSONValue.string(UUID().uuidString)
        let params: [String: JSONValue] = [
            "protocolVersion": .string(Self.defaultProtocolVersion),
            "capabilities": .object([
                "elicitation": .object([
                    "form": .object([:]),
                    "url": .object([:])
                ])
            ]),
            "clientInfo": .object([
                "name": .string("Brok Bot"),
                "version": .string("0.2.0")
            ])
        ]

        let (responseEnvelope, responseSessionID) = try await postJSONRPC(
            connection: connection,
            requestID: requestID,
            method: "initialize",
            params: params,
            accessToken: accessToken,
            sessionID: nil
        )

        if let error = responseEnvelope["error"]?.objectValue {
            throw jsonRPCError(from: error)
        }

        let result = responseEnvelope["result"]?.objectValue ?? [:]
        let protocolVersion = result["protocolVersion"]?.stringValue ?? Self.defaultProtocolVersion
        let serverInfo = result["serverInfo"]?.objectValue
        let effectiveSessionID = connection.statelessMode ? nil : responseSessionID

        // Best-effort `notifications/initialized` (stateless endpoints may return 202/204/405).
        try? await sendInitializedNotification(
            connection: connection,
            accessToken: accessToken,
            sessionID: effectiveSessionID,
            protocolVersion: protocolVersion
        )

        return MCPServerHandshake(
            protocolVersion: protocolVersion,
            sessionID: effectiveSessionID,
            serverName: serverInfo?["name"]?.stringValue,
            serverVersion: serverInfo?["version"]?.stringValue,
            supportsElicitation: true
        )
    }

    public func listTools(
        connection: MCPServerConnection,
        accessToken: String?,
        sessionID: String?
    ) async throws -> [MCPDiscoveredTool] {
        var allTools: [MCPDiscoveredTool] = []
        var cursor: String?
        var safetyIterations = 0

        repeat {
            safetyIterations += 1
            var params: [String: JSONValue] = [:]
            if let cursor, !cursor.isEmpty {
                params["cursor"] = .string(cursor)
            }

            let (envelope, _) = try await postJSONRPC(
                connection: connection,
                requestID: .string(UUID().uuidString),
                method: "tools/list",
                params: params,
                accessToken: accessToken,
                sessionID: connection.statelessMode ? nil : sessionID
            )

            if let error = envelope["error"]?.objectValue {
                throw jsonRPCError(from: error)
            }

            let result = envelope["result"]?.objectValue ?? [:]
            let rawTools = result["tools"]?.arrayValue ?? []
            for item in rawTools {
                guard let obj = item.objectValue,
                      let name = obj["name"]?.stringValue,
                      !name.isEmpty else {
                    continue
                }
                let annotations = obj["annotations"]?.objectValue
                let tool = MCPDiscoveredTool(
                    name: name,
                    title: obj["title"]?.stringValue,
                    description: obj["description"]?.stringValue ?? "",
                    inputSchema: obj["inputSchema"]?.objectValue,
                    readOnlyHint: annotations?["readOnlyHint"]?.boolValue,
                    destructiveHint: annotations?["destructiveHint"]?.boolValue
                )
                allTools.append(tool)
            }

            cursor = result["nextCursor"]?.stringValue
        } while cursor != nil && !(cursor?.isEmpty ?? true) && safetyIterations < 25

        return allTools
    }

    // MARK: - Tool Execution & Server-Driven Elicitation

    public func callTool(
        connection: MCPServerConnection,
        toolName: String,
        arguments: [String: JSONValue],
        accessToken: String?,
        sessionID: String?,
        onElicitation: @Sendable (MCPElicitationRequest) async -> MCPElicitationResponse
    ) async throws -> MCPToolCallPayload {
        try await invokeToolCall(
            connection: connection,
            toolName: toolName,
            arguments: arguments,
            meta: nil,
            accessToken: accessToken,
            sessionID: sessionID,
            allowStatelessRetry: true,
            onElicitation: onElicitation
        )
    }

    private func invokeToolCall(
        connection: MCPServerConnection,
        toolName: String,
        arguments: [String: JSONValue],
        meta: [String: JSONValue]?,
        accessToken: String?,
        sessionID: String?,
        allowStatelessRetry: Bool,
        onElicitation: @Sendable (MCPElicitationRequest) async -> MCPElicitationResponse
    ) async throws -> MCPToolCallPayload {
        let requestID = JSONValue.string(UUID().uuidString)
        var params: [String: JSONValue] = [
            "name": .string(toolName),
            "arguments": .object(arguments)
        ]
        if let meta, !meta.isEmpty {
            params["_meta"] = .object(meta)
        }

        let effectiveSessionID = connection.statelessMode ? nil : sessionID
        let urlRequest = try buildPostRequest(
            connection: connection,
            bodyObject: [
                "jsonrpc": .string("2.0"),
                "id": requestID,
                "method": .string("tools/call"),
                "params": .object(params)
            ],
            accessToken: accessToken,
            sessionID: effectiveSessionID
        )

        let (asyncBytes, response) = try await urlSession.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.decodingError("Expected HTTPURLResponse from MCP server.")
        }

        if http.statusCode == 401 {
            let authHeader = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            let hintURL = MCPOAuthClient.parseWWWAuthenticateResourceMetadata(authHeader)
            throw MCPClientError.unauthorized(resourceMetadataURL: hintURL)
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        guard (200...299).contains(http.statusCode) else {
            var errorBytes = Data()
            for try await byte in asyncBytes where errorBytes.count < 64 * 1024 {
                errorBytes.append(byte)
            }
            throw MCPClientError.httpError(
                statusCode: http.statusCode,
                body: String(decoding: errorBytes, as: UTF8.self)
            )
        }

        if contentType.contains("text/event-stream") {
            return try await consumeToolCallSSEStream(
                asyncBytes: asyncBytes,
                expectedRequestID: requestID,
                connection: connection,
                toolName: toolName,
                arguments: arguments,
                accessToken: accessToken,
                sessionID: effectiveSessionID ?? http.value(forHTTPHeaderField: "Mcp-Session-Id"),
                onElicitation: onElicitation
            )
        }

        var responseData = Data()
        for try await byte in asyncBytes {
            responseData.append(byte)
        }

        let envelope = try decodeJSONObject(responseData)
        return try await handleToolCallEnvelope(
            envelope,
            connection: connection,
            toolName: toolName,
            arguments: arguments,
            accessToken: accessToken,
            sessionID: effectiveSessionID,
            allowStatelessRetry: allowStatelessRetry,
            onElicitation: onElicitation
        )
    }

    private func consumeToolCallSSEStream(
        asyncBytes: URLSession.AsyncBytes,
        expectedRequestID: JSONValue,
        connection: MCPServerConnection,
        toolName: String,
        arguments: [String: JSONValue],
        accessToken: String?,
        sessionID: String?,
        onElicitation: @Sendable (MCPElicitationRequest) async -> MCPElicitationResponse
    ) async throws -> MCPToolCallPayload {
        var parser = SSEStreamParser(stopOnDoneSentinel: true)
        var pendingChunk = Data()
        pendingChunk.reserveCapacity(256)
        var lastAction: MCPElicitationAction?

        func processEvents(_ events: [SSEEvent]) async throws -> MCPToolCallPayload? {
            for sseEvent in events {
                if sseEvent.isDoneSentinel { continue }
                let trimmed = sseEvent.data.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let envelope = try decodeJSONObject(Data(trimmed.utf8))

                // Server-to-client elicitation request mid-stream
                if let method = envelope["method"]?.stringValue,
                   method == "elicitation/create",
                   let serverReqID = envelope["id"] {
                    let elicitation = buildElicitationRequest(
                        serverRequestID: serverReqID,
                        params: envelope["params"]?.objectValue ?? [:],
                        connection: connection,
                        toolName: toolName,
                        arguments: arguments
                    )
                    let clientResponse = await onElicitation(elicitation)
                    lastAction = clientResponse.action

                    var resultObj: [String: JSONValue] = [
                        "action": .string(clientResponse.action.rawValue)
                    ]
                    if let content = clientResponse.content, !content.isEmpty {
                        resultObj["content"] = .object(content)
                    }

                    try await postJSONRPCResponse(
                        connection: connection,
                        responseID: serverReqID,
                        result: .object(resultObj),
                        accessToken: accessToken,
                        sessionID: sessionID
                    )
                    continue
                }

                // Final JSON-RPC response for our tools/call request
                if envelope["id"] == expectedRequestID || envelope["result"] != nil || envelope["error"] != nil {
                    var payload = try await handleToolCallEnvelope(
                        envelope,
                        connection: connection,
                        toolName: toolName,
                        arguments: arguments,
                        accessToken: accessToken,
                        sessionID: sessionID,
                        allowStatelessRetry: false,
                        onElicitation: onElicitation
                    )
                    payload.elicitationAction = payload.elicitationAction ?? lastAction
                    return payload
                }
            }
            return nil
        }

        for try await byte in asyncBytes {
            try Task.checkCancellation()
            pendingChunk.append(byte)
            if byte == 0x0A || byte == 0x0D || pendingChunk.count >= 256 {
                let events = parser.feed(pendingChunk)
                pendingChunk.removeAll(keepingCapacity: true)
                if let resolved = try await processEvents(events) {
                    return resolved
                }
            }
        }

        if !pendingChunk.isEmpty {
            let events = parser.feed(pendingChunk)
            if let resolved = try await processEvents(events) {
                return resolved
            }
        }

        let trailing = parser.finish()
        if let resolved = try await processEvents(trailing) {
            return resolved
        }

        throw MCPClientError.decodingError("SSE stream closed before returning a tools/call response.")
    }

    private func handleToolCallEnvelope(
        _ envelope: [String: JSONValue],
        connection: MCPServerConnection,
        toolName: String,
        arguments: [String: JSONValue],
        accessToken: String?,
        sessionID: String?,
        allowStatelessRetry: Bool,
        onElicitation: @Sendable (MCPElicitationRequest) async -> MCPElicitationResponse
    ) async throws -> MCPToolCallPayload {
        if let errorObj = envelope["error"]?.objectValue {
            let code = errorObj["code"]?.intValue ?? -32000
            let message = errorObj["message"]?.stringValue ?? "Unknown MCP error"
            let dataObj = errorObj["data"]?.objectValue

            // Handle stateless / -32042 elicitation or confirmation retry if allowed
            if allowStatelessRetry,
               (code == -32042 || dataObj?["elicitations"] != nil || dataObj?["elicitation"] != nil) {
                let elicitationParams: [String: JSONValue]
                if let list = dataObj?["elicitations"]?.arrayValue, let first = list.first?.objectValue {
                    elicitationParams = first
                } else if let single = dataObj?["elicitation"]?.objectValue {
                    elicitationParams = single
                } else {
                    elicitationParams = ["message": .string(message)]
                }

                let req = buildElicitationRequest(
                    serverRequestID: nil,
                    params: elicitationParams,
                    connection: connection,
                    toolName: toolName,
                    arguments: arguments
                )
                let response = await onElicitation(req)
                guard response.action == .accept else {
                    return MCPToolCallPayload(
                        outputText: "User \(response.action.rawValue)ed MCP prompt for '\(toolName)': \(req.message)",
                        isError: true,
                        elicitationAction: response.action
                    )
                }

                var metaPayload: [String: JSONValue] = [
                    "elicitationAction": .string(response.action.rawValue)
                ]
                if let elicitationID = req.elicitationID {
                    metaPayload["elicitationId"] = .string(elicitationID)
                }
                if let content = response.content {
                    metaPayload["elicitationContent"] = .object(content)
                }
                var retried = try await invokeToolCall(
                    connection: connection,
                    toolName: toolName,
                    arguments: arguments,
                    meta: metaPayload,
                    accessToken: accessToken,
                    sessionID: sessionID,
                    allowStatelessRetry: false,
                    onElicitation: onElicitation
                )
                retried.elicitationAction = .accept
                return retried
            }

            throw MCPClientError.jsonRPCError(code: code, message: message, data: errorObj["data"])
        }

        let result = envelope["result"]?.objectValue ?? [:]
        let isError = result["isError"]?.boolValue ?? false
        let contentArray = result["content"]?.arrayValue ?? []

        var textParts: [String] = []
        var attachments: [ChatAttachment] = []

        for item in contentArray {
            guard let block = item.objectValue else { continue }
            let blockType = block["type"]?.stringValue ?? "text"
            switch blockType {
            case "text":
                if let text = block["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                }
            case "image":
                if let b64 = block["data"]?.stringValue, !b64.isEmpty {
                    let mime = block["mimeType"]?.stringValue ?? "image/png"
                    let ext = mime.contains("jpeg") ? "jpg" : "png"
                    attachments.append(ChatAttachment(
                        mimeType: mime,
                        filename: "\(toolName).\(ext)",
                        base64Data: b64,
                        caption: "\(connection.name) · \(toolName)"
                    ))
                }
            case "resource":
                if let resource = block["resource"]?.objectValue,
                   let text = resource["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                }
            default:
                textParts.append(JSONValue.encodeObjectString(block))
            }
        }

        if textParts.isEmpty, let structured = result["structuredContent"]?.objectValue {
            textParts.append(JSONValue.encodeObjectString(structured))
        }

        let outputText = textParts.isEmpty
            ? (attachments.isEmpty ? "{}" : "Returned \(attachments.count) attachment(s).")
            : textParts.joined(separator: "\n")

        return MCPToolCallPayload(
            outputText: outputText,
            isError: isError,
            attachments: attachments
        )
    }

    // MARK: - Low-Level JSON-RPC HTTP Helpers

    private func postJSONRPC(
        connection: MCPServerConnection,
        requestID: JSONValue,
        method: String,
        params: [String: JSONValue],
        accessToken: String?,
        sessionID: String?
    ) async throws -> ([String: JSONValue], String?) {
        let request = try buildPostRequest(
            connection: connection,
            bodyObject: [
                "jsonrpc": .string("2.0"),
                "id": requestID,
                "method": .string(method),
                "params": .object(params)
            ],
            accessToken: accessToken,
            sessionID: sessionID
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.decodingError("Expected HTTPURLResponse from MCP server.")
        }

        if http.statusCode == 401 {
            let authHeader = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
            throw MCPClientError.unauthorized(
                resourceMetadataURL: MCPOAuthClient.parseWWWAuthenticateResourceMetadata(authHeader)
            )
        }

        guard (200...299).contains(http.statusCode) else {
            throw MCPClientError.httpError(
                statusCode: http.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        let returnedSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

        if contentType.contains("text/event-stream") {
            var parser = SSEStreamParser(stopOnDoneSentinel: true)
            var events = parser.feed(data)
            events.append(contentsOf: parser.finish())
            for event in events where !event.isDoneSentinel {
                let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty,
                   let envelope = try? decodeJSONObject(Data(trimmed.utf8)),
                   envelope["result"] != nil || envelope["error"] != nil {
                    return (envelope, returnedSessionID)
                }
            }
            throw MCPClientError.decodingError("No JSON-RPC payload in SSE response for '\(method)'.")
        }

        return (try decodeJSONObject(data), returnedSessionID)
    }

    private func sendInitializedNotification(
        connection: MCPServerConnection,
        accessToken: String?,
        sessionID: String?,
        protocolVersion: String
    ) async throws {
        var request = try buildPostRequest(
            connection: connection,
            bodyObject: [
                "jsonrpc": .string("2.0"),
                "method": .string("notifications/initialized")
            ],
            accessToken: accessToken,
            sessionID: sessionID
        )
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        _ = try await urlSession.data(for: request)
    }

    private func postJSONRPCResponse(
        connection: MCPServerConnection,
        responseID: JSONValue,
        result: JSONValue,
        accessToken: String?,
        sessionID: String?
    ) async throws {
        let request = try buildPostRequest(
            connection: connection,
            bodyObject: [
                "jsonrpc": .string("2.0"),
                "id": responseID,
                "result": result
            ],
            accessToken: accessToken,
            sessionID: sessionID
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MCPClientError.httpError(statusCode: status, body: String(decoding: data, as: UTF8.self))
        }
    }

    private func buildPostRequest(
        connection: MCPServerConnection,
        bodyObject: [String: JSONValue],
        accessToken: String?,
        sessionID: String?
    ) throws -> URLRequest {
        guard let url = URL(string: connection.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              url.host != nil else {
            throw MCPClientError.invalidEndpoint(connection.endpointURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(
            connection.protocolVersion ?? Self.defaultProtocolVersion,
            forHTTPHeaderField: "MCP-Protocol-Version"
        )

        if let sessionID, !sessionID.isEmpty, !connection.statelessMode {
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(bodyObject)
        return request
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: JSONValue] {
        do {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let object = decoded.objectValue else {
                throw MCPClientError.decodingError("Expected JSON object from MCP server.")
            }
            return object
        } catch let mcpError as MCPClientError {
            throw mcpError
        } catch {
            throw MCPClientError.decodingError(error.localizedDescription)
        }
    }

    private func jsonRPCError(from object: [String: JSONValue]) -> MCPClientError {
        let code = object["code"]?.intValue ?? -32000
        let message = object["message"]?.stringValue ?? "MCP server error"
        return .jsonRPCError(code: code, message: message, data: object["data"])
    }

    private func buildElicitationRequest(
        serverRequestID: JSONValue?,
        params: [String: JSONValue],
        connection: MCPServerConnection,
        toolName: String,
        arguments: [String: JSONValue]
    ) -> MCPElicitationRequest {
        let rawMode = params["mode"]?.stringValue?.lowercased()
        let urlString = params["url"]?.stringValue
        let mode: MCPElicitationMode
        if rawMode == "url" || (rawMode == nil && urlString != nil) {
            mode = .url
        } else {
            mode = .form
        }

        let message = params["message"]?.stringValue
            ?? "Server '\(connection.name)' requested confirmation before completing '\(toolName)'."
        let schema = params["requestedSchema"]?.objectValue
        let elicitationID = params["elicitationId"]?.stringValue
        let preview = arguments.isEmpty ? nil : JSONValue.encodeObjectString(arguments)
        let toolMeta = connection.discoveredTools.first(where: { $0.name == toolName })

        return MCPElicitationRequest(
            serverRequestID: serverRequestID,
            connectionID: connection.id,
            serverName: connection.name,
            toolName: toolName,
            mode: mode,
            message: message,
            requestedSchema: schema,
            url: urlString.flatMap(URL.init(string:)),
            elicitationID: elicitationID,
            argumentsPreview: preview,
            isReadOperation: toolMeta?.readOnlyHint ?? connection.readOnly
        )
    }
}
