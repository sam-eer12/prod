package com.padlink.controller.ui

import com.padlink.controller.ui.screens.controller.ControlId
import com.padlink.controller.ui.screens.controller.ControllerHapticPolicy
import com.padlink.controller.ui.screens.controller.StickPosition
import org.junit.Assert.*
import org.junit.Test

class ControllerHapticPolicyTest {
    @Test
    fun movementRisesFromLowToMediumAndButtonsAreStronger() {
        val policy = ControllerHapticPolicy()
        val light = requireNotNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.1f, 0f), 100))
        val edge = requireNotNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(1f, 0f), 150))
        val button = policy.buttonPress(151)
        assertEquals(82, light.amplitude)
        assertEquals(140, edge.amplitude)
        assertEquals(170, button.amplitude)
        assertEquals(16L, light.durationMs)
        assertEquals(35L, button.durationMs)
        assertTrue(light.amplitude < edge.amplitude && edge.amplitude < button.amplitude)
    }

    @Test
    fun stationarySticksAndTinyJitterDoNotVibrate() {
        val policy = ControllerHapticPolicy()
        assertNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(), 100))
        assertNotNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.5f, 0f), 200))
        assertNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.5f, 0f), 500))
        assertNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.52f, 0.01f), 800))
    }

    @Test
    fun bothSticksShareRateLimitAndCannotReplaceButtonPulse() {
        val policy = ControllerHapticPolicy()
        assertNotNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.5f, 0f), 100))
        assertNull(policy.stickMoved(ControlId.RIGHT_STICK, StickPosition(0.5f, 0f), 120))
        policy.buttonPress(140)
        assertNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(1f, 0f), 150))
        assertNotNull(policy.stickMoved(ControlId.RIGHT_STICK, StickPosition(0.5f, 0f), 190))
        policy.releaseStick(ControlId.RIGHT_STICK)
        assertNotNull(policy.stickMoved(ControlId.RIGHT_STICK, StickPosition(0.5f, 0f), 240))
        policy.reset()
        assertNotNull(policy.stickMoved(ControlId.LEFT_STICK, StickPosition(0.5f, 0f), 250))
    }
}
