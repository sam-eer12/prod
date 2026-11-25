package org.brokbot.android.notifications

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import org.brokbot.android.BrokApplication
import org.brokbot.android.MainActivity
import org.brokbot.android.R
import org.brokbot.android.core.notifications.BotNotificationSpec
import org.brokbot.android.core.notifications.NotificationActionMode

object BotNotificationHelper {
    const val EXTRA_REQUEST_ID = "org.brokbot.android.extra.REQUEST_ID"
    const val EXTRA_ACTION = "org.brokbot.android.extra.ACTION"
    const val ACTION_ALLOW_ONCE = "ALLOW_ONCE"
    const val ACTION_DENY = "DENY"

    fun post(context: Context, spec: BotNotificationSpec): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) return false
        }

        val notifId = spec.requestId.hashCode()
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_REQUEST_ID, spec.requestId)
        }
        val openPendingIntent = PendingIntent.getActivity(
            context,
            notifId,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val publicVersion = NotificationCompat.Builder(context, BrokApplication.CHANNEL_BROK_ATTENTION)
            .setSmallIcon(R.drawable.ic_brok_notification)
            .setContentTitle("Brok Bot")
            .setContentText(spec.lockScreenSummary)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        val builder = NotificationCompat.Builder(context, BrokApplication.CHANNEL_BROK_ATTENTION)
            .setSmallIcon(R.drawable.ic_brok_notification)
            .setContentTitle(spec.title)
            .setContentText(spec.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(spec.body))
            .setContentIntent(openPendingIntent)
            .setAutoCancel(true)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(publicVersion)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        when (spec.actionMode) {
            NotificationActionMode.TAP_ONLY -> Unit
            NotificationActionMode.REVIEW_IN_APP -> {
                builder.addAction(
                    R.drawable.ic_brok_notification,
                    "Review in Brok Bot",
                    openPendingIntent
                )
            }
            NotificationActionMode.ALLOW_ONCE_DENY -> {
                val allowIntent = Intent(context, BrokNotificationActionReceiver::class.java).apply {
                    putExtra(EXTRA_REQUEST_ID, spec.requestId)
                    putExtra(EXTRA_ACTION, ACTION_ALLOW_ONCE)
                }
                val allowPending = PendingIntent.getBroadcast(
                    context,
                    notifId * 31 + 1,
                    allowIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val denyIntent = Intent(context, BrokNotificationActionReceiver::class.java).apply {
                    putExtra(EXTRA_REQUEST_ID, spec.requestId)
                    putExtra(EXTRA_ACTION, ACTION_DENY)
                }
                val denyPending = PendingIntent.getBroadcast(
                    context,
                    notifId * 31 + 2,
                    denyIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.addAction(R.drawable.ic_brok_notification, "Allow once", allowPending)
                builder.addAction(R.drawable.ic_brok_notification, "Deny", denyPending)
            }
        }

        return runCatching {
            NotificationManagerCompat.from(context).notify(notifId, builder.build())
            true
        }.getOrDefault(false)
    }

    fun cancel(context: Context, requestId: String) {
        NotificationManagerCompat.from(context).cancel(requestId.hashCode())
    }
}
