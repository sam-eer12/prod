import BrokBotCore
import SwiftUI

/// Minimal Liquid Glass modal sheet for creating or editing custom specialist bot personas.
struct PersonaEditorSheet: View {
    let existingPersona: BotPersona?
    let onSave: (BotPersona) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var role: String
    @State private var systemPrompt: String
    @State private var accentHex: String
    @State private var symbolName: String

    private static let colorSwatches: [String] = [
        "#00E5FF",
        "#FF9F0A",
        "#34D399",
        "#A78BFA",
        "#F472B6",
        "#60A5FA",
        "#F87171",
        "#FACC15"
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
        _name = State(initialValue: existingPersona?.name ?? "")
        _role = State(initialValue: existingPersona?.role ?? "")
        _systemPrompt = State(initialValue: existingPersona?.systemPrompt ?? "")
        _accentHex = State(initialValue: existingPersona?.accentHex ?? "#00E5FF")
        _symbolName = State(initialValue: existingPersona?.symbolName ?? "sparkles")
    }

    private var previewColor: Color {
        Color(hex: accentHex)
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
                .opacity(0.80)
                .ignoresSafeArea()

            RadialGradient(
                colors: [previewColor.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 15,
                endRadius: 340
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(existingPersona == nil ? "New Specialist Persona" : "Edit Persona")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Configure role instructions, accent glow, and icon badge.")
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

                // Live Preview Card
                HStack(spacing: 12) {
                    Image(systemName: symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "sparkles" : symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(previewColor)
                        .frame(width: 36, height: 36)
                        .background(previewColor.opacity(0.16))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Specialist Name" : name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Specialist Role" : role)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.60))
                    }

                    Spacer()

                    Text(accentHex.uppercased())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(previewColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(previewColor.opacity(0.12))
                        .clipShape(Capsule())
                }
                .padding(12)
                .liquidGlass(cornerRadius: 14, glowColor: previewColor, material: .hudWindow)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("NAME")
                            TextField("e.g. Research Analyst", text: $name)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("ROLE")
                            TextField("e.g. Technical Deep-Dive & Synthesis", text: $role)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            fieldLabel("SYSTEM PROMPT")
                            TextEditor(text: $systemPrompt)
                                .font(.system(size: 12.5))
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.white)
                                .padding(8)
                                .frame(minHeight: 92, maxHeight: 130)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            fieldLabel("ACCENT HEX COLOR")
                            HStack(spacing: 8) {
                                ForEach(Self.colorSwatches, id: \.self) { hex in
                                    let swatchColor = Color(hex: hex)
                                    let selected = accentHex.caseInsensitiveCompare(hex) == .orderedSame
                                    Button {
                                        accentHex = hex
                                    } label: {
                                        Circle()
                                            .fill(swatchColor)
                                            .frame(width: 22, height: 22)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: selected ? 2.2 : 0)
                                            )
                                            .shadow(color: swatchColor.opacity(selected ? 0.7 : 0.2), radius: 5)
                                    }
                                    .buttonStyle(.plain)
                                }

                                Spacer()

                                TextField("#00E5FF", text: $accentHex)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 96)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                fieldLabel("SF SYMBOL")
                                Spacer()
                                TextField("Custom symbol", text: $symbolName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 150)
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
                }

                HStack {
                    Spacer()
                    Button {
                        savePersona()
                    } label: {
                        Text(existingPersona == nil ? "Create Persona" : "Save Changes")
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
        .frame(width: 470, height: 540)
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
