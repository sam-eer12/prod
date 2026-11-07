package com.padlink.controller.core

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothHidDevice
import android.bluetooth.BluetoothHidDeviceAppSdpSettings
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.core.content.edit
import com.padlink.controller.ui.screens.controller.ControllerState
import com.padlink.controller.ui.screens.controller.ControllerVibration
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class BluetoothPhase { OFF, STARTING, READY, CONNECTING, CONNECTED, ERROR }
data class BluetoothHost(val address: String, val name: String)
data class BluetoothGamepadState(
    val phase: BluetoothPhase = BluetoothPhase.OFF,
    val hosts: List<BluetoothHost> = emptyList(),
    val hostName: String = "",
    val message: String = "",
)

/** Android's native Bluetooth HID Device profile; the desktop uses its own HID driver. */
@SuppressLint("MissingPermission") // Every entry point checks permission; revocation fails closed.
class BluetoothGamepad(context: Context) {
    private val context = context.applicationContext
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private val handler = Handler(Looper.getMainLooper())
    private val mutableState = MutableStateFlow(BluetoothGamepadState())
    val state = mutableState.asStateFlow()
    private var generation = 0
    private var profile: BluetoothHidDevice? = null
    private var device: BluetoothDevice? = null
    private var connectingDevice: BluetoothDevice? = null
    private var reports = BluetoothReportState(BluetoothControllerPreferences.load(context))
    private val vibration = ControllerVibration(this.context)
    private var nextBatteryCheck = 0L
    private var registered = false
    private val session = context.getSharedPreferences("bluetooth_session", Context.MODE_PRIVATE)
    private var resumeAddress: String? = null

    private val heartbeat = object : Runnable {
        override fun run() {
            if (mutableState.value.phase != BluetoothPhase.CONNECTED) return
            if (!send(reports.currentInput())) { fail("Bluetooth input stopped. Reconnect your laptop."); return }
            if (SystemClock.elapsedRealtime() >= nextBatteryCheck) {
                nextBatteryCheck = SystemClock.elapsedRealtime() + 30_000L
                val battery = readBattery()
                if (battery != null && !send(battery)) { fail("Bluetooth input stopped. Reconnect your laptop."); return }
            }
            handler.postDelayed(this, 8)
        }
    }

    fun hasPermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        ContextCompat.checkSelfPermission(context, "android.permission.BLUETOOTH_CONNECT") == PackageManager.PERMISSION_GRANTED

    fun isEnabled(): Boolean = hasPermission() && runCatching { adapter?.isEnabled == true }.getOrDefault(false)

    fun start(previousHost: String? = null) {
        if (mutableState.value.phase in listOf(BluetoothPhase.STARTING, BluetoothPhase.READY, BluetoothPhase.CONNECTING, BluetoothPhase.CONNECTED)) return
        release()
        reports = BluetoothReportState(BluetoothControllerPreferences.load(context))
        resumeAddress = previousHost
        if (!hasPermission()) { fail("Allow nearby-device access to use Bluetooth."); return }
        val bluetooth = adapter
        if (bluetooth == null) { fail("This phone has no Bluetooth adapter."); return }
        if (!isEnabled()) { fail("Turn on Bluetooth, then start Bluetooth mode again."); return }
        session.edit { putBoolean("active", true); putString("host", previousHost) }
        val current = ++generation
        mutableState.value = BluetoothGamepadState(BluetoothPhase.STARTING)
        val listener = object : BluetoothProfile.ServiceListener {
            override fun onServiceConnected(kind: Int, proxy: BluetoothProfile) {
                if (current != generation || kind != BluetoothProfile.HID_DEVICE) {
                    bluetooth.closeProfileProxy(kind, proxy); return
                }
                profile = proxy as? BluetoothHidDevice
                val settings = BluetoothHidDeviceAppSdpSettings(
                    reports.profile.sdpName, reports.profile.sdpDescription, reports.profile.sdpProvider,
                    BluetoothHidDevice.SUBCLASS2_GAMEPAD, reports.profile.descriptor,
                )
                try {
                    if (profile?.registerApp(settings, null, null, context.mainExecutor, callback(current)) != true) {
                        fail("This phone cannot register a Bluetooth gamepad. Its Bluetooth HID Device profile may be disabled.")
                    }
                } catch (_: SecurityException) { fail("Bluetooth permission was revoked. Allow nearby-device access and retry.") }
            }
            override fun onServiceDisconnected(kind: Int) {
                if (current == generation && kind == BluetoothProfile.HID_DEVICE) fail("Bluetooth service disconnected. Start Bluetooth mode again.")
            }
        }
        try {
            if (!bluetooth.getProfileProxy(context, listener, BluetoothProfile.HID_DEVICE)) {
                fail("This phone does not support the Bluetooth HID Device profile.")
            }
        } catch (_: SecurityException) { fail("Bluetooth permission was revoked. Allow nearby-device access and retry.") }
        handler.postDelayed({
            if (current == generation && mutableState.value.phase == BluetoothPhase.STARTING) {
                fail("Bluetooth gamepad service did not start. This phone may not support HID Device mode.")
            }
        }, 5000)
    }

    private fun callback(current: Int) = object : BluetoothHidDevice.Callback() {
        override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, isRegistered: Boolean) {
            if (current != generation) return
            registered = isRegistered
            if (!isRegistered) { fail("Bluetooth gamepad registration ended. Keep PadLink open and start Bluetooth mode again."); return }
            if (mutableState.value.phase == BluetoothPhase.STARTING) mutableState.value = BluetoothGamepadState(BluetoothPhase.READY)
            refreshHosts()
            val previousHost = resumeAddress
            resumeAddress = null
            if (previousHost != null && mutableState.value.phase == BluetoothPhase.READY) connect(previousHost)
        }
        override fun onConnectionStateChanged(host: BluetoothDevice, connectionState: Int) {
            if (current != generation) return
            when (connectionState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (!hasPermission() || runCatching { host.bondState != BluetoothDevice.BOND_BONDED }.getOrDefault(true)) {
                        runCatching { profile?.disconnect(host) }
                        fail("Pair this laptop in Bluetooth settings before connecting the gamepad.")
                        return
                    }
                    if (device != null && device != host) runCatching { profile?.disconnect(device) }
                    device = host
                    connectingDevice = null
                    reports = BluetoothReportState(reports.profile)
                    readBattery()
                    val name = runCatching { host.name }.getOrNull() ?: "Laptop"
                    session.edit { putBoolean("active", true); putString("host", host.address) }
                    mutableState.value = mutableState.value.copy(phase = BluetoothPhase.CONNECTED, hostName = name, message = "")
                    handler.removeCallbacks(heartbeat)
                    if (!reports.initialReports().all(::send)) { fail("Bluetooth input stopped. Reconnect your laptop."); return }
                    nextBatteryCheck = SystemClock.elapsedRealtime() + 30_000L
                    heartbeat.run()
                }
                BluetoothProfile.STATE_CONNECTING -> {
                    connectingDevice = host
                    mutableState.value = mutableState.value.copy(phase = BluetoothPhase.CONNECTING)
                }
                BluetoothProfile.STATE_DISCONNECTED -> if (device == null || device == host) {
                    device = null
                    connectingDevice = null
                    reports = BluetoothReportState(reports.profile)
                    vibration.stop()
                    handler.removeCallbacks(heartbeat)
                    mutableState.value = mutableState.value.copy(phase = BluetoothPhase.READY, hostName = "", message = "Laptop disconnected.")
                    refreshHosts()
                }
            }
        }
        override fun onGetReport(host: BluetoothDevice, type: Byte, id: Byte, bufferSize: Int) {
            if (current != generation) return
            try {
                if (host != device) { profile?.reportError(host, BluetoothHidDevice.ERROR_RSP_NOT_READY); return }
                val payload = when (type) {
                    BluetoothHidDevice.REPORT_TYPE_INPUT -> {
                        if (id.toInt() == XboxOneReports.BATTERY_ID) readBattery()
                        reports.inputPayload(id.toInt() and 0xff)
                    }
                    BluetoothHidDevice.REPORT_TYPE_OUTPUT -> reports.outputPayload(id.toInt() and 0xff)
                    else -> { profile?.reportError(host, BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ); return }
                }
                if (payload == null) profile?.reportError(host, BluetoothHidDevice.ERROR_RSP_INVALID_RPT_ID)
                else if (bufferSize < 0 || bufferSize in 1 until payload.size) {
                    profile?.reportError(host, BluetoothHidDevice.ERROR_RSP_INVALID_PARAM)
                } else profile?.replyReport(host, type, id, payload)
            } catch (_: SecurityException) { fail("Bluetooth permission was revoked.") }
        }
        override fun onSetReport(host: BluetoothDevice, type: Byte, id: Byte, data: ByteArray) {
            if (current != generation) return
            val error = when {
                host != device -> BluetoothHidDevice.ERROR_RSP_NOT_READY
                type != BluetoothHidDevice.REPORT_TYPE_OUTPUT -> BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ
                reports.outputPayload(id.toInt() and 0xff) == null -> BluetoothHidDevice.ERROR_RSP_INVALID_RPT_ID
                !receiveRumble(id.toInt() and 0xff, data) -> BluetoothHidDevice.ERROR_RSP_INVALID_PARAM
                else -> BluetoothHidDevice.ERROR_RSP_SUCCESS
            }
            runCatching { profile?.reportError(host, error) }
        }
        override fun onInterruptData(host: BluetoothDevice, reportId: Byte, data: ByteArray) {
            if (current == generation && host == device) receiveRumble(reportId.toInt() and 0xff, data)
        }
        override fun onSetProtocol(host: BluetoothDevice, protocol: Byte) {
            if (current == generation && protocol != BluetoothHidDevice.PROTOCOL_REPORT_MODE) {
                runCatching { profile?.reportError(host, BluetoothHidDevice.ERROR_RSP_UNSUPPORTED_REQ) }
            }
        }
        override fun onVirtualCableUnplug(host: BluetoothDevice) {
            if (current == generation && host == device) fail("Laptop removed the Bluetooth gamepad. Pair it again in Bluetooth settings.")
        }
    }

    fun refreshHosts() {
        if (!hasPermission()) { fail("Bluetooth permission was revoked."); return }
        try {
            val hosts = adapter?.bondedDevices.orEmpty().take(32)
                .map { BluetoothHost(it.address, it.name ?: "Paired device") }.sortedBy { it.name }
            mutableState.value = mutableState.value.copy(hosts = hosts)
        } catch (_: SecurityException) { fail("Bluetooth permission was revoked.") }
    }

    fun connect(address: String) {
        if (mutableState.value.phase != BluetoothPhase.READY || !registered) return
        if (!hasPermission()) { fail("Bluetooth permission was revoked."); return }
        try {
            val host = adapter?.bondedDevices?.firstOrNull { it.address == address }
                ?: run { fail("Pair this laptop in Bluetooth settings first."); return }
            mutableState.value = mutableState.value.copy(phase = BluetoothPhase.CONNECTING, hostName = host.name ?: "Laptop", message = "")
            connectingDevice = host
            session.edit { putString("host", address) }
            if (profile?.connect(host) != true) { fail("Could not connect the gamepad. Check your laptop’s Bluetooth settings."); return }
            val current = generation
            handler.postDelayed({
                if (current == generation && mutableState.value.phase == BluetoothPhase.CONNECTING) {
                    fail("Bluetooth connection timed out. Check your laptop’s pairing and gamepad support.")
                }
            }, 15000)
        } catch (_: SecurityException) { fail("Bluetooth permission was revoked.") }
    }

    fun update(state: ControllerState) {
        if (mutableState.value.phase != BluetoothPhase.CONNECTED) return
        // Send each touch transition immediately, preserving short press/release pairs.
        if (!reports.update(state).all(::send)) fail("Bluetooth input stopped. Reconnect your laptop.")
    }

    private fun send(report: HidInputReport): Boolean {
        if (!hasPermission()) return false
        val host = device ?: return false
        return runCatching { profile?.sendReport(host, report.id, report.data) == true }.getOrDefault(false)
    }

    private fun readBattery(): HidInputReport? {
        if (reports.profile != BluetoothControllerProfile.XBOX_ONE) return null
        val manager = context.getSystemService(BatteryManager::class.java) ?: return null
        val percent = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        return if (percent in 0..100) reports.setBattery(percent, manager.isCharging) else null
    }

    private fun receiveRumble(id: Int, data: ByteArray): Boolean {
        val rumble = reports.setOutput(id, data) ?: return false
        if (BluetoothControllerPreferences.gameRumbleEnabled(context)) vibration.rumble(rumble)
        return true
    }

    fun stopRumble() { vibration.stop() }

    fun stop() {
        session.edit { clear() }
        resumeAddress = null
        release()
    }

    /** Android may unregister a background HID app. Re-register and reconnect on return. */
    fun pauseForBackground() {
        if (mutableState.value.phase == BluetoothPhase.OFF || mutableState.value.phase == BluetoothPhase.ERROR) return
        release()
    }

    fun resumeAfterBackground() {
        if (mutableState.value.phase == BluetoothPhase.OFF && session.getBoolean("active", false)) {
            start(session.getString("host", null))
        }
    }

    private fun release() {
        ++generation
        handler.removeCallbacksAndMessages(null)
        reports.update(ControllerState()).forEach(::send)
        vibration.stop()
        val oldProfile = profile
        val oldDevice = device ?: connectingDevice
        device = null
        connectingDevice = null
        profile = null
        registered = false
        runCatching { if (oldDevice != null) oldProfile?.disconnect(oldDevice) }
        runCatching { oldProfile?.unregisterApp() }
        runCatching { if (oldProfile != null) adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, oldProfile) }
        mutableState.value = BluetoothGamepadState()
    }

    fun fail(message: String) { stop(); mutableState.value = BluetoothGamepadState(BluetoothPhase.ERROR, message = message) }
}
