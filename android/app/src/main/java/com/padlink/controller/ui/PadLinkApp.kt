package com.padlink.controller.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.os.Build
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.padlink.controller.core.PairingViewModel
import com.padlink.controller.core.wifiPairingEndpoint
import com.padlink.controller.ui.navigation.AppDestination
import com.padlink.controller.ui.screens.home.HomeScreen
import com.padlink.controller.ui.screens.settings.SettingsScreen
import com.padlink.controller.ui.screens.controller.ControllerScreen
import com.padlink.controller.ui.screens.controller.ControllerOrientation

@Composable
fun PadLinkApp() {
    val pairing: PairingViewModel = viewModel()
    val state by pairing.state.collectAsState()
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    fun startListening() {
        val endpoint = wifiPairingEndpoint(context)
        if (endpoint == null) pairing.reportError("Connect your phone and desktop to the same Wi-Fi network.")
        else pairing.start(endpoint)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startListening() else pairing.reportError("Local network access is needed to connect to your desktop.")
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_STOP) pairing.stop() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    var destinationName by rememberSaveable {
        mutableStateOf(AppDestination.HOME.name)
    }
    val destination = AppDestination.valueOf(destinationName)
    var settingsReturn by rememberSaveable { mutableStateOf(AppDestination.HOME.name) }
    ControllerOrientation(destination == AppDestination.CONTROLLER ||
        destination == AppDestination.SETTINGS && settingsReturn == AppDestination.CONTROLLER.name)

    BackHandler(enabled = destination != AppDestination.HOME) {
        destinationName = if (destination == AppDestination.SETTINGS) settingsReturn else AppDestination.HOME.name
    }

    when (destination) {
        AppDestination.HOME -> HomeScreen(
            onOpenSettings = {
                settingsReturn = AppDestination.HOME.name
                destinationName = AppDestination.SETTINGS.name
            },
            onOpenController = {
                pairing.stop()
                destinationName = AppDestination.CONTROLLER.name
            },
            pairing = state,
            onStart = {
                val lanPermission = "android.permission.ACCESS_LOCAL_NETWORK"
                if (Build.VERSION.SDK_INT >= 37 && ContextCompat.checkSelfPermission(context, lanPermission) != PackageManager.PERMISSION_GRANTED) permission.launch(lanPermission)
                else startListening()
            },
            onStop = pairing::stop,
            onAllow = pairing::allow,
            onDeny = pairing::deny,
            onCancel = pairing::cancel,
        )

        AppDestination.SETTINGS -> SettingsScreen(
            onBack = { destinationName = settingsReturn },
        )

        AppDestination.CONTROLLER -> ControllerScreen(
            onSettings = {
                settingsReturn = AppDestination.CONTROLLER.name
                destinationName = AppDestination.SETTINGS.name
            },
            onClose = { destinationName = AppDestination.HOME.name },
        )
    }
}
