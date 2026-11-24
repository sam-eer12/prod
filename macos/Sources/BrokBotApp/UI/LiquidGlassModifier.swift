import AppKit
import SwiftUI

/// Wraps an `NSVisualEffectView` for system-level `.behindWindow` Liquid Glass translucency.
public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// Applies Brok Bot's Clean Minimal Liquid Glass treatment:
/// frosted backdrop, ambient radial persona glow, specular border gradient, and soft elevation shadow.
public struct LiquidGlassModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var glowColor: Color
    public var material: NSVisualEffectView.Material

    public init(
        cornerRadius: CGFloat = 18.0,
        glowColor: Color = .cyan,
        material: NSVisualEffectView.Material = .hudWindow
    ) {
        self.cornerRadius = cornerRadius
        self.glowColor = glowColor
        self.material = material
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(
                ZStack {
                    VisualEffectBackground(material: material, blendingMode: .behindWindow)

                    Color.black.opacity(0.24)

                    RadialGradient(
                        colors: [glowColor.opacity(0.14), Color.clear],
                        center: .topLeading,
                        startRadius: 8,
                        endRadius: 280
                    )
                }
            )
            .clipShape(shape)
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.22), location: 0.0),
                                .init(color: Color.white.opacity(0.04), location: 0.52),
                                .init(color: Color.white.opacity(0.12), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.0
                    )
            )
            .shadow(color: Color.black.opacity(0.20), radius: 14, x: 0, y: 7)
    }
}

public extension View {
    /// Styles the view with Brok Bot's Clean Minimal Liquid Glass surface.
    func liquidGlass(
        cornerRadius: CGFloat = 18.0,
        glowColor: Color = .cyan,
        material: NSVisualEffectView.Material = .hudWindow
    ) -> some View {
        modifier(
            LiquidGlassModifier(
                cornerRadius: cornerRadius,
                glowColor: glowColor,
                material: material
            )
        )
    }
}

public extension Color {
    /// Creates a SwiftUI `Color` from a 6-digit RGB hex string (e.g. `#00E5FF`).
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .cyan
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
