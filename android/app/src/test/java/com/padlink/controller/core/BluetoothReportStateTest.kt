package com.padlink.controller.core

import com.padlink.controller.ui.screens.controller.ControllerState
import org.junit.Assert.*
import org.junit.Test

class BluetoothReportStateTest {
    @Test
    fun missingOrUnknownProfileFallsBackToTheWorkingXboxDescriptor() {
        assertEquals(BluetoothControllerProfile.XBOX_ONE, BluetoothControllerProfile.fromStored(null))
        assertEquals(BluetoothControllerProfile.XBOX_ONE, BluetoothControllerProfile.fromStored("invalid"))
        assertEquals(BluetoothControllerProfile.GENERIC, BluetoothControllerProfile.fromStored("GENERIC"))
        assertEquals(BluetoothControllerProfile.XBOX_ONE, BluetoothControllerProfile.fromStored("XBOX_ONE"))
        assertArrayEquals(XboxOneReports.descriptor, BluetoothControllerProfile.XBOX_ONE.descriptor)
    }

    @Test
    fun genericModeUsesReportIdOneAndRejectsXboxReports() {
        val reports = BluetoothReportState(BluetoothControllerProfile.GENERIC)
        assertEquals(listOf(1), reports.initialReports().map { it.id })
        assertEquals(13, reports.inputPayload(1)!!.size)
        assertNull(reports.inputPayload(0))
        (2..4).forEach { assertNull(reports.inputPayload(it)) }
        assertNull(reports.outputPayload(3))
        assertNull(reports.setOutput(3, ByteArray(8)))
        assertNull(reports.setBattery(50, false))
    }

    @Test
    fun xboxStartsWithAllDeclaredInputReportsAndKeepsTheReportIdOutOfData() {
        val reports = BluetoothReportState(BluetoothControllerProfile.XBOX_ONE)
        assertEquals(listOf(1, 2, 4), reports.initialReports().map { it.id })
        assertEquals(listOf(15, 1, 1), reports.initialReports().map { it.data.size })
        assertNull(reports.inputPayload(0)); assertNull(reports.inputPayload(3))
        assertEquals(8, reports.outputPayload(3)!!.size)
        assertNull(reports.outputPayload(1)); assertNull(reports.outputPayload(4))
    }

    @Test
    fun guideTransitionsSendSeparatePacketsAndNeutralUpdateReleasesIt() {
        val reports = BluetoothReportState(BluetoothControllerProfile.XBOX_ONE)
        val held = ControllerState(buttons = (1 shl 8) or 1)
        val pressed = reports.update(held)
        assertEquals(listOf(1, 2), pressed.map { it.id })
        assertArrayEquals(byteArrayOf(1), pressed[1].data)
        assertArrayEquals(byteArrayOf(1), reports.inputPayload(2))
        assertEquals(listOf(1), reports.update(held).map { it.id })
        assertEquals(1, reports.currentInput().id)
        val released = reports.update(ControllerState())
        assertEquals(listOf(1, 2), released.map { it.id })
        assertArrayEquals(byteArrayOf(0), released[1].data)
        assertArrayEquals(XboxOneReports.input(ControllerState()), reports.inputPayload(1))
    }

    @Test
    fun outputReportsAreStoredOnlyAfterValidIdAndLengthAndCopiedForGetReport() {
        val reports = BluetoothReportState(BluetoothControllerProfile.XBOX_ONE)
        val command = byteArrayOf(0x0f, 10, 20, 30, 40, 50, 0, 1)
        assertNull(reports.setOutput(0, command)); assertNull(reports.setOutput(3, ByteArray(7)))
        assertArrayEquals(ByteArray(8), reports.outputPayload(3))
        assertNotNull(reports.setOutput(3, command))
        val expected = command.copyOf()
        command.fill(0)
        assertArrayEquals(expected, reports.outputPayload(3))
        reports.outputPayload(3)!!.fill(0)
        assertArrayEquals(expected, reports.outputPayload(3))
    }

    @Test
    fun batteryUpdatesOnlySendChangedStatusAndAreAvailableToGetReport() {
        val reports = BluetoothReportState(BluetoothControllerProfile.XBOX_ONE)
        val update = reports.setBattery(50, true)!!
        assertEquals(4, update.id); assertArrayEquals(byteArrayOf(2), update.data)
        assertArrayEquals(update.data, reports.inputPayload(4))
        assertNull(reports.setBattery(51, true))
        assertNotNull(reports.setBattery(51, false))
    }
}
