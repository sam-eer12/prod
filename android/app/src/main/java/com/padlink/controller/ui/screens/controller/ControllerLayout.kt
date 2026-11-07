package com.padlink.controller.ui.screens.controller

import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

enum class ControlKind { BUTTON, STICK, DPAD, TRIGGER, ACTION }

// Digital masks match protocol::frame::Buttons. Navigation actions have no mask.
enum class ControlId(val kind: ControlKind, val label: String, val mask: Int = 0) {
    LT(ControlKind.TRIGGER, "Left Trigger"),
    RT(ControlKind.TRIGGER, "Right Trigger"),
    LB(ControlKind.BUTTON, "Left Bumper", 1 shl 4),
    RB(ControlKind.BUTTON, "Right Bumper", 1 shl 5),
    DPAD(ControlKind.DPAD, "Directional Pad"),
    LEFT_STICK(ControlKind.STICK, "Left Joystick"),
    RIGHT_STICK(ControlKind.STICK, "Right Joystick"),
    L3(ControlKind.BUTTON, "Left Stick Click", 1 shl 9),
    R3(ControlKind.BUTTON, "Right Stick Click", 1 shl 10),
    A(ControlKind.BUTTON, "A", 1),
    B(ControlKind.BUTTON, "B", 1 shl 1),
    X(ControlKind.BUTTON, "X", 1 shl 2),
    Y(ControlKind.BUTTON, "Y", 1 shl 3),
    VIEW(ControlKind.BUTTON, "View", 1 shl 6),
    MENU(ControlKind.BUTTON, "Menu", 1 shl 7),
    SETTINGS(ControlKind.ACTION, "Controller Settings"),
    CLOSE(ControlKind.ACTION, "Close Controller"),
}

data class ControlGeometry(
    val id: ControlId,
    val x: Float,
    val y: Float,
    val radius: Float,
    val touchRadius: Float = radius,
) {
    val capRadius: Float get() = radius * 0.59f
    // The whole cap, including its bevel, stays inside the fixed outer circle.
    val travel: Float get() = radius - capRadius - radius * 0.08f

    fun contains(px: Float, py: Float): Boolean = hypot(px - x, py - y) <= touchRadius
}

/** One geometry source for the renderer, pointer capture, and accessibility. */
class ControllerLayout private constructor(val controls: List<ControlGeometry>, val usable: Boolean) {
    operator fun get(id: ControlId): ControlGeometry = controls.first { it.id == id }

    fun hitTest(x: Float, y: Float): ControlGeometry? =
        if (usable) controls.firstOrNull { it.contains(x, y) } else null

    companion object {
        // Original 526 x 237 reference, with room for the 48 dp close target.
        private val reference = listOf(
            ControlGeometry(ControlId.LT, 36f, 33f, 28f),
            ControlGeometry(ControlId.RT, 489f, 33f, 28f),
            ControlGeometry(ControlId.LB, 89f, 69f, 23f),
            ControlGeometry(ControlId.RB, 437f, 69f, 23f),
            ControlGeometry(ControlId.DPAD, 63f, 147f, 47f),
            ControlGeometry(ControlId.LEFT_STICK, 174f, 178f, 48f),
            ControlGeometry(ControlId.RIGHT_STICK, 352f, 178f, 48f),
            ControlGeometry(ControlId.L3, 236f, 130f, 18f),
            ControlGeometry(ControlId.R3, 289f, 130f, 18f),
            ControlGeometry(ControlId.Y, 463f, 115f, 21f),
            ControlGeometry(ControlId.X, 431f, 147f, 21f),
            ControlGeometry(ControlId.B, 495f, 147f, 21f),
            ControlGeometry(ControlId.A, 463f, 179f, 21f),
            ControlGeometry(ControlId.VIEW, 210f, 60f, 18f),
            ControlGeometry(ControlId.SETTINGS, 263f, 60f, 18f),
            ControlGeometry(ControlId.MENU, 316f, 60f, 18f),
            ControlGeometry(ControlId.CLOSE, 263f, 14f, 12f),
        )

        fun fit(width: Float, height: Float, density: Float): ControllerLayout {
            if (width <= 0f || height <= 0f || density <= 0f ||
                !width.isFinite() || !height.isFinite() || !density.isFinite()
            ) return ControllerLayout(emptyList(), false)
            val scale = min(width / 566f, height / 277f)
            val left = (width - 566f * scale) / 2f
            val top = (height - 277f * scale) / 2f
            val controls = reference.map {
                it.copy(
                    x = left + (it.x + 20f) * scale,
                    y = top + (it.y + 20f) * scale,
                    radius = it.radius * scale,
                    touchRadius = max(it.radius * scale, 24f * density),
                )
            }
            val inside = controls.all {
                it.x - it.touchRadius >= 0 && it.x + it.touchRadius <= width &&
                    it.y - it.touchRadius >= 0 && it.y + it.touchRadius <= height
            }
            val separated = controls.indices.all { i ->
                (i + 1 until controls.size).all { j ->
                    val a = controls[i]
                    val b = controls[j]
                    hypot(a.x - b.x, a.y - b.y) >= a.touchRadius + b.touchRadius
                }
            }
            return ControllerLayout(controls, inside && separated)
        }
    }
}
