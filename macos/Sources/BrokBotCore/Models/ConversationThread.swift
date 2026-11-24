import Foundation

/// Persisted conversation thread bound to a bot persona.
public struct ConversationThread: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var personaID: String
    public var title: String
    public var messages: [ChatMessage]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        personaID: String = BotPersona.chiefOfStaff.id,
        title: String = "New Conversation",
        messages: [ChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.personaID = personaID
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Serializable workspace state capturing conversation threads, personas, and runtime settings.
public struct WorkspaceSnapshot: Codable, Sendable, Equatable {
    public var threads: [ConversationThread]
    public var customPersonas: [BotPersona]
    public var activeThreadID: UUID?
    public var selectedPersonaID: String
    public var computeConfig: ComputeConfiguration
    public var byokConfig: BYOKConfiguration

    public init(
        threads: [ConversationThread] = [],
        customPersonas: [BotPersona] = [],
        activeThreadID: UUID? = nil,
        selectedPersonaID: String = BotPersona.chiefOfStaff.id,
        computeConfig: ComputeConfiguration = ComputeConfiguration(),
        byokConfig: BYOKConfiguration = BYOKConfiguration()
    ) {
        self.threads = threads
        self.customPersonas = customPersonas
        self.activeThreadID = activeThreadID
        self.selectedPersonaID = selectedPersonaID
        self.computeConfig = computeConfig
        self.byokConfig = byokConfig
    }
}

/// Persists `WorkspaceSnapshot` JSON atomically to disk.
public actor WorkspacePersistenceStore {
    public static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("BrokBot", isDirectory: true)
            .appendingPathComponent("workspace.json", isDirectory: false)
    }

    public nonisolated let fileURL: URL

    public init(fileURL: URL = WorkspacePersistenceStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    /// Loads the persisted workspace snapshot, returning `nil` if no file exists yet.
    public func load() throws -> WorkspaceSnapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(WorkspaceSnapshot.self, from: data)
    }

    /// Loads the persisted snapshot or returns a fresh default `WorkspaceSnapshot` when absent.
    public func loadOrDefault() throws -> WorkspaceSnapshot {
        try load() ?? WorkspaceSnapshot()
    }

    /// Atomically persists `snapshot` as JSON with restrictive file permissions (`0600`).
    public func save(_ snapshot: WorkspaceSnapshot) throws {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)

        let tempURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: tempURL) }

        guard fileManager.createFile(
            atPath: tempURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: fileURL)
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Removes the persisted workspace file if present.
    public func reset() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
