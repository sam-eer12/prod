package com.padlink.controller.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val PadLinkDarkColorScheme = darkColorScheme(
    primary = PadPink,
    onPrimary = Color(0xFF3B0A0D),
    primaryContainer = PadRedContainer,
    onPrimaryContainer = PadPink,
    secondary = PadRed,
    onSecondary = Color.White,
    secondaryContainer = PadRedContainer,
    onSecondaryContainer = PadPink,
    background = Charcoal,
    onBackground = OffWhite,
    surface = CharcoalSurface,
    onSurface = OffWhite,
    surfaceVariant = CharcoalSurfaceVariant,
    onSurfaceVariant = Muted,
    outline = Outline,
    outlineVariant = CharcoalSurfaceVariant,
    error = StatusError,
    onError = Color(0xFF690005),
)

/**
 * PadLink uses one dark scheme so the setup flow and the controller share the
 * same charcoal surface. A system-light variant can be added when the layout
 * editor is implemented; dynamic color is intentionally not used.
 */
@Composable
fun PadLinkTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = PadLinkDarkColorScheme,
        typography = PadLinkTypography,
        content = content,
    )
}
