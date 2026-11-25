package org.brokbot.android

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import org.brokbot.android.core.auth.BrokAuthManager
import org.brokbot.android.core.bots.BotPersonaStore
import org.brokbot.android.core.browser.BrokBrowserEngine
import org.brokbot.android.core.compute.BrokComputeEngine
import org.brokbot.android.core.context.PermanentMemoryManager
import org.brokbot.android.core.context.TurnRole
import org.brokbot.android.core.context.WorkingContextStore
import org.brokbot.android.core.notifications.AttentionDecision
import org.brokbot.android.core.notifications.AttentionKind
import org.brokbot.android.core.notifications.AttentionResolution
import org.brokbot.android.core.notifications.BotAttentionCoordinator
import org.brokbot.android.core.notifications.PendingAttentionRecord
import org.brokbot.android.core.providers.BYOKProviderConfig
import org.brokbot.android.notifications.BotNotificationHelper
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Application entry point that initializes local notification channels and core state holders.
 */
class BrokApplication : Application() {

    val workingContextStore: WorkingContextStore by lazy { WorkingContextStore() }
    val permanentMemoryManager: PermanentMemoryManager by lazy { PermanentMemoryManager() }
    val computeEngine: BrokComputeEngine get() = BrokComputeEngine.shared
    val authManager: BrokAuthManager by lazy { BrokAuthManager(applicationContext) }
    val browserEngine: BrokBrowserEngine by lazy { BrokBrowserEngine() }
    val botPersonaStore: BotPersonaStore by lazy { BotPersonaStore(applicationContext) }
    val attentionCoordinator: BotAttentionCoordinator by lazy { BotAttentionCoordinator() }
    val byokConfigFlow: MutableStateFlow<BYOKProviderConfig> by lazy {
        MutableStateFlow(BYOKProviderConfig())
    }

    override fun onCreate() {
        super.onCreate()
        registerNotificationChannels()
    }

    fun triggerAttentionRequest(
        kind: AttentionKind,
        actionSummary: String,
        toolName: String? = null,
        isPrivate: Boolean = false,
        requiresVaultOrSignIn: Boolean = false
    ): PendingAttentionRecord {
        val bot = botPersonaStore.selectedPersona()
        val record = PendingAttentionRecord(
            botId = bot.id,
            botName = bot.name,
            kind = kind,
            actionSummary = actionSummary,
            actionFingerprint = PendingAttentionRecord.computeFingerprint(
                connectionId = "android-local",
                toolName = toolName,
                argsJson = actionSummary
            ),
            connectionId = "android-local",
            toolName = toolName,
            isPrivate = isPrivate,
            requiresVaultOrSignIn = requiresVaultOrSignIn
        )
        attentionCoordinator.register(record)
        attentionCoordinator.buildNotificationSpec(
            requestId = record.requestId,
            botNotificationsEnabled = bot.notificationsEnabled
        )?.let { spec ->
            BotNotificationHelper.post(applicationContext, spec)
        }
        return record
    }

    fun resolveAttentionRequest(requestId: String, decision: AttentionDecision): AttentionResolution {
        val resolution = attentionCoordinator.resolve(
            requestId = requestId,
            decision = decision,
            vaultUnlocked = true,
            connectorAccessValid = true
        )
        BotNotificationHelper.cancel(applicationContext, requestId)
        when (resolution) {
            is AttentionResolution.Resolved -> {
                val verb = when (resolution.decision) {
                    AttentionDecision.ALLOW_ONCE -> "Allowed once"
                    AttentionDecision.DENY -> "Denied"
                    AttentionDecision.CANCEL -> "Cancelled"
                }
                workingContextStore.append(
                    role = TurnRole.SYSTEM,
                    content = "$verb (${resolution.record.botName}): ${resolution.record.actionSummary}"
                )
            }
            is AttentionResolution.Expired -> {
                workingContextStore.append(
                    role = TurnRole.SYSTEM,
                    content = "Expired request could not run: ${resolution.record.actionSummary}"
                )
            }
            is AttentionResolution.AccessCheckFailed -> {
                workingContextStore.append(
                    role = TurnRole.SYSTEM,
                    content = resolution.reason
                )
            }
            else -> Unit
        }
        return resolution
    }

    private fun registerNotificationChannels() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val routinesChannel = NotificationChannel(
            CHANNEL_BROK_ROUTINES,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_DEFAULT
        ).apply {
            description = getString(R.string.notification_channel_desc)
            enableLights(true)
        }
        val attentionChannel = NotificationChannel(
            CHANNEL_BROK_ATTENTION,
            "Bot Attention & Approvals",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Interactive approval gates and task alerts from your Brok Bots"
            lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            enableLights(true)
        }
        manager.createNotificationChannels(listOf(routinesChannel, attentionChannel))
    }

    companion object {
        const val CHANNEL_BROK_ROUTINES = "brok_routines"
        const val CHANNEL_BROK_ATTENTION = "brok_attention"
    }
}
