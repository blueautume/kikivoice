import Foundation

struct KikiRoomMemberPreview: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    let name: String
    let avatarIndex: Int
    let avatarURL: String?
    var id: String { userID }
}

struct KikiRoom: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var host: String
    var hostID: String
    var category: String
    var audience: Int
    var isLive: Bool
    var theme: Int
    var isCreatedByMe: Bool
    var status: String
    var createdAt: Int
    var hostAvatarIndex: Int
    var hostAvatarURL: String?
    var memberPreview: [KikiRoomMemberPreview]
    var language: String { "中文" }

    init(id: String, title: String, host: String, hostID: String, category: String, audience: Int,
         isLive: Bool, theme: Int, isCreatedByMe: Bool, status: String, createdAt: Int = 0, hostAvatarIndex: Int = 0, hostAvatarURL: String? = nil,
         memberPreview: [KikiRoomMemberPreview] = []) {
        self.id = id; self.title = title; self.host = host; self.hostID = hostID
        self.category = category; self.audience = audience; self.isLive = isLive; self.theme = theme
        self.isCreatedByMe = isCreatedByMe; self.status = status; self.createdAt = createdAt
        self.hostAvatarIndex = hostAvatarIndex
        self.hostAvatarURL = hostAvatarURL
        self.memberPreview = memberPreview
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, host, hostID, category, audience, isLive, theme, isCreatedByMe, status, createdAt, hostAvatarIndex, hostAvatarURL, memberPreview
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        host = try values.decode(String.self, forKey: .host)
        hostID = try values.decode(String.self, forKey: .hostID)
        category = try values.decode(String.self, forKey: .category)
        audience = try values.decode(Int.self, forKey: .audience)
        isLive = try values.decode(Bool.self, forKey: .isLive)
        theme = try values.decode(Int.self, forKey: .theme)
        isCreatedByMe = try values.decode(Bool.self, forKey: .isCreatedByMe)
        status = try values.decode(String.self, forKey: .status)
        createdAt = try values.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        hostAvatarIndex = try values.decodeIfPresent(Int.self, forKey: .hostAvatarIndex) ?? 0
        hostAvatarURL = try values.decodeIfPresent(String.self, forKey: .hostAvatarURL)
        memberPreview = try values.decodeIfPresent([KikiRoomMemberPreview].self, forKey: .memberPreview) ?? []
    }
}
