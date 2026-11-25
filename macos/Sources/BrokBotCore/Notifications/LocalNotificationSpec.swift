import Foundation

/// Notification category identifiers registered with macOS `UNUserNotificationCenter`.
public enum BrokNotificationCategory: String, Codable, Sendable, CaseIterable, Equatable {
    case routineBriefing = "BROK_ROUTINE_BRIEFING"
    case needsAttention = "BROK_NEEDS_ATTENTION"
    case approvalRequest = "BROK_APPROVAL_REQUEST"
    case reviewInApp = "BROK_REVIEW_IN_APP"

    /// Interactive actions associated with this notification category.
    public var actions: [BrokNotificationAction] {
        switch self {
        case .routineBriefing, .needsAttention:
            return []
        case .approvalRequest:
            return [.approve, .deny]
        case .reviewInApp:
            return [.reviewInApp]
        }
    }
}

/// Interactive notification action identifiers for approval and review requests.
public enum BrokNotificationAction: String, Codable, Sendable, CaseIterable, Equatable {
    case approve = "BROK_ACTION_APPROVE"
    case deny = "BROK_ACTION_DENY"
    case reviewInApp = "BROK_ACTION_REVIEW_IN_APP"

    /// Default localized action button label.
    public var title: String {
        switch self {
        case .approve: return "Allow once"
        case .deny: return "Deny"
        case .reviewInApp: return "Review in Brok Bot"
        }
    }

    /// Indicates whether the action carries destructive visual emphasis.
    public var isDestructive: Bool {
        self == .deny
    }

    /// Indicates whether tapping the action should bring Brok Bot to the foreground.
    public var opensAppInForeground: Bool {
        self == .reviewInApp
    }
}

/// Platform-independent specification for scheduling a local notification via `UNUserNotificationCenter`.
public struct LocalNotificationPayload: Sendable, Codable, Equatable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var body: String
    public var category: BrokNotificationCategory
    public var userInfo: [String: String]
    public var delaySeconds: TimeInterval
    public var isPrivate: Bool
    public var lockScreenPlaceholder: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case body
        case category
        case userInfo
        case delaySeconds
        case isPrivate
        case lockScreenPlaceholder
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        body: String,
        category: BrokNotificationCategory,
        userInfo: [String: String] = [:],
        delaySeconds: TimeInterval = 1,
        isPrivate: Bool = false,
        lockScreenPlaceholder: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.userInfo = userInfo
        self.delaySeconds = delaySeconds
        self.isPrivate = isPrivate
        self.lockScreenPlaceholder = lockScreenPlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.body = try container.decode(String.self, forKey: .body)
        self.category = try container.decode(BrokNotificationCategory.self, forKey: .category)
        self.userInfo = try container.decodeIfPresent([String: String].self, forKey: .userInfo) ?? [:]
        self.delaySeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .delaySeconds) ?? 1
        self.isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? false
        self.lockScreenPlaceholder = try container.decodeIfPresent(String.self, forKey: .lockScreenPlaceholder)
    }
}
