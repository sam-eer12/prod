package com.padlink.controller.ui.screens.controller

import kotlin.math.hypot
import kotlin.math.roundToInt

data class TouchPulse(val durationMs: Long, val amplitude: Int, val button: Boolean)

/** Separate timing policy makes stationary touches and pulse intensity verifiable. */
class ControllerHapticPolicy {
    private var lastPulseAt = -50L
    private val lastPositions = mutableMapOf<ControlId, StickPosition>()

    fun buttonPress(now: Long): TouchPulse {
        lastPulseAt = now
        return TouchPulse(18L, 128, button = true)
    }

    fun stickMoved(id: ControlId, position: StickPosition, now: Long): TouchPulse? {
        val previous = lastPositions[id] ?: StickPosition()
        if (hypot(position.x - previous.x, position.y - previous.y) < 0.07f) return null
        // Share the limit across both sticks; preserve a stronger button pulse.
        if (now - lastPulseAt < 50L) return null
        lastPulseAt = now
        lastPositions[id] = position
        return TouchPulse(8L, (50 + 60 * position.magnitude.coerceIn(0f, 1f)).roundToInt(), button = false)
    }

    fun releaseStick(id: ControlId) { lastPositions.remove(id) }

    fun reset() {
        lastPositions.clear()
        lastPulseAt = -50L
    }
}
