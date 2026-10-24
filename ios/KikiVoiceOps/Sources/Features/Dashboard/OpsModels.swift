import Foundation

struct OpsDashboard: Decodable {
    let schemaVersion: Int
    let serverTime: String
    let service: Service
    let accountService: AccountService
    let operations: Operations
    let capacity: Capacity
    let connections: Connections
    let quality: Quality
    let infrastructure: Infrastructure
    let health: Health
    let rooms: [Room]
    let alerts: [Alert]
    let maintenance: OpsMaintenance?
    let incidents: OpsIncidentSummary?

    struct Service: Decodable { let id, name, host, mode: String; let readOnly: Bool }
    struct AccountService: Decodable { let connected: Bool; let message: String }
    struct Operations: Decodable {
        let activity: Activity?
        let day, timeZone: String
        let activeRooms, roomsCreatedToday, roomsEndedToday, totalRooms: Int
        let participatingIdentitiesToday, totalParticipatingIdentities: Int
        let identityMetricNote: String
        let roomEndTrackingSince: String?
    }
    struct Activity: Decodable {
        let trackingSince: Double
        let day, timeZone: String
        let activeUsersToday, returningUsersToday: Int
        let onlineUsersNow: Int?
        let onlineSampledAt: Double?
        let roomStaySecondsToday: Double
        let micSeatJoinsToday, reportsToday, pendingReports: Int
        let note: String
    }
    struct Capacity: Decodable {
        let activeRooms: Int
        let activeParticipants: Int?
        let admittedParticipants, maxRooms, maxParticipantsPerRoom, maxParticipantsTotal: Int
        let sfuSampledAt: String?
        let sfuStale: Bool
    }
    struct Connections: Decodable {
        let windowSeconds, attempts, accepted, rejected, reconnects, activeSignals: Int
        let handshakeMsP50, successPercent: Double?
        let sampleNote: String
    }
    struct Quality: Decodable {
        let windowSeconds, samples, excellent, good, poor, lost, unknown: Int
        let poorPercent, rttMsP50, jitterMsP50, packetLossPercentP50: Double?
        let sampleNote: String?
    }
    struct Infrastructure: Decodable {
        let sampledAt: String?
        let stale: Bool
        let cpuPercent: Double?
        let cpuCores: Int?
        let memoryUsedBytes, memoryTotalBytes, memoryPercent: Double?
        let diskUsedBytes, diskTotalBytes, diskPercent: Double?
        let networkReceiveBytesPerSecond, networkTransmitBytesPerSecond, uptimeSeconds: Double?
        let certificateExpiresAt: String?
        let certificateDaysRemaining: Double?
        let services: [ServiceState]
    }
    struct ServiceState: Decodable, Identifiable { let id, name, state: String }
    struct Health: Decodable { let api, sfu: String; let pendingMediaCleanup: Int }
    struct Room: Decodable, Identifiable {
        let id, title, category: String
        let createdAt: Double
        let admittedParticipants: Int
        let onlineParticipants: Int?
        let sfuStale: Bool
        let occupiedSeats, totalSeats, owners, admins, listeners, audioMutedMembers, chatMutedMembers: Int
    }
    struct Alert: Decodable, Identifiable {
        let code, level, message: String
        var id: String { code + message }
    }

    func validateVoiceBoundary() throws {
        guard schemaVersion == 1, service.id == "voice-lab", service.host == "furby.top", service.readOnly,
              !accountService.connected else { throw OpsError.invalidResponse }
        try incidents?.validate()
    }
}

/// Account data has its own schema; it never impersonates voice capacity/quality.
struct AccountOpsDashboard: Decodable {
    let schemaVersion: Int
    let serverTime: String
    let service: OpsDashboard.Service
    let voiceService: VoiceBoundary
    let operations: Operations
    let storage: Storage
    let infrastructure: OpsDashboard.Infrastructure
    let health: Health
    let alerts: [OpsDashboard.Alert]
    let maintenance: OpsMaintenance?
    let push: OpsPushSummary?

    struct VoiceBoundary: Decodable { let included: Bool; let message: String }
    struct Operations: Decodable {
        let activity: Activity?
        let social: Social?
        let day, timeZone: String
        let totalAccounts, accountsCreatedToday, validBusinessSessions, accountsWithValidSessions: Int
        let accountsWithSessionsCreatedToday: Int
        let sessionMetricNote: String
        let appleAuthorizedAccounts, pendingAppleRevocations, dueAppleRevocations: Int
        let appleMetricNote: String
        let accountsWithCustomAvatar: Int
    }
    struct Social: Decodable {
        let follows, mutualPairs, messagesLast30Days, pendingReports, activePostingRestrictions: Int
        let note: String
    }
    struct Activity: Decodable {
        let trackingSince: Double
        let activeAccountsToday, returningAccountsToday: Int
        let retentionDays: Int
        let note: String
    }
    struct Storage: Decodable {
        let databaseBytes, avatarFiles, avatarBytes: Double?
        let avatarScanLimited: Bool
        let sampleNote: String
    }
    struct Health: Decodable { let api: String }

    func validateAccountBoundary() throws {
        guard schemaVersion == 1, service.id == "account", service.host == "kiki.group", service.readOnly,
              !voiceService.included else { throw OpsError.invalidResponse }
        try push?.validate()
    }
}

/// Aggregate account-service APNs state; never carries device/user identifiers.
struct OpsPushSummary: Decodable {
    let schemaVersion: Int
    let configured, enabled: Bool
    let activeDevices, pending, accepted, failed: Int
    let recentFailures: [Failure]

    struct Failure: Decodable {
        let code: String
        let occurredAt: Int
        var message: String {
            switch code {
            case "transport_error": "通知服务连接暂时失败"
            case "rate_limited": "通知请求受到频率限制"
            case "provider_unavailable": "Apple 通知服务暂时不可用"
            case "unregistered", "bad_device_token": "设备通知凭据已失效"
            case "wrong_topic": "通知应用配置需要检查"
            case "provider_auth": "通知服务授权需要检查"
            case "payload_invalid": "通知请求格式需要检查"
            case "expired": "通知已超过发送期限"
            case "privacy_unavailable": "暂时无法核对通知隐私设置"
            default: "通知请求失败"
            }
        }
    }

    func validate() throws {
        guard schemaVersion == 1, [activeDevices, pending, accepted, failed].allSatisfy({ $0 >= 0 }),
              recentFailures.count <= 10,
              recentFailures.allSatisfy({ item in
                  item.occurredAt > 0 && item.code.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil
              }) else { throw OpsError.invalidResponse }
    }
}
