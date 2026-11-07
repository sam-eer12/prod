package com.padlink.controller.ui.screens.controller

import kotlin.math.abs
import kotlin.math.hypot

data class StickPosition(val x: Float = 0f, val y: Float = 0f) {
    val magnitude: Float get() = hypot(x, y)

    companion object {
        fun clamped(x: Float, y: Float): StickPosition {
            if (!x.isFinite() || !y.isFinite()) return StickPosition()
            val length = hypot(x, y)
            return if (length > 1f) StickPosition(x / length, y / length) else StickPosition(x, y)
        }
    }
}

/** Touch state consumed directly by the controller sender without Compose per-frame work. */
data class ControllerState(
    val buttons: Int = 0,
    val leftStick: StickPosition = StickPosition(),
    val rightStick: StickPosition = StickPosition(),
    val leftTrigger: Float = 0f,
    val rightTrigger: Float = 0f,
)

class ControllerInput {
    private data class Touch(
        val control: ControlGeometry,
        val startY: Float,
        var active: Boolean = true,
        var stick: StickPosition = StickPosition(),
        var trigger: Float = 0f,
        var directions: Int = 0,
    )

    private val touches = mutableMapOf<Int, Touch>()
    val state: ControllerState
        get() {
            var buttons = 0
            var left = StickPosition()
            var right = StickPosition()
            var lt = 0f
            var rt = 0f
            touches.values.forEach {
                if (it.active) buttons = buttons or it.control.id.mask or it.directions
                when (it.control.id) {
                    ControlId.LEFT_STICK -> left = it.stick
                    ControlId.RIGHT_STICK -> right = it.stick
                    ControlId.LT -> lt = it.trigger
                    ControlId.RT -> rt = it.trigger
                    else -> Unit
                }
            }
            return ControllerState(buttons, left, right, lt, rt)
        }

    fun controlFor(pointerId: Int): ControlId? = touches[pointerId]?.control?.id
    fun isPressed(id: ControlId): Boolean = touches.values.any { it.control.id == id && it.active }

    fun press(pointerId: Int, control: ControlGeometry, x: Float, y: Float): Boolean {
        // One pointer owns a control until release; a second finger cannot steal a stick.
        if (pointerId in touches || touches.values.any { it.control.id == control.id }) return false
        touches[pointerId] = Touch(control, y)
        move(pointerId, x, y)
        return true
    }

    fun move(pointerId: Int, x: Float, y: Float) {
        val touch = touches[pointerId] ?: return
        val control = touch.control
        when (control.id.kind) {
            ControlKind.STICK -> touch.stick = StickPosition.clamped(
                (x - control.x) / control.travel,
                (y - control.y) / control.travel,
            )
            // A tap is full pull. Drag down by one diameter to feather toward zero.
            ControlKind.TRIGGER -> touch.trigger =
                (1f - (y - touch.startY) / (control.radius * 2f)).coerceIn(0f, 1f)
            ControlKind.DPAD -> touch.directions = dpadDirections(
                (x - control.x) / control.radius,
                (y - control.y) / control.radius,
            )
            ControlKind.BUTTON, ControlKind.ACTION -> touch.active = control.contains(x, y)
        }
    }

    fun release(pointerId: Int) { touches.remove(pointerId) }
    fun reset() { touches.clear() }

    companion object {
        // Eight sectors with a neutral center; diagonals set two protocol direction bits.
        fun dpadDirections(x: Float, y: Float): Int {
            if (!x.isFinite() || !y.isFinite() || hypot(x, y) < 0.22f) return 0
            var bits = 0
            val diagonalBoundary = 0.41421357f // tan(22.5 degrees)
            if (abs(x) >= abs(y) * diagonalBoundary) bits = bits or if (x < 0) 1 shl 13 else 1 shl 14
            if (abs(y) >= abs(x) * diagonalBoundary) bits = bits or if (y < 0) 1 shl 11 else 1 shl 12
            return bits
        }
    }
}
