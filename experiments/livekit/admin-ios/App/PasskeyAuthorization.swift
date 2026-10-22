import AuthenticationServices
import Foundation
import UIKit

enum OpsBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String, minimum: Int = 1, maximum: Int = 32_768) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= (maximum + 2) / 3 * 4,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              value.count % 4 != 1 else { throw OpsError.invalidPasskeyOptions }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base + String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), (minimum...maximum).contains(data.count), encode(data) == value else {
            throw OpsError.invalidPasskeyOptions
        }
        return data
    }
}

struct OpsRegistrationOptions: Decodable {
    let transactionID: String
    let publicKey: PublicKey
    struct PublicKey: Decodable {
        let rp: RP; let user: User; let challenge: String
        let pubKeyCredParams: [Algorithm]
        let authenticatorSelection: Selection
        let attestation: String
        let excludeCredentials: [Descriptor]?
    }
    struct RP: Decodable { let id: String; let name: String }
    struct User: Decodable { let id: String; let name: String; let displayName: String }
    struct Algorithm: Decodable { let type: String; let alg: Int }
    struct Selection: Decodable { let residentKey: String; let userVerification: String }
    struct Descriptor: Decodable { let id: String; let type: String }
    func validate() throws {
        guard !transactionID.isEmpty, transactionID.utf8.count <= 512,
              publicKey.rp.id == OpsIdentityEndpoint.relyingPartyID,
              publicKey.authenticatorSelection.residentKey == "required",
              publicKey.authenticatorSelection.userVerification == "required", publicKey.attestation == "none",
              publicKey.pubKeyCredParams.contains(where: { $0.type == "public-key" && $0.alg == -7 }),
              !publicKey.user.name.isEmpty else { throw OpsError.invalidPasskeyOptions }
        _ = try OpsBase64URL.decode(publicKey.challenge, minimum: 16, maximum: 128)
        _ = try OpsBase64URL.decode(publicKey.user.id, maximum: 64)
        for item in publicKey.excludeCredentials ?? [] {
            guard item.type == "public-key" else { throw OpsError.invalidPasskeyOptions }
            _ = try OpsBase64URL.decode(item.id, maximum: 1024)
        }
    }
}

struct OpsAuthenticationOptions: Decodable {
    let transactionID: String
    let publicKey: PublicKey
    struct PublicKey: Decodable {
        let challenge: String; let rpId: String; let userVerification: String
        let allowCredentials: [OpsRegistrationOptions.Descriptor]?
    }
    func validate() throws {
        guard !transactionID.isEmpty, transactionID.utf8.count <= 512,
              publicKey.rpId == OpsIdentityEndpoint.relyingPartyID,
              publicKey.userVerification == "required", publicKey.allowCredentials?.isEmpty != false else {
            throw OpsError.invalidPasskeyOptions
        }
        _ = try OpsBase64URL.decode(publicKey.challenge, minimum: 16, maximum: 128)
    }
}

/// Exact WebAuthn credential envelope; private key material never enters the app.
struct OpsPasskeyCredential: Codable {
    let id: String
    let rawId: String
    let type: String
    let response: Response
    let clientExtensionResults: [String: Bool]
    struct Response: Codable {
        let clientDataJSON: String
        let attestationObject: String?
        let authenticatorData: String?
        let signature: String?
        let userHandle: String?
    }
    static func registration(id: Data, clientData: Data, attestation: Data) throws -> Self {
        guard !id.isEmpty, id.count <= 1024, !clientData.isEmpty, clientData.count <= 8192,
              !attestation.isEmpty, attestation.count <= 20_000 else { throw OpsError.invalidPasskeyOptions }
        let value = OpsBase64URL.encode(id)
        return Self(id: value, rawId: value, type: "public-key", response: Response(
            clientDataJSON: OpsBase64URL.encode(clientData), attestationObject: OpsBase64URL.encode(attestation),
            authenticatorData: nil, signature: nil, userHandle: nil), clientExtensionResults: [:])
    }
    static func assertion(id: Data, clientData: Data, authenticatorData: Data, signature: Data, userHandle: Data) throws -> Self {
        guard !id.isEmpty, id.count <= 1024, !clientData.isEmpty, clientData.count <= 8192,
              !authenticatorData.isEmpty, authenticatorData.count <= 2048,
              !signature.isEmpty, signature.count <= 2048, !userHandle.isEmpty, userHandle.count <= 64 else {
            throw OpsError.invalidPasskeyOptions
        }
        let value = OpsBase64URL.encode(id)
        return Self(id: value, rawId: value, type: "public-key", response: Response(
            clientDataJSON: OpsBase64URL.encode(clientData), attestationObject: nil,
            authenticatorData: OpsBase64URL.encode(authenticatorData), signature: OpsBase64URL.encode(signature),
            userHandle: OpsBase64URL.encode(userHandle)), clientExtensionResults: [:])
    }
}

@MainActor protocol OpsPasskeyAuthorizing: AnyObject {
    func register(_ options: OpsRegistrationOptions) async throws -> OpsPasskeyCredential
    func authenticate(_ options: OpsAuthenticationOptions) async throws -> OpsPasskeyCredential
    func cancel()
}

/// The same retained controller owns the request, anchor and single continuation.
/// Inactive scenes may be showing system authorization; only background cancels.
@MainActor final class SystemOpsPasskeyAuthorizer: NSObject, OpsPasskeyAuthorizing,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<OpsPasskeyCredential, Error>?
    private var window: UIWindow?
    private var registering = false

    func register(_ options: OpsRegistrationOptions) async throws -> OpsPasskeyCredential {
        try options.validate()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: OpsIdentityEndpoint.relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(challenge: try OpsBase64URL.decode(options.publicKey.challenge),
            name: options.publicKey.user.name, userID: try OpsBase64URL.decode(options.publicKey.user.id, maximum: 64))
        request.userVerificationPreference = .required
        request.attestationPreference = .none
        if let excluded = options.publicKey.excludeCredentials, !excluded.isEmpty {
            if #available(iOS 17.4, *) {
                request.excludedCredentials = try excluded.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: try OpsBase64URL.decode($0.id, maximum: 1024)) }
            } else { throw OpsError.invalidPasskeyOptions }
        }
        return try await perform(request, registering: true)
    }
    func authenticate(_ options: OpsAuthenticationOptions) async throws -> OpsPasskeyCredential {
        try options.validate()
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: OpsIdentityEndpoint.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: try OpsBase64URL.decode(options.publicKey.challenge))
        request.userVerificationPreference = .required
        request.allowedCredentials = [] // Discoverable login; the system selects the synced Passkey.
        return try await perform(request, registering: false)
    }
    private func perform(_ request: ASAuthorizationRequest, registering: Bool) async throws -> OpsPasskeyCredential {
        try Task.checkCancellation()
        guard continuation == nil, controller == nil else { throw OpsError.authorizationInProgress }
        guard let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) else {
            throw OpsError.authorizationUnavailable
        }
        self.registering = registering; window = anchor
        let current = ASAuthorizationController(authorizationRequests: [request])
        current.delegate = self; current.presentationContextProvider = self; controller = current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                current.performRequests()
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel(current) } }
    }
    func cancel() { if let controller { cancel(controller) } }
    private func cancel(_ expected: ASAuthorizationController) {
        guard controller === expected else { return }
        expected.cancel(); finish(.failure(CancellationError()))
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The strong window reference was validated before the request began.
        window ?? UIWindow()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        do {
            if registering, let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
               let attestation = credential.rawAttestationObject {
                finish(.success(try .registration(id: credential.credentialID, clientData: credential.rawClientDataJSON, attestation: attestation)))
            } else if !registering, let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion {
                finish(.success(try .assertion(id: credential.credentialID, clientData: credential.rawClientDataJSON,
                    authenticatorData: credential.rawAuthenticatorData, signature: credential.signature, userHandle: credential.userID)))
            } else { finish(.failure(OpsError.authorizationUnavailable)) }
        } catch { finish(.failure(OpsError.authorizationUnavailable)) }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard self.controller === controller else { return }
        if (error as? ASAuthorizationError)?.code == .canceled { finish(.failure(CancellationError())) }
        else { finish(.failure(OpsError.authorizationUnavailable)) }
    }
    private func finish(_ result: Result<OpsPasskeyCredential, Error>) {
        let pending = continuation
        continuation = nil; controller = nil; window = nil
        pending?.resume(with: result)
    }
}
