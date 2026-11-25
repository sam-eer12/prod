package org.brokbot.android

import org.brokbot.android.core.bots.BotAvatarFace
import org.brokbot.android.core.bots.BotAvatarShape
import org.brokbot.android.core.bots.BotAvatarSpec
import org.brokbot.android.core.bots.BotAvatarStyle
import org.brokbot.android.core.bots.BotPersona
import org.brokbot.android.core.notifications.AttentionDecision
import org.brokbot.android.core.notifications.AttentionKind
import org.brokbot.android.core.notifications.AttentionResolution
import org.brokbot.android.core.notifications.AttentionState
import org.brokbot.android.core.notifications.BotAttentionCoordinator
import org.brokbot.android.core.notifications.NotificationActionMode
import org.brokbot.android.core.notifications.PendingAttentionRecord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BotCustomizationAndAttentionTest {

    @Test
    fun `bot persona round-trips avatar and falls back cleanly for legacy records`() {
        val custom = BotPersona(
            id = "custom-1",
            name = "Researcher",
            role = "Analyst",
            instructions = "Respond with verified sources.",
            accentHex = "#A78BFA",
            iconKey = "globe",
            avatar = BotAvatarSpec(
                shape = BotAvatarShape.CLOUD,
                style = BotAvatarStyle.FACE,
                face = BotAvatarFace.MONOCLE
            ),
            notificationsEnabled = false
        )
        val decodedList = BotPersona.decodeList(BotPersona.encodeList(listOf(custom)))
        assertEquals(1, decodedList.size)
        assertEquals(custom, decodedList[0])

        val legacyJsonArray = """
            [
              {
                "id": "legacy-bot",
                "name": "Legacy Bot",
                "role": "Helper",
                "instructions": "Be concise.",
                "accentHex": "#34D399",
                "iconKey": "cube"
              }
            ]
        """.trimIndent()
        val legacyList = BotPersona.decodeList(legacyJsonArray)
        assertEquals(1, legacyList.size)
        val legacy = legacyList[0]
        assertEquals("#34D399", legacy.accentHex)
        assertEquals("cube", legacy.iconKey)
        assertEquals(BotAvatarShape.CIRCLE, legacy.avatar.shape)
        assertEquals(BotAvatarStyle.ICON, legacy.avatar.style)
        assertTrue(legacy.notificationsEnabled)
    }

    @Test
    fun `attention coordinator enforces single resolution, privacy, expiry, and relaunch expiry`() {
        val coordinator = BotAttentionCoordinator()
        val fp = PendingAttentionRecord.computeFingerprint("conn-1", "send_email", "{}")
        val record = PendingAttentionRecord(
            botId = "inbox-triage",
            botName = "Inbox Triage",
            kind = AttentionKind.YES_NO_APPROVAL,
            actionSummary = "Send weekly digest?",
            actionFingerprint = fp
        )
        coordinator.register(record)

        assertNull(coordinator.buildNotificationSpec(record.requestId, botNotificationsEnabled = false))
        val spec = coordinator.buildNotificationSpec(record.requestId, botNotificationsEnabled = true)!!
        assertEquals(NotificationActionMode.ALLOW_ONCE_DENY, spec.actionMode)
        assertEquals(record.requestId, spec.requestId)

        val mismatch = coordinator.resolve(record.requestId, AttentionDecision.ALLOW_ONCE, expectedFingerprint = "bad")
        assertTrue(mismatch is AttentionResolution.FingerprintMismatch)

        val first = coordinator.resolve(record.requestId, AttentionDecision.ALLOW_ONCE, expectedFingerprint = fp)
        assertTrue(first is AttentionResolution.Resolved)
        assertEquals(AttentionState.APPROVED_ONCE, (first as AttentionResolution.Resolved).record.state)

        val second = coordinator.resolve(record.requestId, AttentionDecision.DENY)
        assertTrue(second is AttentionResolution.AlreadyResolved)

        val privateRecord = PendingAttentionRecord(
            botId = "chief-of-staff",
            botName = "Chief of Staff",
            kind = AttentionKind.YES_NO_APPROVAL,
            actionSummary = "Confidential API key rotation",
            actionFingerprint = "fp-priv",
            isPrivate = true,
            requiresVaultOrSignIn = true
        )
        coordinator.register(privateRecord)
        val privateSpec = coordinator.buildNotificationSpec(privateRecord.requestId, botNotificationsEnabled = true)!!
        assertEquals(NotificationActionMode.REVIEW_IN_APP, privateSpec.actionMode)
        assertFalse(privateSpec.body.contains("Confidential"))

        val relaunchCoordinator = BotAttentionCoordinator()
        val expired = relaunchCoordinator.expirePersistedOnRelaunch(listOf(
            PendingAttentionRecord(
                botId = "chief-of-staff",
                botName = "Chief of Staff",
                kind = AttentionKind.YES_NO_APPROVAL,
                actionSummary = "Interrupted action",
                actionFingerprint = "fp-int"
            )
        ))
        assertEquals(1, expired.size)
        assertEquals(AttentionState.EXPIRED, expired[0].state)
    }
}
