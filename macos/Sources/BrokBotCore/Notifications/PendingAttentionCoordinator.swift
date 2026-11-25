import CryptoKit
import Foundation

public enum PendingAttentionKind: String, Codable, Sendable, Equatable {
    case taskReady
    case yesNoApproval
    case reviewInApp
}

public enum PendingAttentionState: String, Codable, Sendable, Equatable {
    case pending
    case approvedOnce
    case denied
    case cancelled
    case expired
}

public enum PendingAttentionDecision: String, Codable, Sendable, Equatable {
    case allowOnce
    case deny
    case cancel
}

/// Shared record backing both the inline chat Approval Card and OS local attention notification.
public struct PendingAttentionRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let botID: String
    public let botName: String
    public let threadID: UUID?
    public let kind: PendingAttentionKind
    public let actionSummary: String
    public let actionFingerprint: String
    public let connectionID: String?
    public let toolName: String?
    public let isPrivate: Bool
    public let requiresVaultOrSignIn: Bool
    public let requiresExtraInput: Bool
    public let createdAt: Date
    public let expiresAt: Date
    public var state: PendingAttentionState

    public init(
        id: UUID = UUID(),
        botID: String,
        botName: String,
        threadID: UUID? = nil,
        kind: PendingAttentionKind,
        actionSummary: String,
        actionFingerprint: String,
        connectionID: String? = nil,
        toolName: String? = nil,
        isPrivate: Bool = false,
        requiresVaultOrSignIn: Bool = false,
        requiresExtraInput: Bool = false,
        createdAt: Date = Date(),
        expiresAt: Date = Date().addingTimeInterval(300),
        state: PendingAttentionState = .pending
    ) {
        self.id = id
        self.botID = botID
        self.botName = botName
        self.threadID = threadID
        self.kind = kind
        self.actionSummary = actionSummary
        self.actionFingerprint = actionFingerprint
        self.connectionID = connectionID
        self.toolName = toolName
        self.isPrivate = isPrivate
        self.requiresVaultOrSignIn = requiresVaultOrSignIn
        self.requiresExtraInput = requiresExtraInput
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = state
    }

    public var effectiveCategory: BrokNotificationCategory {
        if requiresVaultOrSignIn || requiresExtraInput || isPrivate || kind == .reviewInApp {
            return .reviewInApp
        }
        switch kind {
        case .yesNoApproval:
            return .approvalRequest
        case .taskReady:
            return .needsAttention
        case .reviewInApp:
            return .reviewInApp
        }
    }

    public static func computeFingerprint(
        connectionID: String?,
        toolName: String?,
        argumentsJSON: String?
    ) -> String {
        let material = [
            connectionID ?? "",
            toolName ?? "",
            argumentsJSON ?? ""
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public enum PendingAttentionResolution: Sendable, Equatable {
    case resolved(decision: PendingAttentionDecision, record: PendingAttentionRecord)
    case alreadyResolved(state: PendingAttentionState, record: PendingAttentionRecord)
    case expired(record: PendingAttentionRecord)
    case fingerprintMismatch(record: PendingAttentionRecord)
    case accessCheckFailed(reason: String, record: PendingAttentionRecord)
    case notFound
}

/// Enforces single-use, expiration-aware, privacy-safe resolution of bot attention and approval requests.
public actor PendingAttentionCoordinator {
    private var recordsByID: [UUID: PendingAttentionRecord] = [:]

    public init() {}

    @discardableResult
    public func register(_ record: PendingAttentionRecord) -> PendingAttentionRecord {
        recordsByID[record.id] = record
        return record
    }

    public func record(for id: UUID) -> PendingAttentionRecord? {
        recordsByID[id]
    }

    public func allRecords() -> [PendingAttentionRecord] {
        recordsByID.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingRecords() -> [PendingAttentionRecord] {
        recordsByID.values
            .filter { $0.state == .pending }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Builds a privacy-safe local notification payload carrying only the opaque `request_id`.
    public func buildNotificationPayload(
        for id: UUID,
        botNotificationsEnabled: Bool,
        delaySeconds: TimeInterval = 0.2
    ) -> LocalNotificationPayload? {
        guard botNotificationsEnabled,
              let record = recordsByID[id],
              record.state == .pending else {
            return nil
        }

        let category = record.effectiveCategory
        let safeBody: String
        let safeSubtitle: String?

        if record.isPrivate {
            safeSubtitle = nil
            safeBody = "Action needs review in Brok Bot."
        } else {
            safeSubtitle = record.toolName
            safeBody = record.actionSummary
        }

        return LocalNotificationPayload(
            id: record.id.uuidString,
            title: record.botName,
            subtitle: safeSubtitle,
            body: safeBody,
            category: category,
            userInfo: ["request_id": record.id.uuidString],
            delaySeconds: delaySeconds,
            isPrivate: record.isPrivate,
            lockScreenPlaceholder: "\(record.botName) needs attention in Brok Bot."
        )
    }

    /// Resolves a pending request at most once after validating expiration, action fingerprint, and connector/vault access.
    public func resolve(
        requestID: UUID,
        decision: PendingAttentionDecision,
        expectedFingerprint: String? = nil,
        vaultUnlocked: Bool = true,
        connectorAccessValid: Bool = true,
        now: Date = Date()
    ) -> PendingAttentionResolution {
        guard var record = recordsByID[requestID] else {
            return .notFound
        }

        guard record.state == .pending else {
            return .alreadyResolved(state: record.state, record: record)
        }

        if now > record.expiresAt {
            record.state = .expired
            recordsByID[requestID] = record
            return .expired(record: record)
        }

        if decision == .allowOnce {
            if let expectedFingerprint, expectedFingerprint != record.actionFingerprint {
                return .fingerprintMismatch(record: record)
            }
            if record.requiresVaultOrSignIn && !vaultUnlocked {
                return .accessCheckFailed(
                    reason: "Vault is locked. Unlock Brok Bot Vault to allow this action.",
                    record: record
                )
            }
            if !connectorAccessValid {
                return .accessCheckFailed(
                    reason: "Connector access is missing or disabled.",
                    record: record
                )
            }
        }

        switch decision {
        case .allowOnce:
            record.state = .approvedOnce
        case .deny:
            record.state = .denied
        case .cancel:
            record.state = .cancelled
        }

        recordsByID[requestID] = record
        return .resolved(decision: decision, record: record)
    }

    /// Marks any `.pending` requests persisted before an app restart as `.expired` since continuations cannot resume.
    @discardableResult
    public func expirePersistedOnRelaunch(_ persisted: [PendingAttentionRecord]) -> [PendingAttentionRecord] {
        var newlyExpired: [PendingAttentionRecord] = []
        for var item in persisted {
            if item.state == .pending {
                item.state = .expired
                newlyExpired.append(item)
            }
            recordsByID[item.id] = item
        }
        return newlyExpired
    }
}
