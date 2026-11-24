package org.brokbot.android.background

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.withContext
import org.brokbot.android.BrokApplication
import org.brokbot.android.core.compute.BrokComputeEngine
import java.util.concurrent.TimeUnit

/**
 * Silent periodic background worker for local routine polling and Permanent Memory auto-compaction.
 */
class BrokRoutineWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : CoroutineWorker(appContext, workerParams) {

    override suspend fun doWork(): Result = withContext(BrokComputeEngine.shared.dispatcher()) {
        val app = applicationContext as? BrokApplication
        app?.permanentMemoryManager?.compact()
        Result.success()
    }

    companion object {
        const val UNIQUE_WORK_NAME = "brok_routines_periodic"

        fun schedulePeriodic(context: Context) {
            val constraints = Constraints.Builder()
                .setRequiresBatteryNotLow(true)
                .build()

            val request = PeriodicWorkRequestBuilder<BrokRoutineWorker>(
                15,
                TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .build()

            WorkManager.getInstance(context.applicationContext).enqueueUniquePeriodicWork(
                UNIQUE_WORK_NAME,
                ExistingPeriodicWorkPolicy.KEEP,
                request
            )
        }
    }
}
