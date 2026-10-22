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
    let room: KikiRoom
}

enum KikiRoomRole: String, Codable {
    case owner, admin, member
    var label: String { self == .owner ? "房主" : (self == .admin ? "管理员" : "成员") }
}

struct KikiRoomMember: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let avatarIndex: Int
    let avatarURL: String?
    let role: KikiRoomRole
    let seatIndex: Int?
    let audioMuted: Bool
    let chatMuted: Bool
    let online: Bool
    let canPublishAudio: Bool
    let canPublishData: Bool
    let offlineSince: Int?
    let reconnectDeadline: Int?
    let seatRequestStatus: String

    init(userID: String, name: String, avatarIndex: Int, avatarURL: String?, role: KikiRoomRole,
         seatIndex: Int?, audioMuted: Bool, chatMuted: Bool, online: Bool,
         canPublishAudio: Bool, canPublishData: Bool, offlineSince: Int? = nil,
         reconnectDeadline: Int? = nil, seatRequestStatus: String = "none") {
        self.userID = userID; self.name = name; self.avatarIndex = avatarIndex; self.avatarURL = avatarURL
        self.role = role; self.seatIndex = seatIndex; self.audioMuted = audioMuted; self.chatMuted = chatMuted
        self.online = online; self.canPublishAudio = canPublishAudio; self.canPublishData = canPublishData
        self.offlineSince = offlineSince; self.reconnectDeadline = reconnectDeadline; self.seatRequestStatus = seatRequestStatus
    }
    private enum CodingKeys: String, CodingKey {
        case userID, name, avatarIndex, avatarURL, role, seatIndex, audioMuted, chatMuted, online
        case canPublishAudio, canPublishData, offlineSince, reconnectDeadline, seatRequestStatus
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(userID: try c.decode(String.self, forKey: .userID), name: try c.decode(String.self, forKey: .name),
                  avatarIndex: try c.decode(Int.self, forKey: .avatarIndex), avatarURL: try c.decodeIfPresent(String.self, forKey: .avatarURL),
                  role: try c.decode(KikiRoomRole.self, forKey: .role), seatIndex: try c.decodeIfPresent(Int.self, forKey: .seatIndex),
                  audioMuted: try c.decode(Bool.self, forKey: .audioMuted), chatMuted: try c.decode(Bool.self, forKey: .chatMuted),
                  online: try c.decode(Bool.self, forKey: .online), canPublishAudio: try c.decode(Bool.self, forKey: .canPublishAudio),
                  canPublishData: try c.decode(Bool.self, forKey: .canPublishData), offlineSince: try c.decodeIfPresent(Int.self, forKey: .offlineSince),
                  reconnectDeadline: try c.decodeIfPresent(Int.self, forKey: .reconnectDeadline),
                  seatRequestStatus: try c.decodeIfPresent(String.self, forKey: .seatRequestStatus) ?? "none")
    }
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
    let status: String
    let online: Bool
    init(userID: String, name: String, requestedAt: Int, position: Int, status: String = "pending", online: Bool = true) {
        self.userID = userID; self.name = name; self.requestedAt = requestedAt; self.position = position
        self.status = status; self.online = online
    }
    private enum CodingKeys: String, CodingKey { case userID, name, requestedAt, position, status, online }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(userID: try c.decode(String.self, forKey: .userID), name: try c.decode(String.self, forKey: .name),
                  requestedAt: try c.decode(Int.self, forKey: .requestedAt), position: try c.decode(Int.self, forKey: .position),
                  status: try c.decodeIfPresent(String.self, forKey: .status) ?? "pending",
                  online: try c.decodeIfPresent(Bool.self, forKey: .online) ?? true)
    }
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
    let room: KikiRoom
    let revision: Int
    let me: KikiRoomMember
    let seats: [KikiRoomSeat]
    let members: [KikiRoomMember]
    let queue: [KikiSeatRequest]
    let invitations: [KikiSeatInvitation]
    let bans: [KikiRoomBan]
    let seatMode: String
    let disconnectGraceSeconds: Int
    let ownerDisconnectGraceSeconds: Int

    init(room: KikiRoom, revision: Int, me: KikiRoomMember, seats: [KikiRoomSeat], members: [KikiRoomMember],
         queue: [KikiSeatRequest], invitations: [KikiSeatInvitation], bans: [KikiRoomBan], seatMode: String = "ordered",
         disconnectGraceSeconds: Int = 60, ownerDisconnectGraceSeconds: Int = 15) {
        self.room = room; self.revision = revision; self.me = me; self.seats = seats; self.members = members
        self.queue = queue; self.invitations = invitations; self.bans = bans; self.seatMode = seatMode
        self.disconnectGraceSeconds = disconnectGraceSeconds; self.ownerDisconnectGraceSeconds = ownerDisconnectGraceSeconds
    }
    private enum CodingKeys: String, CodingKey {
        case room, revision, me, seats, members, queue, invitations, bans, seatMode, disconnectGraceSeconds, ownerDisconnectGraceSeconds
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(room: try c.decode(KikiRoom.self, forKey: .room), revision: try c.decode(Int.self, forKey: .revision),
                  me: try c.decode(KikiRoomMember.self, forKey: .me), seats: try c.decode([KikiRoomSeat].self, forKey: .seats),
                  members: try c.decode([KikiRoomMember].self, forKey: .members), queue: try c.decode([KikiSeatRequest].self, forKey: .queue),
                  invitations: try c.decode([KikiSeatInvitation].self, forKey: .invitations), bans: try c.decode([KikiRoomBan].self, forKey: .bans),
                  seatMode: try c.decodeIfPresent(String.self, forKey: .seatMode) ?? "ordered",
                  disconnectGraceSeconds: try c.decodeIfPresent(Int.self, forKey: .disconnectGraceSeconds) ?? 60,
                  ownerDisconnectGraceSeconds: try c.decodeIfPresent(Int.self, forKey: .ownerDisconnectGraceSeconds) ?? 15)
    }
    var listeners: [KikiRoomMember] { members.filter { $0.online && $0.seatIndex == nil } }
    var myRequest: KikiSeatRequest? { queue.first { $0.userID == me.userID } }
    var myInvitation: KikiSeatInvitation? { invitations.first { $0.userID == me.userID && $0.expiresAt > Int(Date().timeIntervalSince1970) } }
    var availableSeats: [KikiRoomSeat] { seats.filter { $0.userID == nil && !$0.locked } }
    var canMoveSeats: Bool { seatMode != "ordered" && me.seatIndex != nil && seats.first(where: { $0.index == me.seatIndex })?.audioLocked == false }
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

struct KikiLibrary: Decodable {
    let favorites: [KikiRoom]
    let recents: [KikiRoom]
    let created: [KikiRoom]
}

struct KikiBlockedUser: Codable, Equatable, Identifiable {
    let userID: String
    let name: String
    let createdAt: Double
    var id: String { userID }
}

struct KikiSafetyNotice: Codable, Equatable, Identifiable {
    let id: String
    let message: String
    let createdAt: Double
    let action: String
    let expiresAt: Double?
}

struct KikiSafetyRestrictions: Codable, Equatable {
    let chatMutedUntil: Double?
    let voiceMutedUntil: Double?
    let bannedUntil: Double?
    func isActive(_ value: Double?, now: Date = Date()) -> Bool { (value ?? 0) > now.timeIntervalSince1970 }
    static let empty = Self(chatMutedUntil: nil, voiceMutedUntil: nil, bannedUntil: nil)
}

struct KikiSafetyState: Codable, Equatable {
    let schemaVersion: Int
    let blockedUsers: [KikiBlockedUser]
    let notices: [KikiSafetyNotice]
    let restrictions: KikiSafetyRestrictions
    var blockedIDs: Set<String> { Set(blockedUsers.map(\.userID)) }
    static let empty = Self(schemaVersion: 1, blockedUsers: [], notices: [], restrictions: .empty)
}

enum KikiReportTargetType: String, Codable { case room, user, message }
enum KikiReportReason: String, Codable, CaseIterable, Identifiable {
    case harassment, spam, sexual, fraud, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .harassment: return "骚扰、辱骂或侵犯隐私"
        case .spam: return "垃圾广告或刷屏"
        case .sexual: return "色情或不适宜内容"
        case .fraud: return "诈骗或冒充"
        case .other: return "其他违规"
        }
    }
}

struct KikiReportTarget: Identifiable {
    let targetType: KikiReportTargetType
    let roomID: String
    let targetUserID: String?
    let messageID: String?
    let name: String
    let id = UUID()
}

struct KikiSafetyReportRequest: Encodable {
    let clientRequestID: String
    let targetType: KikiReportTargetType
    let roomID: String
    let targetUserID: String?
    let messageID: String?
    let reason: KikiReportReason
    let details: String
}

struct KikiSafetyReport: Decodable, Identifiable, Equatable {
    let id: String
    let status: String
    let targetType: KikiReportTargetType
    let roomID: String
    let targetUserID: String?
    let messageID: String?
    let reason: KikiReportReason
    let details: String
    let createdAt: Double
    let resolvedAt: Double?
    var statusLabel: String {
        switch status { case "pending": return "待处理"; case "resolved": return "已处理"; case "dismissed": return "已核查结案"; default: return "处理中" }
    }
}

struct KikiSafetyReportPage: Decodable { let reports: [KikiSafetyReport]; let retentionDays: Int }

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

struct KikiRoomCatalogChange: Decodable, Equatable {
    let revision: Int
    let changed: Bool
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

    func rtcRooms(token: String) async throws -> [KikiRoom] {
        struct Response: Decodable { let rooms: [KikiRoom] }
        let response: Response = try await request("/v1/rooms", token: token)
        return response.rooms
    }

    func rtcRoomCatalogChanges(after: Int?, waitSeconds: Int = 15, token: String) async throws -> KikiRoomCatalogChange {
        guard after == nil || after! >= 0, (0...15).contains(waitSeconds) else {
            throw KikiAPIError.security("房间目录订阅参数无效。")
        }
        var query = "waitSeconds=\(waitSeconds)"
        if let after { query += "&after=\(after)" }
        let change: KikiRoomCatalogChange = try await request("/v1/room-catalog/changes?\(query)", token: token)
        guard change.revision >= 0 else { throw KikiAPIError.invalidResponse }
        return change
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

    func safety(token: String) async throws -> KikiSafetyState {
        let state: KikiSafetyState = try await request("/v1/safety", token: token)
        guard state.schemaVersion == 1 else { throw KikiAPIError.invalidResponse }
        return state
    }

    func blockUser(_ userID: String, enabled: Bool, token: String) async throws -> KikiSafetyState {
        guard userID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw KikiAPIError.security("用户编号无效。")
        }
        let state: KikiSafetyState = try await request("/v1/safety/blocks/\(userID)", method: enabled ? "PUT" : "DELETE", token: token)
        guard state.schemaVersion == 1 else { throw KikiAPIError.invalidResponse }
        return state
    }

    func submitReport(_ report: KikiSafetyReportRequest, token: String) async throws -> KikiSafetyReport {
        try validateRoomID(report.roomID)
        guard UUID(uuidString: report.clientRequestID) != nil, report.details.unicodeScalars.count <= 500 else {
            throw KikiAPIError.security("举报编号无效，或补充说明超过 500 字。")
        }
        guard report.targetType == .room || report.targetUserID?.isEmpty == false,
              report.targetType != .message || report.messageID?.isEmpty == false else {
            throw KikiAPIError.security("请选择需要举报的对象。")
        }
        return try await send("/v1/safety/reports", method: "POST", body: report, token: token)
    }

    func myReports(token: String) async throws -> KikiSafetyReportPage {
        try await request("/v1/safety/reports/mine", token: token)
    }

    func experienceCatalog(token: String) async throws -> KikiExperienceCatalog {
        try await request("/v1/gifts/catalog", token: token)
    }

    func experience(token: String) async throws -> KikiExperienceSnapshot {
        try await request("/v1/me/experience", token: token)
    }

    func giftWallet(token: String) async throws -> KikiGiftWallet {
        try await request("/v1/me/wallet", token: token)
    }

    func sendGift(roomID: String, giftID: String, quantity: Int, recipientIDs: [String],
                  requestID: UUID, token: String) async throws -> KikiGiftSendResult {
        try validateRoomID(roomID)
        try validateExperienceItemID(giftID)
        guard (1...99).contains(quantity), !recipientIDs.isEmpty, recipientIDs.count <= 50,
              Set(recipientIDs).count == recipientIDs.count,
              recipientIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }) else {
            throw KikiAPIError.security("请选择有效的收礼人和礼物数量。")
        }
        struct Body: Encodable { let giftID: String; let quantity: Int; let recipientIDs: [String]; let requestID: String }
        return try await send("/v1/rooms/\(roomID)/gifts", method: "POST",
                              body: Body(giftID: giftID, quantity: quantity, recipientIDs: recipientIDs,
                                         requestID: requestID.uuidString.lowercased()), token: token)
    }

    func giftEvents(roomID: String, after: Int?, token: String) async throws -> KikiGiftEventPage {
        try validateRoomID(roomID)
        if let after, after < 0 { throw KikiAPIError.security("礼物游标无效。") }
        let query = after.map { "?after=\($0)" } ?? ""
        return try await request("/v1/rooms/\(roomID)/gifts\(query)", token: token)
    }

    func purchaseDecoration(decorationID: String, requestID: UUID, token: String) async throws -> KikiDecorationPurchaseResult {
        try validateExperienceItemID(decorationID)
        struct Body: Encodable { let decorationID: String; let requestID: String }
        return try await send("/v1/me/decorations/purchase", method: "POST",
                              body: Body(decorationID: decorationID, requestID: requestID.uuidString.lowercased()), token: token)
    }

    func equipDecoration(kind: KikiDecorationKind, decorationID: String?, token: String) async throws -> KikiDecorationInventory {
        if let decorationID { try validateExperienceItemID(decorationID) }
        struct Body: Encodable {
            let kind: KikiDecorationKind
            let decorationID: String?
            enum CodingKeys: String, CodingKey { case kind, decorationID }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(kind, forKey: .kind)
                if let decorationID { try values.encode(decorationID, forKey: .decorationID) }
                else { try values.encodeNil(forKey: .decorationID) }
            }
        }
        return try await send("/v1/me/decorations/equipped", method: "PUT", body: Body(kind: kind, decorationID: decorationID), token: token)
    }

    func userDecorations(userIDs: [String], token: String) async throws -> KikiPublicDecorationPage {
        let ids = Set(userIDs).sorted()
        guard !ids.isEmpty, ids.count <= 100,
              ids.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil }) else {
            throw KikiAPIError.security("装饰查询的用户编号无效。")
        }
        return try await request("/v1/decorations/users?ids=\(ids.joined(separator: ","))", token: token)
    }

    private func validateExperienceItemID(_ id: String) throws {
        guard id.range(of: "^[a-z0-9_]{1,64}$", options: .regularExpression) != nil else {
            throw KikiAPIError.security("礼物或装饰编号无效。")
        }
    }

    private func validateRoomID(_ roomID: String) throws {
        guard roomID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw KikiAPIError.security("房间标识无效。")
        }
    }

    func cancelRequestsAndClearAvatarCache() async {
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }

    func library(token: String) async throws -> KikiLibrary { try await request("/v1/library", token: token) }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int, token: String) async throws -> KikiRoom {
        guard !isLive else { throw KikiAPIError.server(422, "暂未开放视频直播，请创建语聊房。") }
        struct Body: Encodable { let title: String; let category: String; let isLive: Bool; let theme: Int }
        return try await send("/v1/rooms", method: "POST", body: Body(title: title, category: category, isLive: isLive, theme: theme), token: token)
    }

    func setRoomStatus(_ roomID: String, status: String, token: String) async throws -> KikiRoom {
        try validateRoomID(roomID)
        struct Body: Encodable { let status: String }
        return try await send("/v1/rooms/\(roomID)", method: "PATCH", body: Body(status: status), token: token)
    }

    func updateRoomTitle(_ roomID: String, title: String, token: String) async throws -> KikiRoomState {
        try validateRoomID(roomID)
        let title = try KikiRoomTitlePolicy.validated(title)
        struct Body: Encodable { let title: String }
        let state: KikiRoomState = try await send("/v1/rooms/\(roomID)", method: "PATCH", body: Body(title: title), token: token)
        guard state.room.id == roomID, state.room.title == title, state.revision >= 0 else { throw KikiAPIError.invalidResponse }
        return state
    }

    func favorite(_ roomID: String, enabled: Bool, token: String) async throws {
        try validateRoomID(roomID)
        let _: Success = try await request("/v1/favorites/\(roomID)", method: enabled ? "PUT" : "DELETE", token: token)
    }

    func visit(_ roomID: String, token: String) async throws {
        try validateRoomID(roomID)
        let _: Success = try await request("/v1/history/\(roomID)", method: "POST", token: token)
    }

    func removeHistory(roomID: String?, token: String) async throws {
        if let roomID { try validateRoomID(roomID) }
        let path = roomID.map { "/v1/history/" + $0 } ?? "/v1/history"
        let _: Success = try await request(path, method: "DELETE", token: token)
    }

    private struct Success: Decodable { let ok: Bool }
    private struct ErrorResponse: Decodable { let detail: String; let requiredVersions: KikiLegalVersions?; let code: String? }

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
