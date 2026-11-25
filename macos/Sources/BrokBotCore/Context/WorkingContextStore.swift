import Foundation

/// Space 1 (Working Context): Ephemeral, token-bounded rolling conversation store.
public actor WorkingContextStore {
    public nonisolated let maxTokenBudget: Int
    private var storedMessages: [ChatMessage] = []
    private var evictedSummary: String?

    public init(maxTokenBudget: Int = 8000) {
        self.maxTokenBudget = max(1, maxTokenBudget)
    }

    /// Estimates token count using a lightweight 4-characters-per-token heuristic.
    public nonisolated static func estimateTokens(for content: String) -> Int {
        max(1, content.count / 4)
    }

    /// Appends a message and trims the oldest entries until within `maxTokenBudget`,
    /// folding evicted turns into a bounded rolling summary.
    /// Always retains at least the most recently appended message.
    public func append(_ message: ChatMessage) {
        storedMessages.append(message)
        trimToBudget()
    }

    /// Replaces an existing message's content and streaming/token metadata in place.
    @discardableResult
    public func replaceMessage(
        id: UUID,
        content: String,
        isStreaming: Bool = false,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        attachments: [ChatAttachment]? = nil
    ) -> Bool {
        guard let index = storedMessages.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let existing = storedMessages[index]
        storedMessages[index] = ChatMessage(
            id: existing.id,
            role: existing.role,
            content: content,
            timestamp: existing.timestamp,
            memoryNotice: existing.memoryNotice,
            isStreaming: isStreaming,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            attachments: attachments ?? existing.attachments
        )
        trimToBudget()
        return true
    }

    /// Returns the currently retained ephemeral working messages in chronological order.
    public func messages() -> [ChatMessage] {
        storedMessages
    }

    /// Returns the bounded rolling summary of turns evicted from `WorkingContextStore`, if any.
    public func rollingSummary() -> String? {
        evictedSummary
    }

    /// Returns the working context window, prepending a synthetic `.system` rolling summary turn when present.
    public func contextWindowMessages() -> [ChatMessage] {
        guard let evictedSummary, !evictedSummary.isEmpty else {
            return storedMessages
        }
        let summaryMessage = ChatMessage(
            role: .system,
            content: "Earlier conversation summary: \(evictedSummary)"
        )
        return [summaryMessage] + storedMessages
    }

    /// Returns the total estimated token count across all retained messages.
    public func estimatedTokenCount() -> Int {
        storedMessages.reduce(0) { partialResult, message in
            partialResult + Self.estimateTokens(for: message.content)
        }
    }

    /// Clears all ephemeral working context turns and any rolling eviction summary.
    public func reset() {
        storedMessages.removeAll()
        evictedSummary = nil
    }

    // MARK: - Eviction & Rolling Summary

    private var summaryCharacterCap: Int {
        max(120, maxTokenBudget / 6)
    }

    private func trimToBudget() {
        while storedMessages.count > 1 && estimatedTokenCount() > maxTokenBudget {
            let evicted = storedMessages.removeFirst()
            foldIntoSummary(evicted)
        }
    }

    private func foldIntoSummary(_ message: ChatMessage) {
        let collapsed = message.content
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return }

        let rolePrefix: String
        switch message.role {
        case .user: rolePrefix = "User"
        case .assistant: rolePrefix = "Assistant"
        case .system: rolePrefix = "System"
        }

        let segment = "\(rolePrefix): \(collapsed)"
        let cap = summaryCharacterCap
        let combined: String
        if let existing = evictedSummary, !existing.isEmpty {
            combined = "\(existing) | \(segment)"
        } else {
            combined = segment
        }

        if combined.count <= cap {
            evictedSummary = combined
        } else if segment.count >= cap {
            let cut = max(0, cap - 3)
            evictedSummary = cap >= 3 ? "\(segment.prefix(cut))..." : String(segment.prefix(cap))
        } else {
            let tailCount = max(0, cap - 4)
            evictedSummary = "... \(combined.suffix(tailCount))"
        }
    }
}
