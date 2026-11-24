import Foundation

/// Accumulates partial streaming tool calls and stream-level accounting across SSE chunks.
public struct PartialToolCallAccumulator: Sendable, Equatable {
    public struct PendingToolCall: Sendable, Equatable {
        public var id: String
        public var name: String
        public var arguments: String
        public var fallbackArgumentsJSON: String?

        public init(
            id: String,
            name: String,
            arguments: String = "",
            fallbackArgumentsJSON: String? = nil
        ) {
            self.id = id
            self.name = name
            self.arguments = arguments
            self.fallbackArgumentsJSON = fallbackArgumentsJSON
        }
    }

    public private(set) var pendingByIndex: [Int: PendingToolCall] = [:]
    public var recordedPromptTokens: Int?
    public var lastStopReason: String?
    private var generatedCallCounter = 0

    public init() {}

    /// Merges an OpenAI-compatible `delta.tool_calls` entry at `index`.
    public mutating func appendOpenAIDelta(
        index: Int,
        id: String?,
        name: String?,
        argumentsChunk: String?
    ) {
        var entry = pendingByIndex[index] ?? PendingToolCall(id: "", name: "", arguments: "")
        if let id, !id.isEmpty {
            entry.id = id
        }
        if let name, !name.isEmpty {
            entry.name = name
        }
        if let argumentsChunk {
            entry.arguments.append(argumentsChunk)
        }
        pendingByIndex[index] = entry
    }

    /// Registers a new tool call block (used by Anthropic `content_block_start`).
    public mutating func startToolCall(
        index: Int,
        id: String,
        name: String,
        fallbackArgumentsJSON: String? = nil
    ) {
        pendingByIndex[index] = PendingToolCall(
            id: id,
            name: name,
            arguments: "",
            fallbackArgumentsJSON: fallbackArgumentsJSON
        )
    }

    /// Appends incremental JSON argument fragments to an existing block at `index`.
    public mutating func appendArguments(index: Int, partialJSON: String) {
        var entry = pendingByIndex[index] ?? PendingToolCall(id: "", name: "", arguments: "")
        entry.arguments.append(partialJSON)
        pendingByIndex[index] = entry
    }

    /// Finalizes and removes the pending tool call at `index`, if one exists.
    public mutating func finalizeToolCall(at index: Int) -> ToolCallRecord? {
        guard let entry = pendingByIndex.removeValue(forKey: index) else {
            return nil
        }
        let resolvedID = entry.id.isEmpty ? "call_\(index)" : entry.id
        let resolvedArguments: String
        if !entry.arguments.isEmpty {
            resolvedArguments = entry.arguments
        } else if let fallback = entry.fallbackArgumentsJSON, !fallback.isEmpty {
            resolvedArguments = fallback
        } else {
            resolvedArguments = "{}"
        }
        return ToolCallRecord(
            id: resolvedID,
            name: entry.name,
            argumentsJSON: resolvedArguments
        )
    }

    /// Flushes all pending tool calls in ascending index order.
    public mutating func flushAll() -> [ToolCallRecord] {
        let sortedIndices = pendingByIndex.keys.sorted()
        var records: [ToolCallRecord] = []
        records.reserveCapacity(sortedIndices.count)
        for index in sortedIndices {
            if let record = finalizeToolCall(at: index) {
                records.append(record)
            }
        }
        return records
    }

    /// Generates a deterministic unique ID when a provider omits a tool call ID (e.g. Gemini).
    public mutating func nextGeneratedToolCallID() -> String {
        generatedCallCounter += 1
        return "call_\(generatedCallCounter)"
    }
}

/// Pure Swift 6 BYOK HTTP/SSE model client supporting OpenAI, OpenRouter, NVIDIA NIM,
/// Anthropic Claude, and Google Gemini.
public final class BYOKModelClient: Sendable {
    private static let anthropicVersion = "2023-06-01"
    private static let openRouterReferer = "https://github.com/brok-bot"
    private static let openRouterTitle = "Brok Bot"
    private static let maxErrorBodyBytes = 64 * 1024

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Builds a provider-specific streaming `URLRequest` from a `BYOKChatRequest`.
    public func buildURLRequest(for request: BYOKChatRequest) throws -> URLRequest {
        let apiKey = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw BYOKClientError.missingAPIKey(request.configuration.provider)
        }

        switch request.configuration.provider {
        case .openAI, .openRouter, .nvidiaNIM:
            return try buildOpenAICompatibleRequest(for: request, apiKey: apiKey)
        case .claude:
            return try buildClaudeRequest(for: request, apiKey: apiKey)
        case .gemini:
            return try buildGeminiRequest(for: request, apiKey: apiKey)
        }
    }

    /// Executes the streaming chat request and yields normalized `BYOKStreamEvent` values.
    public func streamChat(_ request: BYOKChatRequest) -> AsyncThrowingStream<BYOKStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try self.buildURLRequest(for: request)
                    let (asyncBytes, response) = try await self.urlSession.bytes(for: urlRequest)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw BYOKClientError.decodingError("Expected HTTPURLResponse from provider.")
                    }

                    guard (200...299).contains(httpResponse.statusCode) else {
                        var errorData = Data()
                        for try await byte in asyncBytes {
                            if errorData.count < Self.maxErrorBodyBytes {
                                errorData.append(byte)
                            } else {
                                break
                            }
                        }
                        let body = String(decoding: errorData, as: UTF8.self)
                        throw BYOKClientError.httpError(
                            statusCode: httpResponse.statusCode,
                            body: body
                        )
                    }

                    var parser = SSEStreamParser()
                    var accumulator = PartialToolCallAccumulator()
                    var pendingFinishReason: String?
                    var pendingChunk = Data()
                    pendingChunk.reserveCapacity(256)

                    for try await byte in asyncBytes {
                        try Task.checkCancellation()
                        pendingChunk.append(byte)

                        if byte == 0x0A || byte == 0x0D || pendingChunk.count >= 256 {
                            let sseEvents = parser.feed(pendingChunk)
                            pendingChunk.removeAll(keepingCapacity: true)
                            try Self.emitStreamEvents(
                                from: sseEvents,
                                provider: request.configuration.provider,
                                accumulator: &accumulator,
                                pendingFinishReason: &pendingFinishReason,
                                continuation: continuation
                            )
                            if parser.receivedDoneSentinel {
                                break
                            }
                        }
                    }

                    if !pendingChunk.isEmpty && !parser.receivedDoneSentinel {
                        let sseEvents = parser.feed(pendingChunk)
                        pendingChunk.removeAll(keepingCapacity: false)
                        try Self.emitStreamEvents(
                            from: sseEvents,
                            provider: request.configuration.provider,
                            accumulator: &accumulator,
                            pendingFinishReason: &pendingFinishReason,
                            continuation: continuation
                        )
                    }

                    let trailingSSEEvents = parser.finish()
                    try Self.emitStreamEvents(
                        from: trailingSSEEvents,
                        provider: request.configuration.provider,
                        accumulator: &accumulator,
                        pendingFinishReason: &pendingFinishReason,
                        continuation: continuation
                    )

                    for remainingToolCall in accumulator.flushAll() {
                        continuation.yield(.toolCall(remainingToolCall))
                    }

                    continuation.yield(.finished(stopReason: pendingFinishReason ?? accumulator.lastStopReason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// Parses a single SSE event payload for the given provider into normalized `BYOKStreamEvent`s.
    public static func parseSSEEvent(
        _ event: SSEEvent,
        provider: BYOKProviderKind,
        accumulator: inout PartialToolCallAccumulator
    ) throws -> [BYOKStreamEvent] {
        if event.isDoneSentinel {
            var events = accumulator.flushAll().map { BYOKStreamEvent.toolCall($0) }
            events.append(.finished(stopReason: accumulator.lastStopReason))
            return events
        }

        let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedData.isEmpty else {
            return []
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: Data(trimmedData.utf8)),
              let json = jsonObject as? [String: Any] else {
            throw BYOKClientError.decodingError("Invalid JSON in SSE payload: \(trimmedData)")
        }

        switch provider {
        case .openAI, .openRouter, .nvidiaNIM:
            return try parseOpenAISSEJSON(json, raw: trimmedData, accumulator: &accumulator)
        case .claude:
            return try parseClaudeSSEJSON(json, eventName: event.event, raw: trimmedData, accumulator: &accumulator)
        case .gemini:
            return try parseGeminiSSEJSON(json, raw: trimmedData, accumulator: &accumulator)
        }
    }

    private static func emitStreamEvents(
        from sseEvents: [SSEEvent],
        provider: BYOKProviderKind,
        accumulator: inout PartialToolCallAccumulator,
        pendingFinishReason: inout String?,
        continuation: AsyncThrowingStream<BYOKStreamEvent, Error>.Continuation
    ) throws {
        for sseEvent in sseEvents {
            let parsed = try parseSSEEvent(
                sseEvent,
                provider: provider,
                accumulator: &accumulator
            )
            for event in parsed {
                if case .finished(let stopReason) = event {
                    if let stopReason {
                        pendingFinishReason = stopReason
                    }
                } else {
                    continuation.yield(event)
                }
            }
        }
    }

    // MARK: - Request Builders

    private func buildOpenAICompatibleRequest(
        for request: BYOKChatRequest,
        apiKey: String
    ) throws -> URLRequest {
        let baseURL = request.configuration.effectiveBaseURL
        let endpointURL = baseURL.appendingPathComponent("chat/completions")

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        if request.configuration.provider == .openRouter {
            urlRequest.setValue(Self.openRouterReferer, forHTTPHeaderField: "HTTP-Referer")
            urlRequest.setValue(Self.openRouterTitle, forHTTPHeaderField: "X-Title")
        }

        var messagesArray: [[String: Any]] = []
        if let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            messagesArray.append([
                "role": BYOKChatRole.system.rawValue,
                "content": systemPrompt
            ])
        }

        for msg in request.messages {
            var entry: [String: Any] = [
                "role": msg.role,
                "content": msg.content
            ]
            if msg.role == BYOKChatRole.tool.rawValue, let toolCallID = msg.toolCallID {
                entry["tool_call_id"] = toolCallID
            }
            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                entry["tool_calls"] = toolCalls.map { tc -> [String: Any] in
                    [
                        "id": tc.id,
                        "type": "function",
                        "function": [
                            "name": tc.name,
                            "arguments": tc.argumentsJSON
                        ]
                    ]
                }
            }
            messagesArray.append(entry)
        }

        var body: [String: Any] = [
            "model": request.configuration.modelID,
            "messages": messagesArray,
            "stream": true,
            "stream_options": ["include_usage": true]
        ]

        if request.maxTokens > 0 {
            body["max_tokens"] = request.maxTokens
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool -> [String: Any] in
                let schema = try Self.parseToolSchemaObject(tool.jsonSchemaParameters, toolName: tool.name)
                return [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": schema
                    ]
                ]
            }
        }

        urlRequest.httpBody = try Self.encodeJSONBody(body)
        return urlRequest
    }

    private func buildClaudeRequest(
        for request: BYOKChatRequest,
        apiKey: String
    ) throws -> URLRequest {
        let baseURL = request.configuration.effectiveBaseURL
        let endpointURL = baseURL.appendingPathComponent("messages")

        var urlRequest = URLRequest(url: endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")

        var systemSegments: [String] = []
        if let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            systemSegments.append(systemPrompt)
        }

        var messagesArray: [[String: Any]] = []
        var pendingToolResults: [[String: Any]] = []

        func flushPendingToolResults() {
            guard !pendingToolResults.isEmpty else { return }
            messagesArray.append([
                "role": BYOKChatRole.user.rawValue,
                "content": pendingToolResults
            ])
            pendingToolResults.removeAll(keepingCapacity: true)
        }

        for msg in request.messages {
            if msg.role == BYOKChatRole.system.rawValue {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    systemSegments.append(trimmed)
                }
                continue
            }

            if msg.role == BYOKChatRole.tool.rawValue {
                pendingToolResults.append([
                    "type": "tool_result",
                    "tool_use_id": msg.toolCallID ?? "",
                    "content": msg.content
                ])
                continue
            }

            flushPendingToolResults()

            if msg.role == BYOKChatRole.assistant.rawValue, let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                var blocks: [[String: Any]] = []
                if !msg.content.isEmpty {
                    blocks.append([
                        "type": "text",
                        "text": msg.content
                    ])
                }
                for tc in toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": tc.id,
                        "name": tc.name,
                        "input": Self.parseJSONObjectOrEmpty(tc.argumentsJSON)
                    ])
                }
                messagesArray.append([
                    "role": BYOKChatRole.assistant.rawValue,
                    "content": blocks
                ])
            } else {
                messagesArray.append([
                    "role": msg.role,
                    "content": msg.content
                ])
            }
        }
        flushPendingToolResults()

        var body: [String: Any] = [
            "model": request.configuration.modelID,
            "max_tokens": max(1, request.maxTokens),
            "stream": true,
            "messages": messagesArray
        ]

        if !systemSegments.isEmpty {
            body["system"] = systemSegments.joined(separator: "\n\n")
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if !request.tools.isEmpty {
            body["tools"] = try request.tools.map { tool -> [String: Any] in
                let schema = try Self.parseToolSchemaObject(tool.jsonSchemaParameters, toolName: tool.name)
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": schema
                ]
            }
        }

        urlRequest.httpBody = try Self.encodeJSONBody(body)
        return urlRequest
    }

    private func buildGeminiRequest(
        for request: BYOKChatRequest,
        apiKey: String
    ) throws -> URLRequest {
        let modelID = request.configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModelID = modelID.hasPrefix("models/")
            ? String(modelID.dropFirst("models/".count))
            : modelID

        guard !normalizedModelID.isEmpty else {
            throw BYOKClientError.invalidURL("Gemini model ID cannot be empty.")
        }

        let baseURL = request.configuration.effectiveBaseURL
        let endpointPath = baseURL
            .appendingPathComponent("models")
            .appendingPathComponent("\(normalizedModelID):streamGenerateContent")

        guard var components = URLComponents(url: endpointPath, resolvingAgainstBaseURL: false) else {
            throw BYOKClientError.invalidURL(endpointPath.absoluteString)
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "alt" }) {
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
        }
        components.queryItems = queryItems

        guard let finalURL = components.url else {
            throw BYOKClientError.invalidURL(endpointPath.absoluteString)
        }

        var urlRequest = URLRequest(url: finalURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        var systemSegments: [String] = []
        if let systemPrompt = request.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !systemPrompt.isEmpty {
            systemSegments.append(systemPrompt)
        }

        var toolNameByCallID: [String: String] = [:]
        var contents: [[String: Any]] = []

        for msg in request.messages {
            if msg.role == BYOKChatRole.system.rawValue {
                let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    systemSegments.append(trimmed)
                }
                continue
            }

            if msg.role == BYOKChatRole.assistant.rawValue {
                var parts: [[String: Any]] = []
                if !msg.content.isEmpty {
                    parts.append(["text": msg.content])
                }
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        toolNameByCallID[tc.id] = tc.name
                        parts.append([
                            "functionCall": [
                                "name": tc.name,
                                "args": Self.parseJSONObjectOrEmpty(tc.argumentsJSON)
                            ]
                        ])
                    }
                }
                if parts.isEmpty {
                    parts.append(["text": ""])
                }
                contents.append([
                    "role": "model",
                    "parts": parts
                ])
            } else if msg.role == BYOKChatRole.tool.rawValue {
                let callID = msg.toolCallID ?? ""
                let resolvedName = toolNameByCallID[callID] ?? (callID.isEmpty ? "tool" : callID)
                let responsePayload: [String: Any]
                if let parsed = Self.parseJSONObjectIfValid(msg.content) {
                    responsePayload = parsed
                } else {
                    responsePayload = ["result": msg.content]
                }
                contents.append([
                    "role": "user",
                    "parts": [
                        [
                            "functionResponse": [
                                "name": resolvedName,
                                "response": responsePayload
                            ]
                        ]
                    ]
                ])
            } else {
                contents.append([
                    "role": "user",
                    "parts": [["text": msg.content]]
                ])
            }
        }

        var body: [String: Any] = [
            "contents": contents
        ]

        if !systemSegments.isEmpty {
            body["systemInstruction"] = [
                "parts": [
                    ["text": systemSegments.joined(separator: "\n\n")]
                ]
            ]
        }

        var generationConfig: [String: Any] = [:]
        if request.maxTokens > 0 {
            generationConfig["maxOutputTokens"] = request.maxTokens
        }
        if let temperature = request.temperature {
            generationConfig["temperature"] = temperature
        }
        if !generationConfig.isEmpty {
            body["generationConfig"] = generationConfig
        }

        if !request.tools.isEmpty {
            let declarations = try request.tools.map { tool -> [String: Any] in
                let schema = try Self.parseToolSchemaObject(tool.jsonSchemaParameters, toolName: tool.name)
                return [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": schema
                ]
            }
            body["tools"] = [
                ["functionDeclarations": declarations]
            ]
        }

        urlRequest.httpBody = try Self.encodeJSONBody(body)
        return urlRequest
    }

    // MARK: - SSE Event Parsers

    private static func parseOpenAISSEJSON(
        _ json: [String: Any],
        raw: String,
        accumulator: inout PartialToolCallAccumulator
    ) throws -> [BYOKStreamEvent] {
        if let errorObj = json["error"] as? [String: Any] {
            let code = (errorObj["code"] as? Int) ?? 500
            let message = (errorObj["message"] as? String) ?? raw
            throw BYOKClientError.httpError(statusCode: code, body: message)
        }

        var events: [BYOKStreamEvent] = []
        var finishReasonFromChoice: String?

        if let choices = json["choices"] as? [[String: Any]], let choice = choices.first {
            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String, !content.isEmpty {
                    events.append(.textDelta(content))
                }

                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for toolCall in toolCalls {
                        let index = (toolCall["index"] as? Int) ?? 0
                        let id = toolCall["id"] as? String
                        let function = toolCall["function"] as? [String: Any]
                        let name = function?["name"] as? String
                        let argumentsChunk = function?["arguments"] as? String
                        accumulator.appendOpenAIDelta(
                            index: index,
                            id: id,
                            name: name,
                            argumentsChunk: argumentsChunk
                        )
                    }
                }
            }

            if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                finishReasonFromChoice = finishReason
                accumulator.lastStopReason = finishReason
                for flushedToolCall in accumulator.flushAll() {
                    events.append(.toolCall(flushedToolCall))
                }
            }
        }

        if let usage = json["usage"] as? [String: Any],
           usage["prompt_tokens"] != nil || usage["completion_tokens"] != nil || usage["total_tokens"] != nil {
            let promptTokens = (usage["prompt_tokens"] as? Int) ?? 0
            let completionTokens = (usage["completion_tokens"] as? Int) ?? 0
            let totalTokens = (usage["total_tokens"] as? Int) ?? (promptTokens + completionTokens)
            events.append(.usage(TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens
            )))
        }

        if let finishReasonFromChoice {
            events.append(.finished(stopReason: finishReasonFromChoice))
        }

        return events
    }

    private static func parseClaudeSSEJSON(
        _ json: [String: Any],
        eventName: String?,
        raw: String,
        accumulator: inout PartialToolCallAccumulator
    ) throws -> [BYOKStreamEvent] {
        let type = (json["type"] as? String) ?? eventName ?? ""
        var events: [BYOKStreamEvent] = []

        switch type {
        case "ping":
            return []

        case "error":
            let errorDict = json["error"] as? [String: Any]
            let message = (errorDict?["message"] as? String) ?? raw
            throw BYOKClientError.decodingError("Anthropic stream error: \(message)")

        case "message_start":
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let inputTokens = usage["input_tokens"] as? Int {
                accumulator.recordedPromptTokens = inputTokens
            }

        case "content_block_start":
            let index = (json["index"] as? Int) ?? 0
            if let block = json["content_block"] as? [String: Any],
               let blockType = block["type"] as? String {
                switch blockType {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                case "tool_use":
                    let id = (block["id"] as? String) ?? accumulator.nextGeneratedToolCallID()
                    let name = (block["name"] as? String) ?? ""
                    let fallback = compactJSONString(from: block["input"])
                    accumulator.startToolCall(
                        index: index,
                        id: id,
                        name: name,
                        fallbackArgumentsJSON: fallback
                    )
                default:
                    break
                }
            }

        case "content_block_delta":
            let index = (json["index"] as? Int) ?? 0
            if let delta = json["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String {
                switch deltaType {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                case "input_json_delta":
                    if let partialJSON = delta["partial_json"] as? String {
                        accumulator.appendArguments(index: index, partialJSON: partialJSON)
                    }
                default:
                    break
                }
            }

        case "content_block_stop":
            let index = (json["index"] as? Int) ?? 0
            if let finalized = accumulator.finalizeToolCall(at: index) {
                events.append(.toolCall(finalized))
            }

        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let stopReason = delta["stop_reason"] as? String,
               !stopReason.isEmpty {
                accumulator.lastStopReason = stopReason
            }
            if let usage = json["usage"] as? [String: Any],
               usage["output_tokens"] != nil || usage["input_tokens"] != nil {
                let promptTokens = (usage["input_tokens"] as? Int) ?? accumulator.recordedPromptTokens ?? 0
                let completionTokens = (usage["output_tokens"] as? Int) ?? 0
                events.append(.usage(TokenUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    totalTokens: promptTokens + completionTokens
                )))
            }

        case "message_stop":
            for remaining in accumulator.flushAll() {
                events.append(.toolCall(remaining))
            }
            events.append(.finished(stopReason: accumulator.lastStopReason))

        default:
            break
        }

        return events
    }

    private static func parseGeminiSSEJSON(
        _ json: [String: Any],
        raw: String,
        accumulator: inout PartialToolCallAccumulator
    ) throws -> [BYOKStreamEvent] {
        if let errorObj = json["error"] as? [String: Any] {
            let code = (errorObj["code"] as? Int) ?? 500
            let message = (errorObj["message"] as? String) ?? raw
            throw BYOKClientError.httpError(statusCode: code, body: message)
        }

        var events: [BYOKStreamEvent] = []
        var finishReasonFromCandidate: String?

        if let candidates = json["candidates"] as? [[String: Any]], let candidate = candidates.first {
            if let content = candidate["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !text.isEmpty {
                        events.append(.textDelta(text))
                    }
                    if let functionCall = part["functionCall"] as? [String: Any],
                       let name = functionCall["name"] as? String {
                        let callID = (functionCall["id"] as? String) ?? accumulator.nextGeneratedToolCallID()
                        let argsJSON = compactJSONString(from: functionCall["args"]) ?? "{}"
                        events.append(.toolCall(ToolCallRecord(
                            id: callID,
                            name: name,
                            argumentsJSON: argsJSON
                        )))
                    }
                }
            }

            if let finishReason = candidate["finishReason"] as? String, !finishReason.isEmpty {
                finishReasonFromCandidate = finishReason
                accumulator.lastStopReason = finishReason
            }
        }

        if let usage = json["usageMetadata"] as? [String: Any],
           usage["promptTokenCount"] != nil || usage["candidatesTokenCount"] != nil || usage["totalTokenCount"] != nil {
            let promptTokens = (usage["promptTokenCount"] as? Int) ?? 0
            let completionTokens = (usage["candidatesTokenCount"] as? Int) ?? 0
            let totalTokens = (usage["totalTokenCount"] as? Int) ?? (promptTokens + completionTokens)
            events.append(.usage(TokenUsage(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: totalTokens
            )))
        }

        if let finishReasonFromCandidate {
            events.append(.finished(stopReason: finishReasonFromCandidate))
        }

        return events
    }

    // MARK: - JSON Helpers

    private static func encodeJSONBody(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        } catch {
            throw BYOKClientError.decodingError("Failed to serialize request JSON: \(error.localizedDescription)")
        }
    }

    private static func parseToolSchemaObject(
        _ rawSchema: String,
        toolName: String
    ) throws -> [String: Any] {
        let trimmed = rawSchema.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["type": "object", "properties": [String: Any]()]
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
            guard let dictionary = obj as? [String: Any] else {
                throw BYOKClientError.decodingError("Tool schema for '\(toolName)' must be a JSON object.")
            }
            return dictionary
        } catch let error as BYOKClientError {
            throw error
        } catch {
            throw BYOKClientError.decodingError(
                "Invalid JSON schema for tool '\(toolName)': \(error.localizedDescription)"
            )
        }
    }

    private static func parseJSONObjectIfValid(_ rawJSON: String) -> [String: Any]? {
        let trimmed = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func parseJSONObjectOrEmpty(_ rawJSON: String) -> [String: Any] {
        parseJSONObjectIfValid(rawJSON) ?? [:]
    }

    private static func compactJSONString(from object: Any?) -> String? {
        guard let object else { return nil }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }
}
