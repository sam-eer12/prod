import Foundation

/// Fully assembled Dual-Space LLM prompt combining Space 2 permanent facts and Space 1 working context.
public struct AssembledPrompt: Sendable, Equatable {
    public let systemPrompt: String
    public let messages: [ChatMessage]
    public let injectedMemoryCount: Int
    public let estimatedTotalTokens: Int

    public init(
        systemPrompt: String,
        messages: [ChatMessage],
        injectedMemoryCount: Int,
        estimatedTotalTokens: Int
    ) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.injectedMemoryCount = injectedMemoryCount
        self.estimatedTotalTokens = estimatedTotalTokens
    }
}

/// Assembles a prompt from persona instructions, compacted Space 2 permanent memories, and Space 1 working turns.
public enum DualSpacePromptAssembler {
    public static func assemble(
        persona: BotPersona,
        permanentEntries: [MemoryEntry],
        workingMessages: [ChatMessage],
        rollingSummary: String? = nil,
        latestUserQuery: String? = nil,
        maxMemoryEntries: Int = 6
    ) -> AssembledPrompt {
        let queryForRanking: String
        if let explicitQuery = latestUserQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitQuery.isEmpty {
            queryForRanking = explicitQuery
        } else if let lastUserMessage = workingMessages.last(where: { $0.role == .user }) {
            queryForRanking = lastUserMessage.content
        } else {
            queryForRanking = ""
        }

        let consolidatedEntries = SemanticCompactor.consolidate(permanentEntries)
        let selectedMemories = SemanticCompactor.relevantEntries(
            for: queryForRanking,
            from: consolidatedEntries,
            limit: max(0, maxMemoryEntries)
        )

        var systemSections: [String] = []
        let trimmedPersonaPrompt = persona.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPersonaPrompt.isEmpty {
            systemSections.append(trimmedPersonaPrompt)
        }

        if !persona.pinnedToolIDs.isEmpty {
            systemSections.append("Pinned Tools: \(persona.pinnedToolIDs.joined(separator: ", "))")
        }

        if !selectedMemories.isEmpty {
            let formattedMemories = selectedMemories
                .map { "- [\($0.category)] \($0.content)" }
                .joined(separator: "\n")
            systemSections.append("Permanent Memory Enclave (Space 2):\n\(formattedMemories)")
        }

        if let summary = rollingSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            systemSections.append("Working Context Summary (Space 1):\n\(summary)")
        }

        let assembledSystemPrompt = systemSections.joined(separator: "\n\n")
        let systemTokens = assembledSystemPrompt.isEmpty
            ? 0
            : WorkingContextStore.estimateTokens(for: assembledSystemPrompt)
        let workingTokens = workingMessages.reduce(0) { partialResult, message in
            partialResult + WorkingContextStore.estimateTokens(for: message.content)
        }

        return AssembledPrompt(
            systemPrompt: assembledSystemPrompt,
            messages: workingMessages,
            injectedMemoryCount: selectedMemories.count,
            estimatedTotalTokens: systemTokens + workingTokens
        )
    }
}
