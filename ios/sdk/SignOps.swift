import Foundation

/// SignOps in an iOS app, with the app's publishable key (pk_live_ or pk_test_). Secret keys stay on your server.
///
///     let signops = SignOps(key: "pk_live_...")
///     try await signops.passkeys.register(token: registrationToken, anchor: view.window!)
///     let r = try await signops.passkeys.signIn(anchor: view.window!)   // send r.signopsToken to your server
///     try await signops.approve.enroll(token: enrolToken, pushToken: apnsOrFcmToken)   // trust this phone for Approve
///     try await signops.push.opened(userInfo: response.notification.request.content.userInfo)
public final class SignOps {
    public static let version = "0.4.0"
    public let key: String
    public let baseURL: URL
    private let session: URLSession

    public init(key: String, baseURL: URL = URL(string: "https://api.signops.dev")!, session: URLSession = .shared) {
        precondition(SignOps.isPublishable(key), "Use the app's publishable key (pk_live_ or pk_test_). A secret key must never ship in an app.")
        self.key = key
        self.baseURL = baseURL
        self.session = session
    }

    @available(iOS 16.0, macOS 13.0, *)
    public var passkeys: Passkeys { Passkeys(signops: self) }

    /// Approve: this phone answers "Is this you?" for its user, with a key in the Secure Enclave.
    public var approve: Approve { Approve(signops: self) }

    /// Push opens, reported from the app so they show on the message and as a push.opened webhook.
    public var push: Push { Push(signops: self) }

    /// Live Activities: the activity's push token, for updates your server sends by ref.
    public var activities: Activities { Activities(signops: self) }

    /// The user's notification inbox, read with the token your server makes.
    public var inbox: Inbox { Inbox(signops: self) }

    var mode: String { key.hasPrefix("pk_test_") ? "test" : "live" }

    static func isPublishable(_ key: String) -> Bool { key.hasPrefix("pk_live_") || key.hasPrefix("pk_test_") }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await request("POST", path, body: body, headers: [:])
    }

    func get(_ path: String, headers: [String: String]) async throws -> [String: Any] {
        try await request("GET", path, body: nil, headers: headers)
    }

    func post(_ path: String, _ body: [String: Any], headers: [String: String]) async throws -> [String: Any] {
        try await request("POST", path, body: body, headers: headers)
    }

    func delete(_ path: String, headers: [String: String]) async throws -> [String: Any] {
        try await request("DELETE", path, body: nil, headers: headers)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?, headers: [String: String]) async throws -> [String: Any] {
        // A path may carry a query (?limit=20): appendingPathComponent would escape the "?".
        let url = path.contains("?") ? URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)! : baseURL.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        req.setValue("signops-ios/\(SignOps.version)", forHTTPHeaderField: "user-agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, res) = try await session.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status >= 400 { throw SignOpsError.from(status: status, data: data) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SignOpsError(status: status, code: "error", message: "SignOps answered with something that is not JSON.")
        }
        return json
    }
}

/// An error from SignOps, or from the phone: "cancelled" (the user closed a prompt), "no_passkey", "passkey_error",
/// "not_enrolled" (Approve has no key on this phone), "no_lock" (no passcode set), "auth_failed", "key_error".
public struct SignOpsError: Error, LocalizedError, Equatable {
    public let status: Int
    public let code: String
    public let message: String
    public var errorDescription: String? { message }

    public init(status: Int, code: String, message: String) {
        self.status = status; self.code = code; self.message = message
    }

    /// The API's error shape: { "error": { "code": "...", "message": "..." } }.
    static func from(status: Int, data: Data) -> SignOpsError {
        let e = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        return SignOpsError(status: status, code: e?["code"] as? String ?? "error", message: e?["message"] as? String ?? "SignOps answered \(status)")
    }
}

/// WebAuthn sends bytes as base64url without padding.
enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
