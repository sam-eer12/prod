package com.padlink.controller.ui.screens.home

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.padlink.controller.R
import com.padlink.controller.core.BluetoothControllerProfile
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
    onSwitchProfile: (BluetoothControllerProfile) -> Unit = {},
) {
    Card(Modifier.fillMaxWidth().testTag("bluetooth_card")) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.bluetooth_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.bluetooth_body), color = MaterialTheme.colorScheme.onSurfaceVariant)

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(
                        if (state.profile == BluetoothControllerProfile.XBOX_ONE) R.string.bluetooth_profile_xbox
                        else R.string.bluetooth_profile_generic,
                    ),
                    style = MaterialTheme.typography.bodySmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.weight(1f),
                )
                if (state.phase == BluetoothPhase.OFF || state.phase == BluetoothPhase.READY || state.phase == BluetoothPhase.ERROR) {
                    TextButton(onClick = {
                        val next = if (state.profile == BluetoothControllerProfile.XBOX_ONE)
                            BluetoothControllerProfile.GENERIC else BluetoothControllerProfile.XBOX_ONE
                        onSwitchProfile(next)
                    }) {
                        Text(
                            stringResource(
                                if (state.profile == BluetoothControllerProfile.XBOX_ONE) R.string.bluetooth_switch_to_generic
                                else R.string.bluetooth_switch_to_xbox,
                            ),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
            }

            if (state.message.isNotEmpty()) {
                Text(
                    state.message,
                    color = if (state.phase == BluetoothPhase.ERROR) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            when (state.phase) {
                BluetoothPhase.OFF, BluetoothPhase.ERROR -> {
                    Button(onClick = onStart, modifier = Modifier.testTag("bluetooth_start")) {
                        Text(stringResource(R.string.bluetooth_start))
                    }
                }
                BluetoothPhase.STARTING -> Text(stringResource(R.string.bluetooth_starting))
                BluetoothPhase.READY -> {
                    if (state.localName.isNotEmpty()) {
                        Text(
                            text = stringResource(R.string.bluetooth_phone_name, state.localName),
                            style = MaterialTheme.typography.labelMedium,
                            fontWeight = FontWeight.Bold,
                        )
                        Text(
                            text = stringResource(R.string.bluetooth_pair_steps, state.localName),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    } else {
                        Text(
                            stringResource(R.string.bluetooth_pair_help),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Button(onClick = onDiscoverable) { Text(stringResource(R.string.bluetooth_discoverable)) }
                        OutlinedButton(onClick = onRefresh) { Text(stringResource(R.string.bluetooth_refresh)) }
                    }
                    state.hosts.forEach { host ->
                        OutlinedButton(onClick = { onConnect(host.address) }, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.bluetooth_connect_host, host.name))
                        }
                    }
                }
                BluetoothPhase.CONNECTING -> Text(stringResource(R.string.bluetooth_connecting, state.hostName))
                BluetoothPhase.CONNECTED -> {
                    Text(
                        stringResource(R.string.bluetooth_connected, state.hostName),
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                    )
                    Button(onClick = onOpenController) { Text(stringResource(R.string.home_open_controller)) }
                }
            }
            if (state.phase != BluetoothPhase.OFF && state.phase != BluetoothPhase.ERROR) {
                OutlinedButton(onClick = onStop) { Text(stringResource(R.string.bluetooth_stop)) }
            }
        }
    }
}
