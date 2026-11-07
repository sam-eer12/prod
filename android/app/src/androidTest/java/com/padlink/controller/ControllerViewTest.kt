package com.padlink.controller

import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.core.graphics.ColorUtils
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.padlink.controller.ui.screens.controller.ControlId
import com.padlink.controller.ui.screens.controller.ControllerPreferences
import com.padlink.controller.ui.screens.controller.ControllerState
import com.padlink.controller.ui.screens.controller.ControllerView
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class ControllerViewTest {
    @get:Rule val composeRule = createAndroidComposeRule<MainActivity>()

    private fun findController(view: View): ControllerView? {
        if (view is ControllerView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) {
            findController(view.getChildAt(i))?.let { return it }
        }
        return null
    }

    private fun openController(): ControllerView {
        composeRule.onNodeWithText("Try controller").performScrollTo().performClick()
        var surface: ControllerView? = null
        composeRule.waitUntil(15_000) {
            composeRule.runOnUiThread { surface = findController(composeRule.activity.window.decorView) }
            surface?.controllerLayout?.usable == true
        }
        return requireNotNull(surface)
    }

    private data class Finger(val id: Int, val x: Float, val y: Float)

    private fun touch(surface: ControllerView, action: Int, vararg fingers: Finger) {
        val now = SystemClock.uptimeMillis()
        val properties = fingers.map { finger -> MotionEvent.PointerProperties().apply {
            id = finger.id
            toolType = MotionEvent.TOOL_TYPE_FINGER
        } }.toTypedArray()
        val coordinates = fingers.map { finger -> MotionEvent.PointerCoords().apply {
            x = finger.x
            y = finger.y
            pressure = 1f
            size = 1f
        } }.toTypedArray()
        val event = MotionEvent.obtain(now, now, action, fingers.size, properties, coordinates,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0)
        try { assertTrue(surface.dispatchTouchEvent(event)) } finally { event.recycle() }
    }

    private fun render(surface: ControllerView, name: String? = null): Bitmap {
        val bitmap = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
        surface.draw(Canvas(bitmap))
        if (name != null) {
            val directory = requireNotNull(surface.context.getExternalFilesDir("controller-tests"))
            File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        }
        return bitmap
    }

    @Test
    fun simultaneousStickAndButtonReleaseIndependentlyAndCancelToNeutral() {
        val surface = openController()
        composeRule.runOnUiThread {
            surface.hapticsEnabled = false
            val stick = surface.controllerLayout[ControlId.LEFT_STICK]
            val a = surface.controllerLayout[ControlId.A]
            val left = Finger(7, stick.x, stick.y)
            val button = Finger(19, a.x, a.y)
            touch(surface, MotionEvent.ACTION_DOWN, left)
            touch(surface, MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), left, button)
            val dragged = left.copy(x = stick.x + 2000, y = stick.y - 2000)
            touch(surface, MotionEvent.ACTION_MOVE, dragged, button)
            assertEquals(1f, surface.currentState.leftStick.magnitude, 0.001f)
            assertEquals(ControlId.A.mask, surface.currentState.buttons)
            render(surface, "dragged").recycle()
            touch(surface, MotionEvent.ACTION_POINTER_UP, dragged, button)
            assertEquals(0f, surface.currentState.leftStick.magnitude, 0f)
            assertEquals(ControlId.A.mask, surface.currentState.buttons)
            touch(surface, MotionEvent.ACTION_CANCEL, button)
            assertEquals(ControllerState(), surface.currentState)
        }
    }

    @Test
    fun pressingButtonDarkensItsFaceAndFocusLossClearsHeldInput() {
        val surface = openController()
        composeRule.runOnUiThread {
            surface.hapticsEnabled = false
            val button = surface.controllerLayout[ControlId.B]
            val sampleX = (button.x + button.radius * 0.48f).toInt()
            val sampleY = (button.y + button.radius * 0.3f).toInt()
            val idle = render(surface, "idle")
            touch(surface, MotionEvent.ACTION_DOWN, Finger(3, button.x, button.y))
            val pressed = render(surface, "pressed")
            assertTrue(ColorUtils.calculateLuminance(pressed.getPixel(sampleX, sampleY)) <
                ColorUtils.calculateLuminance(idle.getPixel(sampleX, sampleY)) * 0.65)
            assertEquals(ControlId.B.mask, surface.currentState.buttons)
            surface.onWindowFocusChanged(false)
            assertEquals(ControllerState(), surface.currentState)
            idle.recycle()
            pressed.recycle()
        }
    }

    @Test
    fun gearClearsTouchesAndSettingsReturnsToController() {
        val surface = openController()
        var lastState = ControllerState()
        composeRule.runOnUiThread {
            surface.hapticsEnabled = false
            surface.onInputChanged = { lastState = it }
            val stick = surface.controllerLayout[ControlId.LEFT_STICK]
            val gear = surface.controllerLayout[ControlId.SETTINGS]
            val left = Finger(7, stick.x + stick.travel, stick.y)
            val settings = Finger(19, gear.x, gear.y)
            touch(surface, MotionEvent.ACTION_DOWN, left)
            touch(surface, MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), left, settings)
            touch(surface, MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT), left, settings)
            assertEquals(ControllerState(), lastState)
        }
        composeRule.onNodeWithText("Touch feedback").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Touch feedback").performClick()
        composeRule.onNodeWithContentDescription("Back").performClick()
        composeRule.onNodeWithText("Local controller · Touch feedback off").assertIsDisplayed()
        composeRule.runOnUiThread {
            val returned = requireNotNull(findController(composeRule.activity.window.decorView))
            assertFalse(returned.hapticsEnabled)
            assertEquals(ControllerState(), returned.currentState)
            val close = returned.controllerLayout[ControlId.CLOSE]
            val finger = Finger(2, close.x, close.y)
            touch(returned, MotionEvent.ACTION_DOWN, finger)
            touch(returned, MotionEvent.ACTION_UP, finger)
            ControllerPreferences.setHapticsEnabled(composeRule.activity, true)
        }
        composeRule.onNodeWithText("PadLink").assertIsDisplayed()
    }
}
