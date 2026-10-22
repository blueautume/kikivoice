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

struct KikiNotificationInboxState: Decodable, Equatable {
    let isPinned: Bool
    let isHidden: Bool
    let throughNotificationID: String?
    let clearedThroughSeq: Int
    init(isPinned: Bool = false, isHidden: Bool = false, throughNotificationID: String? = nil, clearedThroughSeq: Int = 0) {
        self.isPinned = isPinned; self.isHidden = isHidden
        self.throughNotificationID = throughNotificationID; self.clearedThroughSeq = clearedThroughSeq
    }
}

struct KikiNotificationsPage: Decodable {
    let notifications: [KikiSocialNotification]
    let unreadCount: Int
    let nextCursor: String?
    let retentionDays: Int
    let inboxState: KikiNotificationInboxState
    private enum CodingKeys: String, CodingKey { case notifications, unreadCount, nextCursor, retentionDays, inboxState }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifications = try c.decode([KikiSocialNotification].self, forKey: .notifications)
        unreadCount = try c.decode(Int.self, forKey: .unreadCount); nextCursor = try c.decodeIfPresent(String.self, forKey: .nextCursor)
        retentionDays = try c.decode(Int.self, forKey: .retentionDays)
        inboxState = try c.decodeIfPresent(KikiNotificationInboxState.self, forKey: .inboxState) ?? .init()
    }
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
enum KikiMomentKind: String, CaseIterable, Identifiable {
    case all, following, mine
    var id: String { rawValue }
    var title: String { self == .all ? "最新" : (self == .following ? "关注" : "我的") }
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

/// The inbox contains one aggregate notification conversation and private
/// conversations. Notification pagination stays inside its own detail page.
struct KikiInboxEntry: Identifiable, Equatable {
    enum Content: Equatable { case notifications, direct(KikiConversation) }
    let content: Content
    let activityAt: Double?
    let preview: String
    let unreadCount: Int
    var isPinned: Bool = false
    var id: String {
        switch content { case .notifications: return "notifications"; case .direct(let value): return "direct:" + value.id }
    }
    var name: String {
        switch content { case .notifications: return "通知"; case .direct(let value): return value.person.name }
    }
    var unreadLabel: String? { unreadCount > 0 ? (unreadCount > 99 ? "99+" : String(unreadCount)) : nil }

    static func merged(conversations: [KikiConversation], notifications: [KikiSocialNotification], notificationUnreadCount: Int, notificationState: KikiNotificationInboxState = .init()) -> [Self] {
        let latest = notifications.filter { notificationState.clearedThroughSeq == 0 || $0.seq > notificationState.clearedThroughSeq }
            .max { $0.seq == $1.seq ? $0.createdAt < $1.createdAt : $0.seq < $1.seq }
        var entries: [Self] = []
        if !notificationState.isHidden || latest != nil {
            entries.append(Self(content: .notifications, activityAt: latest?.createdAt,
                                preview: compact(latest?.text ?? "关注、点赞、评论与社区提醒"),
                                unreadCount: max(0, notificationUnreadCount), isPinned: notificationState.isPinned))
        }
        var seen: Set<String> = []
        for conversation in conversations where seen.insert(conversation.id).inserted {
            entries.append(Self(content: .direct(conversation), activityAt: conversation.lastMessage?.createdAt,
                                preview: compact(conversation.lastMessage?.text ?? "开始聊天"), unreadCount: max(0, conversation.unreadCount), isPinned: conversation.isPinned))
        }
        return entries.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.activityAt != $1.activityAt { return ($0.activityAt ?? -.infinity) > ($1.activityAt ?? -.infinity) }
            return $0.id < $1.id
        }
    }
    private static func compact(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
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
