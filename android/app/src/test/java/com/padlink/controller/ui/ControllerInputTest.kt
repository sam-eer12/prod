package com.padlink.controller.ui

import com.padlink.controller.ui.screens.controller.ControlId
import com.padlink.controller.ui.screens.controller.ControllerInput
import com.padlink.controller.ui.screens.controller.ControllerLayout
import com.padlink.controller.ui.screens.controller.ControllerState
import com.padlink.controller.ui.screens.controller.StickPosition
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

class ControllerInputTest {
    private val layout = ControllerLayout.fit(900f, 400f, 1f)

    @Test
    fun fullCapStaysInsideOuterRingForEveryDragDirection() {
        val input = ControllerInput()
        val stick = layout[ControlId.LEFT_STICK]
        assertTrue(input.press(7, stick, stick.x, stick.y))
        for (angle in 0 until 360) {
            val radians = Math.toRadians(angle.toDouble())
            input.move(7, stick.x + cos(radians).toFloat() * 10_000, stick.y + sin(radians).toFloat() * 10_000)
            val position = input.state.leftStick
            assertEquals(1f, position.magnitude, 0.0001f)
            assertTrue(hypot(position.x * stick.travel, position.y * stick.travel) + stick.capRadius < stick.radius)
        }
        input.release(7)
        assertEquals(StickPosition(), input.state.leftStick)
    }

    @Test
    fun independentPointersKeepOtherControlsHeldOnRelease() {
        val input = ControllerInput()
        val left = layout[ControlId.LEFT_STICK]
        val right = layout[ControlId.RIGHT_STICK]
        val a = layout[ControlId.A]
        input.press(42, left, left.x + left.travel, left.y)
        input.press(3, right, right.x, right.y - right.travel)
        input.press(19, a, a.x, a.y)
        assertEquals(1, input.state.buttons)
        assertEquals(1f, input.state.leftStick.x, 0.001f)
        assertEquals(-1f, input.state.rightStick.y, 0.001f)
        input.release(42)
        assertEquals(StickPosition(), input.state.leftStick)
        assertEquals(-1f, input.state.rightStick.y, 0.001f)
        assertEquals(1, input.state.buttons)
        input.reset()
        assertEquals(ControllerState(), input.state)
    }

    @Test
    fun secondFingerCannotStealStickAndButtonsReleaseOutsideTheirBounds() {
        val input = ControllerInput()
        val stick = layout[ControlId.LEFT_STICK]
        input.press(11, stick, stick.x, stick.y)
        assertFalse(input.press(9, stick, stick.x + stick.travel, stick.y))
        input.release(9)
        assertEquals(ControlId.LEFT_STICK, input.controlFor(11))
        val button = layout[ControlId.B]
        input.press(2, button, button.x, button.y)
        assertEquals(ControlId.B.mask, input.state.buttons)
        input.move(2, 0f, 0f)
        assertEquals(0, input.state.buttons)
        input.move(2, button.x, button.y)
        assertEquals(ControlId.B.mask, input.state.buttons)
        input.release(2)
        assertEquals(0, input.state.buttons)
    }

    @Test
    fun triggerTapIsFullPullAndDragFeathersUntilRelease() {
        val input = ControllerInput()
        val trigger = layout[ControlId.LT]
        input.press(4, trigger, trigger.x, trigger.y)
        assertEquals(1f, input.state.leftTrigger, 0f)
        input.move(4, trigger.x, trigger.y + trigger.radius)
        assertEquals(0.5f, input.state.leftTrigger, 0.001f)
        input.move(4, trigger.x, trigger.y + trigger.radius * 4)
        assertEquals(0f, input.state.leftTrigger, 0f)
        input.release(4)
        assertEquals(ControllerState(), input.state)
    }

    @Test
    fun dpadSupportsEightDirectionsAndNeutralCenter() {
        val up = 1 shl 11
        val down = 1 shl 12
        val left = 1 shl 13
        val right = 1 shl 14
        val samples = listOf(Triple(0f, -1f, up), Triple(1f, -1f, up or right),
            Triple(1f, 0f, right), Triple(1f, 1f, down or right), Triple(0f, 1f, down),
            Triple(-1f, 1f, down or left), Triple(-1f, 0f, left), Triple(-1f, -1f, up or left))
        samples.forEach { (x, y, expected) -> assertEquals(expected, ControllerInput.dpadDirections(x, y)) }
        assertEquals(0, ControllerInput.dpadDirections(0.1f, 0.1f))
        assertEquals(0, ControllerInput.dpadDirections(Float.NaN, 0f))
    }

    @Test
    fun referenceLayoutKeepsTouchTargetsUsableAndRejectsSmallWindows() {
        for ((width, height, density) in listOf(Triple(900f, 400f, 1f), Triple(2424f, 1000f, 2.75f), Triple(1800f, 800f, 2f))) {
            val fitted = ControllerLayout.fit(width, height, density)
            assertTrue("Layout $width x $height at $density", fitted.usable)
            fitted.controls.forEach { control ->
                assertTrue(control.touchRadius >= 24 * density)
                assertEquals(control.id, fitted.hitTest(control.x, control.y)?.id)
            }
        }
        assertFalse(ControllerLayout.fit(320f, 220f, 1f).usable)
        assertNull(ControllerLayout.fit(320f, 220f, 1f).hitTest(100f, 100f))
        assertFalse(ControllerLayout.fit(Float.NaN, 220f, 1f).usable)
    }
}
