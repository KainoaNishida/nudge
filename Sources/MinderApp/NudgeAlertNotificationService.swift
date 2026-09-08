import Foundation
import MinderCore
import UserNotifications

protocol NudgeAlertNotifying {
    func notifyNewAlerts(_ alerts: [Suggestion]) async
}

struct NudgeNoopAlertNotifier: NudgeAlertNotifying {
    func notifyNewAlerts(_ alerts: [Suggestion]) async {}
}

final class NudgeUserNotificationService: NudgeAlertNotifying {
    private let center: UNUserNotificationCenter
    private let runtimeContext: AppRuntimeContext

    init(
        center: UNUserNotificationCenter = .current(),
        runtimeContext: AppRuntimeContext = AppRuntimeContext()
    ) {
        self.center = center
        self.runtimeContext = runtimeContext
    }

    func notifyNewAlerts(_ alerts: [Suggestion]) async {
        guard runtimeContext.supportsUserNotifications, !alerts.isEmpty else { return }

        let settings = await notificationSettings()
        guard isAuthorized(settings.authorizationStatus) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Nudge found \(alerts.count) new \(alerts.count == 1 ? "alert" : "alerts")"
        content.body = notificationBody(for: alerts)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "nudge-new-alerts-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await add(request)
    }

    private func notificationSettings() async -> UNNotificationSettings {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings)
            }
        }
    }

    private func add(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func isAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func notificationBody(for alerts: [Suggestion]) -> String {
        guard let first = alerts.first else { return "Open Nudge to review." }

        if alerts.count == 1 {
            return "\(first.evidence.threadTitle): \(first.title). Open Nudge to review."
        }

        return "\(first.evidence.threadTitle): \(first.title), plus \(alerts.count - 1) more. Open Nudge to review."
    }
}
