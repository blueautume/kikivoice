import Foundation

struct OpsLoginResult {
    let session: OpsSession
    let account: OpsAccount
}

protocol OpsAPI: Sendable {
    func registrationOptions() async throws -> OpsRegistrationOptions
    func authenticationOptions() async throws -> OpsAuthenticationOptions
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult
    func me(session: OpsSession) async throws -> OpsAccount
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount
    func dashboard(session: OpsSession) async throws -> OpsDashboard
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard
    func moderation(session: OpsSession, filter: OpsReportFilter) async throws -> OpsModerationPage
    func moderate(_ request: OpsModerationRequest, session: OpsSession) async throws -> OpsModerationResult
    func socialModeration(session: OpsSession, filter: OpsReportFilter, cursor: String?) async throws -> OpsSocialModerationPage
    func socialModerate(_ request: OpsSocialActionRequest, session: OpsSession) async throws -> OpsSocialActionResult
    func incidents(_ query: OpsIncidentQuery, session: OpsSession) async throws -> OpsIncidentPage
    func logout(session: OpsSession) async throws
}

extension OpsAPI {
    func moderation(session: OpsSession, filter: OpsReportFilter) async throws -> OpsModerationPage { throw OpsError.forbidden }
    func moderate(_ request: OpsModerationRequest, session: OpsSession) async throws -> OpsModerationResult { throw OpsError.forbidden }
    func socialModeration(session: OpsSession, filter: OpsReportFilter, cursor: String?) async throws -> OpsSocialModerationPage { throw OpsError.forbidden }
    func socialModerate(_ request: OpsSocialActionRequest, session: OpsSession) async throws -> OpsSocialActionResult { throw OpsError.forbidden }
    func incidents(_ query: OpsIncidentQuery, session: OpsSession) async throws -> OpsIncidentPage { throw OpsError.forbidden }
}

struct OpsIdentityAPI: OpsAPI {
    private let transport: any OpsTransport
    init(transport: (any OpsTransport)? = nil) { self.transport = transport ?? SecureOpsTransport() }
    func request(path: String, method: String, session: OpsSession? = nil, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: OpsIdentityEndpoint.baseURL)?.absoluteURL else { throw OpsError.unsafeEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        guard OpsIdentityEndpoint.permits(request), (body?.count ?? 0) <= 32_768 else { throw OpsError.unsafeEndpoint }
        if let session, !session.isValid() { throw OpsError.expired }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let session { request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func send<T: Decodable>(_ type: T.Type, path: String, method: String, session: OpsSession? = nil, body: Data? = nil) async throws -> T {
        let request = try request(path: path, method: method, session: session, body: body)
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard response.url == request.url, data.count <= 2 * 1024 * 1024 else { throw OpsError.redirected }
        switch response.statusCode {
        case 200...299: break
        case 300...399: throw OpsError.redirected
        case 401: throw OpsError.unauthenticated
        case 403: throw OpsError.forbidden
        case 409: throw path.contains("/moderation/") ? OpsError.moderationConflict : OpsError.ceremonyExpired
        case 422:
            if path.contains("/incidents/") { throw OpsError.invalidIncidentQuery }
            throw path.contains("/moderation/") ? OpsError.invalidModeration : OpsError.invalidName
        case 429: throw OpsError.rateLimited
        default: throw OpsError.server(status: response.statusCode)
        }
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw OpsError.invalidResponse }
        return value
    }
    func registrationOptions() async throws -> OpsRegistrationOptions {
        let result = try await send(OpsRegistrationOptions.self, path: "/admin/v2/auth/registration/options", method: "POST", body: Data("{}".utf8))
        try result.validate(); return result
    }
    func authenticationOptions() async throws -> OpsAuthenticationOptions {
        let result = try await send(OpsAuthenticationOptions.self, path: "/admin/v2/auth/authentication/options", method: "POST", body: Data("{}".utf8))
        try result.validate(); return result
    }
    private struct VerifyBody: Encodable { let transactionID: String; let credential: OpsPasskeyCredential }
    private struct SessionResponse: Decodable {
        let token: String; let expiresAt: Double; let serviceID: String; let role: String; let account: OpsAccount
    }
    private func verify(path: String, transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult {
        guard !transactionID.isEmpty, transactionID.utf8.count <= 512 else { throw OpsError.invalidPasskeyOptions }
        let response = try await send(SessionResponse.self, path: path, method: "POST",
            body: JSONEncoder().encode(VerifyBody(transactionID: transactionID, credential: credential)))
        guard response.serviceID == "ops-identity", response.role == "member" else { throw OpsError.invalidResponse }
        try response.account.validate()
        let session = OpsSession(token: response.token, expiresAt: Date(timeIntervalSince1970: response.expiresAt))
        guard session.isValid() else { throw OpsError.invalidResponse }
        return OpsLoginResult(session: session, account: response.account)
    }
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult {
        try await verify(path: "/admin/v2/auth/registration/verify", transactionID: transactionID, credential: credential)
    }
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult {
        try await verify(path: "/admin/v2/auth/authentication/verify", transactionID: transactionID, credential: credential)
    }
    private struct MeResponse: Decodable { let schemaVersion: Int; let account: OpsAccount }
    private func readMe(method: String, session: OpsSession, body: Data? = nil) async throws -> OpsAccount {
        let response = try await send(MeResponse.self, path: "/admin/v2/me", method: method, session: session, body: body)
        guard response.schemaVersion == 1 else { throw OpsError.invalidResponse }
        try response.account.validate(); return response.account
    }
    func me(session: OpsSession) async throws -> OpsAccount { try await readMe(method: "GET", session: session) }
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount {
        guard let name = OpsAccount.validName(name) else { throw OpsError.invalidName }
        struct Body: Encodable { let name: String }
        return try await readMe(method: "PATCH", session: session, body: JSONEncoder().encode(Body(name: name)))
    }
    func dashboard(session: OpsSession) async throws -> OpsDashboard {
        let result = try await send(OpsDashboard.self, path: "/admin/v2/services/voice/dashboard", method: "GET", session: session)
        try result.validateVoiceBoundary(); return result
    }
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard {
        let result = try await send(AccountOpsDashboard.self, path: "/admin/v2/services/account/dashboard", method: "GET", session: session)
        try result.validateAccountBoundary(); return result
    }
    func moderation(session: OpsSession, filter: OpsReportFilter) async throws -> OpsModerationPage {
        struct Body: Encodable { let status: String; let limit: Int }
        let result = try await send(OpsModerationPage.self, path: "/admin/v2/services/voice/moderation/query", method: "POST", session: session,
                                    body: JSONEncoder().encode(Body(status: filter.rawValue, limit: 50)))
        try result.validate(); return result
    }
    func moderate(_ request: OpsModerationRequest, session: OpsSession) async throws -> OpsModerationResult {
        try request.validate()
        let result = try await send(OpsModerationResult.self, path: "/admin/v2/services/voice/moderation/action", method: "POST", session: session,
                                    body: JSONEncoder().encode(request))
        try result.validate(for: request); return result
    }
    func incidents(_ query: OpsIncidentQuery, session: OpsSession) async throws -> OpsIncidentPage {
        let result = try await send(OpsIncidentPage.self, path: "/admin/v2/services/voice/incidents/query", method: "POST", session: session,
                                    body: JSONEncoder().encode(query))
        try result.validate(limit: query.limit); return result
    }
    func socialModeration(session: OpsSession, filter: OpsReportFilter, cursor: String?) async throws -> OpsSocialModerationPage {
        struct Body: Encodable { let status: String; let limit: Int; let cursor: String? }
        guard cursor == nil || cursor!.utf8.count <= 1024 else { throw OpsError.invalidModeration }
        let result = try await send(OpsSocialModerationPage.self, path: "/admin/v2/services/account/social/moderation/query", method: "POST", session: session,
                                    body: JSONEncoder().encode(Body(status: filter.rawValue, limit: 50, cursor: cursor)))
        try result.validate(); return result
    }
    func socialModerate(_ value: OpsSocialActionRequest, session: OpsSession) async throws -> OpsSocialActionResult {
        try value.validate()
        let result = try await send(OpsSocialActionResult.self, path: "/admin/v2/services/account/social/moderation/action", method: "POST", session: session, body: JSONEncoder().encode(value))
        try result.validate(value); return result
    }
    func logout(session: OpsSession) async throws {
        struct Response: Decodable { let revoked: Bool }
        let result = try await send(Response.self, path: "/admin/v2/auth/session", method: "DELETE", session: session)
        guard result.revoked else { throw OpsError.invalidResponse }
    }
}
