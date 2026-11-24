package org.brokbot.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.HazeStyle
import dev.chrisbanes.haze.HazeTint
import dev.chrisbanes.haze.hazeEffect
import org.brokbot.android.ui.theme.BrokColors

/**
 * Clean Minimal Liquid Glass container powered by Haze 1.3.1 RenderEffect blur,
 * translucent obsidian tint, and a subtle specular border gradient.
 */
@Composable
fun LiquidGlassSurface(
    hazeState: HazeState,
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(22.dp),
    glowColor: Color = BrokColors.CyanAccent,
    blurRadius: Dp = 24.dp,
    fillAlpha: Float = 0.42f,
    content: @Composable BoxScope.() -> Unit
) {
    val hazeStyle = HazeStyle(
        backgroundColor = BrokColors.ObsidianVoid,
        tint = HazeTint(color = BrokColors.GlassTint.copy(alpha = 0.48f)),
        blurRadius = blurRadius,
        noiseFactor = 0.08f,
        fallbackTint = HazeTint(color = BrokColors.GlassTint.copy(alpha = 0.84f))
    )

    val specularBrush = Brush.linearGradient(
        colors = listOf(
            BrokColors.BorderLight,
            BrokColors.BorderMid,
            BrokColors.BorderDim
        )
    )

    val personaSheen = Brush.linearGradient(
        colors = listOf(
            glowColor.copy(alpha = 0.09f),
            BrokColors.ObsidianSurface.copy(alpha = fillAlpha)
        )
    )

    Box(
        modifier = modifier
            .clip(shape)
            .hazeEffect(state = hazeState, style = hazeStyle)
            .background(brush = personaSheen, shape = shape)
            .border(width = 1.dp, brush = specularBrush, shape = shape),
        content = content
    )
}
