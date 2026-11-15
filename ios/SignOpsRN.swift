import Foundation
import UIKit
import React

/// The bridge: each call names the publishable key, and the SignOps Swift SDK does the work.
@objc(SignOpsRN)
final class SignOpsRN: NSObject {
    private var clients: [String: SignOps] = [:]
    private let lock = NSLock()

    private func client(_ key: String, _ base: String) -> SignOps {
        lock.lock(); defer { lock.unlock() }
        if let c = clients["\(key) \(base)"] { return c }
        let c = SignOps(key: key, baseURL: URL(string: base)!)
        clients["\(key) \(base)"] = c
        return c
    }

    private func run(_ resolve: @escaping RCTPromiseResolveBlock, _ reject: @escaping RCTPromiseRejectBlock, _ work: @escaping () async throws -> Any?) {
        Task {
            do { resolve(try await work()) }
            catch let e as SignOpsError { reject(e.code, e.message, NSError(domain: "SignOps", code: e.status, userInfo: [NSLocalizedDescriptionKey: e.message])) }
            catch { reject("error", error.localizedDescription, error) }
        }
    }

    private func request(_ m: NSDictionary) -> Approve.Request {
        Approve.Request(id: m["id"] as? String ?? "", context: m["context"] as? String ?? "", city: m["city"] as? String, browser: m["browser"] as? String,
                        options: m["options"] as? [String] ?? [], createdAt: m["createdAt"] as? String ?? "", expiresAt: m["expiresAt"] as? String ?? "",
                        payment: (m["payment"] as? NSDictionary).map { Approve.Payment(amount: $0["amount"] as? String ?? "", currency: $0["currency"] as? String ?? "", payee: $0["payee"] as? String ?? "") })
    }
    /// JavaScript gets null for a missing value.
    private func orNull(_ s: String?) -> Any { s.map { $0 as Any } ?? NSNull() }
    private func requestMap(_ r: Approve.Request) -> [String: Any] {
        ["id": r.id, "context": r.context, "city": orNull(r.city), "browser": orNull(r.browser), "options": r.options, "createdAt": r.createdAt, "expiresAt": r.expiresAt,
         "payment": r.payment.map { ["amount": $0.amount, "currency": $0.currency, "payee": $0.payee] as Any } ?? NSNull()]
    }
    private func answerMap(_ a: Approve.Answer) -> [String: Any] { ["id": a.id, "status": a.status, "reason": orNull(a.reason)] }

    @MainActor private func anchor() throws -> UIWindow {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        guard let w = w else { throw SignOpsError(status: 0, code: "no_activity", message: "SignOps needs the app on screen.") }
        return w
    }

    @objc func approveStatus(_ key: String, base: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { let a = self.client(key, base).approve; return ["enrolled": a.isEnrolled, "deviceId": self.orNull(a.deviceId), "userId": self.orNull(a.userId)] }
    }

    @objc func approveEnroll(_ key: String, base: String, token: String, pushToken: String, name: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) {
            let e = try await self.client(key, base).approve.enroll(token: token, pushToken: pushToken, name: name)
            return ["deviceId": e.deviceId, "userId": e.userId]
        }
    }

    @objc func approvePending(_ key: String, base: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { try await self.client(key, base).approve.pending().map(self.requestMap) }
    }

    @objc func approveApprove(_ key: String, base: String, req: NSDictionary, picked: String, title: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { self.answerMap(try await self.client(key, base).approve.approve(self.request(req), picked: picked, reason: title)) }
    }

    @objc func approveDeny(_ key: String, base: String, req: NSDictionary, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { self.answerMap(try await self.client(key, base).approve.deny(self.request(req))) }
    }

    @objc func approveUpdatePushToken(_ key: String, base: String, token: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { try await self.client(key, base).approve.updatePushToken(token); return nil }
    }

    @objc func approveForget(_ key: String, base: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { self.client(key, base).approve.forget(); return nil }
    }

    @objc func pushOpened(_ key: String, base: String, data: NSDictionary, action: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) { try await self.client(key, base).push.opened(userInfo: data as? [AnyHashable: Any] ?? [:], action: action) }
    }

    @objc func passkeysRegister(_ key: String, base: String, token: String, name: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) {
            let r = try await self.client(key, base).passkeys.register(token: token, anchor: try await self.anchor(), name: name)
            return ["credentialId": r.credentialId, "userId": r.userId, "synced": r.synced]
        }
    }

    @objc func passkeysSignIn(_ key: String, base: String, userId: String?, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        run(resolve, reject) {
            let r = try await self.client(key, base).passkeys.signIn(anchor: try await self.anchor(), userId: userId)
            return ["signopsToken": r.signopsToken, "expiresAt": r.expiresAt]
        }
    }

    @objc static func requiresMainQueueSetup() -> Bool { false }
}
