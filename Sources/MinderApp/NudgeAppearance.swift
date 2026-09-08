import SwiftUI
import MinderCore

struct NudgePalette {
    var primary: Color
    var secondary: Color { primary }
    var tertiary: Color { primary }
    var warning: Color { primary }
    var completion: Color { primary }

    var swatches: [Color] {
        [primary]
    }
}

extension AppColorScheme {
    var palette: NudgePalette {
        switch self {
        case .ocean:
            return NudgePalette(primary: Color(red: 0.0, green: 0.38, blue: 0.82))
        case .sky:
            return NudgePalette(primary: Color(red: 0.0, green: 0.56, blue: 0.86))
        case .cyan:
            return NudgePalette(primary: Color(red: 0.0, green: 0.48, blue: 0.58))
        case .teal:
            return NudgePalette(primary: Color(red: 0.0, green: 0.45, blue: 0.43))
        case .forest:
            return NudgePalette(primary: Color(red: 0.12, green: 0.43, blue: 0.26))
        case .mint:
            return NudgePalette(primary: Color(red: 0.0, green: 0.52, blue: 0.36))
        case .lime:
            return NudgePalette(primary: Color(red: 0.39, green: 0.55, blue: 0.0))
        case .yellow:
            return NudgePalette(primary: Color(red: 0.76, green: 0.56, blue: 0.0))
        case .plum:
            return NudgePalette(primary: Color(red: 0.42, green: 0.25, blue: 0.64))
        case .indigo:
            return NudgePalette(primary: Color(red: 0.26, green: 0.31, blue: 0.72))
        case .pink:
            return NudgePalette(primary: Color(red: 0.74, green: 0.22, blue: 0.47))
        case .ruby:
            return NudgePalette(primary: Color(red: 0.70, green: 0.10, blue: 0.18))
        case .ember:
            return NudgePalette(primary: Color(red: 0.73, green: 0.29, blue: 0.08))
        case .graphite:
            return NudgePalette(primary: Color(red: 0.27, green: 0.31, blue: 0.35))
        }
    }
}

private struct NudgePaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppColorScheme.ocean.palette
}

extension EnvironmentValues {
    var nudgePalette: NudgePalette {
        get { self[NudgePaletteEnvironmentKey.self] }
        set { self[NudgePaletteEnvironmentKey.self] = newValue }
    }
}
