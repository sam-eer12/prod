package com.padlink.controller.core

import android.content.Context
import androidx.core.content.edit
import com.padlink.controller.ui.screens.controller.ControllerState

/** These are SDP strings and report formats, not Bluetooth Device ID overrides. */
enum class BluetoothControllerProfile(
    val sdpName: String,
    val sdpDescription: String,
    val sdpProvider: String,
    val inputReportId: Int,
) {
    GENERIC("PadLink Gamepad", "Phone game controller", "PadLink", ControllerReports.REPORT_ID),
    XBOX_ONE("Xbox Wireless Controller", "Xbox Wireless Controller", "Microsoft", XboxOneReports.INPUT_ID);

    val descriptor: ByteArray get() = when (this) {
        GENERIC -> ControllerReports.descriptor
        XBOX_ONE -> XboxOneReports.descriptor
    }

    fun input(state: ControllerState): ByteArray = when (this) {
        GENERIC -> ControllerReports.bluetooth(state)
        XBOX_ONE -> XboxOneReports.input(state)
    }

    companion object {
        fun fromStored(value: String?): BluetoothControllerProfile = entries.firstOrNull { it.name == value } ?: XBOX_ONE
    }
}

object BluetoothControllerPreferences {
    private const val FILE = "bluetooth_controller"
    private const val PROFILE = "profile"
    private const val GAME_RUMBLE = "game_rumble"

    fun load(context: Context): BluetoothControllerProfile = BluetoothControllerProfile.fromStored(
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getString(PROFILE, null),
    )

    fun save(context: Context, profile: BluetoothControllerProfile) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putString(PROFILE, profile.name) }
    }

    fun gameRumbleEnabled(context: Context): Boolean =
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).getBoolean(GAME_RUMBLE, true)

    fun setGameRumbleEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE).edit { putBoolean(GAME_RUMBLE, enabled) }
    }
}
