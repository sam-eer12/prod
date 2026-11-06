package com.padlink.controller

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import android.os.SystemClock
import com.padlink.controller.core.PairingViewModel
import com.padlink.controller.core.PairingPhase
import com.padlink.controller.core.NativeCore
import com.padlink.controller.core.wifiPairingEndpoint
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun homeScreenRendersAppName() {
        composeRule.onNodeWithText("PadLink").assertIsDisplayed()
    }

    @Test
    fun realConsentButtonIssuesTokenAndBackgroundingStopsListener() {
        val model = ViewModelProvider(composeRule.activity)[PairingViewModel::class.java]
        model.start(requireNotNull(wifiPairingEndpoint(composeRule.activity)))
        composeRule.waitUntil(10_000) { model.state.value.phase == PairingPhase.LISTENING }
        val endpoint = model.state.value.endpoint
        val client = NativeCore.create(2, "$endpoint\nConsent UI test".toByteArray(), SystemClock.elapsedRealtime())
        try {
            val deadline = SystemClock.elapsedRealtime() + 10_000
            while (model.state.value.phase != PairingPhase.CONSENT && SystemClock.elapsedRealtime() < deadline) {
                NativeCore.call(client, 20, 0, byteArrayOf(), SystemClock.elapsedRealtime())
                Thread.sleep(10)
            }
            composeRule.onNodeWithText("Allow").performClick()
            composeRule.waitUntil(5000) { model.state.value.phase == PairingPhase.TOKEN }
            org.junit.Assert.assertEquals(6, model.state.value.code.length)
            composeRule.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            composeRule.waitUntil(5000) { model.state.value.phase == PairingPhase.STOPPED }
            org.junit.Assert.assertEquals("", model.state.value.code)
        } finally { NativeCore.close(client); model.stop() }
    }
}
