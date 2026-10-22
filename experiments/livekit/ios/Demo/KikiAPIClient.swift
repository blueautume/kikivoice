import Foundation
import Security

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

/// Business sessions are separate from short-lived LiveKit room grants.
struct KikiSDKCredentials: Decodable {
    let provider: String
    let serverURL: String
    let userID: String
    let expiresAt: Int
}

struct KikiRoomConnection: Decodable {
    let serverURL: String
    let participantToken: String
    let room: DemoRoom
}

enum KikiRoomRole: String, Codable {
    case owner, admin, member
    var label: String { self == .owner ? "房主" : (self == .admin ? "管理员" : "成员") }
}

struct KikiRoomMember: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let avatarIndex: Int
    let role: KikiRoomRole
    let seatIndex: Int?
    let audioMuted: Bool
    let chatMuted: Bool
    let online: Bool
    let canPublishAudio: Bool
    let canPublishData: Bool
    var id: String { userID }
    var isModerator: Bool { role == .owner || role == .admin }
    func canModerate(_ target: KikiRoomMember) -> Bool {
        userID != target.userID && target.role != .owner && (role == .owner || (role == .admin && target.role == .member))
    }
}

struct KikiRoomSeat: Codable, Equatable, Identifiable {
    let index: Int
    let userID: String?
    let locked: Bool
    let audioLocked: Bool
    var id: Int { index }
}

struct KikiSeatRequest: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let requestedAt: Int
    let position: Int
    var id: String { userID }
}

struct KikiSeatInvitation: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let seatIndex: Int
    let expiresAt: Int
    var id: String { userID }
}

struct KikiRoomBan: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let bannedAt: Int
    var id: String { userID }
}

struct KikiRoomState: Codable, Equatable {
    let room: DemoRoom
    let revision: Int
    let me: KikiRoomMember
    let seats: [KikiRoomSeat]
    let members: [KikiRoomMember]
    let queue: [KikiSeatRequest]
    let invitations: [KikiSeatInvitation]
    let bans: [KikiRoomBan]
    var listeners: [KikiRoomMember] { members.filter { $0.online && $0.seatIndex == nil } }
    var myRequest: KikiSeatRequest? { queue.first { $0.userID == me.userID } }
    var myInvitation: KikiSeatInvitation? { invitations.first { $0.userID == me.userID && $0.expiresAt > Int(Date().timeIntervalSince1970) } }
    var availableSeats: [KikiRoomSeat] { seats.filter { $0.userID == nil && !$0.locked } }
    var canMoveSeats: Bool { me.seatIndex != nil && seats.first(where: { $0.index == me.seatIndex })?.audioLocked == false }
    func member(on seat: KikiRoomSeat) -> KikiRoomMember? { members.first { $0.userID == seat.userID } }
}

enum KikiRoomAction: String, Encodable {
    case requestSeat = "request_seat", cancelRequest = "cancel_request"
    case approveRequest = "approve_request", rejectRequest = "reject_request"
    case inviteSeat = "invite_seat", acceptInvite = "accept_invite", declineInvite = "decline_invite"
    case leaveSeat = "leave_seat", moveSeat = "move_seat", removeSeat = "remove_seat"
    case lockSeat = "lock_seat", lockAudio = "lock_audio", muteAudio = "mute_audio", muteChat = "mute_chat"
    case setAdmin = "set_admin", kick, unban
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
    case rateLimited(Int, String)
    case security(String)
    case legalUpdateRequired(String, KikiLegalVersions?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .server(_, let message), .rateLimited(_, let message), .security(let message): return message
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
/// Server private keys and LiveKit signing secrets never enter the app.
final class KikiAPIClient: @unchecked Sendable {
    static let shared = KikiAPIClient()
    static let endpoint = URL(string: "https://furby.top")!
    private let session: URLSession
    private let baseURL: URL

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

    func loginForLab(name: String, accessCode: String, legalConsent: KikiLegalAcceptance) async throws -> KikiLoginResponse {
        guard legalConsent.accepted, legalConsent.adultConfirmed else {
            throw KikiAPIError.security("请同意协议并确认已满 18 周岁后登录。")
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 16, !accessCode.isEmpty else {
            throw KikiAPIError.server(422, "请输入 1–16 字昵称和实验邀请码。")
        }
        struct Body: Encodable { let name: String; let accessCode: String; let legalConsent: KikiLegalAcceptance }
        return try await send("/v1/auth/lab", method: "POST", body: Body(name: trimmedName, accessCode: accessCode, legalConsent: legalConsent))
    }

    func rtcRooms(token: String) async throws -> [DemoRoom] {
        struct Response: Decodable { let rooms: [DemoRoom] }
        let response: Response = try await request("/v1/rooms", token: token)
        return response.rooms
    }

    func rtcJoin(roomID: String, token: String) async throws -> KikiRoomConnection {
        try validateRoomID(roomID)
        return try await request("/v1/rooms/\(roomID)/token", method: "POST", token: token)
    }

    func roomState(roomID: String, token: String) async throws -> KikiRoomState {
        try validateRoomID(roomID)
        return try await request("/v1/rooms/\(roomID)/state", token: token)
    }

    func roomAction(_ action: KikiRoomAction, roomID: String, targetUserID: String? = nil,
                    seatIndex: Int? = nil, enabled: Bool? = nil, token: String) async throws -> KikiRoomState {
        try validateRoomID(roomID)
        if let seatIndex, !(1...8).contains(seatIndex) { throw KikiAPIError.security("麦位编号无效。") }
        struct Body: Encodable { let action: KikiRoomAction; let targetUserID: String?; let seatIndex: Int?; let enabled: Bool? }
        return try await send("/v1/rooms/\(roomID)/actions", method: "POST",
                              body: Body(action: action, targetUserID: targetUserID, seatIndex: seatIndex, enabled: enabled), token: token)
    }

    func leaveRoom(roomID: String, token: String) async throws {
        try validateRoomID(roomID)
        let _: Success = try await request("/v1/rooms/\(roomID)/leave", method: "POST", token: token)
    }

    func roomMessages(roomID: String, afterSeq: Int, limit: Int = 200, token: String) async throws -> KikiChatPage {
        try validateRoomID(roomID)
        guard afterSeq >= 0, (1...200).contains(limit) else { throw KikiAPIError.security("聊天游标无效。") }
        return try await request("/v1/rooms/\(roomID)/messages?afterSeq=\(afterSeq)&limit=\(limit)", token: token)
    }

    func sendRoomMessage(roomID: String, clientMessageID: String, text: String, token: String) async throws -> KikiChatMessage {
        try validateRoomID(roomID)
        let text = try KikiChatMessage.validatedText(text)
        guard let nonce = UUID(uuidString: clientMessageID) else { throw KikiAPIError.security("消息编号无效。") }
        struct Body: Encodable { let clientMessageID: String; let text: String }
        return try await send("/v1/rooms/\(roomID)/messages", method: "POST",
                              body: Body(clientMessageID: nonce.uuidString.lowercased(), text: text), token: token)
    }

    func setRoomAnnouncement(roomID: String, text: String, token: String) async throws -> KikiRoomAnnouncement {
        try validateRoomID(roomID)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 2_000 else { throw KikiAPIError.security("公告不能超过 2000 字节。") }
        struct Body: Encodable { let text: String }
        return try await send("/v1/rooms/\(roomID)/announcement", method: "PUT", body: Body(text: text), token: token)
    }

    func reportRoomQuality(roomID: String, sample: KikiRoomQualitySample, token: String) async throws {
        try validateRoomID(roomID)
        struct Response: Decodable { let accepted: Bool }
        let _: Response = try await send("/v1/rooms/\(roomID)/quality", method: "POST", body: sample, token: token)
    }

    func diagnostics(token: String) async throws -> KikiServerDiagnostics {
        try await request("/v1/diagnostics", token: token)
    }

    private func validateRoomID(_ roomID: String) throws {
        guard roomID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw KikiAPIError.security("房间标识无效。")
        }
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
        // Only packaged preset indices are used by this experiment.
        return try await send("/v1/me", method: "PATCH", body: Body(name: name, bio: bio, avatarIndex: avatarIndex), token: token)
    }

    func updateNotifications(_ enabled: Bool, token: String) async throws -> KikiUser {
        struct Body: Encodable { let notificationsEnabled: Bool }
        return try await send("/v1/me", method: "PATCH", body: Body(notificationsEnabled: enabled), token: token)
    }

    func library(token: String) async throws -> KikiLibrary { try await request("/v1/library", token: token) }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int, token: String) async throws -> DemoRoom {
        guard !isLive else { throw KikiAPIError.server(422, "实验版暂不支持视频直播，请创建语聊房。") }
        struct Body: Encodable { let title: String; let category: String; let isLive: Bool; let theme: Int }
        return try await send("/v1/rooms", method: "POST", body: Body(title: title, category: category, isLive: isLive, theme: theme), token: token)
    }

    func setRoomStatus(_ roomID: String, status: String, token: String) async throws -> DemoRoom {
        try validateRoomID(roomID)
        struct Body: Encodable { let status: String }
        return try await send("/v1/rooms/\(roomID)", method: "PATCH", body: Body(status: status), token: token)
    }

    func favorite(_ roomID: String, enabled: Bool, token: String) async throws {
        try validateRoomID(roomID)
        let _: Success = try await request("/v1/favorites/\(roomID)", method: enabled ? "PUT" : "DELETE", token: token)
    }

    func visit(_ roomID: String, token: String) async throws {
        try validateRoomID(roomID)
        let _: Success = try await request("/v1/history/\(roomID)", method: "POST", token: token)
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
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw KikiAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: responseData)
            let message = error?.detail
            if http.statusCode == 429 {
                let delay = max(1, min(120, Int(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5))
                throw KikiAPIError.rateLimited(delay, message ?? "请求较多，请稍后重试。")
            }
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
    private static let service = "com.kikitalk.livekitlab.identity"

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
