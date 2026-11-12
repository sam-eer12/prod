package com.padlink.controller.core

import com.padlink.controller.ui.screens.controller.ControllerState
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/** A single gamepad application collection. No keyboard, mouse, or output reports. */
object ControllerReports {
    const val REPORT_ID = 1
    const val REPORT_SIZE = 13
    val descriptor: ByteArray get() = intArrayOf(
        0x05,0x01, 0x09,0x05, 0xa1,0x01, 0x85,0x01,
        0x05,0x09, 0x19,0x01, 0x29,0x0b, 0x15,0x00, 0x25,0x01,
        0x75,0x01, 0x95,0x0b, 0x81,0x02,
        0x75,0x05, 0x95,0x01, 0x81,0x03,
        0x05,0x01, 0x09,0x39, 0x15,0x00, 0x25,0x07,
        0x35,0x00, 0x46,0x3b,0x01, 0x65,0x14, 0x75,0x04, 0x95,0x01, 0x81,0x42,
        0x75,0x04, 0x95,0x01, 0x81,0x03, 0x65,0x00,
        0x09,0x30, 0x09,0x31, 0x09,0x33, 0x09,0x34,
        0x16,0x00,0x80, 0x26,0xff,0x7f, 0x36,0x00,0x80, 0x46,0xff,0x7f,
        0x75,0x10, 0x95,0x04, 0x81,0x02,
        0x09,0x32, 0x09,0x35, 0x15,0x00, 0x26,0xff,0x00,
        0x35,0x00, 0x46,0xff,0x00, 0x75,0x08, 0x95,0x02, 0x81,0x02, 0xc0,
    ).map(Int::toByte).toByteArray()

    private fun axis(value: Float): Short {
        if (!value.isFinite()) return 0
        val clamped = value.coerceIn(-1f, 1f)
        return (clamped * if (clamped < 0) 32768f else 32767f).roundToInt().toShort()
    }
    private fun trigger(value: Float): Byte =
        if (!value.isFinite()) 0 else (value.coerceIn(0f, 1f) * 255f).roundToInt().toByte()

    fun hat(buttons: Int): Int {
        fun pressed(bit: Int) = if (buttons and (1 shl bit) != 0) 1 else 0
        val x = pressed(14) - pressed(13)
        val y = pressed(12) - pressed(11)
        return when {
            x == 0 && y == -1 -> 0
            x == 1 && y == -1 -> 1
            x == 1 && y == 0 -> 2
            x == 1 && y == 1 -> 3
            x == 0 && y == 1 -> 4
            x == -1 && y == 1 -> 5
            x == -1 && y == 0 -> 6
            x == -1 && y == -1 -> 7
            else -> 8
        }
    }

    fun bluetooth(state: ControllerState): ByteArray =
        ByteBuffer.allocate(REPORT_SIZE).order(ByteOrder.LITTLE_ENDIAN)
            .putShort((state.buttons and 0x7ff).toShort())
            .put(hat(state.buttons).toByte())
            .putShort(axis(state.leftStick.x)).putShort(axis(state.leftStick.y))
            .putShort(axis(state.rightStick.x)).putShort(axis(state.rightStick.y))
            .put(trigger(state.leftTrigger)).put(trigger(state.rightTrigger)).array()
}
