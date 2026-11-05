package com.padlink.controller.ui.theme

import androidx.compose.ui.graphics.Color

// Brand palette derived from the supplied controller reference: charcoal
// surfaces, deep-red controls, pale-pink caps, and light labels.
internal val PadPink = Color(0xFFF2C4C9)
internal val PadRed = Color(0xFFB3261E)
internal val PadRedContainer = Color(0xFF5C1214)
internal val Charcoal = Color(0xFF101214)
internal val CharcoalSurface = Color(0xFF171A1D)
internal val CharcoalSurfaceVariant = Color(0xFF23272B)
internal val OffWhite = Color(0xFFF6F1EF)
internal val Muted = Color(0xFFB8B1AF)
internal val Outline = Color(0xFF5A5F63)

// Status indicators are intentionally distinct from the red brand accent so a
// connection error is not confused with ordinary controller chrome.
internal val StatusIdle = Muted
internal val StatusListening = Color(0xFFE8C46A)
internal val StatusPairing = Color(0xFF8FC7FF)
internal val StatusConnected = Color(0xFF7BD88F)
internal val StatusError = Color(0xFFFFB4AB)
