import Foundation

enum OpsIncidentSeverity: String, Codable, CaseIterable, Identifiable {
    case all, warning, error
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部级别"; case .warning: "警告"; case .error: "错误" } }
}
enum OpsIncidentOperation: String, Codable, CaseIterable, Identifiable {
    case all, createRoom = "create_room", joinRoom = "join_room", roomRuntime = "room_runtime"
    var id: String { rawValue }
    var title: String { switch self { case .all: "全部操作"; case .createRoom: "创建房间"; case .joinRoom: "进入房间"; case .roomRuntime: "房内运行" } }
}
struct OpsIncidentFilter: Equatable {
    var severity: OpsIncidentSeverity = .all
    var operation: OpsIncidentOperation = .all
    var userQuery = ""
    func validated() throws -> Self {
        guard userQuery.count <= 80, !userQuery.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OpsError.invalidIncidentQuery
        }
        var result = self
        result.userQuery = userQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
struct OpsIncidentQuery: Encodable, Equatable {
    let severity: OpsIncidentSeverity
    let operation: OpsIncidentOperation
    let userQuery: String?
    let limit: Int
    let cursor: String?
    init(filter: OpsIncidentFilter = OpsIncidentFilter(), cursor: String? = nil, limit: Int = 50) throws {
        let filter = try filter.validated()
        guard (1...50).contains(limit), cursor == nil || OpsIncident.validUUID(cursor!) else { throw OpsError.invalidIncidentQuery }
        severity = filter.severity; operation = filter.operation
        userQuery = filter.userQuery.isEmpty ? nil : filter.userQuery
        self.cursor = cursor; self.limit = limit
    }
}
struct OpsIncident: Decodable, Identifiable, Equatable {
    let eventID, attemptID: String
    let operation: OpsIncidentOperation
    let stage: String
    let severity: OpsIncidentSeverity
    let code, message: String
    let occurredAt, receivedAt: Int
    let elapsedMs: Int?
    let roomID, requestID: String?
    let httpStatus: Int?
    let platform, appVersion, osVersion: String
    let userID, userName, source: String
    var id: String { eventID }
    var safeMessage: String { Self.messages[code] ?? "未分类的房间错误" }
    var sourceTitle: String {
        switch source { case "client": "客户端观测"; case "server": "语聊服务器观测"; case "account": "账号服务器观测"; default: "未知来源" }
    }
    var platformTitle: String { switch platform { case "ios": "iPhone / iOS"; case "ipados": "iPad / iPadOS"; default: "服务器" } }
    var stageTitle: String { Self.stages[stage] ?? "未知阶段" }
    static func validUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value)?.uuidString.lowercased() == value.lowercased()
    }
    func validate() throws {
        guard Self.validUUID(eventID), Self.validUUID(attemptID), requestID == nil || Self.validUUID(requestID!),
              operation != .all, severity != .all, Self.stages[stage] != nil, Self.messages[code] != nil,
              message.count <= 200, occurredAt > 0, receivedAt > 0,
              elapsedMs == nil || (0...3_600_000).contains(elapsedMs!),
              httpStatus == nil || (400...599).contains(httpStatus!),
              roomID == nil || roomID!.range(of: "^lk_[a-f0-9]{32}$", options: .regularExpression) != nil,
              ["ios", "ipados", "server"].contains(platform), ["client", "server", "account"].contains(source),
              userID.range(of: "^kiki_[A-Za-z0-9_]{8,64}$", options: .regularExpression) != nil,
              (1...16).contains(userName.count), !userName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              [appVersion, osVersion].allSatisfy({ !$0.isEmpty && $0.count <= 32 && $0.range(of: "^[A-Za-z0-9 .()_-]+$", options: .regularExpression) != nil }) else {
            throw OpsError.invalidResponse
        }
    }
    static let stages = [
        "account_authorization": "账号授权", "room_api": "房间接口", "token_api": "媒体凭证",
        "media_connect": "媒体连接", "state_sync": "房间状态同步", "media_runtime": "媒体运行",
        "reconnect": "断线重连", "safety_sync": "安全状态同步", "chat_sync": "文字同步",
        "audio_policy": "麦克风策略", "room_action": "房间操作", "room_leave": "退出房间"
    ]
    static let messages = [
        "request_timeout": "请求超时，未及时取得响应", "network_unavailable": "设备网络不可用",
        "network_connection_lost": "网络连接中断", "network_tls_failed": "安全连接建立失败",
        "network_error": "网络请求失败", "http_unauthorized": "业务登录授权不可用",
        "http_forbidden": "操作权限被拒绝", "http_not_found": "请求的房间或资源不存在",
        "http_conflict": "房间状态或操作发生冲突", "http_rate_limited": "请求受到频率限制",
        "http_server_error": "服务端处理失败", "http_invalid_response": "服务响应格式不正确",
        "consent_required": "需要确认当前隐私协议", "capacity_reached": "房间或服务准入达到上限",
        "room_ended": "目标房间已经结束", "voice_banned": "账号受到语聊限制",
        "chat_muted": "账号受到文字禁言限制", "voice_muted": "账号受到上麦限制",
        "content_filtered": "内容未通过过滤", "media_connect_timeout": "媒体连接建立超时",
        "media_connect_failed": "媒体连接建立失败", "media_disconnected": "媒体连接意外断开",
        "reconnect_failed": "媒体重连失败", "state_sync_failed": "房间状态同步失败",
        "audio_publish_failed": "麦克风音轨发布失败", "audio_permission_denied": "麦克风权限不可用",
        "quality_poor": "音频连接质量较差", "quality_lost": "音频连接质量丢失", "unknown_error": "未分类的房间错误"
    ]
}
struct OpsIncidentSummary: Decodable {
    let schemaVersion, trackingSince, retentionDays, totalEvents: Int
    let errorsLast24Hours, warningsLast24Hours, failedAttemptsLast24Hours: Int
    let events: [OpsIncident]
    func validate() throws {
        guard schemaVersion == 1, retentionDays == 7, trackingSince > 0, (0...10_000).contains(totalEvents),
              [errorsLast24Hours, warningsLast24Hours, failedAttemptsLast24Hours].allSatisfy({ (0...totalEvents).contains($0) }),
              errorsLast24Hours + warningsLast24Hours <= totalEvents, events.count <= 50,
              events.count <= totalEvents, Set(events.map(\.eventID)).count == events.count else { throw OpsError.invalidResponse }
        try events.forEach { try $0.validate() }
    }
}
struct OpsIncidentPage: Decodable {
    let schemaVersion: Int
    let events: [OpsIncident]
    let nextCursor: String?
    let retentionDays: Int
    func validate(limit: Int = 50) throws {
        guard schemaVersion == 1, retentionDays == 7, events.count <= limit,
              Set(events.map(\.eventID)).count == events.count,
              nextCursor == nil || (OpsIncident.validUUID(nextCursor!) && nextCursor == events.last?.eventID) else { throw OpsError.invalidResponse }
        try events.forEach { try $0.validate() }
    }
}
