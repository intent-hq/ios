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
        let connectionId: UUID?
        let foregroundPresentationHandled: Bool
    }

    static let shared = LocalNotificationService()

    var onWillPresentNotification: ((Response) -> UNNotificationPresentationOptions)?
    var onNotificationResponse: ((Response) -> Void)?

    private let center: any LocalNotificationCenter
    private let outputVolume: () -> Float

    init(
        center: any LocalNotificationCenter = SystemLocalNotificationCenter(),
        outputVolume: @escaping () -> Float = { NotificationChime.outputVolume }
    ) {
        self.center = center
        self.outputVolume = outputVolume
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
        workspaceName: String,
        connectionId: UUID,
        foregroundPresentationHandled: Bool = false
    ) {
        let content = UNMutableNotificationContent()
        content.title = agentName
        content.body = "Finished in \(workspaceName)"
        content.sound = outputVolume() > 0 ? .default : nil
        content.interruptionLevel = .active
        content.userInfo = [
            "agentId": agentId,
            "workspaceId": workspaceId,
            "agentName": agentName,
            "connectionId": connectionId.uuidString,
            "foregroundPresentationHandled": foregroundPresentationHandled
        ]

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier(
                forAgentId: agentId,
                connectionId: connectionId
            ),
            content: content,
            trigger: nil
        )
        center.add(request, withCompletionHandler: nil)
    }

    func removeDeliveredNotifications(forAgentId agentId: String, connectionId: UUID) {
        center.removeDeliveredNotifications(
            withIdentifiers: [
                Self.notificationIdentifier(
                    forAgentId: agentId,
                    connectionId: connectionId
                )
            ]
        )
    }

    nonisolated static func notificationIdentifier(
        forAgentId agentId: String,
        connectionId: UUID
    ) -> String {
        "agent-idle-\(connectionId.uuidString)-\(agentId)"
    }

    nonisolated static func response(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Response {
        Response(
            actionIdentifier: actionIdentifier,
            agentId: userInfo["agentId"] as? String,
            workspaceId: userInfo["workspaceId"] as? String,
            agentName: userInfo["agentName"] as? String,
            connectionId: (userInfo["connectionId"] as? String).flatMap(UUID.init(uuidString:)),
            foregroundPresentationHandled: userInfo["foregroundPresentationHandled"] as? Bool ?? false
        )
    }

    nonisolated func deliverForegroundNotification(
        _ response: Response,
        completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        Task { @MainActor [weak self] in
            var options = self?.onWillPresentNotification?(response) ?? []
            if let self, !(self.outputVolume() > 0) {
                options.remove(.sound)
            }
            completionHandler(options)
        }
    }

    nonisolated func deliverNotificationResponse(
        _ response: Response,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.onNotificationResponse?(response)
            completionHandler()
        }
    }
}

extension LocalNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let forwardedResponse = Self.response(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: notification.request.content.userInfo
        )
        deliverForegroundNotification(
            forwardedResponse,
            completionHandler: completionHandler
        )
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let forwardedResponse = Self.response(
            actionIdentifier: response.actionIdentifier,
            userInfo: userInfo
        )
        deliverNotificationResponse(
            forwardedResponse,
            completionHandler: completionHandler
        )
    }
}
