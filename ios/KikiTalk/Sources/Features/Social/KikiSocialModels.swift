import Foundation

struct KikiPerson: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var bio: String
    var avatarIndex: Int
    var avatarURL: String?
    var following: Bool
    var followsYou: Bool
    var mutual: Bool
    var followingCount: Int
    var followerCount: Int
    var currentRoomID: String?

    var relationshipLabel: String { mutual ? "互相关注" : (following ? "已关注" : "关注") }
}

struct KikiDirectConversationRoute: Hashable {
    let person: KikiPerson
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.person.id == rhs.person.id }
    func hash(into hasher: inout Hasher) { hasher.combine(person.id) }
}

struct KikiDirectConversationRequest: Identifiable {
    let id = UUID()
    let person: KikiPerson
    let sessionKey: String
    let privacyRevision: Int
}

struct KikiPeoplePage: Decodable {
    let people: [KikiPerson]
    let nextCursor: String?
}

struct KikiFollowingIDs: Decodable {
    let followingIDs: [String]
    let followingCount: Int
    let followerCount: Int
}

struct KikiSocialNotification: Decodable, Identifiable, Equatable {
    let id: String
    let kind: String
    let actor: KikiPerson?
    let text: String
    let createdAt: Double
    let readAt: Double?
    let roomID: String?
    let momentID: String?
    let seq: Int
    init(id: String, kind: String, actor: KikiPerson?, text: String, createdAt: Double, readAt: Double?, roomID: String?, momentID: String?, seq: Int = 0) {
        self.id = id; self.kind = kind; self.actor = actor; self.text = text; self.createdAt = createdAt
        self.readAt = readAt; self.roomID = roomID; self.momentID = momentID; self.seq = seq
    }
    private enum CodingKeys: String, CodingKey { case id, kind, actor, text, createdAt, readAt, roomID, momentID, seq }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); kind = try c.decode(String.self, forKey: .kind)
        actor = try c.decodeIfPresent(KikiPerson.self, forKey: .actor); text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Double.self, forKey: .createdAt); readAt = try c.decodeIfPresent(Double.self, forKey: .readAt)
        roomID = try c.decodeIfPresent(String.self, forKey: .roomID); momentID = try c.decodeIfPresent(String.self, forKey: .momentID)
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
    }
    var isUnread: Bool { readAt == nil }
    var title: String {
        switch kind {
        case "follow": return "新的关注"
        case "mutual_follow": return "你们互相关注了"
        case "room_invite": return "房间邀请"
        case "like": return "新的点赞"
        case "comment": return "新的评论"
        default: return "社区通知"
        }
    }
}

struct KikiNotificationsPage: Decodable {
    let notifications: [KikiSocialNotification]
    let unreadCount: Int
    let nextCursor: String?
}

enum KikiRelationshipKind: String, CaseIterable, Identifiable {
    case following, followers, mutual
    var id: String { rawValue }
    var title: String {
        switch self { case .following: return "关注"; case .followers: return "粉丝"; case .mutual: return "互关" }
    }
}

struct KikiPersonDestination: Identifiable {
    let id: String
}

struct KikiSocialMedia: Codable, Equatable, Identifiable {
    let id: String
    let path: String
    let width: Int
    let height: Int
}
struct KikiMoment: Decodable, Identifiable, Equatable {
    let id: String
    let author: KikiPerson
    let text: String
    let media: [KikiSocialMedia]
    let createdAt: Double
    let likeCount: Int
    let commentCount: Int
    let liked: Bool
    let canDelete: Bool
    let commentPreview: [KikiMomentComment]

    init(id: String, author: KikiPerson, text: String, media: [KikiSocialMedia], createdAt: Double,
         likeCount: Int, commentCount: Int, liked: Bool, canDelete: Bool, commentPreview: [KikiMomentComment] = []) {
        self.id = id; self.author = author; self.text = text; self.media = media; self.createdAt = createdAt
        self.likeCount = likeCount; self.commentCount = commentCount; self.liked = liked; self.canDelete = canDelete
        self.commentPreview = Array(commentPreview.filter { $0.momentID == id }.prefix(3))
    }
    private enum CodingKeys: String, CodingKey {
        case id, author, text, media, createdAt, likeCount, commentCount, liked, canDelete, commentPreview
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), author: try c.decode(KikiPerson.self, forKey: .author),
                  text: try c.decode(String.self, forKey: .text), media: try c.decode([KikiSocialMedia].self, forKey: .media),
                  createdAt: try c.decode(Double.self, forKey: .createdAt), likeCount: try c.decode(Int.self, forKey: .likeCount),
                  commentCount: try c.decode(Int.self, forKey: .commentCount), liked: try c.decode(Bool.self, forKey: .liked),
                  canDelete: try c.decode(Bool.self, forKey: .canDelete),
                  commentPreview: try c.decodeIfPresent([KikiMomentComment].self, forKey: .commentPreview) ?? [])
    }
}
struct KikiMomentsPage: Decodable { let moments: [KikiMoment]; let nextCursor: String? }
struct KikiMomentComment: Decodable, Identifiable, Equatable {
    let id: String
    let momentID: String
    let author: KikiPerson
    let text: String
    let createdAt: Double
    let canDelete: Bool
}
struct KikiCommentsPage: Decodable { let comments: [KikiMomentComment]; let nextCursor: String? }
enum KikiMomentKind: String {
    case all, following, mine
}
struct KikiDirectMessage: Decodable, Identifiable, Equatable {
    let id: String
    let seq: Int
    let senderID: String
    let text: String
    let createdAt: Double
}

/// Account-pair admission comes from the server. Missing introduction metadata
/// on an older server never changes its authoritative canSend decision.
struct KikiDirectMessageAccess: Decodable, Equatable {
    let canSend: Bool
    let remainingBeforeReply: Int?
    let requiresReply: Bool?
    let replyEstablished: Bool?
    let initialMessageLimit: Int?

    init(canSend: Bool, remainingBeforeReply: Int? = nil, requiresReply: Bool? = nil,
         replyEstablished: Bool? = nil, initialMessageLimit: Int? = nil) {
        self.canSend = canSend; self.remainingBeforeReply = remainingBeforeReply
        self.requiresReply = requiresReply; self.replyEstablished = replyEstablished
        self.initialMessageLimit = initialMessageLimit
    }
    var explanation: String? {
        if !canSend {
            return requiresReply == true ? "已发送 5 条消息，等待对方回复后可继续聊天。" : "暂时无法发送消息，请稍后刷新或重试。"
        }
        if replyEstablished == true { return nil }
        if let remainingBeforeReply, initialMessageLimit == 5 {
            return "对方回复前，还可发送 \(max(0, remainingBeforeReply)) 条消息。"
        }
        return nil
    }
}

struct KikiDirectMessageAdmissionError: LocalizedError, Decodable {
    let code: String
    let message: String
    let access: KikiDirectMessageAccess
    var errorDescription: String? { message }
    private enum CodingKeys: String, CodingKey { case code, message }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        message = try c.decode(String.self, forKey: .message)
        access = try KikiDirectMessageAccess(from: decoder)
        guard code == "direct_message_reply_required", !access.canSend, access.requiresReply == true else {
            throw DecodingError.dataCorruptedError(forKey: .code, in: c, debugDescription: "Invalid direct message admission rejection")
        }
    }
}

struct KikiDirectRefreshScope: Hashable {
    let personID: String
    let isForeground: Bool
    let isVisible: Bool
    let hasOverlay: Bool
    var permitsRefresh: Bool { isForeground && isVisible && !hasOverlay }
    static let fallbackNanoseconds: UInt64 = 15_000_000_000
}

struct KikiConversation: Decodable, Identifiable, Equatable {
    let id: String
    let person: KikiPerson
    let lastMessage: KikiDirectMessage?
    let unreadCount: Int
    let directAccess: KikiDirectMessageAccess
    var canSend: Bool { directAccess.canSend }
    let isPinned: Bool
    init(id: String, person: KikiPerson, lastMessage: KikiDirectMessage?, unreadCount: Int, canSend: Bool, isPinned: Bool = false, directAccess: KikiDirectMessageAccess? = nil) {
        self.id = id; self.person = person; self.lastMessage = lastMessage
        self.unreadCount = unreadCount; self.directAccess = directAccess ?? .init(canSend: canSend); self.isPinned = isPinned
    }
    private enum CodingKeys: String, CodingKey { case id, person, lastMessage, unreadCount, canSend, isPinned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); person = try c.decode(KikiPerson.self, forKey: .person)
        lastMessage = try c.decodeIfPresent(KikiDirectMessage.self, forKey: .lastMessage)
        unreadCount = try c.decode(Int.self, forKey: .unreadCount); directAccess = try KikiDirectMessageAccess(from: decoder)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

/// Each interaction is a separate item alongside private conversations.
struct KikiInboxEntry: Decodable, Identifiable, Equatable {
    enum Content: Equatable { case notification(KikiSocialNotification), direct(KikiConversation) }
    let content: Content
    let activityAt: Double?
    let preview: String
    let unreadCount: Int
    var isPinned: Bool = false
    var id: String {
        switch content { case .notification(let value): return "notification:" + value.id; case .direct(let value): return "direct:" + value.id }
    }
    var name: String {
        switch content { case .notification(let value): return value.actor?.name ?? value.title; case .direct(let value): return value.person.name }
    }
    var unreadLabel: String? { unreadCount > 0 ? (unreadCount > 99 ? "99+" : String(unreadCount)) : nil }

    init(content: Content, activityAt: Double?, preview: String, unreadCount: Int, isPinned: Bool = false) {
        self.content = content; self.activityAt = activityAt; self.preview = preview
        self.unreadCount = max(0, unreadCount); self.isPinned = isPinned
    }
    init(notification: KikiSocialNotification) {
        self.init(content: .notification(notification), activityAt: notification.createdAt,
                  preview: Self.compact(notification.text), unreadCount: notification.isUnread ? 1 : 0)
    }
    init(conversation: KikiConversation) {
        self.init(content: .direct(conversation), activityAt: conversation.lastMessage?.createdAt,
                  preview: Self.compact(conversation.lastMessage?.text ?? "开始聊天"), unreadCount: conversation.unreadCount,
                  isPinned: conversation.isPinned)
    }
    private enum CodingKeys: String, CodingKey { case kind, notification, conversation }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "notification": self.init(notification: try c.decode(KikiSocialNotification.self, forKey: .notification))
        case "direct": self.init(conversation: try c.decode(KikiConversation.self, forKey: .conversation))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown inbox item")
        }
    }
    private static func compact(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}

struct KikiInboxPage: Decodable {
    let entries: [KikiInboxEntry]
    let nextCursor: String?
    let unreadNotificationCount: Int
    let unreadDirectMessageCount: Int
}

struct KikiInboxSnapshot: Decodable, Equatable {
    let snapshot: String
}

enum KikiInboxTime {
    static func label(_ timestamp: Double?, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let timestamp, timestamp.isFinite, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: timestamp)
        let format = DateFormatter(); format.locale = Locale(identifier: "zh_Hans_CN"); format.calendar = calendar; format.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { format.dateFormat = "HH:mm" }
        else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        else if let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= week && date < now { format.dateFormat = "EEEE" }
        else if calendar.component(.year, from: date) == calendar.component(.year, from: now) { format.dateFormat = "M/d" }
        else { format.dateFormat = "yy/M/d" }
        return format.string(from: date)
    }
}

enum KikiDirectTimeline {
    static func merged(existing: [KikiDirectMessage], fresh: [KikiDirectMessage], clearedThroughSeq: Int, now: Double = Date().timeIntervalSince1970) -> [KikiDirectMessage] {
        let visibleFresh = fresh.filter { $0.seq > clearedThroughSeq && $0.createdAt >= now - 30 * 86400 }
        guard !visibleFresh.isEmpty else { return [] }
        let oldestFresh = visibleFresh.map(\.seq).min() ?? Int.max
        var bySequence: [Int: KikiDirectMessage] = [:]
        for message in existing where message.seq < oldestFresh && message.seq > clearedThroughSeq && message.createdAt >= now - 30 * 86400 {
            bySequence = bySequence.filter { $0.value.id != message.id }; bySequence[message.seq] = message
        }
        for message in visibleFresh {
            bySequence = bySequence.filter { $0.value.id != message.id }; bySequence[message.seq] = message
        }
        return bySequence.values.sorted { $0.seq < $1.seq }
    }
    static func needsTimestamp(previous: Double, current: Double, calendar: Calendar = .current) -> Bool {
        !calendar.isDate(Date(timeIntervalSince1970: previous), inSameDayAs: Date(timeIntervalSince1970: current)) || abs(current - previous) >= 300
    }
}
struct KikiConversationsPage: Decodable { let conversations: [KikiConversation]; let nextCursor: String?; let unreadCount: Int }
struct KikiDirectMessagesPage: Decodable {
    let conversationID: String?
    let messages: [KikiDirectMessage]
    let nextCursor: String?
    let directAccess: KikiDirectMessageAccess
    var canSend: Bool { directAccess.canSend }
    let unreadCount: Int
    let clearedThroughSeq: Int
    private enum CodingKeys: String, CodingKey { case conversationID, messages, nextCursor, canSend, unreadCount, clearedThroughSeq }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID)
        messages = try c.decode([KikiDirectMessage].self, forKey: .messages); nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        directAccess = try KikiDirectMessageAccess(from: decoder); unreadCount = try c.decode(Int.self, forKey: .unreadCount)
        clearedThroughSeq = try c.decodeIfPresent(Int.self, forKey: .clearedThroughSeq) ?? 0
    }
}
struct KikiDirectMessageReceipt: Decodable {
    let message: KikiDirectMessage
    let conversationID: String
    let directAccess: KikiDirectMessageAccess?
    private enum CodingKeys: String, CodingKey { case message, conversationID, canSend }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(KikiDirectMessage.self, forKey: .message)
        conversationID = try c.decode(String.self, forKey: .conversationID)
        directAccess = c.contains(.canSend) ? try KikiDirectMessageAccess(from: decoder) : nil
    }
}
struct KikiSocialReportReceipt: Decodable {
    struct Report: Decodable, Identifiable {
        let id: String
        let status: String
        let createdAt: Double
        let targetType: String
        let reason: String
        let lastAction: String?
    }
    let report: Report
}
struct KikiSocialReportTarget: Identifiable {
    enum Kind: String { case profile, moment, comment; case directMessage = "direct_message" }
    let kind: Kind
    let targetID: String
    let name: String
    var id: String { kind.rawValue + ":" + targetID }
}
enum KikiSocialReportReason: String, CaseIterable, Identifiable {
    case harassment, spam, sexual, fraud, other
    var id: String { rawValue }
    var title: String {
        switch self { case .harassment: return "骚扰或攻击"; case .spam: return "垃圾信息"; case .sexual: return "不适当内容"; case .fraud: return "欺诈或诱导"; case .other: return "其他问题" }
    }
}

struct KikiPendingDirectMessage: Equatable {
    let requestID: UUID
    let text: String
    var isSending: Bool
    var error: String?
}
struct KikiSocialReportsPage: Decodable { let reports: [KikiSocialReportReceipt.Report]; let retentionDays: Int }

/// Retry an uncertain write with its original ID. Explicit validation/admission
/// rejections allow editing because the server did not accept that write.
enum KikiSocialMutation {
    static func needsSameIDRetry(_ error: Error) -> Bool {
        if error is KikiDirectMessageAdmissionError { return false }
        guard let api = error as? KikiAPIError else { return true }
        switch api {
        case .server(let status, _): return !(400..<500).contains(status) || status == 408
        case .rateLimited, .security: return false
        default: return true
        }
    }
}
