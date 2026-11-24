import Foundation

/// Identifies the author role of a conversation turn in Working Context.
public enum MessageRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
}

/// Represents a single message turn stored in ephemeral Working Context.
public struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let role: MessageRole
    public var content: String
    public let timestamp: Date
    public let memoryNotice: String?
    public var isStreaming: Bool
    public var promptTokens: Int?
    public var completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
        case memoryNotice
        case isStreaming
        case promptTokens
        case completionTokens
    }

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        memoryNotice: String? = nil,
        isStreaming: Bool = false,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.memoryNotice = memoryNotice
        self.isStreaming = isStreaming
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.memoryNotice = try container.decodeIfPresent(String.self, forKey: .memoryNotice)
        self.isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        self.promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
        self.completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
    }
}
