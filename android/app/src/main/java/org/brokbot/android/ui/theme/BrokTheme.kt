package org.brokbot.android.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

object BrokColors {
    val ObsidianVoid = Color(0xFF0D0E12)
    val ObsidianSurface = Color(0xFF14161D)
    val GlassTint = Color(0xFF171B26)
    val CyanAccent = Color(0xFF00E5FF)
    val MonocleGold = Color(0xFFD4AF37)
    val MonocleGoldSoft = Color(0xFFE5C158)
    val TextPrimary = Color(0xFFF4F6FB)
    val TextSecondary = Color(0xFFA0A8B8)
    val BorderLight = Color(0x38FFFFFF)
    val BorderMid = Color(0x0DFFFFFF)
    val BorderDim = Color(0x1EFFFFFF)
    val DangerRed = Color(0xFFFF6B6B)
    val EmeraldOk = Color(0xFF34D399)
}

private val BrokDarkColorScheme = darkColorScheme(
    primary = BrokColors.CyanAccent,
    onPrimary = BrokColors.ObsidianVoid,
    secondary = BrokColors.MonocleGold,
    onSecondary = BrokColors.ObsidianVoid,
    background = BrokColors.ObsidianVoid,
    onBackground = BrokColors.TextPrimary,
    surface = BrokColors.ObsidianSurface,
    onSurface = BrokColors.TextPrimary,
    surfaceVariant = BrokColors.GlassTint,
    onSurfaceVariant = BrokColors.TextSecondary,
    error = BrokColors.DangerRed
)

private val BrokTypography = Typography(
    titleLarge = TextStyle(
        fontSize = 20.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.3).sp,
        color = BrokColors.TextPrimary
    ),
    titleMedium = TextStyle(
        fontSize = 16.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = (-0.1).sp,
        color = BrokColors.TextPrimary
    ),
    bodyMedium = TextStyle(
        fontSize = 14.sp,
        lineHeight = 20.sp,
        color = BrokColors.TextPrimary
    ),
    labelMedium = TextStyle(
        fontSize = 12.sp,
        fontWeight = FontWeight.Medium,
        letterSpacing = 0.2.sp,
        color = BrokColors.TextSecondary
    )
)

@Composable
fun BrokTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = BrokDarkColorScheme,
        typography = BrokTypography,
        content = content
    )
}
