import Foundation

public enum NudgeReleaseChannel: String, Equatable {
    case dev
    case alpha

    public static func current(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> NudgeReleaseChannel {
        if let raw = environment["NUDGE_RELEASE_CHANNEL"]?.nilIfEmpty, let channel = NudgeReleaseChannel(rawValue: raw.lowercased()) {
            return channel
        }
        if let raw = environment["LOOP_RELEASE_CHANNEL"]?.nilIfEmpty, let channel = NudgeReleaseChannel(rawValue: raw.lowercased()) {
            return channel
        }
        if let raw = bundle.object(forInfoDictionaryKey: "NudgeReleaseChannel") as? String,
           let channel = NudgeReleaseChannel(rawValue: raw.lowercased()) {
            return channel
        }
        if let raw = bundle.object(forInfoDictionaryKey: "LoopReleaseChannel") as? String,
           let channel = NudgeReleaseChannel(rawValue: raw.lowercased()) {
            return channel
        }
        return .dev
    }

    public var bundleIdentifier: String {
        switch self {
        case .dev:
            return "com.kainoanishida.nudge.dev"
        case .alpha:
            return "com.kainoanishida.nudge.alpha"
        }
    }

    public var appSupportDirectoryName: String {
        switch self {
        case .dev:
            return "NudgeDev"
        case .alpha:
            return "NudgeAlpha"
        }
    }

    public var legacyLoopAppSupportDirectoryName: String {
        switch self {
        case .dev:
            return "LoopDev"
        case .alpha:
            return "LoopAlpha"
        }
    }

    public var displayName: String {
        switch self {
        case .dev:
            return "Development"
        case .alpha:
            return "Alpha"
        }
    }
}
