package org.brokbot.android.notifications

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.brokbot.android.BrokApplication
import org.brokbot.android.core.notifications.AttentionDecision

class BrokNotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra(BotNotificationHelper.EXTRA_REQUEST_ID) ?: return
        val decision = when (intent.getStringExtra(BotNotificationHelper.EXTRA_ACTION)) {
            BotNotificationHelper.ACTION_ALLOW_ONCE -> AttentionDecision.ALLOW_ONCE
            BotNotificationHelper.ACTION_DENY -> AttentionDecision.DENY
            else -> return
        }
        val app = context.applicationContext as? BrokApplication
        app?.resolveAttentionRequest(requestId = requestId, decision = decision)
        BotNotificationHelper.cancel(context, requestId)
    }
}
