package com.padlink.controller.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import com.padlink.controller.ui.navigation.AppDestination
import com.padlink.controller.ui.screens.home.HomeScreen
import com.padlink.controller.ui.screens.settings.SettingsScreen

@Composable
fun PadLinkApp() {
    var destinationName by rememberSaveable {
        mutableStateOf(AppDestination.HOME.name)
    }
    val destination = AppDestination.valueOf(destinationName)

    BackHandler(enabled = destination == AppDestination.SETTINGS) {
        destinationName = AppDestination.HOME.name
    }

    when (destination) {
        AppDestination.HOME -> HomeScreen(
            onOpenSettings = { destinationName = AppDestination.SETTINGS.name },
        )

        AppDestination.SETTINGS -> SettingsScreen(
            onBack = { destinationName = AppDestination.HOME.name },
        )
    }
}
