package com.padlink.controller.core

import com.padlink.controller.ui.screens.controller.ControllerState

data class HidInputReport(val id: Int, val data: ByteArray)

/** All report data excludes the report ID byte, which Android adds on the wire. */
class BluetoothReportState(val profile: BluetoothControllerProfile) {
    private var input = profile.input(ControllerState())
    private var guide = byteArrayOf(0)
    private var battery = XboxOneReports.battery(100, charging = false)
    private var output = ByteArray(XboxOneReports.RUMBLE_SIZE)

    fun update(state: ControllerState): List<HidInputReport> {
        input = profile.input(state)
        val reports = mutableListOf(currentInput())
        if (profile == BluetoothControllerProfile.XBOX_ONE) {
            val nextGuide = XboxOneReports.guide(state)
            if (!guide.contentEquals(nextGuide)) {
                guide = nextGuide
                reports += HidInputReport(XboxOneReports.GUIDE_ID, guide)
            }
        }
        return reports
    }

    fun currentInput(): HidInputReport = HidInputReport(profile.inputReportId, input)

    fun initialReports(): List<HidInputReport> = when (profile) {
        BluetoothControllerProfile.GENERIC -> listOf(currentInput())
        BluetoothControllerProfile.XBOX_ONE -> listOf(currentInput(),
            HidInputReport(XboxOneReports.GUIDE_ID, guide), HidInputReport(XboxOneReports.BATTERY_ID, battery))
    }

    fun setBattery(percent: Int, charging: Boolean): HidInputReport? {
        if (profile != BluetoothControllerProfile.XBOX_ONE) return null
        val next = XboxOneReports.battery(percent, charging)
        if (battery.contentEquals(next)) return null
        battery = next
        return HidInputReport(XboxOneReports.BATTERY_ID, battery)
    }

    fun inputPayload(id: Int): ByteArray? = when {
        id == profile.inputReportId -> input.copyOf()
        profile != BluetoothControllerProfile.XBOX_ONE -> null
        id == XboxOneReports.GUIDE_ID -> guide.copyOf()
        id == XboxOneReports.BATTERY_ID -> battery.copyOf()
        else -> null
    }

    fun outputPayload(id: Int): ByteArray? = if (profile == BluetoothControllerProfile.XBOX_ONE &&
        id == XboxOneReports.RUMBLE_ID) output.copyOf() else null

    fun setOutput(id: Int, data: ByteArray): XboxOneRumble? {
        if (profile != BluetoothControllerProfile.XBOX_ONE || id != XboxOneReports.RUMBLE_ID) return null
        val rumble = XboxOneRumble.parse(data) ?: return null
        output = data.copyOf()
        return rumble
    }
}
