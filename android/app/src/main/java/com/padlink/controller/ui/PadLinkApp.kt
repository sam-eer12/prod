package com.padlink.controller.ui

import androidx.activity.compose.BackHandler
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.os.Build
import android.bluetooth.BluetoothAdapter
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import com.padlink.controller.core.PairingViewModel
import com.padlink.controller.PadLinkApplication
import com.padlink.controller.core.BluetoothPhase
import com.padlink.controller.core.wifiPairingEndpoint
import com.padlink.controller.ui.navigation.AppDestination
import com.padlink.controller.ui.screens.home.HomeScreen
import com.padlink.controller.ui.screens.settings.SettingsScreen
import com.padlink.controller.ui.screens.controller.ControllerScreen
import com.padlink.controller.ui.screens.controller.ControllerOrientation
import com.padlink.controller.ui.screens.controller.LayoutEditorScreen
import com.padlink.controller.ui.screens.controller.ControllerState

@Composable
fun PadLinkApp() {
    val pairing: PairingViewModel = viewModel()
    val state by pairing.state.collectAsState()
    val context = LocalContext.current
    val bluetooth = remember(context) { (context.applicationContext as PadLinkApplication).bluetoothGamepad }
    val bluetoothState by bluetooth.state.collectAsState()
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var bluetoothSystemDialog by rememberSaveable { mutableStateOf(false) }
    fun startListening() {
        bluetooth.stop()
        val endpoint = wifiPairingEndpoint(context)
        if (endpoint == null) pairing.reportError("Connect your phone and desktop to the same Wi-Fi network.")
        else pairing.start(endpoint)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startListening() else pairing.reportError("Local network access is needed to connect to your desktop.")
    }
    val enableBluetooth = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        bluetoothSystemDialog = false
        if (bluetooth.isEnabled()) bluetooth.start() else bluetooth.fail("Turn on Bluetooth to use the gamepad.")
    }
    val discoverable = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        bluetoothSystemDialog = false
        if (bluetooth.isEnabled()) bluetooth.start()
    }
    fun startBluetooth() {
        pairing.stop()
        if (bluetooth.isEnabled()) bluetooth.start()
        else {
            bluetoothSystemDialog = true
            runCatching { enableBluetooth.launch(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)) }
                .onFailure { bluetoothSystemDialog = false; bluetooth.fail("Bluetooth is unavailable on this phone.") }
        }
    }
    val bluetoothPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { grants ->
        if (grants.values.all { it }) startBluetooth() else bluetooth.fail("Allow nearby-device access to use Bluetooth.")
    }
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_PAUSE -> {
                    bluetooth.update(ControllerState())
                    if (!bluetoothSystemDialog) bluetooth.pauseForBackground()
                }
                Lifecycle.Event.ON_STOP -> {
                    pairing.stop()
                    if (!bluetoothSystemDialog) bluetooth.pauseForBackground()
                }
                Lifecycle.Event.ON_RESUME -> if (!bluetoothSystemDialog) bluetooth.resumeAfterBackground()
                else -> Unit
            }
        }
        lifecycle.addObserver(observer)
        if (lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) bluetooth.resumeAfterBackground()
        onDispose { lifecycle.removeObserver(observer) }
    }
    var destinationName by rememberSaveable {
        mutableStateOf(AppDestination.HOME.name)
    }
    val destination = AppDestination.valueOf(destinationName)
    var settingsReturn by rememberSaveable { mutableStateOf(AppDestination.HOME.name) }
    LaunchedEffect(bluetoothState.phase) {
        if (bluetoothState.phase == BluetoothPhase.CONNECTED && destination == AppDestination.HOME) {
            destinationName = AppDestination.CONTROLLER.name
        }
    }
    ControllerOrientation(destination == AppDestination.CONTROLLER || destination == AppDestination.LAYOUT_EDITOR ||
        destination == AppDestination.SETTINGS && settingsReturn == AppDestination.CONTROLLER.name)

    BackHandler(enabled = destination != AppDestination.HOME) {
        if (destination == AppDestination.CONTROLLER) bluetooth.stop()
        destinationName = when (destination) {
            AppDestination.SETTINGS -> settingsReturn
            AppDestination.LAYOUT_EDITOR -> AppDestination.SETTINGS.name
            else -> AppDestination.HOME.name
        }
    }

    when (destination) {
        AppDestination.HOME -> HomeScreen(
            onOpenSettings = {
                settingsReturn = AppDestination.HOME.name
                destinationName = AppDestination.SETTINGS.name
            },
            onOpenController = {
                if (bluetoothState.phase != BluetoothPhase.CONNECTED) pairing.stop()
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
            bluetooth = bluetoothState,
            onBluetoothStart = {
                val permissions = if (Build.VERSION.SDK_INT >= 31) arrayOf(
                    "android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH_ADVERTISE",
                ) else emptyArray()
                if (permissions.any { ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED }) {
                    bluetoothPermission.launch(permissions)
                } else startBluetooth()
            },
            onBluetoothStop = bluetooth::stop,
            onBluetoothDiscoverable = {
                bluetoothSystemDialog = true
                runCatching { discoverable.launch(Intent(BluetoothAdapter.ACTION_REQUEST_DISCOVERABLE)
                    .putExtra(BluetoothAdapter.EXTRA_DISCOVERABLE_DURATION, 120)) }
                    .onFailure { bluetoothSystemDialog = false; bluetooth.fail("Allow nearby-device access to make the phone discoverable.") }
            },
            onBluetoothRefresh = bluetooth::refreshHosts,
            onBluetoothConnect = bluetooth::connect,
        )

        AppDestination.SETTINGS -> SettingsScreen(
            onBack = { destinationName = settingsReturn },
            onEditLayout = {
                bluetooth.update(ControllerState())
                destinationName = AppDestination.LAYOUT_EDITOR.name
            },
        )

        AppDestination.LAYOUT_EDITOR -> LayoutEditorScreen(onExit = { destinationName = AppDestination.SETTINGS.name })

        AppDestination.CONTROLLER -> ControllerScreen(
            onSettings = {
                settingsReturn = AppDestination.CONTROLLER.name
                destinationName = AppDestination.SETTINGS.name
            },
            onClose = { bluetooth.stop(); destinationName = AppDestination.HOME.name },
            onInputChanged = bluetooth::update,
            connectionLabel = when (bluetoothState.phase) {
                BluetoothPhase.CONNECTED -> "Bluetooth · ${bluetoothState.hostName}"
                BluetoothPhase.STARTING, BluetoothPhase.CONNECTING -> "Bluetooth · Reconnecting…"
                BluetoothPhase.ERROR -> "${bluetoothState.message} Close the controller to retry."
                else -> null
            },
        )
    }
}
