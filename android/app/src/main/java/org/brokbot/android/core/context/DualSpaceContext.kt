package org.brokbot.android.core.context

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * Conversational participant role inside Working Context (Space 1).
 */
enum class TurnRole(val label: String) {
    USER("You"),
    ASSISTANT("Chief of Staff"),
    SYSTEM("System"),
    TOOL("Tool")
}

/**
 * An ephemeral conversational or scratchpad turn in Working Context.
 */
data class WorkingTurn(
    val id: String = UUID.randomUUID().toString(),
    val role: TurnRole,
    val content: String,
    val timestampMillis: Long = System.currentTimeMillis(),
    val estimatedTokens: Int = estimateTokenCount(content)
) {
    companion object {
        fun estimateTokenCount(text: String): Int {
            val trimmed = text.trim()
            if (trimmed.isEmpty()) return 0
            return maxOf(1, (trimmed.length + 3) / 4)
        }
    }
}

/**
 * Space 1: Ephemeral, thread-scoped Working Context with bounded turn and token windowing.
 */
class WorkingContextStore(
    val maxTurns: Int = 24,
    val maxTokens: Int = 8_000
) {
    init {
        require(maxTurns >= 1) { "maxTurns must be >= 1" }
        require(maxTokens >= 1) { "maxTokens must be >= 1" }
    }

    private val lock = Any()
    private val mutableTurns = ArrayDeque<WorkingTurn>()
    private val _turns = MutableStateFlow<List<WorkingTurn>>(emptyList())
    val turnsFlow: StateFlow<List<WorkingTurn>> = _turns.asStateFlow()

    fun append(role: TurnRole, content: String, timestampMillis: Long = System.currentTimeMillis()): WorkingTurn {
        val turn = WorkingTurn(
            role = role,
            content = content.trim(),
            timestampMillis = timestampMillis
        )
        synchronized(lock) {
            mutableTurns.addLast(turn)
            enforceWindowLocked()
            _turns.value = mutableTurns.toList()
        }
        return turn
    }

    fun turns(): List<WorkingTurn> = synchronized(lock) { mutableTurns.toList() }

    fun totalTokens(): Int = synchronized(lock) { mutableTurns.sumOf { it.estimatedTokens } }

    fun clear() {
        synchronized(lock) {
            mutableTurns.clear()
            _turns.value = emptyList()
        }
    }

    private fun enforceWindowLocked() {
        while (mutableTurns.size > maxTurns) {
            mutableTurns.removeFirst()
        }
        while (mutableTurns.size > 1 && mutableTurns.sumOf { it.estimatedTokens } > maxTokens) {
            mutableTurns.removeFirst()
        }
    }
}

/**
 * A durable user preference, identity fact, or routine persisted in Permanent Memory (Space 2).
 */
data class MemoryEntry(
    val id: String = UUID.randomUUID().toString(),
    val category: String,
    val content: String,
    val updatedAtMillis: Long = System.currentTimeMillis(),
    val confidence: Float = 1.0f
)

/**
 * Parsed natural-language intent targeting Permanent Memory.
 */
sealed interface MemoryCommand {
    data class Store(val fact: String, val category: String = "user_preference") : MemoryCommand
    data class Update(val target: String, val replacement: String) : MemoryCommand
    data class Forget(val target: String) : MemoryCommand
}

/**
 * Result of executing a [MemoryCommand] against [PermanentMemoryManager].
 */
data class MemoryMutationResult(
    val command: MemoryCommand,
    val affectedCount: Int,
    val summary: String
)

/**
 * Summary returned after running [SemanticCompactor] across Permanent Memory.
 */
data class CompactionReport(
    val beforeCount: Int,
    val afterCount: Int
) {
    val removedCount: Int get() = (beforeCount - afterCount).coerceAtLeast(0)
}

/**
 * Natural-language parser for Store / Update / Forget permanent memory commands.
 */
object MemoryCommandParser {
    private val storePatterns = listOf(
        Regex("""(?i)^(?:store|save|remember)\s+(?:this\s+)?(?:in|to)?\s*(?:your\s+)?memory\s*:?\s+(.+)$"""),
        Regex("""(?i)^(?:store|save|remember)\s+(?:this\s+)?(?:in|to)\s+(?:your\s+)?memory\s*:\s*(.+)$"""),
        Regex("""(?i)^remember\s*:\s*(.+)$""")
    )

    private val updatePatterns = listOf(
        Regex("""(?i)^update\s+(?:my\s+)?memory\s*(?:about\s+|:?\s*)(.+?)\s+(?:to|with|->)\s+(.+)$"""),
        Regex("""(?i)^update\s+(?:my\s+)?memory\s*:?\s*(.+?)\s+is\s+now\s+(.+)$""")
    )

    private val forgetSuffixPattern =
        Regex("""(?i)^(?:forget|delete|remove)\s+(.+?)\s+from\s+(?:your\s+)?memory\s*$""")

    private val forgetPrefixPattern =
        Regex("""(?i)^(?:forget|delete|remove)\s+(?:about\s+|from\s+(?:your\s+)?memory\s*:?\s*)?(.+)$""")

    fun parse(input: String): MemoryCommand? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null

        for (pattern in storePatterns) {
            val match = pattern.matchEntire(trimmed) ?: continue
            val fact = match.groupValues[1].trim().trimStart(':').trim()
            if (fact.isNotEmpty()) {
                return MemoryCommand.Store(fact = fact, category = inferCategory(fact))
            }
        }

        for (pattern in updatePatterns) {
            val match = pattern.matchEntire(trimmed) ?: continue
            val target = match.groupValues[1].trim().trimStart(':').trim()
            val replacement = match.groupValues[2].trim()
            if (target.isNotEmpty() && replacement.isNotEmpty()) {
                return MemoryCommand.Update(target = target, replacement = replacement)
            }
        }

        forgetSuffixPattern.matchEntire(trimmed)?.let { match ->
            val target = match.groupValues[1].trim()
            if (target.isNotEmpty()) {
                return MemoryCommand.Forget(target = target)
            }
        }

        forgetPrefixPattern.matchEntire(trimmed)?.let { match ->
            val target = match.groupValues[1].trim().trimStart(':').trim()
            if (target.isNotEmpty()) {
                return MemoryCommand.Forget(target = target)
            }
        }

        return null
    }

    internal fun inferCategory(fact: String): String {
        val lower = fact.lowercase()
        return when {
            listOf("flight", "seat", "hotel", "airline", "frequent flyer").any { it in lower } -> "travel"
            listOf("morning", "brief", "weekday", "schedule", "8:00", "routine").any { it in lower } -> "routine"
            listOf("name is", "timezone", "role", "title", "email").any { it in lower } -> "identity"
            else -> "user_preference"
        }
    }
}

/**
 * Deduplicates and semantically consolidates overlapping Permanent Memory entries.
 */
object SemanticCompactor {
    private val stopWords = setOf(
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "in", "is", "it", "my", "of", "on", "or", "that", "the", "this",
        "to", "with", "your"
    )

    fun consolidate(entries: List<MemoryEntry>): List<MemoryEntry> {
        if (entries.size <= 1) return entries

        val sortedNewestFirst = entries.sortedWith(
            compareByDescending<MemoryEntry> { it.updatedAtMillis }
                .thenByDescending { it.confidence }
        )

        val kept = mutableListOf<MemoryEntry>()
        for (candidate in sortedNewestFirst) {
            val existingIndex = kept.indexOfFirst { existing ->
                isSemanticDuplicate(existing, candidate)
            }
            if (existingIndex == -1) {
                kept.add(candidate)
            } else {
                val existing = kept[existingIndex]
                // Retain newest timestamp while keeping the richer phrasing if same recency.
                val preferred = if (candidate.updatedAtMillis > existing.updatedAtMillis) {
                    candidate
                } else if (candidate.updatedAtMillis == existing.updatedAtMillis &&
                    candidate.content.length > existing.content.length
                ) {
                    candidate
                } else {
                    existing
                }
                kept[existingIndex] = preferred
            }
        }
        return kept
    }

    internal fun isSemanticDuplicate(a: MemoryEntry, b: MemoryEntry): Boolean {
        val normA = normalizeText(a.content)
        val normB = normalizeText(b.content)
        if (normA.isEmpty() || normB.isEmpty()) return normA == normB
        if (normA == normB) return true

        val tokensA = meaningfulTokens(normA)
        val tokensB = meaningfulTokens(normB)
        if (tokensA.isEmpty() || tokensB.isEmpty()) return false

        val intersection = tokensA.intersect(tokensB).size.toDouble()
        val union = tokensA.union(tokensB).size.toDouble()
        val jaccard = intersection / union
        if (jaccard >= 0.80) return true

        // Check containment when one fact is an elaborated restatement of the other.
        val minSize = minOf(tokensA.size, tokensB.size)
        val overlapOnSmaller = intersection / minSize.toDouble()
        return overlapOnSmaller >= 0.85 && a.category == b.category && jaccard >= 0.60
    }

    internal fun normalizeText(text: String): String =
        text.lowercase()
            .replace(Regex("[^a-z0-9\\s]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

    internal fun meaningfulTokens(normalizedText: String): Set<String> =
        normalizedText.split(" ")
            .filter { it.isNotBlank() && it !in stopWords }
            .toSet()
}

/**
 * Space 2: Permanent Personal Memory Enclave manager supporting natural-language mutations
 * and semantic auto-compaction.
 */
class PermanentMemoryManager(
    initialEntries: List<MemoryEntry> = defaultBootstrapMemories()
) {
    private val lock = Any()
    private val _entries = MutableStateFlow(initialEntries)
    val entriesFlow: StateFlow<List<MemoryEntry>> = _entries.asStateFlow()

    fun entries(): List<MemoryEntry> = synchronized(lock) { _entries.value }

    fun executeNaturalLanguage(input: String): MemoryMutationResult? {
        val command = MemoryCommandParser.parse(input) ?: return null
        return execute(command)
    }

    fun execute(command: MemoryCommand): MemoryMutationResult = synchronized(lock) {
        val current = _entries.value.toMutableList()
        when (command) {
            is MemoryCommand.Store -> {
                val normFact = SemanticCompactor.normalizeText(command.fact)
                val existingIdx = current.indexOfFirst {
                    SemanticCompactor.normalizeText(it.content) == normFact
                }
                val entry = MemoryEntry(
                    id = if (existingIdx >= 0) current[existingIdx].id else UUID.randomUUID().toString(),
                    category = command.category,
                    content = command.fact,
                    updatedAtMillis = System.currentTimeMillis()
                )
                if (existingIdx >= 0) {
                    current[existingIdx] = entry
                } else {
                    current.add(0, entry)
                }
                _entries.value = current
                MemoryMutationResult(
                    command = command,
                    affectedCount = 1,
                    summary = "Saved to permanent memory (${command.category}): ${command.fact}"
                )
            }

            is MemoryCommand.Update -> {
                val matches = current.indices.filter { matchesTarget(current[it], command.target) }
                if (matches.isEmpty()) {
                    val created = MemoryEntry(
                        category = MemoryCommandParser.inferCategory("${command.target} ${command.replacement}"),
                        content = "${command.target}: ${command.replacement}",
                        updatedAtMillis = System.currentTimeMillis()
                    )
                    current.add(0, created)
                    _entries.value = current
                    return@synchronized MemoryMutationResult(
                        command = command,
                        affectedCount = 1,
                        summary = "No prior entry matched '${command.target}'; stored '${created.content}'."
                    )
                }

                val updatedContent = formatUpdatedContent(command.target, command.replacement)
                for (index in matches) {
                    val existing = current[index]
                    current[index] = existing.copy(
                        content = updatedContent,
                        updatedAtMillis = System.currentTimeMillis()
                    )
                }
                _entries.value = current
                MemoryMutationResult(
                    command = command,
                    affectedCount = matches.size,
                    summary = "Updated ${matches.size} permanent memory record(s) to '$updatedContent'."
                )
            }

            is MemoryCommand.Forget -> {
                val remaining = current.filterNot { matchesTarget(it, command.target) }
                val deletedCount = current.size - remaining.size
                _entries.value = remaining
                MemoryMutationResult(
                    command = command,
                    affectedCount = deletedCount,
                    summary = if (deletedCount > 0) {
                        "Purged $deletedCount record(s) matching '${command.target}' from permanent memory."
                    } else {
                        "No permanent memory records matched '${command.target}'."
                    }
                )
            }
        }
    }

    fun removeById(id: String): Boolean = synchronized(lock) {
        val current = _entries.value
        val next = current.filterNot { it.id == id }
        _entries.value = next
        next.size != current.size
    }

    fun compact(): CompactionReport = synchronized(lock) {
        val before = _entries.value.size
        val compacted = SemanticCompactor.consolidate(_entries.value)
        _entries.value = compacted
        CompactionReport(beforeCount = before, afterCount = compacted.size)
    }

    private fun formatUpdatedContent(target: String, replacement: String): String {
        val cleanTarget = target.trim()
        val cleanReplacement = replacement.trim()
        val targetTokens = SemanticCompactor.meaningfulTokens(SemanticCompactor.normalizeText(cleanTarget))
        val replacementNorm = SemanticCompactor.normalizeText(cleanReplacement)
        val alreadyIncludesTarget = targetTokens.isNotEmpty() &&
            targetTokens.all { it in replacementNorm }
        return if (alreadyIncludesTarget) cleanReplacement else "$cleanTarget: $cleanReplacement"
    }

    private fun matchesTarget(entry: MemoryEntry, target: String): Boolean {
        val normEntry = SemanticCompactor.normalizeText(entry.content)
        val normTarget = SemanticCompactor.normalizeText(target)
        if (normTarget.isEmpty()) return false
        if (normEntry.contains(normTarget)) return true

        val targetTokens = SemanticCompactor.meaningfulTokens(normTarget)
        val entryTokens = SemanticCompactor.meaningfulTokens(normEntry)
        if (targetTokens.isEmpty() || entryTokens.isEmpty()) return false

        val overlap = targetTokens.intersect(entryTokens).size.toDouble() / targetTokens.size.toDouble()
        return overlap >= 0.65
    }

    companion object {
        fun defaultBootstrapMemories(): List<MemoryEntry> = listOf(
            MemoryEntry(
                category = "routine",
                content = "Morning executive briefing runs silently at 08:00 local time."
            ),
            MemoryEntry(
                category = "user_preference",
                content = "Prefer concise bulleted summaries with explicit approval before writes."
            )
        )
    }
}
