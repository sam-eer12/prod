package com.padlink.controller.core

import android.app.Application
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.SystemClock
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.padlink.controller.PadLinkApplication
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong

enum class PairingPhase { STOPPED, LISTENING, CONSENT, TOKEN, PAIRED, ERROR }
data class PairingUiState(
    val phase: PairingPhase = PairingPhase.STOPPED,
    val endpoint: String = "",
    val connection: Long = 0,
    val label: String = "",
    val address: String = "",
    val code: String = "",
    val remainingSeconds: Int = 0,
    val message: String = "",
) { override fun toString(): String = "PairingUiState(phase=$phase)" }

class PairingViewModel(application: Application) : AndroidViewModel(application) {
    private val core get() = (getApplication<Application>() as PadLinkApplication).pairingCore
    private val mutex = Mutex()
    private val generation = AtomicLong()
    private var polling: Job? = null
    private val mutableState = MutableStateFlow(PairingUiState())
    val state = mutableState.asStateFlow()

    fun start(endpoint: String) {
        val current = generation.incrementAndGet()
        polling?.cancel()
        polling = viewModelScope.launch(Dispatchers.IO) {
            val manager = getApplication<Application>().getSystemService(ConnectivityManager::class.java)
            var registered = false
            val selectedNetwork = wifiPairingRoute(getApplication())?.network
            val callback = object : ConnectivityManager.NetworkCallback() {
                private fun validate() = action {
                    val route = wifiPairingRoute(getApplication())
                    if (generation.get() == current && (route == null || route.endpoint != endpoint || route.network != selectedNetwork)) {
                        fail("Wi-Fi connection changed. Start listening again on the current network.")
                    }
                }
                override fun onLost(network: Network) {
                    if (network == selectedNetwork) action {
                        if (generation.get() == current) fail("Wi-Fi connection lost. Start listening again when connected.")
                    }
                }
                override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) { validate() }
                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) { validate() }
            }
            try {
                manager.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
                registered = true
                mutex.withLock {
                    if (generation.get() != current) return@withLock
                    core.stop()
                    val bound = core.start(endpoint)
                    if (generation.get() == current) mutableState.value = PairingUiState(PairingPhase.LISTENING, endpoint = bound)
                }
                while (isActive && generation.get() == current) {
                    mutex.withLock {
                        if (generation.get() == current) {
                            val previous = mutableState.value
                            when (val event = core.poll()) {
                                PhoneEvent.Pending, PhoneEvent.Frame -> Unit
                                is PhoneEvent.Consent -> mutableState.value = previous.copy(phase = PairingPhase.CONSENT, connection = event.id, label = event.label, address = event.address, code = "")
                                is PhoneEvent.Paired -> mutableState.value = previous.copy(phase = PairingPhase.PAIRED, connection = event.id, code = "", remainingSeconds = 0)
                                is PhoneEvent.Closed -> mutableState.value = PairingUiState(PairingPhase.LISTENING, endpoint = previous.endpoint)
                            }
                            val state = mutableState.value
                            if (state.phase == PairingPhase.TOKEN) {
                                val remaining = ((core.deadline() - SystemClock.elapsedRealtime() + 999) / 1000).coerceAtLeast(0).toInt()
                                mutableState.value = state.copy(remainingSeconds = remaining)
                            }
                        }
                    }
                    delay(20)
                }
            } catch (error: Exception) {
                if (generation.get() == current && isActive) fail(error.message ?: "Pairing connection closed")
            } finally {
                if (registered) manager.unregisterNetworkCallback(callback)
            }
        }
    }

    fun allow(id: Long) = action {
        if (mutableState.value.connection != id || mutableState.value.phase != PairingPhase.CONSENT) return@action
        core.allow(id)
        mutableState.value = mutableState.value.copy(phase = PairingPhase.TOKEN, code = core.code(id), remainingSeconds = 60)
    }
    fun deny(id: Long) = action {
        if (mutableState.value.connection != id) return@action
        core.deny(id)
        mutableState.value = PairingUiState(PairingPhase.LISTENING, endpoint = mutableState.value.endpoint)
    }
    fun cancel(id: Long) = action {
        if (mutableState.value.connection != id) return@action
        core.disconnect(id)
        mutableState.value = PairingUiState(PairingPhase.LISTENING, endpoint = mutableState.value.endpoint)
    }
    fun stop() {
        val current = generation.incrementAndGet()
        polling?.cancel()
        mutableState.value = PairingUiState()
        viewModelScope.launch(Dispatchers.IO) { mutex.withLock { if (generation.get() == current) core.stop() } }
    }
    fun reportError(message: String) { stop(); mutableState.value = PairingUiState(PairingPhase.ERROR, message = message) }
    private fun action(block: () -> Unit) {
        val current = generation.get()
        viewModelScope.launch(Dispatchers.IO) { mutex.withLock {
            if (generation.get() == current) {
                try { block() } catch (error: Exception) { fail(error.message ?: "Pairing connection closed") }
            }
        } }
    }
    private fun fail(message: String) { generation.incrementAndGet(); polling?.cancel(); core.stop(); mutableState.value = PairingUiState(PairingPhase.ERROR, message = message) }
    override fun onCleared() { generation.incrementAndGet(); polling?.cancel(); (getApplication<Application>() as PadLinkApplication).stopPairingIfCreated() }
}
