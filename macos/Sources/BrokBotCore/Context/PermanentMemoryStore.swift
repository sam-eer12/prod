import Foundation

/// A single durable personal memory item stored inside Space 2 (Permanent Context Enclave).
public struct MemoryEntry: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var category: String
    public var content: String
    public var lastUpdated: Date
    public var confidence: Float

    public init(
        id: UUID = UUID(),
        category: String = "user_preference",
        content: String,
        lastUpdated: Date = Date(),
        confidence: Float = 1.0
    ) {
        self.id = id
        self.category = category
        self.content = content
        self.lastUpdated = lastUpdated
        self.confidence = confidence
    }
}

/// Natural-language intent extracted from user messages targeting Permanent Memory.
public enum MemoryCommand: Equatable, Sendable {
    case store(String)
    case update(target: String, replacement: String)
    case delete(target: String)
}

/// Regex-based natural-language parser for Dual-Space Memory commands.
public enum MemoryCommandParser {
    /// Parses explicit natural-language memory commands, returning `nil` for normal conversation turns.
    public static func parse(_ input: String) -> MemoryCommand? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Store: "store (this in your )?memory: ...", "save (this )?(to|in) (your )?memory: ...", "remember: ...", "remember that ..."
        let storePatterns = [
            #"^\s*(?:store|save)\s+(?:this\s+)?(?:(?:in|to)\s+(?:your\s+)?)?memory\s*:\s*(.+?)\s*$"#,
            #"^\s*remember\s*:\s*(.+?)\s*$"#,
            #"^\s*remember\s+that\s+(.+?)\s*$"#
        ]
        for pattern in storePatterns {
            if let groups = captureGroups(pattern: pattern, in: trimmed),
               let fact = groups.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fact.isEmpty {
                return .store(fact)
            }
        }

        // 2. Update: "update (my )?memory (about )?<X> (to|with) <Y>"
        let updatePattern = #"^\s*update\s+(?:my\s+)?memory\s+(?:about\s+)?(.+?)\s+(?:to|with)\s+(.+?)\s*$"#
        if let groups = captureGroups(pattern: updatePattern, in: trimmed),
           groups.count >= 2 {
            let target = groups[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty && !replacement.isEmpty {
                return .update(target: target, replacement: replacement)
            }
        }

        // 3. Delete / Forget: "forget (about )?<X>" or "delete <X> from (your )?memory"
        let deletePatterns = [
            #"^\s*forget\s+(?:about\s+)?(.+?)\s*$"#,
            #"^\s*delete\s+(.+?)\s+from\s+(?:your\s+)?memory\s*$"#
        ]
        for pattern in deletePatterns {
            if let groups = captureGroups(pattern: pattern, in: trimmed),
               let target = groups.first?.trimmingCharacters(in: .whitespacesAndNewlines),
               !target.isEmpty {
                return .delete(target: target)
            }
        }

        return nil
    }

    private static func captureGroups(pattern: String, in input: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let nsInput = input as NSString
        let fullRange = NSRange(location: 0, length: nsInput.length)
        guard let match = regex.firstMatch(in: input, options: [], range: fullRange),
              match.numberOfRanges > 1 else {
            return nil
        }

        var results: [String] = []
        for idx in 1..<match.numberOfRanges {
            let range = match.range(at: idx)
            guard range.location != NSNotFound else { continue }
            results.append(nsInput.substring(with: range))
        }
        return results
    }
}

/// Deduplicates, consolidates superseding facts, classifies categories, and ranks Permanent Memory entries.
public enum SemanticCompactor {
    private static let cosineDeduplicationThreshold = 0.78

    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from",
        "has", "have", "i", "in", "is", "it", "my", "of", "on", "or",
        "our", "that", "the", "this", "to", "with", "you", "your"
    ]

    private static let travelKeywords: Set<String> = [
        "flight", "seat", "aisle", "window", "airline", "flyer", "airport",
        "hotel", "passport", "tsa", "lounge", "boarding", "mileage",
        "itinerary", "trip", "travel", "train", "united", "delta"
    ]

    private static let identityKeywords: Set<String> = [
        "name", "email", "phone", "address", "birthday", "born", "timezone",
        "locale", "location", "home", "city", "live", "pronouns",
        "nationality", "citizen", "language", "speak"
    ]

    private static let routineKeywords: Set<String> = [
        "morning", "briefing", "weekday", "weekdays", "daily", "weekly",
        "schedule", "standup", "alarm", "reminder", "routine", "every",
        "bedtime", "workout"
    ]

    private static let workKeywords: Set<String> = [
        "work", "job", "company", "team", "project", "repo", "repository",
        "office", "manager", "ceo", "founder", "client", "vip", "deadline",
        "github", "jira", "slack", "meeting", "meetings", "role", "title", "engineer"
    ]

    private static let preferenceKeywords: Set<String> = [
        "prefer", "preferred", "prefers", "favorite", "favourite", "like",
        "likes", "dislike", "dislikes", "dark", "light", "theme", "font",
        "coffee", "tea", "vegetarian", "vegan", "allergy", "allergic",
        "diet", "bulleted", "concise", "tone", "style", "mode"
    ]

    /// Infers a structured memory category (`travel`, `identity`, `routine`, `work`, `preference`, or `user_preference`).
    public static func inferCategory(for content: String) -> String {
        let tokens = Set(normalizedTokens(for: content))
        guard !tokens.isEmpty else { return "user_preference" }

        let candidates: [(category: String, score: Int)] = [
            ("travel", tokens.intersection(travelKeywords).count),
            ("identity", tokens.intersection(identityKeywords).count),
            ("routine", tokens.intersection(routineKeywords).count),
            ("work", tokens.intersection(workKeywords).count),
            ("preference", tokens.intersection(preferenceKeywords).count)
        ]

        if let best = candidates.max(by: { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            // Prefer earlier domain categories over generic ones on ties
            let order = ["travel": 5, "identity": 4, "routine": 3, "work": 2, "preference": 1]
            return (order[lhs.category] ?? 0) < (order[rhs.category] ?? 0)
        }), best.score > 0 {
            return best.category
        }
        return "user_preference"
    }

    /// Produces a normalized case-insensitive comparison key with collapsed whitespace.
    public static func normalizedKey(for content: String) -> String {
        content
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// Produces lowercased alphanumeric tokens for similarity and relevance scoring.
    public static func normalizedTokens(for content: String) -> [String] {
        content
            .lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Computes bag-of-words term-frequency cosine similarity in `0.0...1.0` over normalized tokens.
    public static func cosineSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = normalizedTokens(for: lhs)
        let rhsTokens = normalizedTokens(for: rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0.0 }

        var lhsCounts: [String: Double] = [:]
        for token in lhsTokens {
            lhsCounts[token, default: 0] += 1.0
        }

        var rhsCounts: [String: Double] = [:]
        for token in rhsTokens {
            rhsCounts[token, default: 0] += 1.0
        }

        var dotProduct = 0.0
        for (token, count) in lhsCounts {
            if let rhsCount = rhsCounts[token] {
                dotProduct += count * rhsCount
            }
        }
        guard dotProduct > 0 else { return 0.0 }

        let lhsNorm = sqrt(lhsCounts.values.reduce(0.0) { $0 + ($1 * $1) })
        let rhsNorm = sqrt(rhsCounts.values.reduce(0.0) { $0 + ($1 * $1) })
        guard lhsNorm > 0, rhsNorm > 0 else { return 0.0 }

        return min(1.0, dotProduct / (lhsNorm * rhsNorm))
    }

    /// Consolidates exact duplicates, cosine-similar duplicates (`>= 0.78` within the same category),
    /// and superseding subject-fact entries, retaining the freshest record.
    public static func consolidate(_ entries: [MemoryEntry]) -> [MemoryEntry] {
        let sortedNewestFirst = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.lastUpdated != rhs.element.lastUpdated {
                return lhs.element.lastUpdated > rhs.element.lastUpdated
            }
            if lhs.element.confidence != rhs.element.confidence {
                return lhs.element.confidence > rhs.element.confidence
            }
            if lhs.offset != rhs.offset {
                return lhs.offset > rhs.offset
            }
            return lhs.element.content.localizedCaseInsensitiveCompare(rhs.element.content) == .orderedAscending
        }

        var kept: [MemoryEntry] = []

        for (_, candidate) in sortedNewestFirst {
            let candidateKey = normalizedKey(for: candidate.content)
            guard !candidateKey.isEmpty else { continue }

            let candidateSubject = extractSubjectKey(from: candidate.content)
            let isRedundant = kept.contains { existing in
                if normalizedKey(for: existing.content) == candidateKey {
                    return true
                }

                if let candidateSubject,
                   let existingSubject = extractSubjectKey(from: existing.content),
                   candidateSubject == existingSubject,
                   categoriesCompatibleForSupersession(existing.category, candidate.category) {
                    return true
                }

                if existing.category.caseInsensitiveCompare(candidate.category) == .orderedSame,
                   cosineSimilarity(existing.content, candidate.content) >= cosineDeduplicationThreshold {
                    return true
                }

                return false
            }

            if !isRedundant {
                kept.append(candidate)
            }
        }

        return kept.sorted { lhs, rhs in
            if lhs.lastUpdated != rhs.lastUpdated {
                return lhs.lastUpdated > rhs.lastUpdated
            }
            return lhs.content.localizedCaseInsensitiveCompare(rhs.content) == .orderedAscending
        }
    }

    /// Selects up to `limit` permanent memory entries ranked by query token overlap, recency, and confidence.
    public static func relevantEntries(
        for query: String,
        from entries: [MemoryEntry],
        limit: Int = 6
    ) -> [MemoryEntry] {
        guard limit > 0, !entries.isEmpty else { return [] }

        let rawQueryTokens = normalizedTokens(for: query)
        let meaningfulQueryTokens = rawQueryTokens.filter { !stopWords.contains($0) }
        let queryTokenSet = Set(meaningfulQueryTokens.isEmpty ? rawQueryTokens : meaningfulQueryTokens)
        let newestDate = entries.map(\.lastUpdated).max() ?? Date()

        let scored: [(entry: MemoryEntry, score: Double)] = entries.map { entry in
            let entryTokens = Set(normalizedTokens(for: entry.content) + normalizedTokens(for: entry.category))
            let overlapRatio: Double
            if queryTokenSet.isEmpty {
                overlapRatio = 0.0
            } else {
                let overlapCount = queryTokenSet.intersection(entryTokens).count
                overlapRatio = Double(overlapCount) / Double(queryTokenSet.count)
            }

            let ageSeconds = max(0.0, newestDate.timeIntervalSince(entry.lastUpdated))
            let recencyScore = 1.0 / (1.0 + (ageSeconds / 86_400.0))
            let confidenceScore = Double(max(0.0, min(1.0, entry.confidence)))

            let totalScore = (overlapRatio * 3.0) + (recencyScore * 0.5) + (confidenceScore * 0.3)
            return (entry: entry, score: totalScore)
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.entry.lastUpdated != rhs.entry.lastUpdated {
                    return lhs.entry.lastUpdated > rhs.entry.lastUpdated
                }
                return lhs.entry.id.uuidString < rhs.entry.id.uuidString
            }
            .prefix(limit)
            .map(\.entry)
    }

    // MARK: - Helpers

    private static func categoriesCompatibleForSupersession(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            return true
        }
        return lhs == "user_preference" || rhs == "user_preference"
    }

    private static func extractSubjectKey(from content: String) -> String? {
        let trimmed = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^\s*(.+?)\s+(?:is\s+now|are\s+now|is|are|:=|:|=)\s+(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsInput = trimmed as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 3 else {
            return nil
        }

        let rawSubject = nsInput.substring(with: match.range(at: 1))
            .replacingOccurrences(of: #"(?i)^(?:user's|my|the|our|user)\s+"#, with: "", options: .regularExpression)
        let rawValue = nsInput.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }

        let subjectTokens = normalizedTokens(for: rawSubject)
        let meaningful = subjectTokens.filter { !stopWords.contains($0) }
        guard !meaningful.isEmpty else { return nil }
        return subjectTokens.joined(separator: " ")
    }
}

/// Persistence abstraction seam for Space 2 encrypted vault storage.
public protocol BrokVaultStoring: Sendable {
    func loadEntries() async throws -> [MemoryEntry]
    func saveEntries(_ entries: [MemoryEntry]) async throws
}

/// Ephemeral in-memory implementation of `BrokVaultStoring` for unit testing and previews.
public actor InMemoryVaultStore: BrokVaultStoring {
    private var entries: [MemoryEntry]

    public init(initialEntries: [MemoryEntry] = []) {
        self.entries = initialEntries
    }

    public func loadEntries() async throws -> [MemoryEntry] {
        entries
    }

    public func saveEntries(_ entries: [MemoryEntry]) async throws {
        self.entries = entries
    }
}

/// Space 2 (Permanent Context Enclave): Manages durable personal facts, natural-language updates, and compaction.
public actor PermanentContextEnclaveManager {
    private let vault: any BrokVaultStoring

    public init(vault: any BrokVaultStoring = InMemoryVaultStore()) {
        self.vault = vault
    }

    /// Intercepts natural-language memory commands and applies them against the vault.
    /// Returns a user-facing status notice if a command was executed, or `nil` for normal chat turns.
    public func executeMemoryCommand(_ input: String) async throws -> String? {
        guard let command = MemoryCommandParser.parse(input) else {
            return nil
        }

        switch command {
        case .store(let fact):
            try await saveFact(fact, category: nil)
            return "Saved to your permanent memory in secure storage."

        case .update(let target, let replacement):
            let updatedCount = try await updateFacts(matching: target, to: replacement)
            if updatedCount > 0 {
                return "Updated \(updatedCount) record(s) in your permanent memory."
            } else {
                return "No matching permanent memory record found for \"\(target)\"."
            }

        case .delete(let target):
            let deletedCount = try await purgeFacts(matching: target)
            return "Removed \(deletedCount) record(s) from your permanent memory."
        }
    }

    /// Lists all entries currently stored in the permanent memory vault.
    public func listEntries() async throws -> [MemoryEntry] {
        try await vault.loadEntries()
    }

    /// Persists a new fact into permanent memory, inferring its category automatically when `category` is omitted.
    public func saveFact(_ fact: String, category: String? = nil) async throws {
        let trimmed = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let resolvedCategory: String
        if let explicit = category?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            resolvedCategory = explicit
        } else {
            resolvedCategory = SemanticCompactor.inferCategory(for: trimmed)
        }

        var entries = try await vault.loadEntries()
        entries.append(MemoryEntry(category: resolvedCategory, content: trimmed, lastUpdated: Date(), confidence: 1.0))
        try await vault.saveEntries(entries)
    }

    /// Updates a specific permanent memory record by `id`, returning `true` if found and updated.
    @discardableResult
    public func updateFact(id: UUID, content: String, category: String? = nil) async throws -> Bool {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return false }

        var entries = try await vault.loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return false
        }

        entries[index].content = trimmedContent
        if let explicitCategory = category?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitCategory.isEmpty {
            entries[index].category = explicitCategory
        }
        entries[index].lastUpdated = Date()

        try await vault.saveEntries(entries)
        return true
    }

    /// Updates all facts matching `query` in place with `replacement` and returns the count updated.
    @discardableResult
    public func updateFacts(matching query: String, to replacement: String) async throws -> Int {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, !trimmedReplacement.isEmpty else { return 0 }

        var entries = try await vault.loadEntries()
        var updatedCount = 0
        let now = Date()

        for index in entries.indices where matches(entry: entries[index], query: trimmedQuery) {
            entries[index].content = trimmedReplacement
            entries[index].lastUpdated = now
            updatedCount += 1
        }

        if updatedCount > 0 {
            try await vault.saveEntries(entries)
        }
        return updatedCount
    }

    /// Purges all facts matching `query` from permanent memory and returns the count removed.
    @discardableResult
    public func purgeFacts(matching query: String) async throws -> Int {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return 0 }

        let entries = try await vault.loadEntries()
        let remaining = entries.filter { !matches(entry: $0, query: trimmedQuery) }
        let deletedCount = entries.count - remaining.count

        if deletedCount > 0 {
            try await vault.saveEntries(remaining)
        }
        return deletedCount
    }

    /// Removes the single memory entry matching `id` from permanent memory.
    @discardableResult
    public func purgeFact(id: UUID) async throws -> Bool {
        let entries = try await vault.loadEntries()
        let remaining = entries.filter { $0.id != id }
        guard remaining.count < entries.count else { return false }
        try await vault.saveEntries(remaining)
        return true
    }

    /// Consolidates duplicate and superseded entries and returns the number of redundant records removed.
    @discardableResult
    public func autoCompact() async throws -> Int {
        let entries = try await vault.loadEntries()
        let compacted = SemanticCompactor.consolidate(entries)
        let removedCount = max(0, entries.count - compacted.count)
        try await vault.saveEntries(compacted)
        return removedCount
    }

    private func matches(entry: MemoryEntry, query: String) -> Bool {
        if entry.content.localizedCaseInsensitiveContains(query) ||
            entry.category.localizedCaseInsensitiveContains(query) {
            return true
        }
        let normalizedContent = SemanticCompactor.normalizedKey(for: entry.content)
        let normalizedQuery = SemanticCompactor.normalizedKey(for: query)
        return !normalizedQuery.isEmpty && normalizedContent.contains(normalizedQuery)
    }
}
