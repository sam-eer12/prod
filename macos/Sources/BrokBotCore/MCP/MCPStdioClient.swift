import Foundation

/// Runs local stdio MCP server child processes (`Foundation.Process` + newline-delimited JSON-RPC 2.0)
/// scheduled on `BrokComputeEngine`.
public final class MCPStdioClient: Sendable {
    public init() {}

    /// Spawns a local stdio MCP server, runs `initialize` + `notifications/initialized` + `tools/list`,
    /// and terminates the child process cleanly.
    public func initializeAndListTools(
        command: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeoutSeconds: TimeInterval = 15
    ) async throws -> (MCPServerHandshake, [MCPDiscoveredTool]) {
        let initReq: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string("1"),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(MCPStreamableHTTPClient.defaultProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Brok Bot"),
                    "version": .string("0.2.0")
                ])
            ])
        ]
        let initializedNotif: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]
        let listReq: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string("2"),
            "method": .string("tools/list"),
            "params": .object([:])
        ]

        let responses = try await runSession(
            command: command,
            arguments: arguments,
            environment: environment,
            outboundMessages: [initReq, initializedNotif, listReq],
            expectedResponseIDs: ["1", "2"],
            timeoutSeconds: timeoutSeconds
        )

        guard let initEnvelope = responses["1"] else {
            throw MCPClientError.processError("Stdio server did not respond to 'initialize'.")
        }
        if let err = initEnvelope["error"]?.objectValue {
            throw MCPClientError.jsonRPCError(
                code: err["code"]?.intValue ?? -32000,
                message: err["message"]?.stringValue ?? "initialize failed",
                data: err["data"]
            )
        }

        let initResult = initEnvelope["result"]?.objectValue ?? [:]
        let serverInfo = initResult["serverInfo"]?.objectValue
        let handshake = MCPServerHandshake(
            protocolVersion: initResult["protocolVersion"]?.stringValue ?? MCPStreamableHTTPClient.defaultProtocolVersion,
            sessionID: nil,
            serverName: serverInfo?["name"]?.stringValue,
            serverVersion: serverInfo?["version"]?.stringValue,
            supportsElicitation: false
        )

        guard let listEnvelope = responses["2"] else {
            throw MCPClientError.processError("Stdio server did not respond to 'tools/list'.")
        }
        if let err = listEnvelope["error"]?.objectValue {
            throw MCPClientError.jsonRPCError(
                code: err["code"]?.intValue ?? -32000,
                message: err["message"]?.stringValue ?? "tools/list failed",
                data: err["data"]
            )
        }

        let rawTools = listEnvelope["result"]?.objectValue?["tools"]?.arrayValue ?? []
        let tools: [MCPDiscoveredTool] = rawTools.compactMap { item in
            guard let obj = item.objectValue,
                  let name = obj["name"]?.stringValue,
                  !name.isEmpty else {
                return nil
            }
            let annotations = obj["annotations"]?.objectValue
            return MCPDiscoveredTool(
                name: name,
                title: obj["title"]?.stringValue,
                description: obj["description"]?.stringValue ?? "",
                inputSchema: obj["inputSchema"]?.objectValue,
                readOnlyHint: annotations?["readOnlyHint"]?.boolValue,
                destructiveHint: annotations?["destructiveHint"]?.boolValue
            )
        }

        return (handshake, tools)
    }

    /// Invokes a tool on a local stdio MCP server (`initialize` -> `notifications/initialized` -> `tools/call`).
    public func callTool(
        command: String,
        arguments: [String],
        environment: [String: String] = [:],
        toolName: String,
        toolArguments: [String: JSONValue],
        connectionName: String = "Stdio MCP",
        timeoutSeconds: TimeInterval = 30
    ) async throws -> MCPToolCallPayload {
        let initReq: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string("1"),
            "method": .string("initialize"),
            "params": .object([
                "protocolVersion": .string(MCPStreamableHTTPClient.defaultProtocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("Brok Bot"),
                    "version": .string("0.2.0")
                ])
            ])
        ]
        let initializedNotif: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string("notifications/initialized")
        ]
        let callReq: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .string("2"),
            "method": .string("tools/call"),
            "params": .object([
                "name": .string(toolName),
                "arguments": .object(toolArguments)
            ])
        ]

        let responses = try await runSession(
            command: command,
            arguments: arguments,
            environment: environment,
            outboundMessages: [initReq, initializedNotif, callReq],
            expectedResponseIDs: ["1", "2"],
            timeoutSeconds: timeoutSeconds
        )

        guard let callEnvelope = responses["2"] else {
            throw MCPClientError.processError("Stdio server did not respond to 'tools/call'.")
        }
        if let err = callEnvelope["error"]?.objectValue {
            throw MCPClientError.jsonRPCError(
                code: err["code"]?.intValue ?? -32000,
                message: err["message"]?.stringValue ?? "tools/call failed",
                data: err["data"]
            )
        }

        let result = callEnvelope["result"]?.objectValue ?? [:]
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
                        caption: "\(connectionName) · \(toolName)"
                    ))
                }
            case "resource":
                if let text = block["resource"]?.objectValue?["text"]?.stringValue, !text.isEmpty {
                    textParts.append(text)
                }
            default:
                textParts.append(JSONValue.encodeObjectString(block))
            }
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

    // MARK: - Subprocess Execution

    private func runSession(
        command: String,
        arguments: [String],
        environment: [String: String],
        outboundMessages: [[String: JSONValue]],
        expectedResponseIDs: Set<String>,
        timeoutSeconds: TimeInterval
    ) async throws -> [String: [String: JSONValue]] {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw MCPClientError.processError("Stdio command cannot be empty.")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var inputBytes = Data()
        for message in outboundMessages {
            let line = try encoder.encode(message)
            inputBytes.append(line)
            inputBytes.append(0x0A)
        }

        let payloadData = inputBytes
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = StdioLockedFlag()
            let processBox = StdioProcessBox()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeoutSeconds) * 1_000_000_000))
                processBox.terminateIfRunning()
                if resumed.claim() {
                    continuation.resume(throwing: MCPClientError.processError("Stdio MCP process timed out after \(Int(timeoutSeconds))s."))
                }
            }

            BrokComputeEngine.shared.enqueue {
                let process = Process()
                if trimmedCommand.contains("/") {
                    process.executableURL = URL(fileURLWithPath: trimmedCommand)
                    process.arguments = arguments
                } else {
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [trimmedCommand] + arguments
                }

                var mergedEnv = ProcessInfo.processInfo.environment
                for (k, v) in environment {
                    mergedEnv[k] = v
                }
                process.environment = mergedEnv

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe
                processBox.set(process)

                do {
                    try process.run()
                    try stdinPipe.fileHandleForWriting.write(contentsOf: payloadData)
                    try stdinPipe.fileHandleForWriting.close()

                    var parsedByID: [String: [String: JSONValue]] = [:]
                    var stdoutBuffer = Data()
                    let readHandle = stdoutPipe.fileHandleForReading

                    while parsedByID.count < expectedResponseIDs.count {
                        let chunk = readHandle.availableData
                        if chunk.isEmpty {
                            break
                        }
                        stdoutBuffer.append(chunk)

                        while let newlineIdx = stdoutBuffer.firstIndex(of: 0x0A) {
                            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<newlineIdx]
                            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIdx)
                            guard !lineData.isEmpty,
                                  let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(lineData)),
                                  let obj = decoded.objectValue else {
                                continue
                            }
                            if let idStr = Self.idString(from: obj["id"]), expectedResponseIDs.contains(idStr) {
                                parsedByID[idStr] = obj
                            }
                        }
                    }

                    // Flush any trailing line without newline if still needed
                    if parsedByID.count < expectedResponseIDs.count && !stdoutBuffer.isEmpty {
                        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: stdoutBuffer),
                           let obj = decoded.objectValue,
                           let idStr = Self.idString(from: obj["id"]),
                           expectedResponseIDs.contains(idStr) {
                            parsedByID[idStr] = obj
                        }
                    }

                    let stderrData = stderrPipe.fileHandleForReading.availableData
                    processBox.terminateIfRunning()
                    timeoutTask.cancel()

                    if parsedByID.count < expectedResponseIDs.count {
                        let stderrText = String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        let detail = stderrText.isEmpty ? "Process exited before returning all JSON-RPC responses." : stderrText
                        if resumed.claim() {
                            continuation.resume(throwing: MCPClientError.processError(detail))
                        }
                        return
                    }

                    if resumed.claim() {
                        continuation.resume(returning: parsedByID)
                    }
                } catch {
                    timeoutTask.cancel()
                    processBox.terminateIfRunning()
                    if resumed.claim() {
                        continuation.resume(throwing: MCPClientError.processError(error.localizedDescription))
                    }
                }
            }
        }
    }

    private static func idString(from value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .number(let d): return String(Int(d))
        default: return nil
        }
    }
}

private final class StdioLockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

private final class StdioProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ proc: Process) {
        lock.lock()
        defer { lock.unlock() }
        self.process = proc
    }

    func terminateIfRunning() {
        lock.lock()
        let proc = self.process
        self.process = nil
        lock.unlock()
        if let proc, proc.isRunning {
            proc.terminate()
        }
    }
}
