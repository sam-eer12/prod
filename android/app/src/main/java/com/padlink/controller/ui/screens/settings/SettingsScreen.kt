package com.padlink.controller.ui.screens.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.Switch
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.DisposableEffect
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import android.content.Intent
import android.provider.Settings
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.padlink.controller.BuildConfig
import com.padlink.controller.R
import com.padlink.controller.ui.theme.PadLinkTheme
import com.padlink.controller.ui.screens.controller.ControllerPreferences
import com.padlink.controller.ui.screens.controller.ControllerLayoutPreferences
import com.padlink.controller.ui.screens.controller.ControllerVibration
import com.padlink.controller.ui.screens.controller.VibrationStatus

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(onBack: () -> Unit, onEditLayout: () -> Unit = {}) {
    val context = LocalContext.current
    var hapticsEnabled by remember { mutableStateOf(ControllerPreferences.hapticsEnabled(context)) }
    val vibration = remember(context) { ControllerVibration(context) }
    var vibrationStatus by remember { mutableStateOf(vibration.status()) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(vibration, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) vibrationStatus = vibration.status()
            if (event == Lifecycle.Event.ON_PAUSE) vibration.stop()
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); vibration.stop() }
    }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title)) },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.background,
                    titleContentColor = MaterialTheme.colorScheme.onBackground,
                    navigationIconContentColor = MaterialTheme.colorScheme.onBackground,
                ),
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.action_back),
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
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            SectionHeader(text = stringResource(R.string.settings_application))
            InfoRow(label = stringResource(R.string.settings_version), value = BuildConfig.VERSION_NAME)
            InfoRow(label = stringResource(R.string.settings_build_type), value = BuildConfig.BUILD_TYPE)
            InfoRow(label = stringResource(R.string.settings_package), value = BuildConfig.APPLICATION_ID)

            HorizontalDivider(
                modifier = Modifier.padding(vertical = 16.dp),
                color = MaterialTheme.colorScheme.outlineVariant,
            )

            SectionHeader(text = stringResource(R.string.settings_controller))
            InfoRow(
                label = stringResource(R.string.settings_layout),
                value = stringResource(if (ControllerLayoutPreferences.load(context).placements.isEmpty())
                    R.string.settings_layout_value else R.string.settings_layout_custom),
            )
            TextButton(onClick = onEditLayout) { Text(stringResource(R.string.settings_edit_layout)) }
            InfoRow(
                label = stringResource(R.string.settings_input),
                value = stringResource(R.string.settings_input_value),
            )
            Row(
                modifier = Modifier.fillMaxWidth().toggleable(
                    value = hapticsEnabled,
                    role = Role.Switch,
                    onValueChange = {
                        hapticsEnabled = it
                        ControllerPreferences.setHapticsEnabled(context, it)
                    },
                ).padding(vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(stringResource(R.string.settings_haptics), style = MaterialTheme.typography.bodyLarge)
                    Text(stringResource(R.string.settings_haptics_detail), style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Switch(checked = hapticsEnabled, onCheckedChange = null)
            }
            Text(stringResource(when (vibrationStatus) {
                VibrationStatus.AVAILABLE -> R.string.haptics_available
                VibrationStatus.SYSTEM_DISABLED -> R.string.haptics_system_disabled
                VibrationStatus.NO_VIBRATOR -> R.string.haptics_unavailable
            }), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            TextButton(enabled = hapticsEnabled && vibrationStatus != VibrationStatus.NO_VIBRATOR, onClick = {
                vibrationStatus = vibration.status()
                vibration.test()
            }) { Text(stringResource(R.string.haptics_test)) }
            if (vibrationStatus == VibrationStatus.SYSTEM_DISABLED) {
                TextButton(onClick = { runCatching { context.startActivity(Intent(Settings.ACTION_SOUND_SETTINGS)) } }) {
                    Text(stringResource(R.string.haptics_open_settings))
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            ) {
                Text(
                    text = stringResource(R.string.settings_note),
                    modifier = Modifier.padding(20.dp),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(
        text = text,
        modifier = Modifier.padding(top = 8.dp, bottom = 4.dp),
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
    )
}

@Composable
private fun InfoRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text(
            text = label,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            modifier = Modifier.weight(1.4f),
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.End,
        )
    }
}

@Preview(showBackground = true, backgroundColor = 0xFF101214, widthDp = 400, heightDp = 800)
@Composable
private fun SettingsScreenPreview() {
    PadLinkTheme {
        SettingsScreen(onBack = {})
    }
}
