package com.padlink.controller.core

/** Xbox's four independent motors are combined onto the phone's single motor. */
data class XboxOneRumble(val magnitude: Int, val durationMs: Long, val delayMs: Long, val repeats: Int) {
    fun timings(): LongArray = LongArray((repeats + 1) * 2) { if (it % 2 == 0) delayMs else durationMs }

    companion object {
        fun parse(data: ByteArray): XboxOneRumble? {
            if (data.size != XboxOneReports.RUMBLE_SIZE) return null
            fun byte(index: Int) = data[index].toInt() and 0xff
            val enabled = byte(0) and 0x0f
            // Enable bits: left trigger 3, right trigger 2, strong 1, weak 0.
            val magnitude = (0..3).maxOf { motor ->
                if (enabled and (1 shl (3 - motor)) != 0) byte(motor + 1).coerceAtMost(100) else 0
            }
            return XboxOneRumble(magnitude, byte(5) * 10L, byte(6) * 10L, byte(7))
        }
    }
}
