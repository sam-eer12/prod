package com.padlink.controller.core

import com.padlink.controller.ui.screens.controller.ControllerState
import com.padlink.controller.ui.screens.controller.StickPosition
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.*
import org.junit.Test

class XboxOneReportsTest {
    @Test
    fun descriptorMatchesCapturedCompactXboxOneSBluetoothDescriptor() {
        val hex = javaClass.getResource("/xbox_one_s_windows.hex")!!.readText()
        val reference = hex.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
        assertEquals(306, reference.size)
        assertArrayEquals(reference, XboxOneReports.descriptor)
    }

    @Test
    fun descriptorAndEveryPacketAgreeOnReportIdsSizesRangesAndCollections() {
        val fields = descriptorFields(XboxOneReports.descriptor)
        val inputBits = fields.filter { it.type == 8 }.groupBy { it.id }.mapValues { (_, fields) -> fields.sumOf { it.size * it.count } }
        val outputBits = fields.filter { it.type == 9 }.groupBy { it.id }.mapValues { (_, fields) -> fields.sumOf { it.size * it.count } }
        assertEquals(mapOf(1 to 120, 2 to 8, 4 to 8), inputBits)
        assertEquals(mapOf(3 to 64), outputBits)
        assertTrue(fields.none { it.type == 11 })
        val stickFields = fields.filter { it.id == 1 && it.count == 2 && it.size == 16 }
        assertEquals(listOf(listOf(0x30, 0x31), listOf(0x33, 0x34)), stickFields.map { it.usages })
        stickFields.forEach { assertEquals(0, it.min); assertEquals(65535, it.max) }
        val triggerFields = fields.filter { it.id == 1 && it.size == 10 }
        assertEquals(listOf(listOf(0x32), listOf(0x35)), triggerFields.map { it.usages })
        triggerFields.forEach { assertEquals(0, it.min); assertEquals(1023, it.max) }
        val hat = fields.single { it.usages == listOf(0x39) }
        assertEquals(1, hat.min); assertEquals(8, hat.max); assertEquals(0x42, hat.flags)
        val buttons = fields.single { it.page == 9 && it.flags and 1 == 0 }
        assertEquals(10, buttons.count); assertEquals(1, buttons.size)
        val guide = fields.single { it.usages == listOf(0x85) }
        assertEquals(2, guide.id); assertEquals(1, guide.size)
        val battery = fields.single { it.page == 6 }
        assertEquals(4, battery.id); assertEquals(8, battery.size)
        assertEquals(15, XboxOneReports.input(ControllerState()).size)
        assertEquals(1, XboxOneReports.guide(ControllerState()).size)
        assertEquals(1, XboxOneReports.battery(50, false).size)
    }

    @Test
    fun neutralInputContainsCenteredUnsignedSticksReleasedTriggersAndNullHat() {
        assertArrayEquals(byteArrayOf(0, -128, 0, -128, 0, -128, 0, -128, 0, 0, 0, 0, 0, 0, 0),
            XboxOneReports.input(ControllerState()))
        assertArrayEquals(byteArrayOf(0), XboxOneReports.guide(ControllerState()))
    }

    @Test
    fun mainButtonBitmapMatchesSdlsOriginalSixteenByteBluetoothParser() {
        val mapping = mapOf(0 to 0, 1 to 1, 2 to 2, 3 to 3, 4 to 4, 5 to 5, 6 to 6, 7 to 7, 9 to 8, 10 to 9)
        mapping.forEach { (internalBit, xboxBit) ->
            val bytes = XboxOneReports.input(ControllerState(buttons = 1 shl internalBit))
            assertEquals(1 shl xboxBit, (bytes[13].toInt() and 0xff) or ((bytes[14].toInt() and 0xff) shl 8))
        }
        assertArrayEquals(XboxOneReports.input(ControllerState()), XboxOneReports.input(ControllerState(buttons = (1 shl 8) or (1 shl 15))))
        assertArrayEquals(byteArrayOf(1), XboxOneReports.guide(ControllerState(buttons = 1 shl 8)))
    }

    @Test
    fun allEightHatDirectionsAreOneBasedAndOppositesCancel() {
        val up = 1 shl 11; val down = 1 shl 12; val left = 1 shl 13; val right = 1 shl 14
        listOf(0 to 0, up to 1, (up or right) to 2, right to 3, (right or down) to 4,
            down to 5, (down or left) to 6, left to 7, (left or up) to 8,
            (up or down) to 0, (left or right) to 0, (up or down or left or right) to 0).forEach { (buttons, expected) ->
            assertEquals(expected, XboxOneReports.input(ControllerState(buttons = buttons))[12].toInt())
        }
    }

    @Test
    fun stickAndTriggerExtremesAndPaddingMatchWireProtocol() {
        val buffer = ByteBuffer.wrap(XboxOneReports.input(ControllerState(
            leftStick = StickPosition(-1f, 1f), rightStick = StickPosition(0.5f, -0.5f),
            leftTrigger = 0.5f, rightTrigger = 1f,
        ))).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(0, buffer.short.toInt() and 0xffff)
        assertEquals(65535, buffer.short.toInt() and 0xffff)
        assertEquals(49152, buffer.short.toInt() and 0xffff)
        assertEquals(16384, buffer.short.toInt() and 0xffff)
        assertEquals(512, buffer.short.toInt() and 0xffff)
        assertEquals(1023, buffer.short.toInt() and 0xffff)
        assertEquals(0, buffer.get().toInt())
        assertEquals(0, buffer.short.toInt())
    }

    @Test
    fun invalidFloatsBecomeNeutralAndFiniteValuesAreClamped() {
        assertArrayEquals(XboxOneReports.input(ControllerState()), XboxOneReports.input(ControllerState(
            leftStick = StickPosition(Float.NaN, Float.POSITIVE_INFINITY),
            rightStick = StickPosition(Float.NEGATIVE_INFINITY, Float.NaN),
            leftTrigger = Float.NaN, rightTrigger = Float.POSITIVE_INFINITY,
        )))
        assertArrayEquals(XboxOneReports.input(ControllerState(
            leftStick = StickPosition(-1f, 1f), leftTrigger = 0f, rightTrigger = 1f,
        )), XboxOneReports.input(ControllerState(
            leftStick = StickPosition(-2f, 2f), leftTrigger = -2f, rightTrigger = 2f,
        )))
    }

    @Test
    fun batteryContainsXboxLevelAndPowerSourceFlagsInsteadOfPercentage() {
        for ((percent, level) in listOf(-1 to 0, 10 to 0, 11 to 1, 40 to 1, 41 to 2, 70 to 2, 71 to 3, 101 to 3)) {
            assertArrayEquals(byteArrayOf((level or 4).toByte()), XboxOneReports.battery(percent, false))
            assertArrayEquals(byteArrayOf(level.toByte()), XboxOneReports.battery(percent, true))
        }
    }

    private data class Field(val type: Int, val id: Int, val page: Int, val usages: List<Int>,
                             val size: Int, val count: Int, val min: Int, val max: Int, val flags: Int)

    /** Parse HID items independently of the encoder, including global inheritance. */
    private fun descriptorFields(bytes: ByteArray): List<Field> {
        val fields = mutableListOf<Field>()
        val usages = mutableListOf<Int>()
        var offset = 0; var page = 0; var id = 0; var size = 0; var count = 0
        var min = 0; var max = 0; var depth = 0; var applications = 0
        while (offset < bytes.size) {
            val prefix = bytes[offset++].toInt() and 0xff
            assertNotEquals(0xfe, prefix)
            val length = if (prefix and 3 == 3) 4 else prefix and 3
            assertTrue(offset + length <= bytes.size)
            var value = 0
            repeat(length) { value = value or ((bytes[offset++].toInt() and 0xff) shl (8 * it)) }
            val type = (prefix shr 2) and 3; val tag = prefix shr 4
            when (type) {
                1 -> when (tag) {
                    0 -> page = value
                    1 -> min = value
                    2 -> max = value
                    7 -> size = value
                    8 -> { id = value; assertTrue(id > 0) }
                    9 -> count = value
                }
                2 -> if (tag == 0) usages += value
                0 -> {
                    when (tag) {
                        8, 9, 11 -> fields += Field(tag, id, page, usages.toList(), size, count, min, max, value)
                        10 -> { if (value == 1) { applications++; assertEquals(1, page); assertEquals(listOf(5), usages) }; depth++ }
                        12 -> { depth--; assertTrue(depth >= 0) }
                        else -> fail("Unknown main item $tag")
                    }
                    usages.clear()
                }
            }
        }
        assertEquals(1, applications); assertEquals(0, depth)
        return fields
    }
}
