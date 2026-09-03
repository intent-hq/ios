import Foundation
import UserNotifications

@MainActor
protocol LocalNotificationCenter: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func getAuthorizationStatus(
        completionHandler: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void
    )
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    )
    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    )
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
private final class SystemLocalNotificationCenter: LocalNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    var delegate: (any UNUserNotificationCenterDelegate)? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func getAuthorizationStatus(
        completionHandler: @escaping @MainActor @Sendable (UNAuthorizationStatus) -> Void
    ) {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                completionHandler(status)
            }
        }
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completionHandler: @escaping @Sendable (Bool, (any Error)?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completionHandler)
    }

    func add(
        _ request: UNNotificationRequest,
        withCompletionHandler completionHandler: (@Sendable ((any Error)?) -> Void)?
    ) {
        center.add(request, withCompletionHandler: completionHandler)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

@MainActor
final class LocalNotificationService: NSObject {
    struct Response: Equatable, Sendable {
        let actionIdentifier: String
        let agentId: String?
        let workspaceId: String?
        let agentName: String?
    }

    static let shared = LocalNotificationService()

    var onWillPresentNotification: ((String) -> Void)?
    var onNotificationResponse: ((Response) -> Void)?

    private let center: any LocalNotificationCenter

    init(center: any LocalNotificationCenter = SystemLocalNotificationCenter()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        center.getAuthorizationStatus { [weak self] status in
            guard status == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func postAgentIdleNotification(
        agentId: String,
        workspaceId: String,
        agentName: String,
        workspaceName: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = agentName
        content.body = "Finished in \(workspaceName)"
        content.sound = .default
        content.userInfo = [
            "agentId": agentId,
            "workspaceId": workspaceId,
            "agentName": agentName,
        ]

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(forAgentId: agentId),
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    func removeDeliveredNotifications(forAgentId agentId: String) {
        center.removeDeliveredNotifications(
            withIdentifiers: [Self.notificationIdentifier(forAgentId: agentId)])
    }

    nonisolated static func notificationIdentifier(forAgentId agentId: String) -> String {
        "agent-idle-\(agentId)"
    }

    nonisolated static func response(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Response {
        Response(
            actionIdentifier: actionIdentifier,
            agentId: userInfo["agentId"] as? String,
            workspaceId: userInfo["workspaceId"] as? String,
            agentName: userInfo["agentName"] as? String
        )
    }

    nonisolated static func presentationOptionsForForegroundNotification()
        -> UNNotificationPresentationOptions
    {
        []
    }
}

extension LocalNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptionsForForegroundNotification())
        let identifier = notification.request.identifier
        Task { @MainActor [weak self] in
            self?.onWillPresentNotification?(identifier)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        let userInfo = response.notification.request.content.userInfo
        let forwardedResponse = Self.response(
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        )
        Task { @MainActor [weak self] in
            self?.onNotificationResponse?(forwardedResponse)
        }
    }
}