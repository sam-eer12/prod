package org.brokbot.android

import org.brokbot.android.core.compute.BrokComputeEngine
import org.brokbot.android.core.compute.ThreadAllocation
import org.brokbot.android.core.context.MemoryCommand
import org.brokbot.android.core.context.MemoryCommandParser
import org.brokbot.android.core.context.MemoryEntry
import org.brokbot.android.core.context.PermanentMemoryManager
import org.brokbot.android.core.context.SemanticCompactor
import org.brokbot.android.core.context.TurnRole
import org.brokbot.android.core.context.WorkingContextStore
import org.brokbot.android.core.providers.BYOKProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DualSpaceContextTest {

    @Test
    fun workingContextWindowingEnforcesTurnAndTokenBudgets() {
        val turnLimited = WorkingContextStore(maxTurns = 3, maxTokens = 10_000)
        turnLimited.append(TurnRole.USER, "Turn 1")
        turnLimited.append(TurnRole.ASSISTANT, "Turn 2")
        turnLimited.append(TurnRole.USER, "Turn 3")
        turnLimited.append(TurnRole.ASSISTANT, "Turn 4")

        val turns = turnLimited.turns()
        assertEquals(3, turns.size)
        assertEquals(listOf("Turn 2", "Turn 3", "Turn 4"), turns.map { it.content })

        // Each 20-char message estimates to 5 tokens; budget of 12 tokens keeps only last 2 turns.
        val tokenLimited = WorkingContextStore(maxTurns = 20, maxTokens = 12)
        tokenLimited.append(TurnRole.USER, "12345678901234567890")
        tokenLimited.append(TurnRole.ASSISTANT, "abcdefghijklmnopqrst")
        tokenLimited.append(TurnRole.USER, "uvwxyz1234567890abcd")

        assertEquals(2, tokenLimited.turns().size)
        assertTrue(tokenLimited.totalTokens() <= 12)
        assertEquals("uvwxyz1234567890abcd", tokenLimited.turns().last().content)

        tokenLimited.clear()
        assertTrue(tokenLimited.turns().isEmpty())
        assertEquals(0, tokenLimited.totalTokens())
    }

    @Test
    fun memoryCommandParserHandlesStoreUpdateForgetAndNormalPrompts() {
        val storeCmd = MemoryCommandParser.parse(
            "Store this in your memory: My preferred flight seat is aisle"
        )
        assertTrue(storeCmd is MemoryCommand.Store)
        storeCmd as MemoryCommand.Store
        assertEquals("My preferred flight seat is aisle", storeCmd.fact)
        assertEquals("travel", storeCmd.category)

        val saveCmd = MemoryCommandParser.parse("Remember: Preferred output language is Spanish")
        assertEquals(
            MemoryCommand.Store("Preferred output language is Spanish", "user_preference"),
            saveCmd
        )

        val updateCmd = MemoryCommandParser.parse(
            "Update my memory about preferred flight seat to window"
        )
        assertEquals(
            MemoryCommand.Update(target = "preferred flight seat", replacement = "window"),
            updateCmd
        )

        val updateIsNow = MemoryCommandParser.parse(
            "Update my memory: preferred output language is now French"
        )
        assertEquals(
            MemoryCommand.Update(target = "preferred output language", replacement = "French"),
            updateIsNow
        )

        val forgetPrefix = MemoryCommandParser.parse("Forget my frequent flyer number")
        assertEquals(MemoryCommand.Forget("my frequent flyer number"), forgetPrefix)

        val forgetSuffix = MemoryCommandParser.parse(
            "Delete preferred flight seat from your memory"
        )
        assertEquals(MemoryCommand.Forget("preferred flight seat"), forgetSuffix)

        val deleteColon = MemoryCommandParser.parse("Delete from your memory: stale credential")
        assertEquals(MemoryCommand.Forget("stale credential"), deleteColon)

        assertNull(MemoryCommandParser.parse("What meetings do I have on Friday?"))
        assertNull(MemoryCommandParser.parse("Remember to buy coffee beans"))
    }

    @Test
    fun permanentMemoryManagerExecutesStoreUpdateAndForget() {
        val manager = PermanentMemoryManager(initialEntries = emptyList())

        val storeResult = manager.executeNaturalLanguage(
            "Store this in your memory: My preferred flight seat is aisle"
        )
        assertNotNull(storeResult)
        assertEquals(1, manager.entries().size)
        assertEquals("travel", manager.entries().first().category)

        val updateResult = manager.executeNaturalLanguage(
            "Update my memory about preferred flight seat to window"
        )
        assertNotNull(updateResult)
        assertEquals(1, updateResult?.affectedCount)
        assertEquals(1, manager.entries().size)
        assertTrue(manager.entries().first().content.contains("window", ignoreCase = true))

        val forgetResult = manager.executeNaturalLanguage(
            "Forget preferred flight seat"
        )
        assertNotNull(forgetResult)
        assertEquals(1, forgetResult?.affectedCount)
        assertTrue(manager.entries().isEmpty())
    }

    @Test
    fun semanticCompactorDeduplicatesAndRetainsDistinctFacts() {
        val entries = listOf(
            MemoryEntry(
                id = "old-dup",
                category = "travel",
                content = "My preferred flight seat is aisle",
                updatedAtMillis = 1_000L
            ),
            MemoryEntry(
                id = "new-dup",
                category = "travel",
                content = "my preferred flight seat is aisle.",
                updatedAtMillis = 2_000L
            ),
            MemoryEntry(
                id = "near-dup",
                category = "travel",
                content = "Preferred flight seat is aisle",
                updatedAtMillis = 1_500L
            ),
            MemoryEntry(
                id = "distinct-1",
                category = "routine",
                content = "Morning executive briefing runs at 08:00 weekdays",
                updatedAtMillis = 1_200L
            ),
            MemoryEntry(
                id = "distinct-2",
                category = "user_preference",
                content = "Preferred output language is Spanish",
                updatedAtMillis = 1_300L
            )
        )

        val compacted = SemanticCompactor.consolidate(entries)
        assertEquals(3, compacted.size)
        assertTrue(compacted.any { it.id == "new-dup" })
        assertTrue(compacted.any { it.id == "distinct-1" })
        assertTrue(compacted.any { it.id == "distinct-2" })

        val manager = PermanentMemoryManager(initialEntries = entries)
        val report = manager.compact()
        assertEquals(5, report.beforeCount)
        assertEquals(3, report.afterCount)
        assertEquals(2, report.removedCount)
    }

    @Test
    fun computeEngineClampsThreadBoundsAndTogglesHardwareAcceleration() {
        val dualCoreEngine = BrokComputeEngine(availableCoresProvider = { 2 })
        assertEquals(1, dualCoreEngine.resolveThreadCount(ThreadAllocation.ONE))
        assertEquals(2, dualCoreEngine.resolveThreadCount(ThreadAllocation.TWO))
        assertEquals(2, dualCoreEngine.resolveThreadCount(ThreadAllocation.FOUR))
        assertEquals(2, dualCoreEngine.resolveThreadCount(ThreadAllocation.AUTO))

        val octaCoreEngine = BrokComputeEngine(availableCoresProvider = { 8 })
        assertEquals(4, octaCoreEngine.resolveThreadCount(ThreadAllocation.FOUR))
        assertEquals(4, octaCoreEngine.resolveThreadCount(ThreadAllocation.AUTO))

        val zeroCoreFallback = BrokComputeEngine(availableCoresProvider = { 0 })
        assertEquals(1, zeroCoreFallback.resolveThreadCount(ThreadAllocation.FOUR))

        octaCoreEngine.setThreadAllocation(ThreadAllocation.TWO)
        assertEquals(2, octaCoreEngine.resolveThreadCount())

        assertTrue(octaCoreEngine.shouldUseHardwareAcceleration(isBatterySaverActive = false))
        assertFalse(octaCoreEngine.shouldUseHardwareAcceleration(isBatterySaverActive = true))
        assertEquals(
            "CPU Fallback (Battery Saver)",
            octaCoreEngine.effectiveAcceleratorLabel(isBatterySaverActive = true)
        )

        octaCoreEngine.setNnapiVulkanEnabled(false)
        assertFalse(octaCoreEngine.shouldUseHardwareAcceleration(isBatterySaverActive = false))
        assertEquals("CPU Only", octaCoreEngine.effectiveAcceleratorLabel())
    }

    @Test
    fun byokProvidersExposeFiveConfiguredEndpoints() {
        assertEquals(5, BYOKProvider.entries.size)
        BYOKProvider.entries.forEach { provider ->
            assertTrue(provider.displayName.isNotBlank())
            assertTrue(provider.defaultModel.isNotBlank())
            assertTrue(provider.baseUrl.startsWith("https://"))
        }
    }
}
