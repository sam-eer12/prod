package com.padlink.controller.ui.screens.home

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.ui.text.font.FontFamily
import com.padlink.controller.core.PairingUiState
import com.padlink.controller.core.PairingPhase
import com.padlink.controller.core.BluetoothGamepadState
import com.padlink.controller.core.BluetoothPhase
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.padlink.controller.R
import com.padlink.controller.domain.ConnectionState
import com.padlink.controller.ui.theme.PadLinkTheme
import com.padlink.controller.ui.theme.StatusConnected
import com.padlink.controller.ui.theme.StatusError
import com.padlink.controller.ui.theme.StatusIdle
import com.padlink.controller.ui.theme.StatusListening
import com.padlink.controller.ui.theme.StatusPairing

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    onOpenSettings: () -> Unit,
    onOpenController: () -> Unit = {},
    pairing: PairingUiState = PairingUiState(),
    onStart: () -> Unit = {},
    onStop: () -> Unit = {},
    onAllow: (Long) -> Unit = {},
    onDeny: (Long) -> Unit = {},
    onCancel: (Long) -> Unit = {},
    bluetooth: BluetoothGamepadState = BluetoothGamepadState(),
    onBluetoothStart: () -> Unit = {},
    onBluetoothStop: () -> Unit = {},
    onBluetoothDiscoverable: () -> Unit = {},
    onBluetoothRefresh: () -> Unit = {},
    onBluetoothConnect: (String) -> Unit = {},
) {
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                    actionIconContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                actions = {
                    IconButton(onClick = onOpenSettings) {
                        Icon(
                            imageVector = Icons.Filled.Settings,
                            contentDescription = stringResource(R.string.action_settings),
                        )
                    }
                },
            )
        },
    ) { contentPadding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(contentPadding)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            Text(
                text = stringResource(R.string.home_headline),
                style = MaterialTheme.typography.headlineSmall,
            )
            Text(
                text = stringResource(R.string.home_body),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            BluetoothCard(bluetooth, onBluetoothStart, onBluetoothStop, onBluetoothDiscoverable,
                onBluetoothRefresh, onBluetoothConnect, onOpenController)

            if (bluetooth.phase == BluetoothPhase.OFF || pairing.phase != PairingPhase.STOPPED) ConnectionCard(state = when (pairing.phase) {
                PairingPhase.STOPPED -> ConnectionState.NOT_CONNECTED
                PairingPhase.LISTENING -> ConnectionState.LISTENING
                PairingPhase.CONSENT, PairingPhase.TOKEN -> ConnectionState.PAIRING
                PairingPhase.PAIRED -> ConnectionState.CONNECTED
                PairingPhase.ERROR -> ConnectionState.ERROR
            })
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(stringResource(R.string.wifi_title), style = MaterialTheme.typography.titleMedium)
                    if (pairing.endpoint.isNotEmpty()) {
                        Text(stringResource(R.string.pairing_endpoint), style = MaterialTheme.typography.labelLarge)
                        Text(pairing.endpoint, fontFamily = FontFamily.Monospace)
                    }
                    when (pairing.phase) {
                        PairingPhase.STOPPED, PairingPhase.ERROR -> {
                            if (pairing.message.isNotEmpty()) Text(pairing.message, color = MaterialTheme.colorScheme.error)
                            Button(onClick = onStart) { Text(stringResource(R.string.pairing_start)) }
                        }
                        PairingPhase.CONSENT -> {
                            Text(stringResource(R.string.pairing_request), style = MaterialTheme.typography.titleMedium)
                            Text(stringResource(R.string.pairing_unverified))
                            Text(pairing.label)
                            Text(pairing.address, fontFamily = FontFamily.Monospace)
                            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                                Button(onClick = { onAllow(pairing.connection) }) { Text(stringResource(R.string.pairing_allow)) }
                                OutlinedButton(onClick = { onDeny(pairing.connection) }) { Text(stringResource(R.string.pairing_deny)) }
                            }
                        }
                        PairingPhase.TOKEN -> {
                            Text(stringResource(R.string.pairing_enter_code))
                            Text(pairing.code, style = MaterialTheme.typography.headlineLarge, fontFamily = FontFamily.Monospace)
                            Text(stringResource(R.string.pairing_expires, pairing.remainingSeconds))
                            OutlinedButton(onClick = { onCancel(pairing.connection) }) { Text(stringResource(R.string.pairing_cancel)) }
                        }
                        PairingPhase.PAIRED -> OutlinedButton(onClick = { onCancel(pairing.connection) }) { Text(stringResource(R.string.pairing_disconnect)) }
                        PairingPhase.LISTENING -> OutlinedButton(onClick = onStop) { Text(stringResource(R.string.pairing_stop)) }
                    }
                }
            }
            ControllerCard(onOpenController, bluetooth.phase == BluetoothPhase.CONNECTED)
        }
    }
}

@Composable
private fun ConnectionCard(state: ConnectionState) {
    val status = state.presentation()

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
        border = BorderStroke(
            width = 1.dp,
            color = MaterialTheme.colorScheme.outline.copy(alpha = 0.35f),
        ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Box(
                modifier = Modifier
                    .padding(top = 6.dp)
                    .size(10.dp)
                    .background(status.indicator, CircleShape),
            )
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = status.title,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    text = status.detail,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ControllerCard(onOpenController: () -> Unit, connected: Boolean) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = stringResource(R.string.home_controller_title),
                style = MaterialTheme.typography.titleMedium,
            )
            Text(
                text = stringResource(R.string.home_controller_body),
                style = MaterialTheme.typography.bodyMedium,
            )
            Button(onClick = onOpenController) {
                Text(stringResource(if (connected) R.string.home_open_controller else R.string.home_try_controller))
            }
        }
    }
}

private data class StatusPresentation(
    val title: String,
    val detail: String,
    val indicator: Color,
)

@Composable
private fun ConnectionState.presentation(): StatusPresentation = when (this) {
    ConnectionState.NOT_CONNECTED -> StatusPresentation(
        title = stringResource(R.string.status_not_connected),
        detail = stringResource(R.string.status_not_connected_detail),
        indicator = StatusIdle,
    )

    ConnectionState.LISTENING -> StatusPresentation(
        title = stringResource(R.string.status_listening),
        detail = stringResource(R.string.status_listening_detail),
        indicator = StatusListening,
    )

    ConnectionState.PAIRING -> StatusPresentation(
        title = stringResource(R.string.status_pairing),
        detail = stringResource(R.string.status_pairing_detail),
        indicator = StatusPairing,
    )

    ConnectionState.CONNECTED -> StatusPresentation(
        title = stringResource(R.string.status_connected),
        detail = stringResource(R.string.status_connected_detail),
        indicator = StatusConnected,
    )

    ConnectionState.ERROR -> StatusPresentation(
        title = stringResource(R.string.status_error),
        detail = stringResource(R.string.status_error_detail),
        indicator = StatusError,
    )
}

@Preview(showBackground = true, backgroundColor = 0xFF101214, widthDp = 400, heightDp = 800)
@Composable
private fun HomeScreenPreview() {
    PadLinkTheme {
        HomeScreen(onOpenSettings = {})
    }
}
