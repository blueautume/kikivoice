import Foundation

struct OpsModerationPage: Decodable {
    let schemaVersion: Int
    let reports: [OpsReport]
    let retentionDays: Int
    let activeRestrictions: [OpsActiveRestriction]?
    let activeRestrictionsTruncated: Bool?
    func validate() throws {
        guard schemaVersion == 1, (1...365).contains(retentionDays), reports.count <= 50,
              Set(reports.map(\.id)).count == reports.count else { throw OpsError.invalidResponse }
        for report in reports { try report.validate() }
        for restriction in activeRestrictions ?? [] { try restriction.validate() }
    }
}

struct OpsActiveRestriction: Decodable, Identifiable {
    let reportID, targetUserID: String
    let chatMutedUntil, voiceMutedUntil, bannedUntil: Double?
    var id: String { targetUserID }
    func validate() throws {
        guard !reportID.isEmpty, reportID.utf8.count <= 128, !targetUserID.isEmpty, targetUserID.utf8.count <= 128,
              [chatMutedUntil, voiceMutedUntil, bannedUntil].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 })
        else { throw OpsError.invalidResponse }
    }
}

enum OpsReportFilter: String, CaseIterable, Identifiable {
    case pending, resolved, all
    var id: String { rawValue }
    var label: String { switch self { case .pending: "待处理"; case .resolved: "已处理"; case .all: "全部" } }
}

struct OpsReport: Decodable, Identifiable {
    let id, status, targetType, roomID, roomTitle, reporterID, reporterName: String
    let targetUserID, targetName, messageID: String?
    let reason, details: String
    let messageExcerpt: String?
    let createdAt: Double
    let resolvedAt: Double?
    let lastAction: String?
    let evidenceExpiresAt: Double
    var statusLabel: String {
        switch status { case "pending": "待处理"; case "resolved": "已处理"; case "dismissed": "已驳回"; default: "未知" }
    }
    var typeLabel: String { switch targetType { case "room": "房间"; case "message": "消息"; default: "用户" } }
    var reasonLabel: String {
        switch reason { case "harassment": "骚扰或辱骂"; case "spam": "垃圾广告"; case "sexual": "色情内容"; case "fraud": "诈骗"; default: "其他" }
    }
    func permits(_ action: OpsModerationAction) -> Bool {
        if action == .closeRoom { return true }
        if action == .dismiss { return status == "pending" }
        return targetUserID?.isEmpty == false
    }
    func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !roomID.isEmpty,
              ["pending", "resolved", "dismissed"].contains(status),
              ["room", "user", "message"].contains(targetType),
              details.utf8.count <= 4096, (messageExcerpt?.utf8.count ?? 0) <= 8192,
              createdAt.isFinite, createdAt > 0, evidenceExpiresAt.isFinite,
              evidenceExpiresAt >= createdAt else { throw OpsError.invalidResponse }
    }
}

enum OpsModerationAction: String, CaseIterable, Identifiable, Codable {
    case warn, muteChat = "mute_chat", muteAudio = "mute_audio", banUser = "ban_user"
    case closeRoom = "close_room", dismiss, restoreUser = "restore_user"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .warn: "发送警告"; case .muteChat: "临时文字禁言"; case .muteAudio: "临时禁麦"
        case .banUser: "临时语聊封禁"; case .closeRoom: "关闭违规房间"
        case .dismiss: "驳回举报"; case .restoreUser: "解除语聊限制"
        }
    }
    var requiresDuration: Bool { [.muteChat, .muteAudio, .banUser].contains(self) }
}

struct OpsModerationRequest: Codable, Equatable {
    let requestID: String
    let reportID: String
    let action: OpsModerationAction
    let durationSeconds: Int?
    let note: String
    func validate() throws {
        let cleaned = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: requestID) != nil, !reportID.isEmpty, reportID.utf8.count <= 128,
              !cleaned.isEmpty, cleaned.unicodeScalars.count <= 500,
              !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format || $0.properties.generalCategory == .surrogate }) else { throw OpsError.invalidModeration }
        if action.requiresDuration {
            guard let durationSeconds, (60...2_592_000).contains(durationSeconds) else { throw OpsError.invalidModeration }
        } else if durationSeconds != nil { throw OpsError.invalidModeration }
    }
}

struct OpsPendingModeration: Codable, Equatable {
    let accountID: String
    let request: OpsModerationRequest
    let createdAt: Date
}

struct OpsModerationResult: Decodable {
    let ok: Bool
    let requestID, reportID, action, status: String
    let mediaCleanupPending: Bool
    func validate(for request: OpsModerationRequest) throws {
        guard ok, requestID == request.requestID, reportID == request.reportID,
              action == request.action.rawValue, ["resolved", "dismissed"].contains(status) else { throw OpsError.invalidResponse }
    }
}

struct OpsMaintenance: Decodable {
    let backup: Backup
    struct Backup: Decodable {
        let lastSuccessAt, verifiedAt, backupAgeSeconds: Double?
        let healthy: Bool?
        let lastError: String?
        let retentionDays: Int
    }
}
