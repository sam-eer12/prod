package com.padlink.controller.ui.screens.controller

import android.content.Context
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.core.content.edit

/** Brief local feedback, bounded independently of touch-event frequency. */
class ControllerHaptics(private val view: View) {
    private val vibrator = view.context.getSystemService(Vibrator::class.java)
    private val policy = ControllerHapticPolicy()
    var enabled: Boolean = true
        set(value) {
            field = value
            if (!value) stop()
        }

    fun buttonPress() { pulse(policy.buttonPress(SystemClock.uptimeMillis())) }

    fun stickMoved(id: ControlId, position: StickPosition) {
        policy.stickMoved(id, position, SystemClock.uptimeMillis())?.let(::pulse)
    }

    fun releaseStick(id: ControlId) { policy.releaseStick(id) }

    fun stop() {
        vibrator?.cancel()
        policy.reset()
    }

    @Suppress("DEPRECATION")
    private fun pulse(pulse: TouchPulse) {
        if (!enabled || !view.isHapticFeedbackEnabled ||
            Settings.System.getInt(view.context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1) == 0
        ) return
        if (vibrator?.hasVibrator() == true && vibrator.hasAmplitudeControl()) {
            vibrator.vibrate(VibrationEffect.createOneShot(pulse.durationMs, pulse.amplitude))
        } else {
            // System touch effects remain optional on devices without amplitude control.
            view.performHapticFeedback(if (pulse.button) HapticFeedbackConstants.VIRTUAL_KEY else HapticFeedbackConstants.CLOCK_TICK)
        }
    }
}

object ControllerPreferences {
    private const val FILE = "controller"
    private const val HAPTICS = "touch_haptics"
    fun hapticsEnabled(context: Context): Boolean = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getBoolean(HAPTICS, true)
    fun setHapticsEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putBoolean(HAPTICS, enabled) }
    }
}
