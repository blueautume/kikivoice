import Foundation
import UIKit

struct KikiAppleChallenge: Decodable { let challengeID: String; let nonce: String; let expiresAt: Int }
struct KikiAccountLoginResponse: Decodable { let token: String; let user: KikiUser }
struct KikiAccountRefreshResponse: Decodable { let user: KikiUser }
struct KikiVoiceSessionResponse: Decodable {
    let token: String
    let expiresAt: Int
    let user: KikiUser
    let sdk: KikiSDKCredentials
}

/// Uses the public HTTPS domain and the operating system's CA trust store.
/// Server private keys and service signing secrets never enter the app.
final class KikiAccountAPIClient: @unchecked Sendable {
    static let shared = KikiAccountAPIClient()
    static let endpoint = URL(string: "https://kiki.group")!
    private let session: URLSession
    private let baseURL: URL
    private let avatarCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 80
        return cache
    }()

    init(baseURL: URL = KikiAccountAPIClient.endpoint, session: URLSession? = nil) {
        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 35
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            self.session = URLSession(configuration: configuration,
                                      delegate: KikiHTTPSDelegate(), delegateQueue: nil)
        }
    }

    func appleChallenge() async throws -> KikiAppleChallenge {
        struct Body: Encodable { }
        return try await send("/v1/auth/apple/challenge", method: "POST", body: Body())
    }

    /// Public text only: no bearer, cookies, device identifier or diagnostic
    /// context. This is safe to use from the legal reader before account use.
    func legalDocuments() async throws -> KikiLegalBundle {
        let url = baseURL.appendingPathComponent("v1/legal/documents")
        guard url.scheme == "https", url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil else { throw KikiAPIError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "application/json" else { throw KikiAPIError.invalidResponse }
        return try KikiLegalBundle.decodeValidated(data)
    }

    func loginWithApple(challengeID: String, identityToken: String, authorizationCode: String,
                        legalConsent: KikiLegalAcceptance) async throws -> KikiAccountLoginResponse {
        guard legalConsent.accepted, legalConsent.adultConfirmed else {
            throw KikiAPIError.security("请同意协议并确认已满 18 周岁后登录。")
        }
        struct Body: Encodable {
            let challengeID: String; let identityToken: String; let authorizationCode: String
            let legalConsent: KikiLegalAcceptance
        }
        return try await send("/v1/auth/apple", method: "POST", body: Body(challengeID: challengeID,
            identityToken: identityToken, authorizationCode: authorizationCode, legalConsent: legalConsent))
    }

    func legalStatus(token: String) async throws -> KikiLegalStatus {
        try await request("/v1/me/legal-consent", token: token)
    }

    func registerLegalConsent(_ legalConsent: KikiLegalAcceptance, token: String) async throws -> KikiLegalStatus {
        struct Body: Encodable { let legalConsent: KikiLegalAcceptance }
        return try await send("/v1/me/legal-consent", method: "POST", body: Body(legalConsent: legalConsent), token: token)
    }

    func withdrawLegalConsent(token: String) async throws {
        let _: Success = try await request("/v1/me/legal-consent", method: "DELETE", token: token)
    }

    func cancelRequestsAndClearAvatarCache() async {
        avatarCache.removeAllObjects()
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }

    func voiceSession(token: String) async throws -> KikiVoiceSessionResponse {
        try await request("/v1/voice/session", method: "POST", token: token)
    }

    func refresh(token: String) async throws -> KikiAccountRefreshResponse {
        try await request("/v1/auth/refresh", method: "POST", token: token)
    }

    func me(token: String) async throws -> KikiUser { try await request("/v1/me", token: token) }

    func updateProfile(name: String, bio: String, avatarIndex: Int? = nil, token: String) async throws -> KikiUser {
        struct Body: Encodable {
            let name: String; let bio: String; let avatarIndex: Int?
        }
        // Omitting avatarIndex preserves a custom photo; explicitly sending an
        // index switches back to that preset on the server.
        return try await send("/v1/me", method: "PATCH", body: Body(name: name, bio: bio, avatarIndex: avatarIndex), token: token)
    }

    func uploadAvatar(jpegData: Data, token: String) async throws -> KikiUser {
        guard !jpegData.isEmpty, jpegData.count <= 2 * 1024 * 1024 else {
            throw KikiAPIError.server(422, "头像文件过大，请换一张照片。")
        }
        return try await request("/v1/me/avatar", method: "POST", data: jpegData, token: token, contentType: "image/jpeg")
    }

    func cachedAvatar(_ value: String) -> UIImage? {
        guard let url = trustedAvatarURL(value) else { return nil }
        return avatarCache.object(forKey: url as NSURL)
    }

    /// Uses system HTTPS validation, just like authenticated requests. The
    /// public avatar route never receives an account token or permits redirects.
    func loadAvatar(_ value: String) async throws -> UIImage {
        guard let url = trustedAvatarURL(value) else { throw KikiAPIError.security("头像地址无法验证。") }
        if let cached = avatarCache.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType == "image/jpeg", data.count <= 2 * 1024 * 1024,
              let image = UIImage(data: data), image.size.width <= 1024, image.size.height <= 1024 else {
            throw KikiAPIError.invalidResponse
        }
        avatarCache.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    private func trustedAvatarURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https", url.host == baseURL.host,
              url.port == baseURL.port, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.range(of: "^/v1/avatars/[A-Za-z0-9_-]+\\.jpg$", options: .regularExpression) != nil else { return nil }
        return url
    }

    func updateNotifications(_ enabled: Bool, token: String) async throws -> KikiUser {
        struct Body: Encodable { let notificationsEnabled: Bool }
        return try await send("/v1/me", method: "PATCH", body: Body(notificationsEnabled: enabled), token: token)
    }

    func pushStatus(token: String) async throws -> KikiPushStatus {
        try await request("/v1/push/status", token: token)
    }
    func registerPushDevice(installationID: String, revision: Int64, deviceToken: String,
                            environment: String, permission: String, token: String) async throws -> KikiPushReceipt {
        guard UUID(uuidString: installationID) != nil, revision > 0,
              ["sandbox", "production"].contains(environment), ["authorized", "provisional"].contains(permission),
              !deviceToken.isEmpty, deviceToken.utf8.count <= 512,
              deviceToken.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else { throw KikiAPIError.invalidResponse }
        struct Body: Encodable { let token: String; let environment: String; let revision: Int64; let permission: String }
        return try await send("/v1/push/devices/\(installationID)", method: "PUT", body: Body(token: deviceToken, environment: environment, revision: revision, permission: permission), token: token)
    }
    func unregisterPushDevice(installationID: String, revision: Int64, token: String) async throws {
        guard UUID(uuidString: installationID) != nil, revision > 0 else { throw KikiAPIError.invalidResponse }
        struct Body: Encodable { let revision: Int64 }
        let _: Success = try await send("/v1/push/devices/\(installationID)", method: "DELETE", body: Body(revision: revision), token: token)
    }
    func resolvePush(_ deliveryID: String, token: String) async throws -> KikiPushRoute {
        guard UUID(uuidString: deliveryID) != nil else { throw KikiAPIError.invalidResponse }
        return try await request("/v1/push/destinations/\(deliveryID)", token: token)
    }

    func invalidateRevokedAppleSession(token: String) async throws {
        let _: Success = try await request("/v1/auth/apple/revoked", method: "POST", token: token)
    }

    func logout(token: String) async throws {
        let _: Success = try await request("/v1/auth/logout", method: "POST", token: token)
    }

    func deleteAccount(token: String) async throws {
        let _: Success = try await request("/v1/account", method: "DELETE", token: token)
    }

    func recordForegroundActivity(token: String) async throws {
        struct Body: Encodable { }
        struct Response: Decodable { let recorded: Bool; let day: String; let retentionDays: Int }
        let _: Response = try await send("/v1/me/activity", method: "POST", body: Body(), token: token)
    }

    func reportIncident(_ incident: KikiIncident, token: String) async throws {
        struct Response: Decodable { let ok: Bool; let queued: Bool }
        let response: Response = try await send("/v1/voice/incidents", method: "POST", body: incident, token: token)
        guard response.ok else { throw KikiAPIError.invalidResponse }
    }

    private struct Success: Decodable { let ok: Bool }
    private struct ErrorResponse: Decodable { let detail: String; let requiredVersions: KikiLegalVersions?; let code: String? }
    private struct DirectAdmissionResponse: Decodable { let detail: KikiDirectMessageAdmissionError }

    private func send<Body: Encodable, Response: Decodable>(_ path: String, method: String, body: Body, token: String? = nil) async throws -> Response {
        try await request(path, method: method, data: JSONEncoder().encode(body), token: token)
    }

    private func request<Response: Decodable>(_ path: String, method: String = "GET", data: Data? = nil, token: String? = nil, contentType: String = "application/json") async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw KikiAPIError.invalidResponse }
        guard url.scheme == "https", url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil else {
            throw KikiAPIError.security("业务接口必须使用指定服务器的安全连接。")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        KikiIncidentContext.prepare(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            KikiIncidentContext.note(error)
            throw KikiTransportFailure(code: .transport(error))
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw KikiAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 403, method == "POST", path.hasPrefix("/v1/social/conversations/"), path.hasSuffix("/messages") {
                if let denial = try? JSONDecoder().decode(DirectAdmissionResponse.self, from: responseData) {
                    KikiIncidentContext.note(http, serverCode: denial.detail.code)
                    throw denial.detail
                }
            }
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
            KikiIncidentContext.note(http, serverCode: error?.code)
            let message = error?.detail
            if http.statusCode == 429 {
                let delay = max(1, min(120, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5))
                throw KikiAPIError.rateLimited(delay, message ?? "请求较多，请稍后重试。")
            }
            if http.statusCode == 428 {
                throw KikiAPIError.legalUpdateRequired(message ?? "协议已更新，请获取并重新确认当前协议。", error?.requiredVersions)
            }
            throw KikiAPIError.server(http.statusCode, message ?? (http.statusCode == 401 ? "登录已过期，请重新登录。" : "请求未完成，请检查输入后重试。"))
        }
        do { return try JSONDecoder().decode(Response.self, from: responseData) }
        catch {
            KikiIncidentContext.attempt?.noteFailure(code: .invalidResponse, requestID: http.value(forHTTPHeaderField: "X-Kiki-Request-ID"))
            throw KikiAPIError.invalidResponse
        }
    }
}


extension KikiAccountAPIClient {
    private func validateSocialID(_ userID: String) throws {
        guard userID.range(of: "^kiki_[A-Za-z0-9_]{8,64}$", options: .regularExpression) != nil else {
            throw KikiAPIError.security("账号编号无法验证。")
        }
    }

    private func socialPath(_ route: String, query: String? = nil, cursor: String? = nil) throws -> String {
        var components = URLComponents()
        components.path = "/v1/social/" + route
        var items = [URLQueryItem(name: "limit", value: "20")]
        if let query, !query.isEmpty { items.append(.init(name: "query", value: String(query.prefix(80)))) }
        if let cursor {
            guard !cursor.isEmpty, cursor.utf8.count <= 1024 else { throw KikiAPIError.invalidResponse }
            items.append(.init(name: "cursor", value: cursor))
        }
        components.queryItems = items
        guard let result = components.string else { throw KikiAPIError.invalidResponse }
        return result
    }

    func socialPeople(query: String, cursor: String?, token: String) async throws -> KikiPeoplePage {
        try await request(socialPath("people", query: query, cursor: cursor), token: token)
    }

    func socialPerson(_ userID: String, token: String) async throws -> KikiPerson {
        try validateSocialID(userID)
        struct Response: Decodable { let person: KikiPerson }
        let result: Response = try await request("/v1/social/people/\(userID)", token: token)
        return result.person
    }

    func socialRelationships(_ kind: KikiRelationshipKind, cursor: String?, token: String) async throws -> KikiPeoplePage {
        let path = try socialPath("relationships", cursor: cursor) + "&kind=" + kind.rawValue
        return try await request(path, token: token)
    }

    func socialFollow(_ userID: String, enabled: Bool, requestID: UUID, token: String) async throws -> KikiPerson {
        try validateSocialID(userID)
        struct Body: Encodable { let requestID: UUID }
        struct Response: Decodable { let person: KikiPerson }
        let result: Response = try await send("/v1/social/follows/\(userID)", method: enabled ? "PUT" : "DELETE", body: Body(requestID: requestID), token: token)
        return result.person
    }

    func socialFollowingIDs(token: String) async throws -> KikiFollowingIDs {
        try await request("/v1/social/relationships/ids", token: token)
    }

    func socialNotifications(cursor: String?, token: String) async throws -> KikiNotificationsPage {
        try await request(socialPath("notifications", cursor: cursor), token: token)
    }

    func socialReadNotifications(ids: [String], all: Bool, token: String) async throws -> Int {
        struct Body: Encodable { let ids: [String]?; let all: Bool? }
        struct Response: Decodable { let unreadCount: Int }
        let result: Response = try await send("/v1/social/notifications/read", method: "POST",
            body: Body(ids: all ? nil : ids, all: all ? true : nil), token: token)
        return result.unreadCount
    }
}

extension KikiAccountAPIClient {
    private func validateSocialUUID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw KikiAPIError.security("内容编号无法验证。") }
    }
    func socialUpload(jpeg: Data, token: String) async throws -> KikiSocialMedia {
        guard !jpeg.isEmpty, jpeg.count <= 2 * 1024 * 1024 else { throw KikiAPIError.server(422, "图片过大，请重新选择。") }
        return try await request("/v1/social/media", method: "POST", data: jpeg, token: token, contentType: "image/jpeg")
    }
    func socialImage(_ media: KikiSocialMedia, token: String) async throws -> UIImage {
        try validateSocialUUID(media.id)
        guard media.path == "/v1/social/media/\(media.id).jpg", let url = URL(string: media.path, relativeTo: baseURL)?.absoluteURL else {
            throw KikiAPIError.security("图片地址无法验证。")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw KikiAPIError.invalidResponse }
        if http.statusCode == 428 {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw KikiAPIError.legalUpdateRequired(error?.detail ?? "协议已更新，请重新确认。", error?.requiredVersions)
        }
        guard http.statusCode == 200 else { throw KikiAPIError.server(http.statusCode, "图片暂时不可查看。") }
        guard http.mimeType == "image/jpeg", data.count <= 2 * 1024 * 1024,
              let image = UIImage(data: data), image.size.width <= 4096, image.size.height <= 4096 else { throw KikiAPIError.invalidResponse }
        return image
    }
    func socialMoments(kind: KikiMomentKind, userID: String? = nil, cursor: String?, token: String) async throws -> KikiMomentsPage {
        var path = try socialPath("moments", cursor: cursor) + "&kind=" + kind.rawValue
        if let userID { try validateSocialID(userID); path += "&userID=" + userID }
        return try await request(path, token: token)
    }
    func socialMoment(_ id: String, token: String) async throws -> KikiMoment {
        try validateSocialUUID(id)
        struct Response: Decodable { let moment: KikiMoment }
        let result: Response = try await request("/v1/social/moments/\(id)", token: token)
        return result.moment
    }
    func socialPublishMoment(requestID: UUID, text: String, mediaIDs: [String], token: String) async throws -> KikiMoment {
        struct Body: Encodable { let requestID: UUID; let text: String; let mediaIDs: [String] }
        struct Response: Decodable { let moment: KikiMoment }
        let result: Response = try await send("/v1/social/moments", method: "POST", body: Body(requestID: requestID, text: text, mediaIDs: mediaIDs), token: token)
        return result.moment
    }
    func socialDeleteMoment(_ id: String, token: String) async throws {
        try validateSocialUUID(id)
        let _: Success = try await request("/v1/social/moments/\(id)", method: "DELETE", token: token)
    }
    func socialLike(_ id: String, enabled: Bool, requestID: UUID, token: String) async throws -> KikiMoment {
        try validateSocialUUID(id)
        struct Body: Encodable { let requestID: UUID }
        struct Response: Decodable { let moment: KikiMoment }
        let result: Response = try await send("/v1/social/moments/\(id)/like", method: enabled ? "PUT" : "DELETE", body: Body(requestID: requestID), token: token)
        return result.moment
    }
    func socialComments(_ id: String, cursor: String?, token: String) async throws -> KikiCommentsPage {
        try validateSocialUUID(id)
        return try await request(socialPath("moments/\(id)/comments", cursor: cursor), token: token)
    }
    func socialComment(_ id: String, text: String, requestID: UUID, token: String) async throws -> KikiMomentComment {
        try validateSocialUUID(id)
        struct Body: Encodable { let requestID: UUID; let text: String }
        struct Response: Decodable { let comment: KikiMomentComment }
        let result: Response = try await send("/v1/social/moments/\(id)/comments", method: "POST", body: Body(requestID: requestID, text: text), token: token)
        return result.comment
    }
    func socialDeleteComment(_ id: String, token: String) async throws {
        try validateSocialUUID(id)
        let _: Success = try await request("/v1/social/comments/\(id)", method: "DELETE", token: token)
    }
    func socialConversations(cursor: String?, token: String) async throws -> KikiConversationsPage {
        try await request(socialPath("conversations", cursor: cursor), token: token)
    }
    func socialInbox(cursor: String?, token: String) async throws -> KikiInboxPage {
        try await request(socialPath("inbox", cursor: cursor), token: token)
    }
    func socialInboxSnapshot(token: String) async throws -> KikiInboxSnapshot {
        try await request("/v1/social/inbox/snapshot", token: token)
    }
    func socialMutateInbox(snapshot: KikiInboxSnapshot, clear: Bool, requestID: UUID, token: String) async throws {
        guard !snapshot.snapshot.isEmpty, snapshot.snapshot.utf8.count <= 1024 else { throw KikiAPIError.invalidResponse }
        struct Body: Encodable { let requestID: UUID; let snapshot: String }
        let result: Success = try await send("/v1/social/inbox/" + (clear ? "clear" : "read"), method: "POST",
                                            body: Body(requestID: requestID, snapshot: snapshot.snapshot), token: token)
        guard result.ok else { throw KikiAPIError.invalidResponse }
    }
    func socialDirectMessages(_ personID: String, cursor: String?, token: String) async throws -> KikiDirectMessagesPage {
        try validateSocialID(personID)
        return try await request(socialPath("conversations/\(personID)/messages", cursor: cursor), token: token)
    }
    func socialSendDirect(_ personID: String, text: String, requestID: UUID, token: String) async throws -> KikiDirectMessageReceipt {
        try validateSocialID(personID)
        struct Body: Encodable { let requestID: UUID; let text: String }
        return try await send("/v1/social/conversations/\(personID)/messages", method: "POST", body: Body(requestID: requestID, text: text), token: token)
    }
    func socialSetConversationPinned(_ personID: String, pinned: Bool, requestID: UUID, token: String) async throws {
        try validateSocialID(personID)
        struct Body: Encodable { let requestID: UUID; let pinned: Bool }
        let result: Success = try await send("/v1/social/conversations/\(personID)/pin", method: "PUT", body: Body(requestID: requestID, pinned: pinned), token: token)
        guard result.ok else { throw KikiAPIError.invalidResponse }
    }
    func socialClearConversation(_ personID: String, throughMessageID: String, requestID: UUID, token: String) async throws {
        try validateSocialID(personID); try validateSocialUUID(throughMessageID)
        struct Body: Encodable { let requestID: UUID; let throughMessageID: String }
        let result: Success = try await send("/v1/social/conversations/\(personID)/clear", method: "POST", body: Body(requestID: requestID, throughMessageID: throughMessageID), token: token)
        guard result.ok else { throw KikiAPIError.invalidResponse }
    }
    func socialReadDirect(_ personID: String, throughMessageID: String, token: String) async throws -> Int {
        try validateSocialID(personID); try validateSocialUUID(throughMessageID)
        struct Body: Encodable { let throughMessageID: String }
        struct Response: Decodable { let unreadCount: Int }
        let result: Response = try await send("/v1/social/conversations/\(personID)/read", method: "POST", body: Body(throughMessageID: throughMessageID), token: token)
        return result.unreadCount
    }
    func socialReport(_ target: KikiSocialReportTarget, reason: KikiSocialReportReason, details: String, requestID: UUID, token: String) async throws -> KikiSocialReportReceipt {
        if target.kind == .profile { try validateSocialID(target.targetID) } else { try validateSocialUUID(target.targetID) }
        struct Body: Encodable { let requestID: UUID; let targetType: String; let targetID: String; let reason: String; let details: String }
        return try await send("/v1/social/reports", method: "POST", body: Body(requestID: requestID, targetType: target.kind.rawValue, targetID: target.targetID, reason: reason.rawValue, details: details), token: token)
    }
    func socialBlock(_ personID: String, enabled: Bool, requestID: UUID, token: String) async throws {
        try validateSocialID(personID)
        struct Body: Encodable { let requestID: UUID }
        let _: Success = try await send("/v1/social/blocks/\(personID)", method: enabled ? "PUT" : "DELETE", body: Body(requestID: requestID), token: token)
    }
}

extension KikiAccountAPIClient {
    func socialReports(token: String) async throws -> KikiSocialReportsPage {
        try await request("/v1/social/reports/mine", token: token)
    }
}
