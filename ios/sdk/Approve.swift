import Foundation
import LocalAuthentication
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Approve: this phone answers "Is this you?" for its user, signing each answer with a P-256 key made in the Secure
/// Enclave. The private key never leaves the phone; SignOps keeps the public key. (The Simulator has no Secure Enclave:
/// there the key is a Keychain key, for testing.)
///
///     try await signops.approve.enroll(token: tokenFromYourServer, pushToken: apnsOrFcmToken)   // once, after your own login
///     let waiting = try await signops.approve.pending()                  // when the app opens or an approve push arrives
///     try await signops.approve.approve(waiting[0], picked: "47")        // Face ID, Touch ID or passcode, then signed
///
/// Or show the ready-made screen: ApproveView(signops: signops).
///
/// Add NSFaceIDUsageDescription to the app's Info.plist, or Face ID is refused.
public struct Approve {
    public struct Enrolled: Equatable { public let deviceId: String; public let userId: String }

    /// A sign-in or action waiting for this user's answer. options holds three numbers; one of them is on the user's other screen.
    public struct Request: Equatable, Identifiable {
        public let id: String
        public let context: String
        public let city: String?
        public let browser: String?
        public let options: [String]
        public let createdAt: String
        public let expiresAt: String
        /// Set when the request is a payment: show it, the answer signs it.
        public var payment: Payment? = nil
    }

    /// A payment to approve (0.4.0): amount as text with two decimals, a three-letter currency, who is paid.
    public struct Payment: Equatable {
        public let amount: String
        public let currency: String
        public let payee: String
        /// "INR 1,499.00"
        public var amountText: String {
            let parts = amount.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            // Lakh grouping for rupees (1,49,999), thousands otherwise.
            let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: currency == "INR" ? "en_IN" : "en_US")
            let whole = Int64(parts[0]).flatMap { f.string(from: NSNumber(value: $0)) } ?? parts[0]
            return "\(currency) \(whole).\(parts.count > 1 ? parts[1] : "00")"
        }
        /// "INR 1,499.00 to Sharma Stores"
        public var text: String { "\(amountText) to \(payee)" }
    }

    /// status is approved or denied. reason is wrong_number when the user approved with a number that was not on the screen.
    public struct Answer: Equatable { public let id: String; public let status: String; public let reason: String? }

    let signops: SignOps
    private var tag: String { "dev.signops.approve.\(signops.mode)" }
    private var defaults: UserDefaults { UserDefaults(suiteName: tag) ?? .standard }

    public var deviceId: String? { defaults.string(forKey: "device_id") }
    public var userId: String? { defaults.string(forKey: "user_id") }
    /// True when this phone holds an Approve key and SignOps has its device id.
    public var isEnrolled: Bool { deviceId != nil && (try? privateKey()) != nil }

    /// Trusts this phone for the user your server named. The token is single-use, lasts 10 minutes and comes from your
    /// server: POST /v1/approve/enroll-token { user_id }. pushToken is what your server would register for this phone:
    /// the APNs token as hex (SignOps.apnsToken(from:)) when the app sends straight to APNs, or the FCM token.
    /// Enrolling again replaces the key. A user can have 5 trusted phones; a sixth drops the oldest.
    @discardableResult
    public func enroll(token: String, pushToken: String, name: String? = nil) async throws -> Enrolled {
        let publicKey = try makeKey()
        let out = try await signops.post("/v1/approve/devices/enroll", [
            "token": token, "public_key": publicKey, "push_token": pushToken, "platform": "ios", "name": String((name ?? Self.deviceName).prefix(80)),
        ])
        guard let dev = out["device_id"] as? String, let user = out["user_id"] as? String else {
            throw SignOpsError(status: 0, code: "error", message: "SignOps did not return a device id.")
        }
        defaults.set(dev, forKey: "device_id")
        defaults.set(user, forKey: "user_id")
        return Enrolled(deviceId: dev, userId: user)
    }

    /// Requests waiting for this phone's user, newest first (at most 5). Call it when the app opens as well as on the push.
    public func pending() async throws -> [Request] {
        guard let dev = deviceId else { throw Self.notEnrolled }
        let ts = Self.timestamp()
        let out = try await signops.get("/v1/approve/pending", headers: [
            "signops-device": dev, "signops-timestamp": ts, "signops-signature": try sign(ApproveMessages.pending(ts)),
        ])
        return Self.parsePending(out)
    }

    /// Approves with the number the user picked, after Face ID, Touch ID or the passcode.
    /// A number that is not the one on the other screen is answered as denied, reason wrong_number.
    @discardableResult
    public func approve(_ request: Request, picked: String, reason: String? = nil) async throws -> Answer {
        try await confirmOwner(reason ?? request.payment.map { "Pay \($0.text)" } ?? request.context)
        return try await answer(request, decision: "approve", picked: picked)
    }

    /// Denies the request. No Face ID: saying no is always allowed.
    @discardableResult
    public func deny(_ request: Request) async throws -> Answer {
        try await answer(request, decision: "deny", picked: "")
    }

    /// Call when the push token changes (didRegisterForRemoteNotificationsWithDeviceToken, or Firebase's token refresh).
    /// Does nothing when the phone is not enrolled.
    public func updatePushToken(_ pushToken: String) async throws {
        guard let dev = deviceId, (try? privateKey()) != nil else { return }
        let ts = Self.timestamp()
        _ = try await signops.post("/v1/approve/devices/push-token", [
            "device_id": dev, "push_token": pushToken, "timestamp": Int64(ts)!, "signature": try sign(ApproveMessages.pushToken(ts, pushToken)),
        ])
    }

    /// Removes the key and the device id from this phone, for sign-out. Your server removes the device from SignOps:
    /// POST /v1/approve/devices/:id/remove.
    public func forget() {
        SecItemDelete(keyQuery() as CFDictionary)
        defaults.removeObject(forKey: "device_id")
        defaults.removeObject(forKey: "user_id")
    }

    /// True for the push SignOps sends to ring the phone for an approval. Its payload carries approve_id.
    public static func isApprovePush(_ userInfo: [AnyHashable: Any]) -> Bool { userInfo["signops"] as? String == "approve" }
    /// The request id from an approve push.
    public static func requestId(_ userInfo: [AnyHashable: Any]) -> String? { isApprovePush(userInfo) ? userInfo["approve_id"] as? String : nil }

    // MARK: - inside

    private func answer(_ request: Request, decision: String, picked: String) async throws -> Answer {
        let id = request.id
        guard let dev = deviceId else { throw Self.notEnrolled }
        let ts = Self.timestamp()
        let out = try await signops.post("/v1/approve/\(id)/respond", [
            "device_id": dev, "decision": decision, "picked": picked, "timestamp": Int64(ts)!,
            "signature": try sign(ApproveMessages.respond(ts, id, decision, picked, request.payment)),
        ])
        return Answer(id: out["id"] as? String ?? id, status: out["status"] as? String ?? "", reason: out["reason"] as? String)
    }

    private func keyQuery() -> [String: Any] {
        [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom]
    }

    private func privateKey() throws -> SecKey {
        var q = keyQuery()
        q[kSecReturnRef as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let key = item else { throw Self.notEnrolled }
        return key as! SecKey
    }

    /// A new P-256 key under this app's tag, replacing any old one. Returns the public key as SPKI, base64url.
    private func makeKey() throws -> String {
        SecItemDelete(keyQuery() as CFDictionary)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, Self.enclave ? .privateKeyUsage : [], &error) else {
            throw SignOpsError(status: 0, code: "key_error", message: "Could not set the key's access rules.")
        }
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrAccessControl as String: access],
        ]
        if Self.enclave { attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error), let pub = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw SignOpsError(status: 0, code: "key_error", message: "The phone could not make a key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return Base64URL.encode(ApproveMessages.spki(fromX963: raw))
    }

    private func sign(_ message: String) throws -> String {
        let key = try privateKey()
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(message.utf8) as CFData, &error) as Data? else {
            throw SignOpsError(status: 0, code: "key_error", message: "The phone could not sign: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        return Base64URL.encode(sig)
    }

    /// Face ID, Touch ID or the passcode. A phone with no passcode cannot approve.
    private func confirmOwner(_ reason: String) async throws {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            throw SignOpsError(status: 0, code: "no_lock", message: "Set a passcode on this phone to approve sign-ins.")
        }
        do {
            _ = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: String(reason.prefix(120)))
        } catch let e as LAError where [.userCancel, .appCancel, .systemCancel].contains(e.code) {
            throw SignOpsError(status: 0, code: "cancelled", message: "The user closed the Face ID prompt.")
        } catch {
            throw SignOpsError(status: 0, code: "auth_failed", message: error.localizedDescription)
        }
    }

    private static var enclave: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return SecureEnclaveCheck.available
        #endif
    }

    static func timestamp() -> String { String(Int64(Date().timeIntervalSince1970 * 1000)) }
    static let notEnrolled = SignOpsError(status: 0, code: "not_enrolled", message: "This phone is not trusted for Approve. Call approve.enroll after your own login.")

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    static func parsePending(_ out: [String: Any]) -> [Request] {
        (out["data"] as? [[String: Any]] ?? []).compactMap { r in
            guard let id = r["id"] as? String, let context = r["context"] as? String, let options = r["options"] as? [String] else { return nil }
            let p = r["payment"] as? [String: Any]
            let payment = (p?["amount"] as? String).flatMap { a in (p?["currency"] as? String).flatMap { c in (p?["payee"] as? String).map { Payment(amount: a, currency: c, payee: $0) } } }
            return Request(id: id, context: context, city: r["city"] as? String, browser: r["browser"] as? String, options: options,
                           createdAt: r["created_at"] as? String ?? "", expiresAt: r["expires_at"] as? String ?? "", payment: payment)
        }
    }
}

/// Macs without a T2 or Apple chip have no Secure Enclave; every iPhone that runs iOS 16 has one.
enum SecureEnclaveCheck {
    static let available: Bool = {
        #if os(iOS)
        return true
        #else
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, &error) else { return false }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256,
                                    kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave, kSecPrivateKeyAttrs as String: [kSecAttrAccessControl as String: access]]
        return SecKeyCreateRandomKey(attrs as CFDictionary, &error) != nil
        #endif
    }()
}

/// What the phone signs, exactly as the API checks it: "<unix ms>.<what>".
enum ApproveMessages {
    static func pending(_ ts: String) -> String { "\(ts).pending" }
    static func respond(_ ts: String, _ id: String, _ decision: String, _ picked: String, _ payment: Approve.Payment? = nil) -> String {
        "\(ts).\(id).\(decision).\(picked)" + (payment.map { ".pay:\($0.currency):\($0.amount):\($0.payee)" } ?? "")
    }
    static func pushToken(_ ts: String, _ token: String) -> String { "\(ts).token.\(token)" }

    /// Apple exports a P-256 public key as the 65-byte X9.63 point; SignOps takes SPKI, which is that point after a fixed header.
    static let spkiHeader = Data([0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00])
    static func spki(fromX963 raw: Data) -> Data { spkiHeader + raw }
}

extension SignOps {
    /// The APNs device token as the hex string SignOps expects, from didRegisterForRemoteNotificationsWithDeviceToken.
    public static func apnsToken(from deviceToken: Data) -> String { deviceToken.map { String(format: "%02x", $0) }.joined() }
}
