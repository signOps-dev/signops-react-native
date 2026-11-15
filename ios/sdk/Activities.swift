import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Live Activities (Starter and Pro). Your server starts and updates the activity by ref (POST /v1/activities); the app
/// starts the Live Activity with ActivityKit, push type .token, and gives SignOps its push token.
///
///     let activity = try Activity.request(attributes: attrs, content: .init(state: state, staleDate: nil), pushType: .token)
///     signops.activities.register(ref: "order_1042", activity: activity)
///
/// Updates then go from SignOps straight to Apple, so the Apple key (.p8) must be uploaded under Push, iOS.
public struct Activities {
    let signops: SignOps

    /// Sends one push token for ref. register(ref:activity:) calls this each time iOS gives a new token.
    public func sendToken(_ token: Data, ref: String) async throws {
        _ = try await signops.post("/v1/activities/\(ref)/token", ["push_token": Activities.hex(token)])
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    #if canImport(ActivityKit) && os(iOS)
    /// Follows the activity's push token and sends it to SignOps for ref. Keep the task while the activity runs; it ends by itself when the activity does.
    @available(iOS 16.1, *)
    @discardableResult
    public func register<A: ActivityAttributes>(ref: String, activity: Activity<A>) -> Task<Void, Never> {
        Task {
            for await token in activity.pushTokenUpdates {
                try? await sendToken(token, ref: ref)
            }
        }
    }
    #endif
}
