import Foundation

/// Canonical chat message roles supported by the BYOK model client.
public enum BYOKChatRole: String, Codable, Sendable, Equatable, CaseIterable {
    case system
    case user
    case assistant
    case tool
}

/// Self-contained message model for BYOK LLM requests, decoupled from persistence models.
public struct BYOKChatMessage: Codable, Sendable, Equatable {
    /// Message role (`"system"`, `"user"`, `"assistant"`, or `"tool"`).
    public var role: String
    public var content: String
    public var toolCallID: String?
    public var toolCalls: [ToolCallRecord]?

    public init(
        role: String,
        content: String,
        toolCallID: String? = nil,
        toolCalls: [ToolCallRecord]? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.toolCalls = toolCalls
    }

    public init(
        role: BYOKChatRole,
        content: String,
        toolCallID: String? = nil,
        toolCalls: [ToolCallRecord]? = nil
    ) {
        self.init(
            role: role.rawValue,
            content: content,
            toolCallID: toolCallID,
            toolCalls: toolCalls
        )
    }
}

/// Token accounting metrics reported by a BYOK provider stream.
public struct TokenUsage: Codable, Sendable, Equatable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int

    public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
    }

    public init(promptTokens: Int, completionTokens: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = promptTokens + completionTokens
    }
}

/// Function/tool schema definition passed to BYOK providers.
public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    /// Raw JSON object string describing the JSON Schema for tool parameters.
    public var jsonSchemaParameters: String

    public init(
        name: String,
        description: String,
        jsonSchemaParameters: String = "{\"type\":\"object\",\"properties\":{}}"
    ) {
        self.name = name
        self.description = description
        self.jsonSchemaParameters = jsonSchemaParameters
    }

    public init(
        name: String,
        description: String,
        jsonSchemaData: Data
    ) throws {
        guard let jsonString = String(data: jsonSchemaData, encoding: .utf8) else {
            throw BYOKClientError.decodingError("Tool schema data for '\(name)' is not valid UTF-8.")
        }
        self.name = name
        self.description = description
        self.jsonSchemaParameters = jsonString
    }

    public init(
        name: String,
        description: String,
        jsonSchemaParameters: [String: String]
    ) {
        self.name = name
        self.description = description
        if jsonSchemaParameters.isEmpty {
            self.jsonSchemaParameters = "{\"type\":\"object\",\"properties\":{}}"
        } else if let data = try? JSONSerialization.data(
            withJSONObject: jsonSchemaParameters,
            options: [.sortedKeys]
        ), let jsonString = String(data: data, encoding: .utf8) {
            self.jsonSchemaParameters = jsonString
        } else {
            self.jsonSchemaParameters = "{\"type\":\"object\",\"properties\":{}}"
        }
    }
}

/// Accumulated function/tool call emitted by a model turn.
public struct ToolCallRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var argumentsJSON: String

    public init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

/// Complete request payload sent to a BYOK LLM provider.
public struct BYOKChatRequest: Codable, Sendable, Equatable {
    public var configuration: BYOKConfiguration
    public var apiKey: String
    public var systemPrompt: String?
    public var messages: [BYOKChatMessage]
    public var tools: [ToolDefinition]
    public var temperature: Double?
    public var maxTokens: Int

    public init(
        configuration: BYOKConfiguration,
        apiKey: String,
        systemPrompt: String? = nil,
        messages: [BYOKChatMessage],
        tools: [ToolDefinition] = [],
        temperature: Double? = nil,
        maxTokens: Int = 4096
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

/// Normalized streaming event emitted by `BYOKModelClient.streamChat(_:)`.
public enum BYOKStreamEvent: Sendable, Equatable {
    case textDelta(String)
    case toolCall(ToolCallRecord)
    case usage(TokenUsage)
    case finished(stopReason: String?)
}

/// Errors produced while building requests, executing HTTP calls, or decoding SSE streams.
public enum BYOKClientError: Error, LocalizedError, Sendable, Equatable {
    case missingAPIKey(BYOKProviderKind)
    case invalidURL(String)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider.displayName)."
        case .invalidURL(let urlString):
            return "Invalid provider endpoint URL: \(urlString)"
        case .httpError(let statusCode, let body):
            if body.isEmpty {
                return "Provider returned HTTP \(statusCode)."
            }
            return "Provider returned HTTP \(statusCode): \(body)"
        case .decodingError(let details):
            return "Failed to decode provider response: \(details)"
        }
    }
}
