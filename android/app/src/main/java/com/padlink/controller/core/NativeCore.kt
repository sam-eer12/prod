package com.padlink.controller.core

import android.os.SystemClock
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** All cryptography, frames, request limits, and socket ownership live in Rust. */
object NativeCore {
    init { System.loadLibrary("padlink_core") }
    external fun create(role: Int, data: ByteArray, now: Long): Long
    external fun call(handle: Long, operation: Int, connection: Long, data: ByteArray, now: Long): ByteArray
    external fun close(handle: Long)
}

sealed interface PhoneEvent {
    data object Pending : PhoneEvent
    data class Consent(val id: Long, val label: String, val address: String) : PhoneEvent
    data class Paired(val id: Long) : PhoneEvent
    data class Closed(val id: Long) : PhoneEvent
    data object Frame : PhoneEvent
}

class PhonePairingCore : AutoCloseable {
    private var handle = NativeCore.create(0, byteArrayOf(), SystemClock.elapsedRealtime())
    @Synchronized
    private fun call(op: Int, id: Long = 0, bytes: ByteArray = byteArrayOf()): ByteArray {
        check(handle != 0L) { "Pairing core is closed" }
        return NativeCore.call(handle, op, id, bytes, SystemClock.elapsedRealtime())
    }
    fun start(endpoint: String): String = call(1, bytes = endpoint.toByteArray()).decodeToString()
    fun stop() { call(2) }
    fun allow(id: Long) { call(4, id) }
    fun deny(id: Long) { call(5, id) }
    fun disconnect(id: Long) { call(8, id) }
    /** Stops the pairing listener/socket and moves keys into a session handle. */
    fun detachSession(id: Long): NativeSession = NativeSession(ByteBuffer.wrap(call(30, id)).order(ByteOrder.LITTLE_ENDIAN).long)
    fun code(id: Long): String {
        val bytes = call(6, id)
        return try { bytes.decodeToString() } finally { bytes.fill(0) }
    }
    fun deadline(): Long = ByteBuffer.wrap(call(7)).order(ByteOrder.LITTLE_ENDIAN).long
    fun poll(): PhoneEvent {
        val bytes = call(3)
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        return when (buffer.get().toInt()) {
            0 -> PhoneEvent.Pending
            1 -> {
                val id = buffer.long
                val length = buffer.short.toInt() and 0xffff
                require(length in 1..64 && buffer.remaining() >= length)
                val label = ByteArray(length).also(buffer::get).decodeToString()
                val address = ByteArray(buffer.remaining()).also(buffer::get).decodeToString()
                PhoneEvent.Consent(id, label, address)
            }
            2 -> PhoneEvent.Paired(buffer.long)
            3 -> PhoneEvent.Closed(buffer.long)
            4 -> PhoneEvent.Frame
            else -> error("Unsupported native pairing event")
        }
    }
    @Synchronized
    override fun close() { if (handle != 0L) { NativeCore.close(handle); handle = 0 } }
}

enum class SessionTransport(val wire: Int) { UDP(1), TCP(2) }
data class ResumeEndpoint(val transport: SessionTransport, val desktop: String, val phone: String)
data class ResumeResult(val frames: List<ByteArray>, val readyToCommit: Boolean)

/** Memory-only session ownership. Callers own candidate sockets and fully write
 * every resume reply before readyWritten(). Input must stay neutral until the
 * confirmed new epoch, clock measurement, and a fresh State sample. */
class NativeSession internal constructor(private var handle: Long) : AutoCloseable {
    @Synchronized
    private fun call(op: Int, bytes: ByteArray = byteArrayOf()): ByteArray {
        check(handle != 0L) { "Session is closed" }
        return NativeCore.call(handle, op, 0, bytes, SystemClock.elapsedRealtime())
    }
    fun expiresAt(): Long = ByteBuffer.wrap(call(17)).order(ByteOrder.LITTLE_ENDIAN).long
    fun epoch(): Int = ByteBuffer.wrap(call(19)).order(ByteOrder.LITTLE_ENDIAN).int
    /** Only after authenticated clock bounds and sample-age validation. */
    fun recordValidatedFreshInput(sampleLocalMs: Long) {
        call(18, ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(sampleLocalMs).array())
    }
    fun seal(transport: SessionTransport, type: Int, payload: ByteArray): ByteArray =
        call(15, byteArrayOf(transport.wire.toByte(), type.toByte()) + payload)
    fun open(transport: SessionTransport, packet: ByteArray): ByteArray =
        call(16, byteArrayOf(transport.wire.toByte()) + packet)
    fun startResume(path: ResumeEndpoint) {
        call(40, "${path.transport.wire}\n${path.desktop}\n${path.phone}".toByteArray())
    }
    fun beginResume(): ByteArray = call(41)
    fun receiveResume(source: String, packet: ByteArray): ResumeResult {
        val address = source.toByteArray()
        require(address.size in 1..128 && packet.size <= 258)
        val bytes = call(42, ByteBuffer.allocate(2 + address.size + packet.size).order(ByteOrder.LITTLE_ENDIAN)
            .putShort(address.size.toShort()).put(address).put(packet).array())
        val buffer = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val ready = buffer.get().toInt() == 1
        val count = buffer.get().toInt() and 0xff
        require(count <= 2)
        val frames = List(count) {
            val size = buffer.short.toInt() and 0xffff
            require(size <= 258 && size <= buffer.remaining())
            ByteArray(size).also(buffer::get)
        }
        require(!buffer.hasRemaining())
        return ResumeResult(frames, ready)
    }
    fun readyWritten() { call(43) }
    fun finishResume(): ResumeEndpoint {
        val fields = call(44).decodeToString().split('\n')
        require(fields.size == 3)
        return ResumeEndpoint(SessionTransport.entries.first { it.wire == fields[0].toInt() }, fields[1], fields[2])
    }
    fun resumeDeadline(): Long = ByteBuffer.wrap(call(45)).order(ByteOrder.LITTLE_ENDIAN).long
    @Synchronized
    override fun close() { if (handle != 0L) { NativeCore.close(handle); handle = 0 } }
    companion object {
        /** Diagnostic desktop role uses the exact same lease and resume code. */
        fun detachDesktop(client: Long): NativeSession = NativeSession(ByteBuffer.wrap(
            NativeCore.call(client, 31, 0, byteArrayOf(), SystemClock.elapsedRealtime())
        ).order(ByteOrder.LITTLE_ENDIAN).long)
    }
}
