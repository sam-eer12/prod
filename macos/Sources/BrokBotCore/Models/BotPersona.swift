import Foundation

/// Defines a Brok Bot teammate persona (e.g., Chief of Staff or specialist sub-bot).
public struct BotPersona: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var role: String
    public var systemPrompt: String
    public var symbolName: String
    public var accentHex: String
    public var isDefault: Bool
    public var pinnedToolIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case role
        case systemPrompt
        case symbolName
        case accentHex
        case isDefault
        case pinnedToolIDs
    }

    public init(
        id: String = UUID().uuidString,
        name: String,
        role: String,
        systemPrompt: String,
        symbolName: String,
        accentHex: String,
        isDefault: Bool = false,
        pinnedToolIDs: [String] = []
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.systemPrompt = systemPrompt
        self.symbolName = symbolName
        self.accentHex = accentHex
        self.isDefault = isDefault
        self.pinnedToolIDs = pinnedToolIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.role = try container.decode(String.self, forKey: .role)
        self.systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        self.symbolName = try container.decode(String.self, forKey: .symbolName)
        self.accentHex = try container.decode(String.self, forKey: .accentHex)
        self.isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        self.pinnedToolIDs = try container.decodeIfPresent([String].self, forKey: .pinnedToolIDs) ?? []
    }

    /// Parses `accentHex` (e.g. `#00E5FF` or `00E5FF`) into normalized 0...1 RGB components.
    public var accentRGB: (red: Double, green: Double, blue: Double) {
        Self.parseHexRGB(accentHex) ?? (red: 0.0, green: 0.898, blue: 1.0)
    }

    /// Converts a 6-character RGB hex string to normalized floating-point color components.
    public static func parseHexRGB(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            return nil
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return (red: r, green: g, blue: b)
    }

    /// Primary Chief of Staff orchestrator preset.
    public static let chiefOfStaff = BotPersona(
        id: "chief-of-staff",
        name: "Chief of Staff",
        role: "Primary Orchestrator",
        systemPrompt: "You are Brok Bot's Chief of Staff. Coordinate tasks, respect Dual-Space memory boundaries, and keep responses crisp and actionable.",
        symbolName: "sparkles",
        accentHex: "#00E5FF",
        isDefault: true
    )

    /// Blender & 3D scene generation specialist preset.
    public static let threeDArtist = BotPersona(
        id: "3d-artist",
        name: "3D Artist",
        role: "Blender & Spatial Specialist",
        systemPrompt: "You are the 3D Artist specialist. Generate clean bpy scripts, materials, lighting rigs, and viewport render previews with explicit approval gates.",
        symbolName: "cube.transparent",
        accentHex: "#FF9F0A",
        isDefault: false
    )

    /// Gmail and Google Calendar triage specialist preset.
    public static let inboxTriage = BotPersona(
        id: "inbox-triage",
        name: "Inbox Triage",
        role: "Email & Calendar Specialist",
        systemPrompt: "You are the Inbox Triage specialist. Prioritize unread threads, detect calendar conflicts, and draft concise executive summaries.",
        symbolName: "tray.full",
        accentHex: "#34D399",
        isDefault: false
    )

    /// Built-in default persona presets.
    public static let presets: [BotPersona] = [
        .chiefOfStaff,
        .threeDArtist,
        .inboxTriage
    ]
}
