import AuthenticationServices
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Passkeys on your own domain, made and used through Apple's AuthenticationServices.
///
/// Before it works: add the app under Passkeys, Setup in the SignOps dashboard (Team ID and bundle id), host the
/// apple-app-site-association file it shows at https://<your domain>/.well-known/apple-app-site-association, and add
/// webcredentials:<your domain> under Associated Domains in Xcode.
@available(iOS 16.0, macOS 13.0, *)
public struct Passkeys {
    public struct Registered: Equatable { public let credentialId: String; public let userId: String; public let synced: Bool }
    public struct SignedIn: Equatable { public let signopsToken: String; public let expiresAt: String }

    let signops: SignOps
    private static let platform = "ios"

    /// Makes a passkey for the user the token was made for. The token comes from your server (POST /v1/passkeys/registration-token).
    @MainActor
    public func register(token: String, anchor: ASPresentationAnchor, name: String? = nil) async throws -> Registered {
        let options = try await signops.post("/v1/passkeys/register/options", ["token": token, "platform": Self.platform])
        let request = try Self.registrationRequest(options)
        let authorization = try await Prompt(anchor: anchor).run([request])
        guard let made = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration, let attestation = made.rawAttestationObject else {
            throw SignOpsError(status: 0, code: "passkey_error", message: "The phone did not return a passkey.")
        }
        let id = Base64URL.encode(made.credentialID)
        let response: [String: Any] = [
            "id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": "platform", "clientExtensionResults": [String: Any](),
            "response": ["clientDataJSON": Base64URL.encode(made.rawClientDataJSON), "attestationObject": Base64URL.encode(attestation), "transports": ["internal", "hybrid"]],
        ]
        let out = try await signops.post("/v1/passkeys/register/verify", ["token": token, "platform": Self.platform, "name": String((name ?? Self.deviceName).prefix(80)), "response": response])
        return Registered(credentialId: out["credential_id"] as? String ?? id, userId: out["user_id"] as? String ?? "", synced: out["synced"] as? Bool ?? false)
    }

    /// Signs in with a passkey. Without userId the phone offers every passkey it has for your domain; with it, only that
    /// user's. autofill: true offers the passkey in the keyboard's suggestions on your username field (set its
    /// textContentType to .username) instead of opening a sheet. Send signopsToken to your server, which checks it with
    /// POST /v1/passkeys/verify before starting a session.
    @MainActor
    public func signIn(anchor: ASPresentationAnchor, userId: String? = nil, autofill: Bool = false) async throws -> SignedIn {
        var body: [String: Any] = ["platform": Self.platform]
        if let userId = userId { body["user_id"] = userId }
        let start = try await signops.post("/v1/passkeys/signin/options", body)
        guard let options = start["options"] as? [String: Any], let session = start["session"] as? String else {
            throw SignOpsError(status: 0, code: "error", message: "SignOps did not send sign-in options.")
        }
        let request = try Self.assertionRequest(options)
        let authorization = try await Prompt(anchor: anchor).run([request], autofill: autofill)
        guard let used = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw SignOpsError(status: 0, code: "no_passkey", message: "The phone did not return a passkey.")
        }
        let id = Base64URL.encode(used.credentialID)
        var inner: [String: Any] = [
            "clientDataJSON": Base64URL.encode(used.rawClientDataJSON),
            "authenticatorData": Base64URL.encode(used.rawAuthenticatorData),
            "signature": Base64URL.encode(used.signature),
        ]
        if !used.userID.isEmpty { inner["userHandle"] = Base64URL.encode(used.userID) }
        let response: [String: Any] = ["id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": "platform", "clientExtensionResults": [String: Any](), "response": inner]
        let out = try await signops.post("/v1/passkeys/signin/verify", ["session": session, "platform": Self.platform, "response": response])
        guard let token = out["signops_token"] as? String else { throw SignOpsError(status: 0, code: "error", message: "SignOps did not send a signops_token.") }
        return SignedIn(signopsToken: token, expiresAt: out["expires_at"] as? String ?? "")
    }

    // The options SignOps sends are the WebAuthn JSON a browser takes; Apple's requests take the same fields as bytes.
    static func registrationRequest(_ o: [String: Any]) throws -> ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest {
        guard let rp = o["rp"] as? [String: Any], let rpId = rp["id"] as? String,
              let user = o["user"] as? [String: Any], let name = user["name"] as? String,
              let userId = (user["id"] as? String).flatMap(Base64URL.decode),
              let challenge = (o["challenge"] as? String).flatMap(Base64URL.decode) else {
            throw SignOpsError(status: 0, code: "error", message: "The registration options from SignOps are incomplete.")
        }
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId).createCredentialRegistrationRequest(challenge: challenge, name: name, userID: userId)
        request.userVerificationPreference = .preferred
        if #available(iOS 17.4, macOS 14.4, *), let exclude = o["excludeCredentials"] as? [[String: Any]] {
            request.excludedCredentials = exclude.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        }
        return request
    }

    static func assertionRequest(_ o: [String: Any]) throws -> ASAuthorizationPlatformPublicKeyCredentialAssertionRequest {
        guard let rpId = o["rpId"] as? String, let challenge = (o["challenge"] as? String).flatMap(Base64URL.decode) else {
            throw SignOpsError(status: 0, code: "error", message: "The sign-in options from SignOps are incomplete.")
        }
        let request = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId).createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .preferred
        if let allow = o["allowCredentials"] as? [[String: Any]] {
            request.allowedCredentials = allow.compactMap { ($0["id"] as? String).flatMap(Base64URL.decode) }.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        }
        return request
    }

    @MainActor static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// Runs one ASAuthorizationController and waits for its answer. Keeps itself alive until the system calls back.
@available(iOS 16.0, macOS 13.0, *)
final class Prompt: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var keepAlive: Prompt?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    @MainActor
    func run(_ requests: [ASAuthorizationRequest], autofill: Bool = false) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<ASAuthorization, Error>) in
            continuation = c
            keepAlive = self
            let controller = ASAuthorizationController(authorizationRequests: requests)
            controller.delegate = self
            controller.presentationContextProvider = self
            #if os(iOS)
            if autofill { controller.performAutoFillAssistedRequests() } else { controller.performRequests() }
            #else
            controller.performRequests()
            #endif
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor { anchor }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil; keepAlive = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let e = error as? ASAuthorizationError
        let mapped: Error = e?.code == .canceled
            ? SignOpsError(status: 0, code: "cancelled", message: "The user closed the passkey prompt, or there is no passkey for this app on the phone.")
            : SignOpsError(status: 0, code: "passkey_error", message: error.localizedDescription)
        continuation?.resume(throwing: mapped)
        continuation = nil; keepAlive = nil
    }
}
