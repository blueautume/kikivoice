import Foundation

/// Dashboard source identities remain distinct; they are never authentication origins.
enum OpsService: String, Codable, CaseIterable, Identifiable {
    case voice, account, community
    var id: String { rawValue }
    var title: String {
        switch self { case .voice: "语聊服务"; case .account: "账号服务"; case .community: "社区管理" }
    }
    var hostLabel: String { self == .account ? "kiki.group" : "furby.top" }
}

enum OpsIdentityEndpoint {
    static let host = "kiki.group"
    static let relyingPartyID = host
    static let baseURL = URL(string: "https://kiki.group")!
    static let keychainService = "com.kikitalk.voiceops.identity.v2"
    static let allowedMethods = [
        "/admin/v2/auth/registration/options": "POST",
        "/admin/v2/auth/registration/verify": "POST",
        "/admin/v2/auth/authentication/options": "POST",
        "/admin/v2/auth/authentication/verify": "POST",
        "/admin/v2/auth/session": "DELETE",
        "/admin/v2/me": "GET,PATCH",
        "/admin/v2/services/account/dashboard": "GET",
        "/admin/v2/services/voice/dashboard": "GET",
        "/admin/v2/services/voice/incidents/query": "POST",
        "/admin/v2/services/voice/moderation/query": "POST",
        "/admin/v2/services/voice/moderation/action": "POST"
        ,"/admin/v2/services/account/social/moderation/query": "POST"
        ,"/admin/v2/services/account/social/moderation/action": "POST"
    ]
    static func permits(_ request: URLRequest) -> Bool {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == host, parts.port == nil || parts.port == 443,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return false }
        guard let methods = allowedMethods[parts.percentEncodedPath] else { return false }
        return methods.split(separator: ",").contains(Substring(request.httpMethod ?? "GET"))
    }
}

struct OpsPermissions: Codable, Equatable {
    let voice: Bool
    let account: Bool
    let community: Bool
    init(voice: Bool, account: Bool, community: Bool = false) {
        self.voice = voice; self.account = account; self.community = community
    }
    private enum CodingKeys: String, CodingKey { case voice, account, community }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        voice = try values.decode(Bool.self, forKey: .voice)
        account = try values.decode(Bool.self, forKey: .account)
        community = try values.decodeIfPresent(Bool.self, forKey: .community) ?? false
    }
    func permits(_ service: OpsService) -> Bool {
        switch service { case .voice: voice; case .account: account; case .community: community }
    }
}

struct OpsAccount: Codable, Equatable {
    let id: String
    let name: String?
    let needsName: Bool
    let permissions: OpsPermissions
    func validate() throws {
        guard id.range(of: "^ops_[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil,
              needsName || name?.isEmpty == false else { throw OpsError.invalidResponse }
    }
    static func validName(_ value: String) -> String? {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard (1...32).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return name
    }
}

struct OpsSession: Codable, Equatable {
    let token: String
    let expiresAt: Date
    let host: String
    let version: Int
    init(token: String, expiresAt: Date, host: String = OpsIdentityEndpoint.host, version: Int = 2) {
        self.token = token; self.expiresAt = expiresAt; self.host = host; self.version = version
    }
    func isValid(now: Date = Date()) -> Bool {
        version == 2 && host == OpsIdentityEndpoint.host && token.range(of: "^[A-Za-z0-9_-]{16,512}$", options: .regularExpression) != nil
            && expiresAt > now && expiresAt.timeIntervalSince(now) <= 8 * 3600 + 60
    }
}

enum OpsError: LocalizedError, Equatable {
    case unauthenticated, expired, unsafeEndpoint, forbidden, invalidName, invalidIncidentQuery
    case redirected, invalidResponse, server(status: Int), keychain(Int32), rateLimited
    case authorizationUnavailable, invalidPasskeyOptions, authorizationInProgress, ceremonyExpired, invalidModeration, moderationConflict, unresolvedModeration
    var errorDescription: String? {
        switch self {
        case .unauthenticated: "管理会话已失效，请使用通行密钥重新登录。"
        case .expired: "管理会话已到期，请重新登录。"
        case .unsafeEndpoint: "服务地址不符合安全配置。"
        case .forbidden: "当前服务待授权，请将姓名与唯一编号提供给管理员。"
        case .invalidName: "请输入 1–32 字的名字，不含控制字符。"
        case .invalidIncidentQuery: "查询条件或翻页位置已失效，请刷新记录；昵称或编号最多 80 字。"
        case .redirected: "服务器返回了重定向，连接已停止。"
        case .invalidResponse: "服务器数据暂时无法解析。"
        case .server(let status): "服务暂时不可用（\(status)），请稍后刷新。"
        case .keychain: "无法安全保存管理会话，请重新尝试。"
        case .rateLimited: "操作过于频繁，请稍后重试。"
        case .authorizationUnavailable: "系统暂时无法完成通行密钥验证，请检查 iCloud 钥匙串与设备设置后重试。"
        case .invalidPasskeyOptions: "通行密钥验证请求无效，请重新尝试。"
        case .authorizationInProgress: "系统验证正在进行中，请稍候。"
        case .ceremonyExpired: "本次通行密钥验证已失效，请重新尝试。"
        case .invalidModeration: "请填写不超过 500 字的处理说明，并选择有效的限制期限。"
        case .moderationConflict: "举报或处置状态已变化，请刷新核对后再操作。"
        case .unresolvedModeration: "还有一项处理结果尚未确认，请先在社区管理中恢复该操作，避免重复处置。"
        }
    }
}
