import Foundation

/// Notification category identifiers registered with macOS `UNUserNotificationCenter`.
public enum BrokNotificationCategory: String, Codable, Sendable, CaseIterable, Equatable {
    case routineBriefing = "BROK_ROUTINE_BRIEFING"
    case approvalRequest = "BROK_APPROVAL_REQUEST"

    /// Interactive actions associated with this notification category.
    public var actions: [BrokNotificationAction] {
        switch self {
        case .routineBriefing:
            return []
        case .approvalRequest:
            return [.approve, .deny]
        }
    }
}

/// Interactive notification action identifiers for approval requests.
public enum BrokNotificationAction: String, Codable, Sendable, CaseIterable, Equatable {
    case approve = "BROK_ACTION_APPROVE"
    case deny = "BROK_ACTION_DENY"

    /// Default localized action button label.
    public var title: String {
        switch self {
        case .approve: return "Approve"
        case .deny: return "Deny"
        }
    }

    /// Indicates whether the action carries destructive visual emphasis.
    public var isDestructive: Bool {
        self == .deny
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

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        body: String,
        category: BrokNotificationCategory,
        userInfo: [String: String] = [:],
        delaySeconds: TimeInterval = 1
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.category = category
        self.userInfo = userInfo
        self.delaySeconds = delaySeconds
    }
}
