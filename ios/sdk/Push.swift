import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Push opens. Every push SignOps sends carries its message id as signops_id; report the open and it shows on the
/// message in the dashboard and as a push.opened webhook. Your app still registers for pushes with Apple (or Firebase)
/// and your server adds the token (POST /v1/devices): no SignOps SDK is needed to receive pushes.
///
///     // UNUserNotificationCenterDelegate
///     func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
///         try? await signops.push.opened(userInfo: response.notification.request.content.userInfo, action: response.actionIdentifier)
///     }
public struct Push {
    let signops: SignOps

    /// Reports the open. action is the tapped button's identifier; the default tap (UNNotificationDefaultActionIdentifier)
    /// counts as a plain open. Returns false, without a call, for a push that did not come through SignOps.
    @discardableResult
    public func opened(userInfo: [AnyHashable: Any], action: String? = nil) async throws -> Bool {
        guard let id = Push.messageId(userInfo) else { return false }
        var body: [String: Any] = ["platform": "ios"]
        if let action = action, action != "com.apple.UNNotificationDefaultActionIdentifier" { body["action"] = action }
        _ = try await signops.post("/v1/push/\(id)/opened", body)
        return true
    }

    #if canImport(UserNotifications) && os(iOS)
    /// A category for pushes with buttons. iOS draws buttons only from categories the app registered, so register one
    /// per set of buttons at launch and send its identifier as ios_category; each button's id is the action reported back.
    ///
    ///     UNUserNotificationCenter.current().setNotificationCategories([Push.category("ORDER", buttons: [("track", "Track"), ("call", "Call")])])
    public static func category(_ identifier: String, buttons: [(id: String, title: String)]) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: buttons.map { UNNotificationAction(identifier: $0.id, title: $0.title, options: [.foreground]) }, intentIdentifiers: [])
    }

    /// The buttons a push carries (signops_buttons), with their links, for an app that opens a button's link itself.
    public static func buttons(_ userInfo: [AnyHashable: Any]) -> [(id: String, title: String, link: String?)] {
        guard let raw = userInfo["signops_buttons"] as? String, let d = raw.data(using: .utf8),
              let a = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return a.compactMap { o in (o["id"] as? String).map { ($0, o["title"] as? String ?? "", o["link"] as? String) } }
    }
    #endif

    /// The SignOps message id in a push's payload, or nil for a push that did not come through SignOps.
    public static func messageId(_ userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["signops_id"] as? String, id.hasPrefix("msg_") else { return nil }
        return id
    }
}
