package com.padlink.controller.core

import com.padlink.controller.ui.screens.controller.ControllerState
import com.padlink.controller.ui.screens.controller.StickPosition
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class ControllerReportsTest {
    @Test
    fun neutralReportReleasesEveryControlWithANullHat() {
        assertArrayEquals(byteArrayOf(0,0,8,0,0,0,0,0,0,0,0,0,0), ControllerReports.bluetooth(ControllerState()))
    }

    @Test
    fun everyGamepadButtonUsesItsOwnHidButtonBit() {
        for (bit in 0..10) {
            val report = ByteBuffer.wrap(ControllerReports.bluetooth(ControllerState(buttons = 1 shl bit))).order(ByteOrder.LITTLE_ENDIAN)
            assertEquals(1 shl bit, report.short.toInt() and 0xffff)
        }
        val reserved = ByteBuffer.wrap(ControllerReports.bluetooth(ControllerState(buttons = 1 shl 15))).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0, reserved.short.toInt())
    }

    @Test
    fun dpadUsesEightDirectionsAndCancelsOppositePresses() {
        val up = 1 shl 11; val down = 1 shl 12; val left = 1 shl 13; val right = 1 shl 14
        val cases = listOf(0 to 8, up to 0, (up or right) to 1, right to 2, (down or right) to 3,
            down to 4, (down or left) to 5, left to 6, (up or left) to 7,
            (up or down or left or right) to 8)
        cases.forEach { (buttons, hat) ->
            val report = ControllerReports.bluetooth(ControllerState(buttons = buttons))
            assertEquals(hat, report[2].toInt())
            assertEquals(0, report[0].toInt())
            assertEquals(0, report[1].toInt())
        }
    }

    @Test
    fun sticksAndTriggersRetainIndependentFullAnalogRanges() {
        val report = ByteBuffer.wrap(ControllerReports.bluetooth(ControllerState(
            leftStick = StickPosition(-1f, 1f), rightStick = StickPosition(0.5f, -0.5f),
            leftTrigger = 0f, rightTrigger = 1f,
        ))).order(ByteOrder.LITTLE_ENDIAN)
        report.position(3)
        assertEquals(-32768, report.short.toInt())
        assertEquals(32767, report.short.toInt())
        assertEquals(16384, report.short.toInt())
        assertEquals(-16384, report.short.toInt())
        assertEquals(0, report.get().toInt() and 0xff)
        assertEquals(255, report.get().toInt() and 0xff)
    }

    @Test
    fun nonFiniteValuesBecomeNeutralAndOutOfRangeValuesAreClamped() {
        val invalid = ControllerReports.bluetooth(ControllerState(
            leftStick = StickPosition(Float.NaN, Float.POSITIVE_INFINITY),
            rightStick = StickPosition(Float.NEGATIVE_INFINITY, Float.NaN),
            leftTrigger = Float.NaN, rightTrigger = Float.POSITIVE_INFINITY,
        ))
        assertArrayEquals(ControllerReports.bluetooth(ControllerState()), invalid)
        val clamped = ByteBuffer.wrap(ControllerReports.bluetooth(ControllerState(
            leftStick = StickPosition(-2f, 2f), leftTrigger = -1f, rightTrigger = 2f,
        ))).order(ByteOrder.LITTLE_ENDIAN)
        clamped.position(3)
        assertEquals(-32768, clamped.short.toInt()); assertEquals(32767, clamped.short.toInt())
        assertEquals(0, clamped.get(11).toInt() and 0xff); assertEquals(255, clamped.get(12).toInt() and 0xff)
    }

    @Test
    fun descriptorDeclaresExactlyOneGamepadAndOnlyThirteenBytesOfInput() {
        val bytes = ControllerReports.descriptor
        var offset = 0; var page = 0; var usage = 0; var size = 0; var count = 0
        var inputBits = 0; var applications = 0; var depth = 0
        while (offset < bytes.size) {
            val prefix = bytes[offset++].toInt() and 0xff
            assertNotEquals("Long HID items are unnecessary", 0xfe, prefix)
            val length = when (prefix and 3) { 3 -> 4; else -> prefix and 3 }
            var value = 0
            repeat(length) { index -> value = value or ((bytes[offset++].toInt() and 0xff) shl (8 * index)) }
            val type = (prefix shr 2) and 3; val tag = prefix shr 4
            if (type == 1) when (tag) {
                0 -> { page = value; assertTrue("Only Desktop and Button usages are allowed", page == 1 || page == 9) }
                7 -> size = value
                8 -> assertEquals("A numbered input report is required for host compatibility", ControllerReports.REPORT_ID, value)
                9 -> count = value
            }
            if (type == 2 && tag == 0) usage = value
            if (type == 0) when (tag) {
                8 -> inputBits += size * count
                9, 11 -> fail("No output or feature reports are declared")
                10 -> { if (value == 1) { applications++; assertEquals(1, page); assertEquals(5, usage) }; depth++ }
                12 -> depth--
            }
        }
        assertEquals(1, applications); assertEquals(0, depth)
        assertEquals(ControllerReports.REPORT_SIZE * 8, inputBits)
    }
}
