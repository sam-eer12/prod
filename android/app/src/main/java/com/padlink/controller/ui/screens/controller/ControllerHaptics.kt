package com.padlink.controller.ui.screens.controller

import android.content.Context
import android.os.SystemClock
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.media.AudioAttributes
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import androidx.core.content.edit
import com.padlink.controller.core.XboxOneRumble
import kotlin.math.roundToInt

/** Brief local feedback, bounded independently of touch-event frequency. */
class ControllerHaptics(private val view: View) {
    private val vibration = ControllerVibration(view.context)
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
        vibration.stop()
        policy.reset()
    }

    private fun pulse(pulse: TouchPulse) {
        if (!enabled || !view.isHapticFeedbackEnabled || !vibration.systemEnabled()) return
        if (!vibration.pulse(pulse)) {
            view.performHapticFeedback(if (pulse.button) HapticFeedbackConstants.VIRTUAL_KEY else HapticFeedbackConstants.CLOCK_TICK)
        }
    }
}

enum class VibrationStatus { AVAILABLE, SYSTEM_DISABLED, NO_VIBRATOR }

/** Direct one-shots also work on motors that do not support amplitude control. */
class ControllerVibration(private val context: Context) {
    @Suppress("DEPRECATION")
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= 31) {
        context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else context.getSystemService(Vibrator::class.java)

    @Suppress("DEPRECATION") // Android still exposes this touch-feedback preference on supported releases.
    fun systemEnabled(): Boolean = Settings.System.getInt(
        context.contentResolver, Settings.System.HAPTIC_FEEDBACK_ENABLED, 1,
    ) != 0

    fun status(): VibrationStatus = when {
        vibrator?.hasVibrator() != true -> VibrationStatus.NO_VIBRATOR
        !systemEnabled() -> VibrationStatus.SYSTEM_DISABLED
        else -> VibrationStatus.AVAILABLE
    }

    @Suppress("DEPRECATION")
    fun pulse(pulse: TouchPulse): Boolean {
        if (status() != VibrationStatus.AVAILABLE) return false
        val motor = vibrator ?: return false
        val amplitude = if (motor.hasAmplitudeControl()) pulse.amplitude else VibrationEffect.DEFAULT_AMPLITUDE
        val effect = VibrationEffect.createOneShot(pulse.durationMs, amplitude)
        return runCatching {
            if (Build.VERSION.SDK_INT >= 33) motor.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
            else motor.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION).build())
        }.isSuccess
    }

    fun test(): Boolean = pulse(TouchPulse(100L, 180, button = true))

    /** Keep Xbox timing/loops, folding its four motor strengths onto one actuator. */
    @Suppress("DEPRECATION")
    fun rumble(rumble: XboxOneRumble): Boolean {
        stop()
        if (rumble.magnitude == 0 || rumble.durationMs == 0L) return true
        if (status() != VibrationStatus.AVAILABLE) return false
        val motor = vibrator ?: return false
        val timings = rumble.timings()
        val amplitude = if (motor.hasAmplitudeControl()) (rumble.magnitude * 255f / 100f).roundToInt()
            else VibrationEffect.DEFAULT_AMPLITUDE
        val amplitudes = IntArray(timings.size) { if (it % 2 == 0) 0 else amplitude }
        val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
        return runCatching {
            if (Build.VERSION.SDK_INT >= 33) motor.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_MEDIA))
            else motor.vibrate(effect, AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_GAME).build())
        }.isSuccess
    }

    fun stop() { vibrator?.cancel() }
}

object ControllerPreferences {
    private const val FILE = "controller"
    private const val HAPTICS = "touch_haptics"
    fun hapticsEnabled(context: Context): Boolean = context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getBoolean(HAPTICS, true)
    fun setHapticsEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putBoolean(HAPTICS, enabled) }
    }
}
