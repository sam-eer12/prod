package com.padlink.controller

import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.Lifecycle
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.padlink.controller.ui.screens.controller.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LayoutEditorTest {
    @get:Rule val rule = createAndroidComposeRule<MainActivity>()

    @Before fun resetPreferences() { ControllerLayoutPreferences.save(rule.activity, ControllerLayoutProfile()) }
    @After fun restorePreferences() { ControllerLayoutPreferences.save(rule.activity, ControllerLayoutProfile()) }

    private fun findSurface(view: View): ControllerView? {
        if (view is ControllerView) return view
        if (view is ViewGroup) for (i in 0 until view.childCount) findSurface(view.getChildAt(i))?.let { return it }
        return null
    }

    private fun surface(editing: Boolean): ControllerView {
        var result: ControllerView? = null
        rule.waitUntil(15_000) {
            rule.runOnUiThread { result = findSurface(rule.activity.window.decorView) }
            result?.editing == editing && result?.controllerLayout?.usable == true
        }
        return requireNotNull(result)
    }

    private fun openEditor(): ControllerView {
        rule.onNodeWithContentDescription("Settings").performClick()
        rule.onNodeWithText("Edit layout").performScrollTo().performClick()
        return surface(true)
    }

    private fun drag(view: ControllerView, id: ControlId, targetX: Float, targetY: Float) {
        val control = view.controllerLayout[id]
        val now = SystemClock.uptimeMillis()
        for ((action, x, y) in listOf(Triple(MotionEvent.ACTION_DOWN, control.x, control.y),
            Triple(MotionEvent.ACTION_MOVE, targetX, targetY), Triple(MotionEvent.ACTION_UP, targetX, targetY))) {
            val event = MotionEvent.obtain(now, SystemClock.uptimeMillis(), action, x, y, 0)
            try { assertTrue(view.dispatchTouchEvent(event)) } finally { event.recycle() }
        }
    }

    @Test fun dragAndResizeSavePersistAndCancelLeavesTheSavedLayoutIntact() {
        val editor = openEditor()
        var draft = ControllerLayoutProfile()
        rule.runOnUiThread {
            val stick = editor.controllerLayout[ControlId.LEFT_STICK]
            drag(editor, ControlId.LEFT_STICK, stick.x - 8f, stick.y - 8f)
            editor.adjustSelected(scale = 0.8f)
            draft = editor.layoutProfile
            assertTrue(editor.controllerLayout.usable)
            assertEquals(ControllerState(), editor.currentState)
        }
        rule.onNodeWithText("Save layout").performClick()
        assertEquals(draft, ControllerLayoutPreferences.load(rule.activity))
        rule.onNodeWithContentDescription("Back").performClick()
        rule.onNodeWithText("Try controller").performScrollTo().performClick()
        val gameplay = surface(false)
        rule.runOnUiThread {
            assertEquals(draft, gameplay.layoutProfile)
            assertEquals(ControllerLayout.fit(gameplay.width.toFloat(), gameplay.height.toFloat(),
                gameplay.resources.displayMetrics.density, draft).controls, gameplay.controllerLayout.controls)
            gameplay.onSettings()
        }
        rule.onNodeWithText("Edit layout").performScrollTo().performClick()
        val second = surface(true)
        rule.runOnUiThread { second.adjustSelected(dxDp = 4f) }
        rule.onNodeWithText("Cancel").performClick()
        assertEquals(draft, ControllerLayoutPreferences.load(rule.activity))
        rule.onNodeWithText("Edit layout").performScrollTo().performClick()
        surface(true)
        rule.onNodeWithText("Reset").performClick()
        rule.onNodeWithText("Save layout").performClick()
        assertTrue(ControllerLayoutPreferences.load(rule.activity).placements.isEmpty())
    }

    @Test fun overlapDisablesSaveAndEditingNeverEmitsGamepadPresses() {
        val editor = openEditor()
        var nonNeutral = 0
        rule.runOnUiThread {
            editor.onInputChanged = { if (it != ControllerState()) nonNeutral++ }
            val b = editor.controllerLayout[ControlId.B]
            drag(editor, ControlId.A, b.x, b.y)
            assertFalse(editor.controllerLayout.usable)
            assertEquals(ControllerState(), editor.currentState)
            assertEquals(0, nonNeutral)
        }
        rule.onNodeWithText("Save layout").assertIsNotEnabled()
        rule.onNodeWithText("Reset").performClick()
        rule.onNodeWithText("Save layout").performClick()
        assertTrue(ControllerLayoutPreferences.load(rule.activity).placements.isEmpty())
    }

    @Test fun editorDraftAndSelectedControlSurviveBackgroundAndActivityRecreation() {
        val editor = openEditor()
        var draft = ControllerLayoutProfile()
        rule.runOnUiThread {
            editor.selectedControl = ControlId.LEFT_STICK
            editor.adjustSelected(dxDp = -4f, scale = 0.8f)
            draft = editor.layoutProfile
        }
        rule.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        rule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        assertEquals(draft, surface(true).layoutProfile)
        rule.activityRule.scenario.recreate()
        val restored = surface(true)
        assertEquals(draft, restored.layoutProfile)
        assertEquals(ControllerState(), restored.currentState)
        rule.onNodeWithText("Cancel").performClick()
        assertTrue(ControllerLayoutPreferences.load(rule.activity).placements.isEmpty())
    }

    @Test fun controllerScreenReturnsNeutralAfterBackgroundAndRecreation() {
        rule.onNodeWithText("Try controller").performScrollTo().performClick()
        val controller = surface(false)
        rule.runOnUiThread {
            val a = controller.controllerLayout[ControlId.A]
            val event = MotionEvent.obtain(0, 0, MotionEvent.ACTION_DOWN, a.x, a.y, 0)
            try { controller.dispatchTouchEvent(event) } finally { event.recycle() }
            assertEquals(ControlId.A.mask, controller.currentState.buttons)
        }
        rule.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        assertEquals(ControllerState(), controller.currentState)
        rule.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        assertEquals(ControllerState(), surface(false).currentState)
        rule.activityRule.scenario.recreate()
        assertEquals(ControllerState(), surface(false).currentState)
    }

    @Test fun settingsExposeVibrationTestAndAccessibleLayoutAdjustments() {
        val editor = openEditor()
        rule.onNodeWithText("Adjust control").performClick()
        rule.runOnUiThread { editor.adjustSelected(scale = 1.1f) }
        rule.onNodeWithText("Done").performClick()
        assertTrue(editor.layoutProfile.placements.containsKey(ControlId.LEFT_STICK))
        rule.onNodeWithText("Cancel").performClick()
        rule.onNodeWithText("Test vibration").performScrollTo().assertIsDisplayed().performClick()
    }
}
