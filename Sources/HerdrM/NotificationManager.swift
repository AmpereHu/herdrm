import AppKit
import HerdrKit
import UserNotifications

private let blockedCategoryID = "agent.blocked"
private let replyActionID = "agent.reply"

/// Posts macOS notifications when an agent finishes or gets blocked, jumps to the agent
/// when one is clicked, and lets a blocked agent be answered straight from the banner.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    weak var model: AppModel?

    func setup(model: AppModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // A blocked agent is usually one question away from carrying on, so the banner
        // carries a text field: answering there beats switching apps to type one word.
        let reply = UNTextInputNotificationAction(
            identifier: replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to this agent…"
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: blockedCategoryID,
                actions: [reply],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts the "needs your input" / "finished" banner for one status transition.
    /// For a blocked agent it also reads the pane, so the banner can show the question
    /// itself instead of a generic line.
    func post(
        agent: AgentInfo,
        status: AgentStatus,
        device: Device,
        spaceName: String,
        service: HerdrService
    ) {
        guard status == .blocked || status == .done else { return }
        guard UserDefaults.standard.object(forKey: "notifications.enabled") as? Bool ?? true else { return }

        let paneID = agent.paneID
        let title = agent.title
        let kind = agent.agent
        let deviceID = device.id
        let deviceName = device.name

        Task {
            // Checked per post, not cached at launch: authorization can be granted (or
            // revoked) in System Settings long after the app started.
            guard await Self.isAuthorized() else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.sound = .default
            content.threadIdentifier = "\(deviceID.uuidString)-\(spaceName)"
            content.userInfo = ["paneID": paneID, "deviceID": deviceID.uuidString]

            switch status {
            case .blocked:
                let question = await Self.paneTail(paneID: paneID, service: service)
                content.subtitle = "\(kind) needs your input · \(spaceName) · \(deviceName)"
                content.body = question ?? "\(kind) needs your input · \(spaceName) · \(deviceName)"
                content.categoryIdentifier = blockedCategoryID
                // Blocked means an agent is idling until you answer, which is exactly the
                // case worth breaking through Focus for. Without the time-sensitive
                // entitlement the system quietly treats this as a normal banner.
                content.interruptionLevel = .timeSensitive
            case .done:
                content.body = "\(kind) finished · \(spaceName) · \(deviceName)"
            default:
                return
            }

            let request = UNNotificationRequest(
                identifier: "agent-\(deviceID.uuidString)-\(paneID)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private static func isAuthorized() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    /// The last line or two the agent printed, stripped of ANSI, or nil if the read fails.
    private static func paneTail(paneID: String, service: HerdrService) async -> String? {
        guard let read = try? await service.readPane(paneID: paneID) else { return nil }
        return TerminalText.tail(read.text)
    }

    // Show banners even while the app is frontmost (herdr already suppresses
    // "done" for the pane you are actively watching).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Plain values only: the response itself must not cross to another executor.
        let info = response.notification.request.content.userInfo
        let paneID = info["paneID"] as? String
        let deviceID = (info["deviceID"] as? String).flatMap(UUID.init(uuidString:))
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        let isReply = response.actionIdentifier == replyActionID

        Task { @MainActor in
            guard let model = self.model, let paneID, let deviceID else { return }
            let ref = PaneRef(deviceID: deviceID, paneID: paneID)
            if isReply, let replyText, !replyText.trimmingCharacters(in: .whitespaces).isEmpty {
                model.reply(to: ref, text: replyText)
            } else {
                NSApp.activate(ignoringOtherApps: true)
                model.reveal(ref)
            }
        }
        completionHandler()
    }
}
