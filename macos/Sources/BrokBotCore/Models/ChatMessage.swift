import Foundation

/// Identifies the author role of a conversation turn in Working Context.
public enum MessageRole: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case system
}

/// Inline media attachment (e.g., PNG viewport render from Blender 3D Bridge).
public struct ChatAttachment: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var mimeType: String
    public var filename: String
    public var base64Data: String
    public var caption: String?

    public init(
        id: UUID = UUID(),
        mimeType: String,
        filename: String,
        base64Data: String,
        caption: String? = nil
    ) {
        self.id = id
        self.mimeType = mimeType
        self.filename = filename
        self.base64Data = base64Data
        self.caption = caption
    }

    /// Decodes `base64Data` into raw image/file bytes when valid.
    public var decodedData: Data? {
        Data(base64Encoded: base64Data, options: [.ignoreUnknownCharacters])
    }
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
    public var attachments: [ChatAttachment]

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case timestamp
        case memoryNotice
        case isStreaming
        case promptTokens
        case completionTokens
        case attachments
    }

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        memoryNotice: String? = nil,
        isStreaming: Bool = false,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.memoryNotice = memoryNotice
        self.isStreaming = isStreaming
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.attachments = attachments
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
        self.attachments = try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
    }
}
