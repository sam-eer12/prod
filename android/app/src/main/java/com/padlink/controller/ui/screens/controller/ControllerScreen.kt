package com.padlink.controller.ui.screens.controller

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.padlink.controller.R

internal fun Context.activity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.activity()
    else -> null
}

/** Keep controller settings in landscape too; restore the prior orientation on exit. */
@Composable
fun ControllerOrientation(active: Boolean) {
    val activity = LocalContext.current.activity()
    val previous by rememberSaveable {
        mutableIntStateOf(activity?.requestedOrientation ?: ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED)
    }
    DisposableEffect(active, activity) {
        activity?.requestedOrientation = if (active) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE else previous
        // Restore when leaving the route, not when rotation disposes the old Activity.
        onDispose { }
    }
}

@Composable
fun ControllerScreen(
    onSettings: () -> Unit,
    onClose: () -> Unit,
    onInputChanged: (ControllerState) -> Unit = {},
    connectionLabel: String? = null,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val hapticsEnabled = ControllerPreferences.hapticsEnabled(context)
    val layoutProfile = remember(context) { ControllerLayoutPreferences.load(context) }
    var usable by remember { mutableStateOf(true) }
    var fallback by remember { mutableStateOf(false) }
    val surface = remember(context) { ControllerView(context) }

    DisposableEffect(surface, lifecycle) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) surface.resetInput()
        }
        lifecycle.addObserver(observer)
        val window = context.activity()?.window
        val bars = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        val previousBehavior = bars?.systemBarsBehavior
        bars?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        bars?.hide(WindowInsetsCompat.Type.systemBars())
        surface.keepScreenOn = true
        onDispose {
            surface.resetInput()
            surface.keepScreenOn = false
            lifecycle.removeObserver(observer)
            bars?.show(WindowInsetsCompat.Type.systemBars())
            if (previousBehavior != null) bars?.systemBarsBehavior = previousBehavior
        }
    }

    Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.background).safeDrawingPadding()) {
        Box(Modifier.weight(1f)) {
            AndroidView(
                factory = { surface.apply { onLayoutUsableChanged = { usable = it } } },
                modifier = Modifier.fillMaxSize().testTag("controller_surface"),
                onRelease = { it.resetInput() },
                update = {
                    it.onSettings = onSettings
                    it.onClose = onClose
                    it.hapticsEnabled = hapticsEnabled
                    it.onInputChanged = onInputChanged
                    it.onLayoutFallbackChanged = { value -> fallback = value }
                    it.layoutProfile = layoutProfile
                },
            )
            if (!usable) {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp, Alignment.CenterVertically),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(stringResource(R.string.controller_window_small), style = MaterialTheme.typography.titleMedium)
                    Button(onClick = onClose) { Text(stringResource(R.string.controller_close)) }
                }
            }
        }
        // Match the editor's footer so its validated geometry is identical during play.
        Box(Modifier.fillMaxWidth().height(48.dp), contentAlignment = Alignment.Center) {
            Text(
                if (fallback) stringResource(R.string.editor_fallback)
                else connectionLabel ?: stringResource(if (hapticsEnabled) R.string.controller_local_haptics else R.string.controller_local),
                Modifier.padding(horizontal = 16.dp),
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}
