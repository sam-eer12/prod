package org.brokbot.android.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Silently schedules Brok Bot background routines when the device finishes booting,
 * without launching any foreground Activity.
 */
class BrokBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED) {
            BrokRoutineWorker.schedulePeriodic(context.applicationContext)
        }
    }
}
