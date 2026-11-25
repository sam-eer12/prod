package org.brokbot.android.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.brokbot.android.core.bots.BotAvatarFace
import org.brokbot.android.core.bots.BotAvatarShape
import org.brokbot.android.core.bots.BotAvatarSpec
import org.brokbot.android.core.bots.BotAvatarStyle
import org.brokbot.android.core.bots.BotPersona

@Composable
fun BotAvatarView(
    persona: BotPersona,
    size: Dp = 36.dp,
    modifier: Modifier = Modifier
) {
    BotAvatarView(
        avatar = persona.avatar,
        accentHex = persona.accentHex,
        iconKey = persona.iconKey,
        fallbackInitial = persona.name.firstOrNull()?.uppercaseChar()?.toString() ?: "B",
        size = size,
        modifier = modifier
    )
}

@Composable
fun BotAvatarView(
    avatar: BotAvatarSpec,
    accentHex: String,
    iconKey: String,
    fallbackInitial: String = "B",
    size: Dp = 36.dp,
    modifier: Modifier = Modifier
) {
    val fillColor = parseHexColor(accentHex)
    val inkColor = Color(0xFF0E1118)

    Box(
        modifier = modifier.size(size),
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val w = this.size.width
            val h = this.size.height
            val shapePath = buildSilhouettePath(avatar.shape, w, h)

            drawPath(path = shapePath, color = fillColor)
            drawPath(
                path = shapePath,
                brush = Brush.linearGradient(
                    colors = listOf(Color.White.copy(alpha = 0.45f), Color.White.copy(alpha = 0.08f))
                ),
                style = Stroke(width = (w * 0.04f).coerceAtLeast(1.2f))
            )

            if (avatar.style == BotAvatarStyle.FACE) {
                when (avatar.face) {
                    BotAvatarFace.DOTS -> {
                        val r = w * 0.07f
                        drawCircle(color = inkColor, radius = r, center = Offset(w * 0.37f, h * 0.48f))
                        drawCircle(color = inkColor, radius = r, center = Offset(w * 0.63f, h * 0.48f))
                    }
                    BotAvatarFace.HAPPY -> {
                        val stroke = Stroke(width = (w * 0.075f).coerceAtLeast(2f), cap = StrokeCap.Round)
                        val leftArc = Path().apply {
                            moveTo(w * 0.28f, h * 0.52f)
                            quadraticTo(w * 0.37f, h * 0.38f, w * 0.46f, h * 0.52f)
                        }
                        val rightArc = Path().apply {
                            moveTo(w * 0.54f, h * 0.52f)
                            quadraticTo(w * 0.63f, h * 0.38f, w * 0.72f, h * 0.52f)
                        }
                        drawPath(leftArc, color = inkColor, style = stroke)
                        drawPath(rightArc, color = inkColor, style = stroke)
                    }
                    BotAvatarFace.FOCUSED -> {
                        drawRoundRect(
                            color = inkColor,
                            topLeft = Offset(w * 0.27f, h * 0.44f),
                            size = Size(w * 0.18f, h * 0.11f),
                            cornerRadius = CornerRadius(w * 0.06f, w * 0.06f)
                        )
                        drawRoundRect(
                            color = inkColor,
                            topLeft = Offset(w * 0.55f, h * 0.44f),
                            size = Size(w * 0.18f, h * 0.11f),
                            cornerRadius = CornerRadius(w * 0.06f, w * 0.06f)
                        )
                    }
                    BotAvatarFace.WINK -> {
                        drawCircle(color = inkColor, radius = w * 0.07f, center = Offset(w * 0.37f, h * 0.48f))
                        drawRoundRect(
                            color = inkColor,
                            topLeft = Offset(w * 0.54f, h * 0.46f),
                            size = Size(w * 0.19f, h * 0.07f),
                            cornerRadius = CornerRadius(w * 0.04f, w * 0.04f)
                        )
                    }
                    BotAvatarFace.VISOR -> {
                        drawRoundRect(
                            color = inkColor,
                            topLeft = Offset(w * 0.21f, h * 0.41f),
                            size = Size(w * 0.58f, h * 0.18f),
                            cornerRadius = CornerRadius(w * 0.09f, w * 0.09f)
                        )
                        drawRoundRect(
                            color = Color.White.copy(alpha = 0.45f),
                            topLeft = Offset(w * 0.28f, h * 0.45f),
                            size = Size(w * 0.20f, h * 0.04f),
                            cornerRadius = CornerRadius(w * 0.02f, w * 0.02f)
                        )
                    }
                    BotAvatarFace.MONOCLE -> {
                        drawCircle(color = inkColor, radius = w * 0.065f, center = Offset(w * 0.36f, h * 0.48f))
                        drawCircle(
                            color = inkColor,
                            radius = w * 0.12f,
                            center = Offset(w * 0.63f, h * 0.48f),
                            style = Stroke(width = (w * 0.06f).coerceAtLeast(1.8f))
                        )
                        drawCircle(color = inkColor, radius = w * 0.05f, center = Offset(w * 0.63f, h * 0.48f))
                    }
                }
            }
        }

        if (avatar.style == BotAvatarStyle.ICON) {
            Text(
                text = iconGlyphFor(iconKey, fallbackInitial),
                fontSize = (size.value * 0.42f).sp,
                fontWeight = FontWeight.Bold,
                color = inkColor
            )
        }
    }
}

fun parseHexColor(hex: String, fallback: Color = Color(0xFF00E5FF)): Color {
    val cleaned = hex.trim().removePrefix("#")
    if (cleaned.length != 6) return fallback
    val value = cleaned.toLongOrNull(16) ?: return fallback
    return Color((0xFF000000L or value).toInt())
}

private fun iconGlyphFor(iconKey: String, fallbackInitial: String): String = when (iconKey.lowercase()) {
    "sparkles" -> "✦"
    "cube" -> "◆"
    "tray" -> "✉"
    "code" -> "</>"
    "globe" -> "◎"
    "shield" -> "◈"
    "bolt" -> "⚡"
    else -> fallbackInitial
}

private fun buildSilhouettePath(shape: BotAvatarShape, w: Float, h: Float): Path = Path().apply {
    when (shape) {
        BotAvatarShape.CIRCLE -> {
            addOval(androidx.compose.ui.geometry.Rect(0f, 0f, w, h))
        }
        BotAvatarShape.ROUNDED_SQUARE -> {
            addRoundRect(
                androidx.compose.ui.geometry.RoundRect(
                    left = 0f,
                    top = 0f,
                    right = w,
                    bottom = h,
                    cornerRadius = CornerRadius(w * 0.28f, h * 0.28f)
                )
            )
        }
        BotAvatarShape.SOFT_TRIANGLE -> {
            moveTo(w * 0.50f, h * 0.06f)
            quadraticTo(w * 0.88f, h * 0.24f, w * 0.94f, h * 0.80f)
            quadraticTo(w * 0.86f, h * 0.96f, w * 0.50f, h * 0.94f)
            quadraticTo(w * 0.14f, h * 0.96f, w * 0.06f, h * 0.80f)
            quadraticTo(w * 0.12f, h * 0.24f, w * 0.50f, h * 0.06f)
            close()
        }
        BotAvatarShape.CLOUD -> {
            addOval(androidx.compose.ui.geometry.Rect(w * 0.10f, h * 0.34f, w * 0.54f, h * 0.82f))
            addOval(androidx.compose.ui.geometry.Rect(w * 0.26f, h * 0.14f, w * 0.74f, h * 0.66f))
            addOval(androidx.compose.ui.geometry.Rect(w * 0.46f, h * 0.34f, w * 0.90f, h * 0.82f))
            addRoundRect(
                androidx.compose.ui.geometry.RoundRect(
                    left = w * 0.16f,
                    top = h * 0.44f,
                    right = w * 0.84f,
                    bottom = h * 0.84f,
                    cornerRadius = CornerRadius(w * 0.20f, w * 0.20f)
                )
            )
        }
        BotAvatarShape.PEBBLE -> {
            moveTo(w * 0.52f, h * 0.08f)
            cubicTo(w * 0.82f, h * 0.08f, w * 0.96f, h * 0.30f, w * 0.94f, h * 0.54f)
            cubicTo(w * 0.92f, h * 0.82f, w * 0.68f, h * 0.94f, w * 0.46f, h * 0.92f)
            cubicTo(w * 0.18f, h * 0.90f, w * 0.04f, h * 0.72f, w * 0.06f, h * 0.48f)
            cubicTo(w * 0.08f, h * 0.20f, w * 0.24f, h * 0.08f, w * 0.52f, h * 0.08f)
            close()
        }
    }
}
