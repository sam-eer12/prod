package com.padlink.controller.ui

import com.padlink.controller.ui.screens.controller.*
import org.junit.Assert.*
import org.junit.Test

class ControllerLayoutProfileTest {
    private val reference = ControllerLayout.fit(900f, 400f, 1f)

    @Test fun movedAndResizedControlsShareDrawingAndHitGeometry() {
        val stick = reference[ControlId.LEFT_STICK]
        val profile = ControllerLayoutProfile().with(ControlId.LEFT_STICK,
            ControlPlacement((stick.x - 10f) / 900f, (stick.y - 10f) / 400f, 0.8f))
        val fitted = ControllerLayout.fit(900f, 400f, 1f, profile)
        val moved = fitted[ControlId.LEFT_STICK]
        assertTrue(fitted.usable)
        assertEquals(stick.x - 10f, moved.x, 0.001f)
        assertEquals(stick.radius * 0.8f, moved.radius, 0.001f)
        assertEquals(stick.capRadius * 0.8f, moved.capRadius, 0.001f)
        assertEquals(stick.travel * 0.8f, moved.travel, 0.001f)
        assertEquals(ControlId.LEFT_STICK, fitted.hitTest(moved.x, moved.y)?.id)
        assertEquals(reference[ControlId.SETTINGS], fitted[ControlId.SETTINGS])
        assertEquals(reference[ControlId.CLOSE], fitted[ControlId.CLOSE])
    }

    @Test fun overlapsAndOffscreenTouchTargetsCannotBeUsed() {
        val b = reference[ControlId.B]
        val overlap = ControllerLayoutProfile().with(ControlId.A, ControlPlacement(b.x / 900f, b.y / 400f, 1f))
        assertFalse(ControllerLayout.fit(900f, 400f, 1f, overlap).usable)
        val offscreen = ControllerLayoutProfile().with(ControlId.A, ControlPlacement(0f, 0f, 1f))
        assertFalse(ControllerLayout.fit(900f, 400f, 1f, offscreen).usable)
        val smaller = ControllerLayoutProfile().with(ControlId.A, ControlPlacement(
            reference[ControlId.A].x / 900f, reference[ControlId.A].y / 400f, 0.65f))
        assertTrue(ControllerLayout.fit(900f, 400f, 1f, smaller)[ControlId.A].touchRadius >= 24f)
    }

    @Test fun profilesRoundTripWithoutChangingDefaults() {
        val defaults = ControllerLayoutProfile()
        val profile = defaults.with(ControlId.LT, ControlPlacement(0.1f, 0.2f, 1.2f))
            .with(ControlId.A, ControlPlacement(0.8f, 0.7f, 0.9f))
        assertEquals(profile, ControllerLayoutProfile.decode(profile.encode()))
        assertEquals(defaults, ControllerLayoutProfile.decode("1"))
        assertTrue(defaults.placements.isEmpty())
    }

    @Test fun malformedAndUnsafeSavedProfilesAreRejected() {
        for (value in listOf("", "2", "1|A,NaN,0.5,1", "1|A,0.5,Infinity,1", "1|A,0.5,0.5,0.1",
            "1|A,-0.1,0.5,1", "1|A,0.5,0.5,1|A,0.6,0.5,1", "1|SETTINGS,0.5,0.5,1",
            "1|CLOSE,0.5,0.5,1", "1|UNKNOWN,0.5,0.5,1", "1|A,0.5,0.5", "1|")) {
            assertNull(value, ControllerLayoutProfile.decode(value))
        }
        assertNull(ControllerLayoutProfile.decode("1".repeat(4097)))
    }
}
