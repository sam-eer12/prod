import BrokBotCore
import SwiftUI

/// Renders a solid-color bot silhouette with simple expressive eyes or an SF Symbol icon.
struct BotAvatarView: View {
    let avatar: BotAvatarSpec
    let accentHex: String
    let symbolName: String
    var size: CGFloat = 30

    init(persona: BotPersona, size: CGFloat = 30) {
        self.avatar = persona.avatar
        self.accentHex = persona.accentHex
        self.symbolName = persona.symbolName
        self.size = size
    }

    init(avatar: BotAvatarSpec, accentHex: String, symbolName: String, size: CGFloat = 30) {
        self.avatar = avatar
        self.accentHex = accentHex
        self.symbolName = symbolName
        self.size = size
    }

    private var fillColor: Color {
        Color(hex: accentHex)
    }

    var body: some View {
        ZStack {
            BotSilhouetteShape(kind: avatar.shape)
                .fill(fillColor)
                .overlay(
                    BotSilhouetteShape(kind: avatar.shape)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.45), Color.white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(0.8, size * 0.04)
                        )
                )
                .shadow(color: fillColor.opacity(0.32), radius: size * 0.16, y: 1)

            if avatar.style == .face {
                faceOverlay
            } else {
                Image(systemName: symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "sparkles" : symbolName)
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(Color(red: 0.06, green: 0.07, blue: 0.10))
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var faceOverlay: some View {
        let ink = Color(red: 0.06, green: 0.07, blue: 0.10)
        switch avatar.face {
        case .dots:
            HStack(spacing: size * 0.18) {
                Circle().fill(ink).frame(width: size * 0.14, height: size * 0.14)
                Circle().fill(ink).frame(width: size * 0.14, height: size * 0.14)
            }
        case .happy:
            HStack(spacing: size * 0.16) {
                HappyEyeArc().stroke(ink, style: StrokeStyle(lineWidth: max(1.6, size * 0.075), lineCap: .round))
                    .frame(width: size * 0.18, height: size * 0.12)
                HappyEyeArc().stroke(ink, style: StrokeStyle(lineWidth: max(1.6, size * 0.075), lineCap: .round))
                    .frame(width: size * 0.18, height: size * 0.12)
            }
        case .focused:
            HStack(spacing: size * 0.16) {
                Capsule().fill(ink).frame(width: size * 0.18, height: size * 0.11)
                Capsule().fill(ink).frame(width: size * 0.18, height: size * 0.11)
            }
        case .wink:
            HStack(spacing: size * 0.17) {
                Circle().fill(ink).frame(width: size * 0.14, height: size * 0.14)
                Capsule().fill(ink).frame(width: size * 0.18, height: max(2, size * 0.07))
            }
        case .visor:
            Capsule()
                .fill(ink)
                .frame(width: size * 0.58, height: size * 0.18)
                .overlay(
                    Capsule()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: size * 0.22, height: max(1.5, size * 0.04))
                        .offset(x: -size * 0.10, y: -size * 0.03)
                )
        case .monocle:
            HStack(spacing: size * 0.12) {
                Circle().fill(ink).frame(width: size * 0.13, height: size * 0.13)
                Circle()
                    .stroke(ink, lineWidth: max(1.6, size * 0.065))
                    .frame(width: size * 0.24, height: size * 0.24)
                    .overlay(Circle().fill(ink).frame(width: size * 0.10, height: size * 0.10))
            }
        }
    }
}

private struct HappyEyeArc: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY),
            control: CGPoint(x: rect.midX, y: rect.minY - rect.height * 0.3)
        )
        return path
    }
}

struct BotSilhouetteShape: Shape {
    let kind: BotAvatarShape

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .circle:
            return Circle().path(in: rect)

        case .roundedSquare:
            return RoundedRectangle(cornerRadius: rect.width * 0.28, style: .continuous).path(in: rect)

        case .softTriangle:
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.50, y: h * 0.06))
            path.addQuadCurve(to: CGPoint(x: w * 0.94, y: h * 0.80), control: CGPoint(x: w * 0.88, y: h * 0.24))
            path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.94), control: CGPoint(x: w * 0.86, y: h * 0.96))
            path.addQuadCurve(to: CGPoint(x: w * 0.06, y: h * 0.80), control: CGPoint(x: w * 0.14, y: h * 0.96))
            path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.06), control: CGPoint(x: w * 0.12, y: h * 0.24))
            path.closeSubpath()
            return path

        case .cloud:
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.addEllipse(in: CGRect(x: w * 0.10, y: h * 0.34, width: w * 0.44, height: h * 0.48))
            path.addEllipse(in: CGRect(x: w * 0.26, y: h * 0.14, width: w * 0.48, height: h * 0.52))
            path.addEllipse(in: CGRect(x: w * 0.46, y: h * 0.34, width: w * 0.44, height: h * 0.48))
            path.addRoundedRect(
                in: CGRect(x: w * 0.16, y: h * 0.44, width: w * 0.68, height: h * 0.40),
                cornerSize: CGSize(width: w * 0.20, height: h * 0.20)
            )
            return path

        case .pebble:
            var path = Path()
            let w = rect.width
            let h = rect.height
            path.move(to: CGPoint(x: w * 0.52, y: h * 0.08))
            path.addCurve(
                to: CGPoint(x: w * 0.94, y: h * 0.54),
                control1: CGPoint(x: w * 0.82, y: h * 0.08),
                control2: CGPoint(x: w * 0.96, y: h * 0.30)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.46, y: h * 0.92),
                control1: CGPoint(x: w * 0.92, y: h * 0.82),
                control2: CGPoint(x: w * 0.68, y: h * 0.94)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.06, y: h * 0.48),
                control1: CGPoint(x: w * 0.18, y: h * 0.90),
                control2: CGPoint(x: w * 0.04, y: h * 0.72)
            )
            path.addCurve(
                to: CGPoint(x: w * 0.52, y: h * 0.08),
                control1: CGPoint(x: w * 0.08, y: h * 0.20),
                control2: CGPoint(x: w * 0.24, y: h * 0.08)
            )
            path.closeSubpath()
            return path
        }
    }
}
