import Foundation
import Security
import UIKit

struct KikiUser: Codable, Equatable {
    let id: String
    let sdkUserID: String
    var name: String
    var bio: String
    var avatarIndex: Int
    var notificationsEnabled: Bool
    var avatarURL: String?
    var needsNickname: Bool

    private enum CodingKeys: String, CodingKey {
        case id, sdkUserID, name, bio, avatarIndex, notificationsEnabled, avatarURL, needsNickname
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sdkUserID = try values.decode(String.self, forKey: .sdkUserID)
        name = try values.decode(String.self, forKey: .name)
        bio = try values.decode(String.self, forKey: .bio)
        avatarIndex = try values.decode(Int.self, forKey: .avatarIndex)
        notificationsEnabled = try values.decode(Bool.self, forKey: .notificationsEnabled)
        avatarURL = try values.decodeIfPresent(String.self, forKey: .avatarURL)
        needsNickname = try values.decodeIfPresent(Bool.self, forKey: .needsNickname) ?? false
    }
}

struct KikiSDKCredentials: Decodable {
    let sdkAppID: Int
    let userID: String
    let userSig: String
    let expiresAt: Int
}

struct KikiAppleChallenge: Decodable {
    let challengeID: String
    let nonce: String
    let expiresAt: Int
}

struct KikiLoginResponse: Decodable {
    let token: String
    let user: KikiUser
    let sdk: KikiSDKCredentials
}

struct KikiRefreshResponse: Decodable {
    let user: KikiUser
    let sdk: KikiSDKCredentials
}

struct KikiLibrary: Decodable {
    let favorites: [DemoRoom]
    let recents: [DemoRoom]
    let created: [DemoRoom]
}

enum KikiAPIError: Foundation.LocalizedError {
    case server(Int, String)
    case security(String)
    case legalUpdateRequired(String, KikiLegalVersions?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(_, let message), .security(let message): return message
        case .legalUpdateRequired(let message, _): return message
        case .invalidResponse: return "服务器返回的数据无法读取，请稍后重试。"
        }
    }
    var isUnauthorized: Bool {
        if case .server(401, _) = self { return true }
        return false
    }
}

/// Uses the public HTTPS domain and the operating system's CA trust store.
/// Server private keys and Tencent signing secrets never enter the app.
final class KikiAPIClient: @unchecked Sendable {
    static let shared = KikiAPIClient()
    static let endpoint = URL(string: "https://kiki.group")!
    private let session: URLSession
    private let baseURL: URL
    private let avatarCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 80
        return cache
    }()

    init(baseURL: URL = KikiAPIClient.endpoint, session: URLSession? = nil) {
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

    func loginWithApple(challengeID: String, identityToken: String, authorizationCode: String,
                        legalConsent: KikiLegalAcceptance) async throws -> KikiLoginResponse {
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

    func refresh(token: String) async throws -> KikiRefreshResponse {
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

    func library(token: String) async throws -> KikiLibrary { try await request("/v1/library", token: token) }

    func roomMetadata(ids: [String], token: String) async throws -> [DemoRoom] {
        struct Body: Encodable { let ids: [String] }
        struct Response: Decodable { let rooms: [DemoRoom] }
        let uniqueIDs = Array(Set(ids)).sorted()
        var rooms: [DemoRoom] = []
        // Ask for the actual SDK rooms, including long-running rooms older
        // than the server's recent-history window. Keep each body below 16 KiB.
        for offset in stride(from: 0, to: uniqueIDs.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(uniqueIDs[offset..<min(offset + 100, uniqueIDs.count)])
            let response: Response = try await send("/v1/rooms/lookup", method: "POST", body: Body(ids: batch), token: token)
            rooms.append(contentsOf: response.rooms)
        }
        return rooms
    }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int, token: String) async throws -> DemoRoom {
        struct Body: Encodable { let title: String; let category: String; let isLive: Bool; let theme: Int }
        return try await send("/v1/rooms", method: "POST", body: Body(title: title, category: category, isLive: isLive, theme: theme), token: token)
    }

    func setRoomStatus(_ roomID: String, status: String, token: String) async throws -> DemoRoom {
        struct Body: Encodable { let status: String }
        return try await send("/v1/rooms/\(roomID)", method: "PATCH", body: Body(status: status), token: token)
    }

    func favorite(_ roomID: String, enabled: Bool, token: String) async throws {
        let _: Success = try await request("/v1/favorites/\(roomID)", method: enabled ? "PUT" : "DELETE", token: token)
    }

    func visit(_ roomID: String, token: String) async throws {
        let _: Success = try await request("/v1/history/\(roomID)", method: "POST", token: token)
    }

    func giftCatalog(token: String) async throws -> KikiGiftCatalog {
        try await request("/v1/gifts/catalog", token: token)
    }

    func giftWallet(token: String) async throws -> KikiGiftWallet {
        try await request("/v1/me/wallet", token: token)
    }

    func sendGift(roomID: String, giftID: String, quantity: Int, requestID: String,
                  noticeVersion: String, token: String) async throws -> KikiGiftSendResponse {
        struct Body: Encodable { let giftID: String; let quantity: Int; let requestID: String; let noticeVersion: String }
        return try await send("/v1/rooms/\(roomID)/gifts", method: "POST",
                              body: Body(giftID: giftID, quantity: quantity, requestID: requestID, noticeVersion: noticeVersion), token: token)
    }

    func sendGiftBatch(roomID: String, giftID: String, quantity: Int, recipientIDs: [String], requestID: String,
                       noticeVersion: String, token: String) async throws -> KikiGiftBatchSendResponse {
        struct Body: Encodable {
            let giftID: String; let quantity: Int; let recipientIDs: [String]; let requestID: String; let noticeVersion: String
        }
        return try await send("/v1/rooms/\(roomID)/gifts/batch", method: "POST",
                              body: Body(giftID: giftID, quantity: quantity, recipientIDs: recipientIDs,
                                         requestID: requestID, noticeVersion: noticeVersion), token: token)
    }

    func giftEvents(roomID: String, after cursor: Int64?, token: String) async throws -> KikiGiftEventPage {
        let query = cursor.map { "?after=\($0)&limit=30" } ?? "?limit=30"
        return try await request("/v1/rooms/\(roomID)/gifts\(query)", token: token)
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

    private struct Success: Decodable { let ok: Bool }
    private struct ErrorResponse: Decodable { let detail: String; let requiredVersions: KikiLegalVersions? }

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
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if data != nil { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost:
                throw KikiAPIError.server(0, "网络已断开，请检查网络后重试。")
            case .timedOut, .cannotConnectToHost:
                throw KikiAPIError.server(0, "暂时无法连接服务器，请稍后重试。")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .secureConnectionFailed:
                throw KikiAPIError.security("服务器身份校验失败，请使用最新版本或联系管理员。")
            default: throw KikiAPIError.server(0, "网络请求失败，请稍后重试。")
            }
        }
        guard let http = response as? HTTPURLResponse else { throw KikiAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
            let message = error?.detail
            if http.statusCode == 428 {
                throw KikiAPIError.legalUpdateRequired(message ?? "协议已更新，请更新 App 并重新核对协议。", error?.requiredVersions)
            }
            throw KikiAPIError.server(http.statusCode, message ?? (http.statusCode == 401 ? "登录已过期，请重新登录。" : "请求未完成，请检查输入后重试。"))
        }
        do { return try JSONDecoder().decode(Response.self, from: responseData) }
        catch { throw KikiAPIError.invalidResponse }
    }
}

/// Do not override server-trust challenges: URLSession validates the public CA
/// chain, hostname and validity dates, so routine certificate renewal works.
final class KikiHTTPSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Authenticated JSON endpoints have no redirects. Do not carry a
        // bearer credential to an alternate host or downgrade to HTTP.
        completionHandler(nil)
    }
}

enum KikiKeychain {
    private static let service = "com.kikitalk.identity"

    static func read(_ key: String) -> String? {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                   kSecAttrAccount: key, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, key: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
        let attributes: [CFString: Any] = [kSecValueData: Data(value.utf8), kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
                throw KikiAPIError.security("无法安全保存登录凭据，请重新启动 App 后重试。")
            }
        } else if status != errSecSuccess {
            throw KikiAPIError.security("无法安全保存登录凭据，请重新启动 App 后重试。")
        }
    }

    static func remove(_ key: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key] as CFDictionary)
    }

}
