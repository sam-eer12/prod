package org.brokbot.android

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import org.brokbot.android.core.compute.BrokComputeEngine
import org.brokbot.android.core.context.PermanentMemoryManager
import org.brokbot.android.core.context.WorkingContextStore
import org.brokbot.android.core.providers.BYOKProviderConfig
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Application entry point that initializes local notification channels and core state holders.
 */
class BrokApplication : Application() {

    val workingContextStore: WorkingContextStore by lazy { WorkingContextStore() }
    val permanentMemoryManager: PermanentMemoryManager by lazy { PermanentMemoryManager() }
    val computeEngine: BrokComputeEngine get() = BrokComputeEngine.shared
    val byokConfigFlow: MutableStateFlow<BYOKProviderConfig> by lazy {
        MutableStateFlow(BYOKProviderConfig())
    }

    override fun onCreate() {
        super.onCreate()
        registerNotificationChannels()
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
        manager.createNotificationChannel(routinesChannel)
    }

    companion object {
        const val CHANNEL_BROK_ROUTINES = "brok_routines"
    }
}
