import Foundation
import XCTest
@testable import BrokBotCore

final class BotCustomizationAndAttentionTests: XCTestCase {
    func testBotPersonaAvatarAndLegacyFallbackDecoding() throws {
        let custom = BotPersona(
            id: "research-bot",
            name: "Research Analyst",
            role: "Deep Dive",
            systemPrompt: "Provide structured citations.",
            symbolName: "doc.text.magnifyingglass",
            accentHex: "#A78BFA",
            avatar: BotAvatarSpec(shape: .pebble, style: .face, face: .visor),
            notificationsEnabled: false,
            isDefault: false
        )
        let encoded = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(BotPersona.self, from: encoded)
        XCTAssertEqual(decoded, custom)
        XCTAssertEqual(decoded.avatar.shape, .pebble)
        XCTAssertEqual(decoded.avatar.face, .visor)
        XCTAssertFalse(decoded.notificationsEnabled)

        // Legacy persona JSON without `avatar` or `notificationsEnabled`
        let legacyJSON = """
        {
          "id": "legacy-1",
          "name": "Legacy Helper",
          "role": "Assistant",
          "systemPrompt": "Help carefully.",
          "symbolName": "terminal",
          "accentHex": "#34D399"
        }
        """
        let legacy = try JSONDecoder().decode(BotPersona.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.accentHex, "#34D399")
        XCTAssertEqual(legacy.symbolName, "terminal")
        XCTAssertEqual(legacy.avatar.shape, .circle)
        XCTAssertEqual(legacy.avatar.style, .icon)
        XCTAssertTrue(legacy.notificationsEnabled)
    }

    func testPendingAttentionLifecyclePrivacyAtMostOnceAndRelaunchExpiry() async throws {
        let coordinator = PendingAttentionCoordinator()
        let fingerprint = PendingAttentionRecord.computeFingerprint(
            connectionID: "gmail-mcp",
            toolName: "send_mail",
            argumentsJSON: #"{"to":"alex@example.com"}"#
        )

        // 1. Yes/No approval notification uses Allow once / Deny and opaque request_id only
        let approvalRecord = PendingAttentionRecord(
            botID: "inbox-triage",
            botName: "Inbox Triage",
            kind: .yesNoApproval,
            actionSummary: "Send reply to Alex?",
            actionFingerprint: fingerprint,
            connectionID: "gmail-mcp",
            toolName: "send_mail",
            isPrivate: false,
            requiresVaultOrSignIn: false
        )
        await coordinator.register(approvalRecord)

        let mutedPayload = await coordinator.buildNotificationPayload(for: approvalRecord.id, botNotificationsEnabled: false)
        XCTAssertNil(mutedPayload)

        let maybePayload = await coordinator.buildNotificationPayload(for: approvalRecord.id, botNotificationsEnabled: true)
        let payload = try XCTUnwrap(maybePayload)
        XCTAssertEqual(payload.category, .approvalRequest)
        XCTAssertEqual(payload.category.actions.map(\.title), ["Allow once", "Deny"])
        XCTAssertEqual(payload.userInfo, ["request_id": approvalRecord.id.uuidString])

        // Mismatched fingerprint must be rejected without consuming pending state
        let mismatch = await coordinator.resolve(
            requestID: approvalRecord.id,
            decision: .allowOnce,
            expectedFingerprint: "tampered"
        )
        XCTAssertEqual(mismatch, .fingerprintMismatch(record: approvalRecord))

        // First decision succeeds; second decision (e.g. duplicate tap from notification + chat card) is blocked
        let first = await coordinator.resolve(
            requestID: approvalRecord.id,
            decision: .allowOnce,
            expectedFingerprint: fingerprint
        )
        guard case .resolved(let decision, let resolvedRecord) = first else {
            return XCTFail("Expected .resolved, got \(first)")
        }
        XCTAssertEqual(decision, .allowOnce)
        XCTAssertEqual(resolvedRecord.state, .approvedOnce)

        let duplicate = await coordinator.resolve(requestID: approvalRecord.id, decision: .deny)
        XCTAssertEqual(duplicate, .alreadyResolved(state: .approvedOnce, record: resolvedRecord))

        // 2. Private + locked vault request downgrades to Review in Brok Bot with generic lock-screen summary
        let privateRecord = PendingAttentionRecord(
            botID: "chief-of-staff",
            botName: "Chief of Staff",
            kind: .yesNoApproval,
            actionSummary: "Secret prompt details that must stay off lock screen",
            actionFingerprint: "fp-private",
            isPrivate: true,
            requiresVaultOrSignIn: true
        )
        await coordinator.register(privateRecord)
        let maybePrivatePayload = await coordinator.buildNotificationPayload(for: privateRecord.id, botNotificationsEnabled: true)
        let privatePayload = try XCTUnwrap(maybePrivatePayload)
        XCTAssertEqual(privatePayload.category, .reviewInApp)
        XCTAssertEqual(privatePayload.category.actions, [.reviewInApp])
        XCTAssertFalse(privatePayload.body.contains("Secret prompt details"))
        XCTAssertEqual(privatePayload.userInfo, ["request_id": privateRecord.id.uuidString])

        let lockedAttempt = await coordinator.resolve(
            requestID: privateRecord.id,
            decision: .allowOnce,
            vaultUnlocked: false
        )
        if case .accessCheckFailed = lockedAttempt { } else {
            XCTFail("Expected accessCheckFailed when vault is locked")
        }

        // 3. Expiration check & relaunch persistence expiration
        let expiredRecord = PendingAttentionRecord(
            botID: "3d-artist",
            botName: "3D Artist",
            kind: .yesNoApproval,
            actionSummary: "Run bpy script",
            actionFingerprint: "fp-exp",
            expiresAt: Date().addingTimeInterval(-10)
        )
        await coordinator.register(expiredRecord)
        let expiredRes = await coordinator.resolve(requestID: expiredRecord.id, decision: .allowOnce)
        if case .expired(let r) = expiredRes {
            XCTAssertEqual(r.state, .expired)
        } else {
            XCTFail("Expected expired result")
        }

        let relaunched = PendingAttentionRecord(
            botID: "chief-of-staff",
            botName: "Chief of Staff",
            kind: .yesNoApproval,
            actionSummary: "Pending across restart",
            actionFingerprint: "fp-restart"
        )
        let freshCoordinator = PendingAttentionCoordinator()
        let newlyExpired = await freshCoordinator.expirePersistedOnRelaunch([relaunched])
        XCTAssertEqual(newlyExpired.count, 1)
        XCTAssertEqual(newlyExpired[0].state, .expired)
    }
}
