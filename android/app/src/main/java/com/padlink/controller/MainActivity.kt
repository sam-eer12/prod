package com.padlink.controller

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.padlink.controller.ui.PadLinkApp
import com.padlink.controller.ui.theme.PadLinkTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // PadLink is dark-first to match the controller surface. Keep the system
        // bars transparent with light icons regardless of the device theme.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )

        setContent {
            PadLinkTheme {
                PadLinkApp()
            }
        }
    }
}
