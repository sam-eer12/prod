package com.padlink.controller.ui.screens.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.padlink.controller.R
import com.padlink.controller.core.BluetoothGamepadState
import com.padlink.controller.core.BluetoothPhase

@Composable
fun BluetoothCard(
    state: BluetoothGamepadState,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onDiscoverable: () -> Unit,
    onRefresh: () -> Unit,
    onConnect: (String) -> Unit,
    onOpenController: () -> Unit,
) {
    Card(Modifier.fillMaxWidth().testTag("bluetooth_card")) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.bluetooth_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.bluetooth_body), color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (state.message.isNotEmpty()) {
                Text(state.message, color = if (state.phase == BluetoothPhase.ERROR) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            }
            when (state.phase) {
                BluetoothPhase.OFF, BluetoothPhase.ERROR -> {
                    Button(onClick = onStart, modifier = Modifier.testTag("bluetooth_start")) {
                        Text(stringResource(R.string.bluetooth_start))
                    }
                }
                BluetoothPhase.STARTING -> Text(stringResource(R.string.bluetooth_starting))
                BluetoothPhase.READY -> {
                    Text(stringResource(R.string.bluetooth_pair_help))
                    Button(onClick = onDiscoverable) { Text(stringResource(R.string.bluetooth_discoverable)) }
                    OutlinedButton(onClick = onRefresh) { Text(stringResource(R.string.bluetooth_refresh)) }
                    state.hosts.forEach { host ->
                        OutlinedButton(onClick = { onConnect(host.address) }) {
                            Text(stringResource(R.string.bluetooth_connect_host, host.name))
                        }
                    }
                }
                BluetoothPhase.CONNECTING -> Text(stringResource(R.string.bluetooth_connecting, state.hostName))
                BluetoothPhase.CONNECTED -> {
                    Text(stringResource(R.string.bluetooth_connected, state.hostName))
                    Button(onClick = onOpenController) { Text(stringResource(R.string.home_open_controller)) }
                }
            }
            if (state.phase != BluetoothPhase.OFF && state.phase != BluetoothPhase.ERROR) {
                OutlinedButton(onClick = onStop) { Text(stringResource(R.string.bluetooth_stop)) }
            }
        }
    }
}
