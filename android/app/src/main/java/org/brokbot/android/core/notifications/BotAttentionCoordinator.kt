package org.brokbot.android.core.notifications

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.MessageDigest
import java.util.UUID

enum class AttentionKind {
    TASK_READY,
    YES_NO_APPROVAL,
    REVIEW_IN_APP
}

enum class AttentionState {
    PENDING,
    APPROVED_ONCE,
    DENIED,
    CANCELLED,
    EXPIRED
}

enum class AttentionDecision {
    ALLOW_ONCE,
    DENY,
    CANCEL
}

enum class NotificationActionMode {
    TAP_ONLY,
    ALLOW_ONCE_DENY,
    REVIEW_IN_APP
}

data class PendingAttentionRecord(
    val requestId: String = UUID.randomUUID().toString(),
    val botId: String,
    val botName: String,
    val kind: AttentionKind,
    val actionSummary: String,
    val actionFingerprint: String,
    val connectionId: String? = null,
    val toolName: String? = null,
    val isPrivate: Boolean = false,
    val requiresVaultOrSignIn: Boolean = false,
    val requiresExtraInput: Boolean = false,
    val createdAtMillis: Long = System.currentTimeMillis(),
    val expiresAtMillis: Long = createdAtMillis + 300_000L,
    val state: AttentionState = AttentionState.PENDING
) {
    val effectiveActionMode: NotificationActionMode
        get() = when {
            requiresVaultOrSignIn || requiresExtraInput || isPrivate || kind == AttentionKind.REVIEW_IN_APP ->
                NotificationActionMode.REVIEW_IN_APP
            kind == AttentionKind.YES_NO_APPROVAL ->
                NotificationActionMode.ALLOW_ONCE_DENY
            else ->
                NotificationActionMode.TAP_ONLY
        }

    companion object {
        fun computeFingerprint(connectionId: String?, toolName: String?, argsJson: String?): String {
            val raw = listOf(connectionId.orEmpty(), toolName.orEmpty(), argsJson.orEmpty()).joinToString("|")
            val digest = MessageDigest.getInstance("SHA-256").digest(raw.toByteArray(Charsets.UTF_8))
            return digest.joinToString("") { "%02x".format(it) }
        }
    }
}

data class BotNotificationSpec(
    val requestId: String,
    val title: String,
    val body: String,
    val lockScreenSummary: String,
    val actionMode: NotificationActionMode,
    val isPrivate: Boolean
)

sealed interface AttentionResolution {
    data class Resolved(val decision: AttentionDecision, val record: PendingAttentionRecord) : AttentionResolution
    data class AlreadyResolved(val state: AttentionState, val record: PendingAttentionRecord) : AttentionResolution
    data class Expired(val record: PendingAttentionRecord) : AttentionResolution
    data class FingerprintMismatch(val record: PendingAttentionRecord) : AttentionResolution
    data class AccessCheckFailed(val reason: String, val record: PendingAttentionRecord) : AttentionResolution
    data object NotFound : AttentionResolution
}

class BotAttentionCoordinator {
    private val lock = Any()
    private val records = linkedMapOf<String, PendingAttentionRecord>()
    private val _pendingFlow = MutableStateFlow<List<PendingAttentionRecord>>(emptyList())
    val pendingFlow: StateFlow<List<PendingAttentionRecord>> = _pendingFlow.asStateFlow()

    fun register(record: PendingAttentionRecord): PendingAttentionRecord = synchronized(lock) {
        records[record.requestId] = record
        refreshPendingLocked()
        record
    }

    fun recordFor(requestId: String): PendingAttentionRecord? = synchronized(lock) { records[requestId] }

    fun pendingRecords(): List<PendingAttentionRecord> = synchronized(lock) {
        records.values.filter { it.state == AttentionState.PENDING }
    }

    fun buildNotificationSpec(
        requestId: String,
        botNotificationsEnabled: Boolean
    ): BotNotificationSpec? = synchronized(lock) {
        if (!botNotificationsEnabled) return@synchronized null
        val record = records[requestId] ?: return@synchronized null
        if (record.state != AttentionState.PENDING) return@synchronized null

        val safeBody = if (record.isPrivate) {
            "Action needs review in Brok Bot."
        } else {
            record.actionSummary
        }

        BotNotificationSpec(
            requestId = record.requestId,
            title = record.botName,
            body = safeBody,
            lockScreenSummary = "${record.botName} needs attention in Brok Bot.",
            actionMode = record.effectiveActionMode,
            isPrivate = record.isPrivate
        )
    }

    fun resolve(
        requestId: String,
        decision: AttentionDecision,
        expectedFingerprint: String? = null,
        vaultUnlocked: Boolean = true,
        connectorAccessValid: Boolean = true,
        nowMillis: Long = System.currentTimeMillis()
    ): AttentionResolution = synchronized(lock) {
        val current = records[requestId] ?: return@synchronized AttentionResolution.NotFound
        if (current.state != AttentionState.PENDING) {
            return@synchronized AttentionResolution.AlreadyResolved(current.state, current)
        }
        if (nowMillis > current.expiresAtMillis) {
            val expired = current.copy(state = AttentionState.EXPIRED)
            records[requestId] = expired
            refreshPendingLocked()
            return@synchronized AttentionResolution.Expired(expired)
        }
        if (decision == AttentionDecision.ALLOW_ONCE) {
            if (expectedFingerprint != null && expectedFingerprint != current.actionFingerprint) {
                return@synchronized AttentionResolution.FingerprintMismatch(current)
            }
            if (current.requiresVaultOrSignIn && !vaultUnlocked) {
                return@synchronized AttentionResolution.AccessCheckFailed(
                    "Vault or sign-in required before allowing this action.",
                    current
                )
            }
            if (!connectorAccessValid) {
                return@synchronized AttentionResolution.AccessCheckFailed(
                    "Connector access is missing or disabled.",
                    current
                )
            }
        }

        val nextState = when (decision) {
            AttentionDecision.ALLOW_ONCE -> AttentionState.APPROVED_ONCE
            AttentionDecision.DENY -> AttentionState.DENIED
            AttentionDecision.CANCEL -> AttentionState.CANCELLED
        }
        val updated = current.copy(state = nextState)
        records[requestId] = updated
        refreshPendingLocked()
        AttentionResolution.Resolved(decision, updated)
    }

    fun expirePersistedOnRelaunch(persisted: List<PendingAttentionRecord>): List<PendingAttentionRecord> = synchronized(lock) {
        val expiredNow = mutableListOf<PendingAttentionRecord>()
        persisted.forEach { item ->
            val next = if (item.state == AttentionState.PENDING) {
                item.copy(state = AttentionState.EXPIRED).also { expiredNow.add(it) }
            } else {
                item
            }
            records[next.requestId] = next
        }
        refreshPendingLocked()
        expiredNow
    }

    private fun refreshPendingLocked() {
        _pendingFlow.value = records.values.filter { it.state == AttentionState.PENDING }
    }
}
