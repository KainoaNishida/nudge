import AppKit
import SwiftUI

struct NudgeSymbol: View {
    @Environment(\.nudgePalette) private var palette

    var size: CGFloat = 30

    private var cornerRadius: CGFloat {
        max(6, size * 0.24)
    }

    private var strokeWidth: CGFloat {
        max(1.8, size * 0.075)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(palette.primary)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: max(0.5, size * 0.018))
                }

            NudgeGlyphShape()
                .stroke(.white, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Nudge")
    }
}

enum NudgeSymbolImage {
    static func menuBarTemplate() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2.2, dy: 2.2)
        let path = makeBezierGlyph(in: rect)
        path.lineWidth = 1.85
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.black.setStroke()
        path.stroke()

        image.isTemplate = true
        return image
    }

    private static func makeBezierGlyph(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()

        path.move(to: point(0.30, 0.16, in: rect))
        path.line(to: point(0.70, 0.16, in: rect))
        path.curve(
            to: point(0.88, 0.34, in: rect),
            controlPoint1: point(0.80, 0.16, in: rect),
            controlPoint2: point(0.88, 0.24, in: rect)
        )
        path.line(to: point(0.88, 0.54, in: rect))
        path.curve(
            to: point(0.70, 0.72, in: rect),
            controlPoint1: point(0.88, 0.64, in: rect),
            controlPoint2: point(0.80, 0.72, in: rect)
        )
        path.line(to: point(0.55, 0.72, in: rect))
        path.line(to: point(0.42, 0.86, in: rect))
        path.line(to: point(0.40, 0.72, in: rect))
        path.line(to: point(0.30, 0.72, in: rect))
        path.curve(
            to: point(0.12, 0.54, in: rect),
            controlPoint1: point(0.20, 0.72, in: rect),
            controlPoint2: point(0.12, 0.64, in: rect)
        )
        path.line(to: point(0.12, 0.34, in: rect))
        path.curve(
            to: point(0.30, 0.16, in: rect),
            controlPoint1: point(0.12, 0.24, in: rect),
            controlPoint2: point(0.20, 0.16, in: rect)
        )
        path.close()

        path.move(to: point(0.34, 0.44, in: rect))
        path.line(to: point(0.45, 0.55, in: rect))
        path.line(to: point(0.67, 0.34, in: rect))

        return path
    }

    private static func point(_ x: CGFloat, _ yDown: CGFloat, in rect: CGRect) -> NSPoint {
        NSPoint(
            x: rect.minX + rect.width * x,
            y: rect.minY + rect.height * (1 - yDown)
        )
    }
}

private struct NudgeGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: point(0.30, 0.16, in: rect))
        path.addLine(to: point(0.70, 0.16, in: rect))
        path.addQuadCurve(to: point(0.88, 0.34, in: rect), control: point(0.88, 0.16, in: rect))
        path.addLine(to: point(0.88, 0.54, in: rect))
        path.addQuadCurve(to: point(0.70, 0.72, in: rect), control: point(0.88, 0.72, in: rect))
        path.addLine(to: point(0.55, 0.72, in: rect))
        path.addLine(to: point(0.42, 0.86, in: rect))
        path.addLine(to: point(0.40, 0.72, in: rect))
        path.addLine(to: point(0.30, 0.72, in: rect))
        path.addQuadCurve(to: point(0.12, 0.54, in: rect), control: point(0.12, 0.72, in: rect))
        path.addLine(to: point(0.12, 0.34, in: rect))
        path.addQuadCurve(to: point(0.30, 0.16, in: rect), control: point(0.12, 0.16, in: rect))
        path.closeSubpath()

        path.move(to: point(0.34, 0.44, in: rect))
        path.addLine(to: point(0.45, 0.55, in: rect))
        path.addLine(to: point(0.67, 0.34, in: rect))

        return path
    }

    private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
}
