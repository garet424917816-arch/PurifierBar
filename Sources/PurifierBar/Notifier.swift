// System notifications. Created only inside the bundle: outside it
// UNUserNotificationCenter is unavailable and crashes.
import Foundation
import PurifierCore
import UserNotifications

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var authorizationRequested = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Without a delegate the system hides notifications while the app is active (panel or settings open).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Requests permission once at startup, if at least one toggle is on.
    func requestAuthorizationIfNeeded(alerts: AlertSettings) {
        guard !authorizationRequested else { return }
        guard alerts.filterLow || alerts.fault || alerts.unreachable else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Shows a notification. The identifier is per kind, so a repeat replaces the previous one,
    /// instead of multiplying it.
    func post(_ alert: PurifierAlert) {
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: alert)
        content.body = Self.body(for: alert)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: alert),
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func identifier(for alert: PurifierAlert) -> String {
        switch alert {
        case .filterLow: return "filterLow"
        case .fault: return "fault"
        case .unreachable: return "unreachable"
        }
    }

    private static func title(for alert: PurifierAlert) -> String {
        switch alert {
        case .filterLow: return String(localized: "Time to replace the filter")
        case .fault: return String(localized: "Purifier fault")
        case .unreachable: return String(localized: "Purifier unavailable")
        }
    }

    private static func body(for alert: PurifierAlert) -> String {
        switch alert {
        case .filterLow(let percent):
            return String(localized: "Filter life: \(percent) %. Replace the filter.")
        case .fault(let fault):
            switch fault {
            case .motorStuck: return String(localized: "Motor stuck. Check the device.")
            case .sensorLost: return String(localized: "Sensor lost. Check the device.")
            case .other(let code): return String(localized: "Fault code: \(code). Check the device.")
            case .none: return String(localized: "Check the device.")
            }
        case .unreachable:
            return String(localized: "Cannot reach the purifier. Check power and Wi-Fi.")
        }
    }
}
