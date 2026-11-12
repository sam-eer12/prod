package com.padlink.controller.ui.screens.controller

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.padlink.controller.R
import kotlin.math.roundToInt

@Composable
fun LayoutEditorScreen(onExit: () -> Unit) {
    val context = LocalContext.current
    var draft by rememberSaveable { mutableStateOf(ControllerLayoutPreferences.load(context).encode()) }
    val profile = ControllerLayoutProfile.decode(draft) ?: ControllerLayoutProfile()
    var selectedName by rememberSaveable { mutableStateOf(ControlId.LEFT_STICK.name) }
    val selected = ControlId.valueOf(selectedName)
    var adjust by rememberSaveable { mutableStateOf(false) }
    var usable by remember { mutableStateOf(false) }
    val surface = remember(context) { ControllerView(context).apply { editing = true; hapticsEnabled = false } }

    DisposableEffect(surface) {
        val window = context.activity()?.window
        val bars = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        val previous = bars?.systemBarsBehavior
        bars?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        bars?.hide(WindowInsetsCompat.Type.systemBars())
        surface.keepScreenOn = true
        onDispose {
            surface.resetInput()
            surface.keepScreenOn = false
            bars?.show(WindowInsetsCompat.Type.systemBars())
            if (previous != null) bars?.systemBarsBehavior = previous
        }
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).safeDrawingPadding()) {
        AndroidView(
            factory = { surface },
            modifier = Modifier.weight(1f).fillMaxWidth().testTag("layout_editor_surface"),
            onRelease = { it.resetInput() },
            update = {
                it.onEditSelection = { id -> selectedName = id.name }
                it.onEditChanged = { changed -> draft = changed.encode() }
                it.onLayoutUsableChanged = { valid -> usable = valid }
                it.layoutProfile = profile
                it.selectedControl = selected
            },
        )
        Row(Modifier.fillMaxWidth().height(48.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = onExit) { Text(stringResource(R.string.editor_cancel)) }
            TextButton(onClick = { draft = ControllerLayoutProfile().encode() }) { Text(stringResource(R.string.editor_reset)) }
            Text(
                stringResource(if (usable) R.string.editor_drag else R.string.editor_invalid),
                modifier = Modifier.weight(1f).padding(horizontal = 8.dp),
                style = MaterialTheme.typography.labelSmall,
                color = if (usable) MaterialTheme.colorScheme.onSurfaceVariant else MaterialTheme.colorScheme.error,
            )
            TextButton(onClick = { adjust = true }) { Text(stringResource(R.string.editor_adjust)) }
            TextButton(enabled = usable, onClick = {
                // Validate against the current surface before persisting the draft.
                if (surface.controllerLayout.usable && surface.layoutProfile == profile) {
                    ControllerLayoutPreferences.save(context, profile)
                    onExit()
                }
            }) { Text(stringResource(R.string.editor_save)) }
        }
    }

    if (adjust) {
        var expanded by remember { mutableStateOf(false) }
        AlertDialog(
            onDismissRequest = { adjust = false },
            title = { Text(stringResource(R.string.editor_adjust)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box {
                        TextButton(onClick = { expanded = true }, modifier = Modifier.testTag("editor_select_control")) {
                            Text(selected.label)
                        }
                        DropdownMenu(expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 240.dp)) {
                            ControlId.entries.filter { it.kind != ControlKind.ACTION }.forEach { id ->
                                DropdownMenuItem(text = { Text(id.label) }, onClick = { selectedName = id.name; expanded = false })
                            }
                        }
                    }
                    val scale = profile.placements[selected]?.scale ?: 1f
                    Text(stringResource(R.string.editor_size, (scale * 100).roundToInt()))
                    Slider(value = scale, onValueChange = { surface.adjustSelected(scale = it) }, valueRange = 0.65f..1.65f,
                        modifier = Modifier.testTag("editor_size"))
                }
            },
            confirmButton = { TextButton(onClick = { adjust = false }) { Text(stringResource(R.string.editor_done)) } },
        )
    }
}
