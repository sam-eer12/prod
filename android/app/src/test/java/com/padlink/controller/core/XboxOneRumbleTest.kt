package com.padlink.controller.core

import org.junit.Assert.*
import org.junit.Test

class XboxOneRumbleTest {
    @Test
    fun acceptsSdlsBluetoothRumblePacketWithoutDuplicatingTheId() {
        val rumble = XboxOneRumble.parse(byteArrayOf(0x0f, 0, 0, 100, 50, -1, 0, -21))!!
        assertEquals(100, rumble.magnitude)
        assertEquals(2550L, rumble.durationMs)
        assertEquals(0L, rumble.delayMs)
        assertEquals(235, rumble.repeats)
        assertNull(XboxOneRumble.parse(ByteArray(7)))
        assertNull(XboxOneRumble.parse(byteArrayOf(3, 0x0f, 0, 0, 100, 50, -1, 0, -21)))
    }

    @Test
    fun enableMaskUsesXboxMotorOrderAndDisabledMotorsDoNotContribute() {
        listOf(8 to 10, 4 to 20, 2 to 30, 1 to 40, 0 to 0, 15 to 40).forEach { (mask, expected) ->
            assertEquals(expected, XboxOneRumble.parse(byteArrayOf(mask.toByte(), 10, 20, 30, 40, 1, 0, 0))!!.magnitude)
        }
        assertEquals(100, XboxOneRumble.parse(byteArrayOf(1, 0, 0, 0, -1, 1, 0, 0))!!.magnitude)
    }

    @Test
    fun delayDurationAndLoopsProduceAFiniteWaveformAndZeroCommandStops() {
        val rumble = XboxOneRumble.parse(byteArrayOf(1, 0, 0, 0, 50, 20, 5, 2))!!
        assertArrayEquals(longArrayOf(50, 200, 50, 200, 50, 200), rumble.timings())
        val stopped = XboxOneRumble.parse(ByteArray(8))!!
        assertEquals(0, stopped.magnitude); assertEquals(0L, stopped.durationMs)
    }
}
