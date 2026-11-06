package com.padlink.controller

import android.app.Application
import com.padlink.controller.core.PhonePairingCore

/**
 * Process-wide application entry point.
 *
 * Retains phone-wide admission history across activity and listener restarts.
 */
class PadLinkApplication : Application() {
    private val nativeCore = lazy { PhonePairingCore() }
    val pairingCore: PhonePairingCore get() = nativeCore.value
    fun stopPairingIfCreated() { if (nativeCore.isInitialized()) nativeCore.value.stop() }
}
