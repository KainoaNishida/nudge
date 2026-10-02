import AppKit
import SwiftUI

struct NudgeSymbol: View {
    var size: CGFloat = 30

    var body: some View {
        PixelCatSprite(alerting: false, alternate: true, blink: false)
            .frame(width: size * 0.86, height: size * 0.86)
            .frame(width: size, height: size)
            .background(Color(red: 0.16, green: 0.19, blue: 0.24),
                        in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
            .accessibilityLabel("Nudge cat")
    }
}

enum NudgeSymbolImage {
    static func menuBarTemplate() -> NSImage {
        let image = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "Nudge cat")
            ?? NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Nudge cat")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }
}
