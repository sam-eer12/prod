import BrokBotCore
import Foundation
import UserNotifications

/// Safely wraps `UNUserNotificationCenter` for bundled `.app` runs while staying crash-free under `swift run`.
@MainActor
final class LocalNotificationManager: NSObject, ObservableObject {
    @Published private(set) var isBundledApp: Bool
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastStatusMessage: String?
    @Published private(set) var lastHandledActionSummary: String?

    var onActionReceived: (@MainActor (BrokNotificationAction, String, [String: String]) -> Void)?
    var onOpenWorkspaceRequested: (@MainActor (UUID?) -> Void)?

    override init() {
        self.isBundledApp = Bundle.main.bundleURL.pathExtension == "app"
        super.init()
    }

    /// Registers interactive categories and checks notification permissions when running inside `.app`.
    func configureIfBundled() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            isBundledApp = false
            lastStatusMessage = "Local notifications require BrokBot.app (safely bypassed under swift run)."
            return
        }

        isBundledApp = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)

        Task {
            await refreshAuthorizationStatus()
        }
    }

    /// Refreshes the cached notification authorization status from macOS.
    func refreshAuthorizationStatus() async {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            authorizationStatus = .notDetermined
            return
        }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Requests user authorization for banners, sounds, and badges when running inside `BrokBot.app`.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            lastStatusMessage = "Local notifications require running from BrokBot.app."
            return false
        }

        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            lastStatusMessage = granted
                ? "Local notifications authorized."
                : "Notifications denied. Enable Brok Bot in System Settings -> Notifications."
            return granted
        } catch {
            lastStatusMessage = "Authorization failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Schedules a `LocalNotificationPayload` through `UNUserNotificationCenter` when bundled.
    @discardableResult
    func scheduleNotification(_ payload: LocalNotificationPayload) async -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            lastStatusMessage = "Skipped '\(payload.title)' (notifications require BrokBot.app)."
            return false
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = await requestAuthorization()
            guard granted else { return false }
        case .denied:
            lastStatusMessage = "Notifications are disabled in System Settings -> Notifications."
            return false
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            break
        }

        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let subtitle = payload.subtitle, !subtitle.isEmpty {
            content.subtitle = subtitle
        }
        content.body = payload.isPrivate
            ? (payload.lockScreenPlaceholder ?? "Action needs review in Brok Bot.")
            : payload.body
        content.categoryIdentifier = payload.category.rawValue
        content.userInfo = payload.userInfo
        content.sound = .default

        let trigger: UNNotificationTrigger?
        if payload.delaySeconds > 0 {
            trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(0.5, payload.delaySeconds),
                repeats: false
            )
        } else {
            trigger = nil
        }

        let request = UNNotificationRequest(
            identifier: payload.id,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            lastStatusMessage = "Scheduled notification: \(payload.title)"
            return true
        } catch {
            lastStatusMessage = "Failed to schedule notification: \(error.localizedDescription)"
            return false
        }
    }

    /// Dismisses any pending or delivered OS notification matching `requestID`.
    func dismissNotification(requestID: UUID) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let identifier = requestID.uuidString
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    /// Schedules a test interactive notification showcasing `approvalRequest` (`[Allow once]` / `[Deny]`).
    @discardableResult
    func sendTestNotification() async -> Bool {
        let payload = LocalNotificationPayload(
            title: "Brok Bot · Approval Check",
            subtitle: "Dual-Space & Local Daemon Ready",
            body: "Test notification active. Choose Allow once or Deny to test interactive actions.",
            category: .approvalRequest,
            userInfo: ["source": "test_notification"],
            delaySeconds: 1.0
        )
        return await scheduleNotification(payload)
    }

    var authorizationSummary: String {
        guard isBundledApp else {
            return "App Bundle Required"
        }
        switch authorizationStatus {
        case .authorized:
            return "Authorized"
        case .provisional:
            return "Provisional"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not Requested"
        case .ephemeral:
            return "Ephemeral"
        @unknown default:
            return "Unknown"
        }
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        let categories = Set(BrokNotificationCategory.allCases.map { category -> UNNotificationCategory in
            let actions = category.actions.map { action -> UNNotificationAction in
                var options: UNNotificationActionOptions = []
                if action.isDestructive {
                    options.insert(.destructive)
                }
                if action.opensAppInForeground {
                    options.insert(.foreground)
                }
                return UNNotificationAction(
                    identifier: action.rawValue,
                    title: action.title,
                    options: options
                )
            }
            return UNNotificationCategory(
                identifier: category.rawValue,
                actions: actions,
                intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: "Needs your attention in Brok Bot.",
                options: [.customDismissAction]
            )
        })
        center.setNotificationCategories(categories)
    }

    private func handleNotificationResponse(
        actionIdentifier: String,
        title: String,
        userInfo: [String: String]
    ) {
        let rawRequestID = userInfo["request_id"] ?? userInfo["elicitation_id"]
        let parsedRequestID = rawRequestID.flatMap(UUID.init(uuidString:))

        if let action = BrokNotificationAction(rawValue: actionIdentifier) {
            lastHandledActionSummary = "\(action.title) selected for '\(title)'"
            lastStatusMessage = lastHandledActionSummary
            if action.opensAppInForeground {
                onOpenWorkspaceRequested?(parsedRequestID)
            } else {
                onActionReceived?(action, title, userInfo)
            }
        } else if actionIdentifier == UNNotificationDefaultActionIdentifier {
            onOpenWorkspaceRequested?(parsedRequestID)
        }
    }
}

extension LocalNotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionIdentifier = response.actionIdentifier
        let title = response.notification.request.content.title
        var stringInfo: [String: String] = [:]
        for (key, value) in response.notification.request.content.userInfo {
            if let k = key as? String, let v = value as? String {
                stringInfo[k] = v
            }
        }
        await MainActor.run {
            self.handleNotificationResponse(
                actionIdentifier: actionIdentifier,
                title: title,
                userInfo: stringInfo
            )
        }
    }
}
