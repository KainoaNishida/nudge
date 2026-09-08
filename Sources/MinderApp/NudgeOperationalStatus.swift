import SwiftUI
import MinderCore

enum NudgeOperationalStatusState: Equatable {
    case ready
    case limited
    case needsSetup
}

struct NudgeOperationalStatus: Equatable {
    var state: NudgeOperationalStatusState
    var title: String
    var detail: String
    var systemImage: String
    var targetSettingsStep: OnboardingStep

    var shortTitle: String {
        switch state {
        case .ready:
            return "Working"
        case .limited:
            return "Needs attention"
        case .needsSetup:
            return "Not working"
        }
    }

    static func make(
        profile: UserProfile?,
        permissionHealth: [PermissionHealth],
        sources: [ConversationSource],
        lastRefreshFailed: Bool,
        hasCloudAIConfig: Bool,
        now: Date = Date()
    ) -> NudgeOperationalStatus {
        let fullDisk = health(for: .fullDiskAccess, in: permissionHealth)
        let messages = health(for: .appleMessages, in: permissionHealth)
        let notifications = health(for: .notifications, in: permissionHealth)
        let messagesSource = sources.first { $0.kind == .appleMessages }
        let cadence = profile?.notificationCadence ?? .hourlyDigest

        if lastRefreshFailed {
            return NudgeOperationalStatus(
                state: .needsSetup,
                title: "Needs setup",
                detail: "The last refresh failed. Open Messages settings and check access before trying again.",
                systemImage: "exclamationmark.triangle.fill",
                targetSettingsStep: .messages
            )
        }

        guard fullDisk.state == .available else {
            return NudgeOperationalStatus(
                state: .needsSetup,
                title: "Needs setup",
                detail: "Full Disk Access is needed before Nudge can read recent Messages.",
                systemImage: "lock.fill",
                targetSettingsStep: .messages
            )
        }

        guard messages.state == .available else {
            return NudgeOperationalStatus(
                state: .needsSetup,
                title: "Needs setup",
                detail: "Messages access is not ready yet. Check permissions, then refresh.",
                systemImage: "message.badge.fill",
                targetSettingsStep: .messages
            )
        }

        guard messagesSource?.lastSyncAt != nil else {
            return NudgeOperationalStatus(
                state: .needsSetup,
                title: "Needs setup",
                detail: "Import recent Messages once so Nudge can start building alerts.",
                systemImage: "arrow.down.message.fill",
                targetSettingsStep: .messages
            )
        }

        if cadence != .quiet, let notificationStatus = notificationLimitedStatus(for: notifications.state) {
            return NudgeOperationalStatus(
                state: .limited,
                title: notificationStatus.title,
                detail: notificationStatus.detail,
                systemImage: notificationStatus.systemImage,
                targetSettingsStep: .notifications
            )
        }

        if let lastSyncAt = messagesSource?.lastSyncAt, now.timeIntervalSince(lastSyncAt) > Self.staleRefreshInterval {
            return NudgeOperationalStatus(
                state: .limited,
                title: "Refresh recommended",
                detail: "Messages permissions are working, but the last import is stale. Use Refresh to check again.",
                systemImage: "clock.badge.exclamationmark",
                targetSettingsStep: .messages
            )
        }

        if profile?.cloudAIEnabled == true && !hasCloudAIConfig {
            return NudgeOperationalStatus(
                state: .limited,
                title: "Messages ready",
                detail: "Messages permissions are working. Cloud AI needs credentials, so local suggestions will continue.",
                systemImage: "cloud.slash.fill",
                targetSettingsStep: .cloudAI
            )
        }

        return NudgeOperationalStatus(
            state: .ready,
            title: "Ready",
            detail: "Messages permissions are working. Nudge is monitoring recent Messages for alerts.",
            systemImage: "checkmark.seal.fill",
            targetSettingsStep: .about
        )
    }

    private static let staleRefreshInterval: TimeInterval = 2 * 60 * 60

    private static func health(
        for kind: PermissionKind,
        in permissionHealth: [PermissionHealth]
    ) -> PermissionHealth {
        permissionHealth.first { $0.kind == kind } ?? PermissionHealth(
            kind: kind,
            state: .missing,
            detail: "\(kind.displayName) has not been checked yet."
        )
    }

    private static func notificationLimitedStatus(for state: HealthState) -> (title: String, detail: String, systemImage: String)? {
        switch state {
        case .available:
            return nil
        case .missing:
            return (
                "Enable notifications",
                "Messages permissions are working. Notifications have not been enabled yet.",
                "bell.badge.fill"
            )
        case .revoked:
            return (
                "Notifications off",
                "Messages permissions are working. Notifications are disabled in System Settings.",
                "bell.slash.fill"
            )
        case .degraded:
            return (
                "Notifications unclear",
                "Messages permissions are working. Nudge could not confirm notification status.",
                "bell.badge.waveform.fill"
            )
        case .unsupported:
            return (
                "Notifications unavailable",
                "Messages permissions are working. Notifications are unavailable in this launch mode.",
                "bell.slash.fill"
            )
        }
    }
}

extension NudgeOperationalStatusState {
    var tint: Color {
        switch self {
        case .ready:
            return .green
        case .limited:
            return .orange
        case .needsSetup:
            return .red
        }
    }
}
