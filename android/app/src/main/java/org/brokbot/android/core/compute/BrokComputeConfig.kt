package org.brokbot.android.core.compute

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * User-selectable worker concurrency setting for local background processing, embeddings,
 * and CRDT synchronization.
 */
enum class ThreadAllocation(
    val requestedThreads: Int?,
    val label: String
) {
    ONE(1, "1"),
    TWO(2, "2"),
    FOUR(4, "4"),
    AUTO(null, "Auto")
}

/**
 * Immutable snapshot of compute & hardware acceleration preferences.
 */
data class ComputeSettings(
    val threadAllocation: ThreadAllocation = ThreadAllocation.AUTO,
    val nnapiVulkanEnabled: Boolean = true,
    val batterySaverFallback: Boolean = true
)

/**
 * Manages bounded worker thread allocation and NNAPI/Vulkan hardware acceleration state.
 */
class BrokComputeEngine(
    private val availableCoresProvider: () -> Int = { Runtime.getRuntime().availableProcessors() }
) {
    private val _settings = MutableStateFlow(ComputeSettings())
    val settingsFlow: StateFlow<ComputeSettings> = _settings.asStateFlow()

    fun currentSettings(): ComputeSettings = _settings.value

    fun setThreadAllocation(allocation: ThreadAllocation) {
        _settings.value = _settings.value.copy(threadAllocation = allocation)
    }

    fun setNnapiVulkanEnabled(enabled: Boolean) {
        _settings.value = _settings.value.copy(nnapiVulkanEnabled = enabled)
    }

    fun setBatterySaverFallback(enabled: Boolean) {
        _settings.value = _settings.value.copy(batterySaverFallback = enabled)
    }

    /**
     * Resolves and clamps the worker thread count to valid hardware bounds `1..maxOf(1, availableCores)`.
     */
    fun resolveThreadCount(
        allocation: ThreadAllocation = _settings.value.threadAllocation,
        availableCores: Int = availableCoresProvider()
    ): Int {
        val safeCores = maxOf(1, availableCores)
        val requested = allocation.requestedThreads ?: safeCores.coerceIn(1, 4)
        return requested.coerceIn(1, safeCores)
    }

    /**
     * Returns whether NNAPI / Vulkan acceleration should be engaged given user preference
     * and battery saver constraints.
     */
    fun shouldUseHardwareAcceleration(isBatterySaverActive: Boolean = false): Boolean {
        val state = _settings.value
        if (!state.nnapiVulkanEnabled) return false
        if (state.batterySaverFallback && isBatterySaverActive) return false
        return true
    }

    fun effectiveAcceleratorLabel(isBatterySaverActive: Boolean = false): String {
        val state = _settings.value
        return when {
            !state.nnapiVulkanEnabled -> "CPU Only"
            state.batterySaverFallback && isBatterySaverActive -> "CPU Fallback (Battery Saver)"
            else -> "NNAPI / Vulkan"
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    fun dispatcher(): CoroutineDispatcher {
        val parallelism = resolveThreadCount()
        return Dispatchers.Default.limitedParallelism(parallelism)
    }

    companion object {
        val shared: BrokComputeEngine by lazy { BrokComputeEngine() }
    }
}
