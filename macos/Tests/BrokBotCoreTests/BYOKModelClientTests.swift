import Foundation
import XCTest
@testable import BrokBotCore

private final class MockURLProtocolRegistry: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, [Data])

    static let shared = MockURLProtocolRegistry()

    private let lock = NSLock()
    private var handlersByHost: [String: Handler] = [:]

    func register(host: String, handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        handlersByHost[host] = handler
    }

    func unregister(host: String) {
        lock.lock()
        defer { lock.unlock() }
        handlersByHost.removeValue(forKey: host)
    }

    func handler(for host: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlersByHost[host]
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let host = request.url?.host,
              let handler = MockURLProtocolRegistry.shared.handler(for: host) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.cannotFindHost)
            )
            return
        }

        let bodyData = Self.readBody(from: request)

        do {
            let (response, chunks) = try handler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let httpBody = request.httpBody {
            return httpBody
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }
        return data
    }
}

final class BYOKModelClientTests: XCTestCase {
    private func makeMockedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeUniqueMockHost() -> (host: String, baseURL: URL) {
        let host = "mock-\(UUID().uuidString.lowercased()).local"
        let url = URL(string: "https://\(host)/v1")!
        return (host, url)
    }

    private func decodeJSONObject(_ data: Data?) throws -> [String: Any] {
        let unwrapped = try XCTUnwrap(data)
        let obj = try JSONSerialization.jsonObject(with: unwrapped)
        return try XCTUnwrap(obj as? [String: Any])
    }

    private var sampleTools: [ToolDefinition] {
        [
            ToolDefinition(
                name: "get_weather",
                description: "Get current weather for a city.",
                jsonSchemaParameters: #"{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}"#
            )
        ]
    }

    // MARK: - Build URL Request Tests (All 5 Providers)

    func testBuildURLRequestOpenRouter() throws {
        let client = BYOKModelClient()
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .openRouter, modelID: "anthropic/claude-sonnet-4"),
            apiKey: "sk-or-v1-test",
            systemPrompt: "Be concise.",
            messages: [
                BYOKChatMessage(role: "user", content: "Weather in NYC?"),
                BYOKChatMessage(
                    role: "assistant",
                    content: "",
                    toolCalls: [ToolCallRecord(id: "call_1", name: "get_weather", argumentsJSON: #"{"city":"NYC"}"#)]
                ),
                BYOKChatMessage(role: "tool", content: #"{"temp":72}"#, toolCallID: "call_1")
            ],
            tools: sampleTools,
            temperature: 0.2,
            maxTokens: 1024
        )

        let urlRequest = try client.buildURLRequest(for: request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-v1-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "HTTP-Referer"), "https://github.com/brok-bot")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "X-Title"), "Brok Bot")

        let json = try decodeJSONObject(urlRequest.httpBody)
        XCTAssertEqual(json["model"] as? String, "anthropic/claude-sonnet-4")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)
        XCTAssertEqual(json["temperature"] as? Double, 0.2)

        let streamOptions = try XCTUnwrap(json["stream_options"] as? [String: Any])
        XCTAssertEqual(streamOptions["include_usage"] as? Bool, true)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be concise.")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertNotNil(messages[2]["tool_calls"])
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call_1")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
    }

    func testBuildURLRequestOpenAIAndNvidiaNIM() throws {
        let client = BYOKModelClient()

        let openAIReq = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .openAI, modelID: "gpt-4.1"),
            apiKey: "sk-openai-test",
            messages: [BYOKChatMessage(role: "user", content: "Hello")],
            tools: sampleTools
        )
        let openAIURLReq = try client.buildURLRequest(for: openAIReq)
        XCTAssertEqual(openAIURLReq.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(openAIURLReq.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai-test")
        XCTAssertNil(openAIURLReq.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(openAIURLReq.value(forHTTPHeaderField: "X-Title"))

        let nimReq = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .nvidiaNIM, modelID: "meta/llama-3.3-70b-instruct"),
            apiKey: "nvapi-test",
            messages: [BYOKChatMessage(role: "user", content: "Hello")],
            tools: sampleTools
        )
        let nimURLReq = try client.buildURLRequest(for: nimReq)
        XCTAssertEqual(nimURLReq.url?.absoluteString, "https://integrate.api.nvidia.com/v1/chat/completions")
        XCTAssertEqual(nimURLReq.value(forHTTPHeaderField: "Authorization"), "Bearer nvapi-test")
        XCTAssertNil(nimURLReq.value(forHTTPHeaderField: "HTTP-Referer"))
    }

    func testBuildURLRequestClaude() throws {
        let client = BYOKModelClient()
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .claude, modelID: "claude-sonnet-4-20250514"),
            apiKey: "sk-ant-test",
            systemPrompt: "System instruction",
            messages: [
                BYOKChatMessage(role: "user", content: "Check Tokyo weather"),
                BYOKChatMessage(
                    role: "assistant",
                    content: "Checking...",
                    toolCalls: [ToolCallRecord(id: "toolu_1", name: "get_weather", argumentsJSON: #"{"city":"Tokyo"}"#)]
                ),
                BYOKChatMessage(role: "tool", content: #"{"temp":20}"#, toolCallID: "toolu_1")
            ],
            tools: sampleTools,
            maxTokens: 2048
        )

        let urlRequest = try client.buildURLRequest(for: request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let json = try decodeJSONObject(urlRequest.httpBody)
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-20250514")
        XCTAssertEqual(json["system"] as? String, "System instruction")
        XCTAssertEqual(json["max_tokens"] as? Int, 2048)
        XCTAssertEqual(json["stream"] as? Bool, true)

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "get_weather")
        XCTAssertNotNil(tools[0]["input_schema"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        let assistantContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 2)
        XCTAssertEqual(assistantContent[1]["type"] as? String, "tool_use")
        let toolResultMsg = messages[2]
        XCTAssertEqual(toolResultMsg["role"] as? String, "user")
        let toolResultBlocks = try XCTUnwrap(toolResultMsg["content"] as? [[String: Any]])
        XCTAssertEqual(toolResultBlocks[0]["type"] as? String, "tool_result")
        XCTAssertEqual(toolResultBlocks[0]["tool_use_id"] as? String, "toolu_1")
    }

    func testBuildURLRequestGemini() throws {
        let client = BYOKModelClient()
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .gemini, modelID: "gemini-2.5-pro"),
            apiKey: "AIza-test",
            systemPrompt: "Gemini system prompt",
            messages: [
                BYOKChatMessage(role: "user", content: "Weather in Paris?"),
                BYOKChatMessage(
                    role: "assistant",
                    content: "",
                    toolCalls: [ToolCallRecord(id: "call_paris", name: "get_weather", argumentsJSON: #"{"city":"Paris"}"#)]
                ),
                BYOKChatMessage(role: "tool", content: #"{"temp":18}"#, toolCallID: "call_paris")
            ],
            tools: sampleTools,
            temperature: 0.5,
            maxTokens: 1500
        )

        let urlRequest = try client.buildURLRequest(for: request)
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-goog-api-key"), "AIza-test")

        let json = try decodeJSONObject(urlRequest.httpBody)
        let systemInstruction = try XCTUnwrap(json["systemInstruction"] as? [String: Any])
        let sysParts = try XCTUnwrap(systemInstruction["parts"] as? [[String: Any]])
        XCTAssertEqual(sysParts[0]["text"] as? String, "Gemini system prompt")

        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 3)
        XCTAssertEqual(contents[1]["role"] as? String, "model")
        let toolResponseParts = try XCTUnwrap(contents[2]["parts"] as? [[String: Any]])
        let funcResponse = try XCTUnwrap(toolResponseParts[0]["functionResponse"] as? [String: Any])
        XCTAssertEqual(funcResponse["name"] as? String, "get_weather")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools[0]["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations[0]["name"] as? String, "get_weather")
        XCTAssertNotNil(declarations[0]["parameters"])
    }

    func testMissingAPIKeyThrowsAcrossProviders() async {
        let client = BYOKModelClient()
        for provider in BYOKProviderKind.allCases {
            let request = BYOKChatRequest(
                configuration: BYOKConfiguration(provider: provider),
                apiKey: "   \n ",
                messages: [BYOKChatMessage(role: "user", content: "Hi")]
            )
            XCTAssertThrowsError(try client.buildURLRequest(for: request)) { error in
                XCTAssertEqual(error as? BYOKClientError, .missingAPIKey(provider))
            }

            do {
                for try await _ in client.streamChat(request) {
                    XCTFail("Expected missingAPIKey error for \(provider)")
                }
                XCTFail("Expected streamChat to throw for \(provider)")
            } catch let error as BYOKClientError {
                XCTAssertEqual(error, .missingAPIKey(provider))
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
        }
    }

    func testInvalidToolSchemaThrowsDecodingError() throws {
        let client = BYOKModelClient()
        let badTool = ToolDefinition(
            name: "broken",
            description: "Bad JSON",
            jsonSchemaParameters: "{not-valid-json"
        )
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .openAI),
            apiKey: "sk-test",
            messages: [BYOKChatMessage(role: "user", content: "Hi")],
            tools: [badTool]
        )

        XCTAssertThrowsError(try client.buildURLRequest(for: request)) { error in
            guard case .decodingError = error as? BYOKClientError else {
                XCTFail("Expected decodingError, got \(error)")
                return
            }
        }
    }

    // MARK: - SSEStreamParser Tests

    func testSSEStreamParserArbitraryChunkBoundariesCRLFCommentsAndMultiLineData() {
        var parser = SSEStreamParser()

        let rawStream =
            ": keep-alive comment\r\n" +
            "event: message_delta\r\n" +
            "data: {\"line\":1,\r\n" +
            "data: \"emoji\":\"🚀\"}\r\n" +
            "\r\n" +
            ": another comment\n" +
            "data: second\n" +
            "data: payload\n" +
            "\n" +
            "data: [DONE]\n" +
            "\n" +
            "data: ignored_after_done\n\n"

        // Feed 1 byte at a time so both \r\n and 4-byte UTF-8 emojis split across chunk boundaries.
        var collected: [SSEEvent] = []
        for byte in Data(rawStream.utf8) {
            collected.append(contentsOf: parser.feed(Data([byte])))
        }
        collected.append(contentsOf: parser.finish())

        XCTAssertTrue(parser.receivedDoneSentinel)
        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(
            collected[0],
            SSEEvent(event: "message_delta", data: "{\"line\":1,\n\"emoji\":\"🚀\"}")
        )
        XCTAssertEqual(
            collected[1],
            SSEEvent(event: nil, data: "second\npayload")
        )
    }

    func testSSEStreamParserSplitCRLFBetweenEventsAndTrailingSlashBaseURL() throws {
        var parser = SSEStreamParser()
        // Chunk 1 ends mid-CRLF right after \r; chunk 2 begins with \n\n (completing CRLF + blank line).
        let e1 = parser.feed("data: first\r")
        XCTAssertTrue(e1.isEmpty)
        let e2 = parser.feed("\n\r\ndata: second\r\n\r\n")
        XCTAssertEqual(e2, [
            SSEEvent(event: nil, data: "first"),
            SSEEvent(event: nil, data: "second")
        ])

        let client = BYOKModelClient()
        let req = BYOKChatRequest(
            configuration: BYOKConfiguration(
                provider: .openAI,
                customBaseURL: URL(string: "https://proxy.example.com/custom/v1/")!
            ),
            apiKey: "sk-custom",
            messages: [BYOKChatMessage(role: "user", content: "Hi")]
        )
        let urlReq = try client.buildURLRequest(for: req)
        XCTAssertEqual(urlReq.url?.absoluteString, "https://proxy.example.com/custom/v1/chat/completions")
    }

    func testSSEStreamParserFlushWithoutTrailingBlankLineAndDoneObservation() {
        var parser = SSEStreamParser(stopOnDoneSentinel: false)
        let events1 = parser.feed("data: [DONE]\n\nevent: custom\ndata: trailing")
        let flushed = parser.finish()

        XCTAssertTrue(parser.receivedDoneSentinel)
        XCTAssertEqual(events1.count, 1)
        XCTAssertTrue(events1[0].isDoneSentinel)
        XCTAssertEqual(flushed, [SSEEvent(event: "custom", data: "trailing")])
    }

    func testSSEStreamParserBOMSplitAcrossChunks() {
        var parser = SSEStreamParser()
        var bomAndPayload = Data([0xEF, 0xBB, 0xBF])
        bomAndPayload.append(Data("data: clean\n\n".utf8))

        var events: [SSEEvent] = []
        events.append(contentsOf: parser.feed(bomAndPayload.prefix(2)))
        events.append(contentsOf: parser.feed(bomAndPayload.dropFirst(2)))
        events.append(contentsOf: parser.finish())

        XCTAssertEqual(events, [SSEEvent(event: nil, data: "clean")])
    }

    // MARK: - Pure SSE Event Parsing Tests

    func testPureParseSSEEventOpenAIParallelToolCalls() throws {
        var acc = PartialToolCallAccumulator()

        let c1 = try BYOKModelClient.parseSSEEvent(
            SSEEvent(data: #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"fn_a","arguments":"{\"x\":"}},{"index":1,"id":"call_b","function":{"name":"fn_b","arguments":"{\"y\":"}}]}}]}"#),
            provider: .openAI,
            accumulator: &acc
        )
        XCTAssertTrue(c1.isEmpty)

        let c2 = try BYOKModelClient.parseSSEEvent(
            SSEEvent(data: #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"1}"}},{"index":1,"function":{"arguments":"2}"}}]},"finish_reason":"tool_calls"}]}"#),
            provider: .openAI,
            accumulator: &acc
        )
        XCTAssertEqual(c2, [
            .toolCall(ToolCallRecord(id: "call_a", name: "fn_a", argumentsJSON: #"{"x":1}"#)),
            .toolCall(ToolCallRecord(id: "call_b", name: "fn_b", argumentsJSON: #"{"y":2}"#)),
            .finished(stopReason: "tool_calls")
        ])
    }

    // MARK: - End-to-End Streaming Tests (MockURLProtocol)

    func testStreamChatOpenAICompatibleTextToolCallAndUsage() async throws {
        let (host, baseURL) = makeUniqueMockHost()
        defer { MockURLProtocolRegistry.shared.unregister(host: host) }

        let ssePayload = [
            #"data: {"choices":[{"index":0,"delta":{"content":"Let me check "},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"content":"that."},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Boston\"}"}}]},"finish_reason":null}]}"#,
            "",
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "",
            #"data: {"choices":[],"usage":{"prompt_tokens":14,"completion_tokens":9,"total_tokens":23}}"#,
            "",
            #"data: [DONE]"#,
            "",
            ""
        ].joined(separator: "\n")

        // Slice into irregular chunk sizes to stress URLSession.bytes + SSEStreamParser.
        let bytes = Data(ssePayload.utf8)
        let chunks = [
            Data(bytes.prefix(37)),
            Data(bytes.dropFirst(37).prefix(91)),
            Data(bytes.dropFirst(128))
        ]

        MockURLProtocolRegistry.shared.register(host: host) { request, _ in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, chunks)
        }

        let client = BYOKModelClient(urlSession: makeMockedSession())
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .openRouter, customBaseURL: baseURL),
            apiKey: "sk-or-mock",
            messages: [BYOKChatMessage(role: "user", content: "Boston weather?")],
            tools: sampleTools
        )

        var events: [BYOKStreamEvent] = []
        for try await event in client.streamChat(request) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .textDelta("Let me check "),
            .textDelta("that."),
            .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", argumentsJSON: #"{"city":"Boston"}"#)),
            .usage(TokenUsage(promptTokens: 14, completionTokens: 9, totalTokens: 23)),
            .finished(stopReason: "tool_calls")
        ])
    }

    func testStreamChatClaudeTextToolUseAndUsage() async throws {
        let (host, baseURL) = makeUniqueMockHost()
        defer { MockURLProtocolRegistry.shared.unregister(host: host) }

        let ssePayload = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":30,"output_tokens":1}}}"#,
            "",
            "event: ping",
            #"data: {"type":"ping"}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Checking "}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"weather"}}"#,
            "",
            "event: content_block_stop",
            #"data: {"type":"content_block_stop","index":0}"#,
            "",
            "event: content_block_start",
            #"data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_99","name":"get_weather","input":{}}}"#,
            "",
            "event: content_block_delta",
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"SF\"}"}}"#,
            "",
            "event: content_block_stop",
            #"data: {"type":"content_block_stop","index":1}"#,
            "",
            "event: message_delta",
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":18}}"#,
            "",
            "event: message_stop",
            #"data: {"type":"message_stop"}"#,
            "",
            ""
        ].joined(separator: "\r\n")

        MockURLProtocolRegistry.shared.register(host: host) { request, _ in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, [Data(ssePayload.utf8)])
        }

        let client = BYOKModelClient(urlSession: makeMockedSession())
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .claude, customBaseURL: baseURL),
            apiKey: "sk-ant-mock",
            messages: [BYOKChatMessage(role: "user", content: "SF weather?")],
            tools: sampleTools
        )

        var events: [BYOKStreamEvent] = []
        for try await event in client.streamChat(request) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .textDelta("Checking "),
            .textDelta("weather"),
            .toolCall(ToolCallRecord(id: "toolu_99", name: "get_weather", argumentsJSON: #"{"city":"SF"}"#)),
            .usage(TokenUsage(promptTokens: 30, completionTokens: 18, totalTokens: 48)),
            .finished(stopReason: "tool_use")
        ])
    }

    func testStreamChatGeminiTextFunctionCallAndUsage() async throws {
        let (host, baseURL) = makeUniqueMockHost()
        defer { MockURLProtocolRegistry.shared.unregister(host: host) }

        let ssePayload = [
            #"data: {"candidates":[{"content":{"parts":[{"text":"Sunny "}],"role":"model"}}]}"#,
            "",
            #"data: {"candidates":[{"content":{"parts":[{"functionCall":{"name":"get_weather","args":{"city":"Seattle"}}}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":12,"candidatesTokenCount":7,"totalTokenCount":19}}"#,
            "",
            ""
        ].joined(separator: "\n")

        MockURLProtocolRegistry.shared.register(host: host) { request, _ in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, [Data(ssePayload.utf8)])
        }

        let client = BYOKModelClient(urlSession: makeMockedSession())
        let request = BYOKChatRequest(
            configuration: BYOKConfiguration(provider: .gemini, customBaseURL: baseURL),
            apiKey: "AIza-mock",
            messages: [BYOKChatMessage(role: "user", content: "Seattle weather?")],
            tools: sampleTools
        )

        var events: [BYOKStreamEvent] = []
        for try await event in client.streamChat(request) {
            events.append(event)
        }

        XCTAssertEqual(events, [
            .textDelta("Sunny "),
            .toolCall(ToolCallRecord(id: "call_1", name: "get_weather", argumentsJSON: #"{"city":"Seattle"}"#)),
            .usage(TokenUsage(promptTokens: 12, completionTokens: 7, totalTokens: 19)),
            .finished(stopReason: "STOP")
        ])
    }

    func testHTTPErrorMappingFor401And429() async throws {
        for statusCode in [401, 429] {
            let (host, baseURL) = makeUniqueMockHost()
            defer { MockURLProtocolRegistry.shared.unregister(host: host) }

            let errorJSON = #"{"error":{"message":"Status \#(statusCode) failure"}}"#
            MockURLProtocolRegistry.shared.register(host: host) { request, _ in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, [Data(errorJSON.utf8)])
            }

            let client = BYOKModelClient(urlSession: makeMockedSession())
            let request = BYOKChatRequest(
                configuration: BYOKConfiguration(provider: .nvidiaNIM, customBaseURL: baseURL),
                apiKey: "nvapi-mock",
                messages: [BYOKChatMessage(role: "user", content: "Ping")]
            )

            do {
                for try await _ in client.streamChat(request) {
                    XCTFail("Expected HTTP \(statusCode) error")
                }
                XCTFail("Expected streamChat to throw HTTP \(statusCode)")
            } catch let error as BYOKClientError {
                XCTAssertEqual(error, .httpError(statusCode: statusCode, body: errorJSON))
            }
        }
    }

    // MARK: - BYOKProvider & LocalNotificationSpec Tests

    func testBYOKProviderAdditiveMetadata() {
        for provider in BYOKProviderKind.allCases {
            XCTAssertFalse(provider.apiKeyPlaceholder.isEmpty)
            XCTAssertTrue(provider.keyHintURL.hasPrefix("https://"))
            XCTAssertFalse(provider.displayName.isEmpty)
            XCTAssertFalse(provider.defaultModelID.isEmpty)
        }
        XCTAssertEqual(BYOKProviderKind.openRouter.apiKeyPlaceholder, "sk-or-v1-...")
        XCTAssertEqual(BYOKProviderKind.claude.apiKeyPlaceholder, "sk-ant-...")
    }

    func testLocalNotificationSpecCodableAndCategories() throws {
        XCTAssertEqual(BrokNotificationCategory.routineBriefing.rawValue, "BROK_ROUTINE_BRIEFING")
        XCTAssertEqual(BrokNotificationCategory.approvalRequest.rawValue, "BROK_APPROVAL_REQUEST")
        XCTAssertEqual(BrokNotificationCategory.approvalRequest.actions, [.approve, .deny])
        XCTAssertEqual(BrokNotificationAction.approve.rawValue, "BROK_ACTION_APPROVE")
        XCTAssertEqual(BrokNotificationAction.deny.rawValue, "BROK_ACTION_DENY")

        let payload = LocalNotificationPayload(
            id: "notif-42",
            title: "Approve Tool Execution",
            subtitle: "Blender 3D Bridge",
            body: "Run blender_execute_script?",
            category: .approvalRequest,
            userInfo: ["request_id": "req_123"],
            delaySeconds: 2.5
        )
        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LocalNotificationPayload.self, from: encoded)
        XCTAssertEqual(decoded, payload)
    }
}
