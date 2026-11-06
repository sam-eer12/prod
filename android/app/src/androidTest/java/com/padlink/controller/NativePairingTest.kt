package com.padlink.controller

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.padlink.controller.core.NativeCore
import com.padlink.controller.core.PhoneEvent
import com.padlink.controller.core.NativeSession
import com.padlink.controller.core.ResumeEndpoint
import com.padlink.controller.core.SessionTransport
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder

@RunWith(AndroidJUnit4::class)
class NativePairingTest {
    private fun now() = SystemClock.elapsedRealtime()
    @Test
    fun jniSocketPairingRetriesWrongCodeAndAuthenticatesRoundTrip() {
        val app = InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as PadLinkApplication
        val phone = app.pairingCore
        phone.stop()
        val endpoint = phone.start("127.0.0.1:0")
        val client = NativeCore.create(2, "$endpoint\nJNI ABI test".toByteArray(), now())
        var code = ""
        var attempts = 0
        var verified = false
        var pingTime = 0L
        var connection = 0L
        try {
            val deadline = now() + 10_000
            while (now() < deadline && !verified) {
                when (val event = phone.poll()) {
                    is PhoneEvent.Consent -> { phone.allow(event.id); code = phone.code(event.id) }
                    is PhoneEvent.Paired -> connection = event.id
                    else -> Unit
                }
                val event = NativeCore.call(client, 20, 0, byteArrayOf(), now())
                when (event[0].toInt()) {
                    1 -> {
                        val candidate = if (attempts == 0) { if (code == "AAAAAA") "BBBBBB" else "AAAAAA" } else code.lowercase()
                        val bytes = candidate.toByteArray()
                        try { NativeCore.call(client, 21, 0, bytes, now()) } finally { bytes.fill(0) }
                        attempts++
                    }
                    3 -> {
                        pingTime = now() * 1000
                        val ping = ByteBuffer.allocate(17).order(ByteOrder.LITTLE_ENDIAN).put(4.toByte()).putLong(77).putLong(pingTime).array()
                        NativeCore.call(client, 22, 0, ping, now())
                    }
                    4 -> {
                        assertEquals(5, event[1].toInt())
                        val pong = ByteBuffer.wrap(event, 2, event.size - 2).order(ByteOrder.LITTLE_ENDIAN)
                        assertEquals(77L, pong.long)
                        assertEquals(pingTime, pong.long)
                        verified = true
                    }
                }
                Thread.sleep(5)
            }
            assertTrue("JNI encrypted round trip did not complete", verified)
            assertEquals(2, attempts)
            phone.detachSession(connection).use { phoneSession ->
                NativeSession.detachDesktop(client).use { desktopSession ->
                    val expiry = desktopSession.expiresAt()
                    val path = ResumeEndpoint(SessionTransport.TCP, "127.0.0.1:41338", "127.0.0.1:41337")
                    phoneSession.startResume(path)
                    desktopSession.startResume(path)
                    val a = desktopSession.beginResume()
                    val b = phoneSession.receiveResume(path.desktop, a).frames.single()
                    val ca = desktopSession.receiveResume(path.phone, b).frames.single()
                    val replies = phoneSession.receiveResume(path.desktop, ca).frames
                    assertEquals(2, replies.size)
                    assertFalse(desktopSession.receiveResume(path.phone, replies[0]).readyToCommit)
                    assertTrue(desktopSession.receiveResume(path.phone, replies[1]).readyToCommit)
                    phoneSession.readyWritten()
                    assertEquals(path, desktopSession.finishResume())
                    assertEquals(path, phoneSession.finishResume())
                    assertEquals(2, desktopSession.epoch())
                    assertEquals(expiry, desktopSession.expiresAt())
                    val payload = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).putLong(99).putLong(now() * 1000).array()
                    val packet = desktopSession.seal(SessionTransport.TCP, 4, payload)
                    val opened = phoneSession.open(SessionTransport.TCP, packet)
                    assertEquals(4, opened[0].toInt())
                    assertArrayEquals(payload, opened.copyOfRange(1, opened.size))
                    assertThrows(IllegalStateException::class.java) { phoneSession.open(SessionTransport.TCP, packet) }
                }
            }
        } finally { code = ""; NativeCore.close(client); phone.stop() }
    }

    @Test
    fun nativeBoundaryRejectsOversizeNegativeClockAndClosedHandles() {
        val desktop = NativeCore.create(1, "Boundary test".toByteArray(), now())
        try {
            assertThrows(IllegalStateException::class.java) { NativeCore.call(desktop, 10, 0, ByteArray(4097), now()) }
            assertThrows(IllegalStateException::class.java) { NativeCore.call(desktop, 10, 0, byteArrayOf(), -1) }
            assertTrue(NativeCore.call(desktop, 10, 0, byteArrayOf(), now()).size < 4096)
        } finally { NativeCore.close(desktop) }
        assertThrows(IllegalStateException::class.java) { NativeCore.call(desktop, 10, 0, byteArrayOf(), now()) }
        assertThrows(IllegalStateException::class.java) { NativeCore.call(desktop, 90, 0, byteArrayOf(), now()) }
    }
}
