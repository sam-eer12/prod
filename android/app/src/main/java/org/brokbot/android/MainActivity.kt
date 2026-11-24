package org.brokbot.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import org.brokbot.android.background.BrokRoutineWorker
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

        setContent {
            BrokTheme {
                BrokHomeScreen(
                    workingContextStore = app.workingContextStore,
                    permanentMemoryManager = app.permanentMemoryManager,
                    computeEngine = app.computeEngine,
                    byokConfigFlow = app.byokConfigFlow
                )
            }
        }
    }
}
