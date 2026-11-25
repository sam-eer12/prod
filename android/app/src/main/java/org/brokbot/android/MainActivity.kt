package org.brokbot.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import org.brokbot.android.background.BrokRoutineWorker
import org.brokbot.android.notifications.BotNotificationHelper
import org.brokbot.android.ui.BrokHomeScreen
import org.brokbot.android.ui.theme.BrokTheme

/**
 * Main entry point hosting the Liquid Glass Chief of Staff workspace.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val app = application as BrokApplication
        BrokRoutineWorker.schedulePeriodic(applicationContext)
        handleAttentionIntent(intent, app)

        setContent {
            BrokTheme {
                BrokHomeScreen(
                    workingContextStore = app.workingContextStore,
                    permanentMemoryManager = app.permanentMemoryManager,
                    computeEngine = app.computeEngine,
                    byokConfigFlow = app.byokConfigFlow,
                    authManager = app.authManager,
                    browserEngine = app.browserEngine,
                    botPersonaStore = app.botPersonaStore,
                    attentionCoordinator = app.attentionCoordinator,
                    onResolveAttention = { reqId, decision ->
                        app.resolveAttentionRequest(reqId, decision)
                    },
                    onTriggerAttentionSample = { requiresApproval ->
                        app.triggerAttentionRequest(
                            kind = if (requiresApproval) {
                                org.brokbot.android.core.notifications.AttentionKind.YES_NO_APPROVAL
                            } else {
                                org.brokbot.android.core.notifications.AttentionKind.TASK_READY
                            },
                            actionSummary = if (requiresApproval) {
                                "Allow ${app.botPersonaStore.selectedPersona().name} to run a sample workspace check?"
                            } else {
                                "${app.botPersonaStore.selectedPersona().name} task is ready for review."
                            },
                            toolName = if (requiresApproval) "sample_action" else null
                        )
                    }
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val app = application as BrokApplication
        handleAttentionIntent(intent, app)
    }

    private fun handleAttentionIntent(intent: Intent?, app: BrokApplication) {
        val requestId = intent?.getStringExtra(BotNotificationHelper.EXTRA_REQUEST_ID) ?: return
        val record = app.attentionCoordinator.recordFor(requestId) ?: return
        app.botPersonaStore.selectBot(record.botId)
    }
}
