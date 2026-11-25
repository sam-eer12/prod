import BrokBotCore
import SwiftUI

/// Minimal Liquid Glass modal sheet for creating or editing custom specialist bots, avatars, and attention alerts.
struct PersonaEditorSheet: View {
    let existingPersona: BotPersona?
    let onSave: (BotPersona) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedPresetID: String?
    @State private var name: String
    @State private var role: String
    @State private var systemPrompt: String
    @State private var accentHex: String
    @State private var customPickerColor: Color
    @State private var avatarShape: BotAvatarShape
    @State private var avatarStyle: BotAvatarStyle
    @State private var avatarFace: BotAvatarFace
    @State private var symbolName: String
    @State private var notificationsEnabled: Bool

    private static let colorSwatches: [(name: String, hex: String)] = [
        ("Cyan", "#00E5FF"),
        ("Amber", "#FF9F0A"),
        ("Emerald", "#34D399"),
        ("Violet", "#A78BFA"),
        ("Rose", "#F472B6"),
        ("Sky", "#60A5FA"),
        ("Coral", "#F87171"),
        ("Gold", "#FACC15")
    ]

    private static let symbolChoices: [String] = [
        "sparkles",
        "cube.transparent",
        "tray.full",
        "terminal",
        "doc.text.magnifyingglass",
        "calendar.badge.clock",
        "wand.and.stars",
        "cpu",
        "shield.checkered",
        "globe",
        "paintbrush",
        "waveform",
        "hammer",
        "chart.bar",
        "envelope",
        "folder"
    ]

    init(
        existingPersona: BotPersona? = nil,
        onSave: @escaping (BotPersona) -> Void
    ) {
        self.existingPersona = existingPersona
        self.onSave = onSave
        let initialHex = existingPersona?.accentHex ?? "#00E5FF"
        _selectedPresetID = State(initialValue: nil)
        _name = State(initialValue: existingPersona?.name ?? "")
        _role = State(initialValue: existingPersona?.role ?? "")
        _systemPrompt = State(initialValue: existingPersona?.systemPrompt ?? "")
        _accentHex = State(initialValue: initialHex)
        _customPickerColor = State(initialValue: Color(hex: initialHex))
        _avatarShape = State(initialValue: existingPersona?.avatar.shape ?? .circle)
        _avatarStyle = State(initialValue: existingPersona?.avatar.style ?? .face)
        _avatarFace = State(initialValue: existingPersona?.avatar.face ?? .dots)
        _symbolName = State(initialValue: existingPersona?.symbolName ?? "sparkles")
        _notificationsEnabled = State(initialValue: existingPersona?.notificationsEnabled ?? true)
    }

    private var previewColor: Color {
        Color(hex: accentHex)
    }

    private var currentAvatarSpec: BotAvatarSpec {
        BotAvatarSpec(shape: avatarShape, style: avatarStyle, face: avatarFace)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()

            Color(red: 0.05, green: 0.055, blue: 0.075)
                .opacity(0.82)
                .ignoresSafeArea()

            RadialGradient(
                colors: [previewColor.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 15,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(existingPersona == nil ? "New Bot" : "Edit Bot")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Customize instructions, silhouette shape, color, face or icon, and attention alerts.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.60))
                    }
                    Spacer()
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(Capsule())
                }

                // Dual-size Live Preview (Teammate list + Chat header)
                HStack(spacing: 14) {
                    VStack(spacing: 4) {
                        BotAvatarView(
                            avatar: currentAvatarSpec,
                            accentHex: accentHex,
                            symbolName: symbolName,
                            size: 28
                        )
                        Text("List")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    VStack(spacing: 4) {
                        BotAvatarView(
                            avatar: currentAvatarSpec,
                            accentHex: accentHex,
                            symbolName: symbolName,
                            size: 42
                        )
                        Text("Header")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Bot Name" : name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Specialist Role" : role)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.60))
                    }

                    Spacer()

                    Text(notificationsEnabled ? "Alerts On" : "Muted")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(notificationsEnabled ? previewColor : .white.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background((notificationsEnabled ? previewColor : Color.white).opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(12)
                .liquidGlass(cornerRadius: 14, glowColor: previewColor, material: .hudWindow)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if existingPersona == nil {
                            VStack(alignment: .leading, spacing: 6) {
                                fieldLabel("STARTING POINT")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 7) {
                                        startingPointPill(title: "Blank Bot", isSelected: selectedPresetID == nil) {
                                            selectedPresetID = nil
                                            name = ""
                                            role = ""
                                            systemPrompt = ""
                                        }
                                        ForEach(BotPersona.presets) { preset in
                                            startingPointPill(title: preset.name, isSelected: selectedPresetID == preset.id) {
                                                applyPresetTemplate(preset)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                fieldLabel("NAME")
                                TextField("e.g. Research Analyst", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                fieldLabel("ROLE")
                                TextField("e.g. Deep-Dive & Synthesis", text: $role)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel("CUSTOM INSTRUCTIONS")
                            TextEditor(text: $systemPrompt)
                                .font(.system(size: 12.5))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.white)
                                .padding(8)
                                .frame(minHeight: 86, maxHeight: 120)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        }

                        // Shape selector
                        VStack(alignment: .leading, spacing: 7) {
                            fieldLabel("PROFILE SHAPE")
                            HStack(spacing: 8) {
                                ForEach(BotAvatarShape.allCases) { shape in
                                    let isSelected = avatarShape == shape
                                    Button {
                                        avatarShape = shape
                                    } label: {
                                        VStack(spacing: 5) {
                                            ZStack(alignment: .topTrailing) {
                                                BotAvatarView(
                                                    avatar: BotAvatarSpec(shape: shape, style: avatarStyle, face: avatarFace),
                                                    accentHex: accentHex,
                                                    symbolName: symbolName,
                                                    size: 32
                                                )
                                                if isSelected {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 11))
                                                        .foregroundStyle(.white, previewColor)
                                                        .offset(x: 4, y: -4)
                                                }
                                            }
                                            Text(shape.displayName)
                                                .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.65))
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? previewColor.opacity(0.16) : Color.white.opacity(0.05))
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(isSelected ? previewColor.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Color selector
                        VStack(alignment: .leading, spacing: 7) {
                            fieldLabel("COLOR")
                            HStack(spacing: 8) {
                                ForEach(Self.colorSwatches, id: \.hex) { swatch in
                                    let swatchColor = Color(hex: swatch.hex)
                                    let selected = accentHex.caseInsensitiveCompare(swatch.hex) == .orderedSame
                                    Button {
                                        accentHex = swatch.hex
                                        customPickerColor = swatchColor
                                    } label: {
                                        ZStack {
                                            Circle()
                                                .fill(swatchColor)
                                                .frame(width: 24, height: 24)
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.white, lineWidth: selected ? 2.2 : 0)
                                                )
                                            if selected {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(.black)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .help(swatch.name)
                                }

                                ColorPicker("", selection: $customPickerColor, supportsOpacity: false)
                                    .labelsHidden()
                                    .onChange(of: customPickerColor) { _, newColor in
                                        if let hex = newColor.toHexString() {
                                            accentHex = hex
                                        }
                                    }

                                Spacer()

                                TextField("#00E5FF", text: $accentHex)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 90)
                            }
                        }

                        // Face vs Icon selector
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                fieldLabel("FACE OR ICON")
                                Spacer()
                                Picker("Avatar Style", selection: $avatarStyle) {
                                    ForEach(BotAvatarStyle.allCases) { style in
                                        Text(style.displayName).tag(style)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(width: 170)
                            }

                            if avatarStyle == .face {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                    ForEach(BotAvatarFace.allCases) { face in
                                        let isSelected = avatarFace == face
                                        Button {
                                            avatarFace = face
                                        } label: {
                                            HStack(spacing: 8) {
                                                BotAvatarView(
                                                    avatar: BotAvatarSpec(shape: avatarShape, style: .face, face: face),
                                                    accentHex: accentHex,
                                                    symbolName: symbolName,
                                                    size: 26
                                                )
                                                Text(face.displayName)
                                                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                                                    .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.72))
                                                    .lineLimit(1)
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundStyle(previewColor)
                                                }
                                            }
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 6)
                                            .background(isSelected ? previewColor.opacity(0.18) : Color.white.opacity(0.05))
                                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                                    .stroke(isSelected ? previewColor.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            } else {
                                HStack {
                                    Text("SF Symbol")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.65))
                                    Spacer()
                                    TextField("Custom symbol", text: $symbolName)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .frame(width: 160)
                                }

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                                    ForEach(Self.symbolChoices, id: \.self) { symbol in
                                        let isSelected = symbolName == symbol
                                        Button {
                                            symbolName = symbol
                                        } label: {
                                            Image(systemName: symbol)
                                                .font(.system(size: 13.5))
                                                .foregroundStyle(isSelected ? previewColor : .white.opacity(0.75))
                                                .frame(width: 34, height: 32)
                                                .background(isSelected ? previewColor.opacity(0.20) : Color.white.opacity(0.06))
                                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                        .stroke(isSelected ? previewColor.opacity(0.65) : Color.clear, lineWidth: 1)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Needs attention notifications toggle
                        Toggle(isOn: $notificationsEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Needs attention notifications")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                Text("Allow this bot to send local alerts when a task is ready or an action needs approval.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .toggleStyle(.switch)
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        savePersona()
                    } label: {
                        Text(existingPersona == nil ? "Create Bot" : "Save Changes")
                            .font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(canSave ? previewColor.opacity(0.28) : Color.white.opacity(0.08))
                            .foregroundStyle(canSave ? .white : .white.opacity(0.45))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(canSave ? previewColor.opacity(0.6) : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                }
            }
            .padding(20)
        }
        .frame(width: 540, height: 660)
    }

    private func startingPointPill(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? previewColor.opacity(0.24) : Color.white.opacity(0.06))
            .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? previewColor.opacity(0.70) : Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func applyPresetTemplate(_ preset: BotPersona) {
        selectedPresetID = preset.id
        name = "\(preset.name) Copy"
        role = preset.role
        systemPrompt = preset.systemPrompt
        accentHex = preset.accentHex
        customPickerColor = Color(hex: preset.accentHex)
        avatarShape = preset.avatar.shape
        avatarStyle = preset.avatar.style
        avatarFace = preset.avatar.face
        symbolName = preset.symbolName
        notificationsEnabled = preset.notificationsEnabled
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(.white.opacity(0.50))
    }

    private func savePersona() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSymbol = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHex = normalizeHex(accentHex)

        let persona = BotPersona(
            id: existingPersona?.id ?? UUID().uuidString,
            name: trimmedName,
            role: trimmedRole,
            systemPrompt: trimmedPrompt,
            symbolName: trimmedSymbol.isEmpty ? "sparkles" : trimmedSymbol,
            accentHex: normalizedHex,
            avatar: currentAvatarSpec,
            notificationsEnabled: notificationsEnabled,
            isDefault: existingPersona?.isDefault ?? false,
            pinnedToolIDs: existingPersona?.pinnedToolIDs ?? []
        )

        onSave(persona)
        dismiss()
    }

    private func normalizeHex(_ raw: String) -> String {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, UInt32(cleaned, radix: 16) != nil else {
            return "#00E5FF"
        }
        return "#\(cleaned.uppercased())"
    }
}

private extension Color {
    func toHexString() -> String? {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(nsColor.redComponent * 255))
        let g = Int(round(nsColor.greenComponent * 255))
        let b = Int(round(nsColor.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
