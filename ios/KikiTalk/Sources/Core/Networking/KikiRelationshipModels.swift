import Foundation

enum KikiRelationshipMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case bazi, zodiac, mbti
    var id: String { rawValue }
    var title: String {
        switch self { case .bazi: return KikiL10n.text("八字"); case .mbti: return "MBTI"; case .zodiac: return KikiL10n.text("星座") }
    }
}

struct KikiRelationshipSummary: Codable, Equatable, Sendable {
    let code: String
    let label: String
    let description: String
    var harmonyIndex: Int? = nil
    var conflictIndex: Int? = nil
    var isAvailable: Bool { code != "UNAVAILABLE" }
}

struct KikiRelationshipPair: Codable, Equatable, Identifiable, Sendable {
    let aID: String
    let bID: String
    let bazi: KikiRelationshipSummary
    let mbti: KikiRelationshipSummary
    let zodiac: KikiRelationshipSummary
    var id: String { [aID, bID].sorted().joined(separator: "|") }
    func summary(for mode: KikiRelationshipMode) -> KikiRelationshipSummary {
        switch mode { case .bazi: return bazi; case .mbti: return mbti; case .zodiac: return zodiac }
    }
}

/// This public projection intentionally has no birthday, birthplace or pillars.
struct KikiRelationshipPublicProfile: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    var mbtiType: String? = nil
    var zodiacSign: String? = nil
    var id: String { userID }
}

struct KikiRoomRelationships: Codable, Equatable, Sendable {
    let roomID: String
    let roomRevision: Int
    let ruleVersion: String
    let revision: String
    let profiles: [KikiRelationshipPublicProfile]
    let pairs: [KikiRelationshipPair]
}

enum KikiBirthCalendar: String, Codable, CaseIterable, Identifiable, Sendable {
    case gregorian, lunar
    var id: String { rawValue }
    var title: String { self == .gregorian ? KikiL10n.text("公历") : KikiL10n.text("农历") }
}

enum KikiRelationshipEditor: String, CaseIterable, Identifiable, Sendable {
    case bazi, mbti
    var id: String { rawValue }
    var title: String { self == .bazi ? KikiL10n.text("八字") : "MBTI" }
}

/// Only sent to the account owner's private endpoints. Explicit nulls allow
/// clearing a field instead of accidentally keeping a previously saved value.
struct KikiRelationshipProfileDraft: Codable, Equatable, Sendable {
    var mbtiType: String? = nil
    var zodiacSign: String? = nil
    var birthCalendar: KikiBirthCalendar = .gregorian
    var birthDate: String? = nil
    var birthLeapMonth = false
    var birthTime: String? = nil
    var birthPlaceCode: String? = nil
    var birthFold: Int? = nil
    var baziEnabled = false
    var mbtiEnabled = true
    var zodiacEnabled = true

    enum CodingKeys: String, CodingKey {
        case mbtiType, zodiacSign, birthCalendar, birthDate, birthLeapMonth
        case birthTime, birthPlaceCode, birthFold, baziEnabled, mbtiEnabled, zodiacEnabled
    }

    func encode(to encoder: Encoder) throws {
        try encodeEditableFields(to: encoder, editor: nil)
    }

    fileprivate func encodeEditableFields(to encoder: Encoder, editor: KikiRelationshipEditor?) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if editor != .bazi { try c.encode(mbtiType, forKey: .mbtiType) }
        if editor != .mbti {
            try c.encode(birthCalendar, forKey: .birthCalendar)
            try c.encode(birthDate, forKey: .birthDate)
            try c.encode(birthLeapMonth, forKey: .birthLeapMonth)
            try c.encode(birthTime, forKey: .birthTime)
            try c.encode(birthPlaceCode, forKey: .birthPlaceCode)
        }
        // The server derives zodiac and civil-time handling. Sharing is part
        // of accepted terms, so legacy choices must never overwrite it.
    }

    /// Calendar changes are alternate representations of the same civil date.
    /// Keep the recorded clock, birthplace and unrelated profile fields intact.
    func changingCalendar(to calendar: KikiBirthCalendar, using preview: KikiRelationshipProfile) -> Self? {
        guard let date = calendar == .gregorian ? preview.gregorianBirthDate : preview.lunarBirthDate else { return nil }
        var converted = self
        converted.birthCalendar = calendar
        converted.birthDate = date
        converted.birthLeapMonth = calendar == .lunar && preview.lunarBirthLeapMonth == true
        return converted
    }
}

/// A focused editor sends only its own fields, even when its loaded snapshot
/// contains the other editor's data. Omitted fields remain unchanged server-side.
struct KikiRelationshipProfilePatch: Encodable, Sendable {
    let draft: KikiRelationshipProfileDraft
    let editor: KikiRelationshipEditor?
    func encode(to encoder: Encoder) throws {
        try draft.encodeEditableFields(to: encoder, editor: editor)
    }
}

struct KikiPrivateRelationshipChart: Decodable, Equatable, Sendable {
    let status: String
    let pillars: [String]?
    let trueSolarTime: String?
    let civilTime: String?
    let message: String?
}

/// Never attached to a public person, voice member or LiveKit metadata.
struct KikiRelationshipProfile: Decodable, Equatable, Sendable {
    let mbtiType: String?
    let zodiacSign: String?
    let birthCalendar: KikiBirthCalendar
    let birthDate: String?
    let birthLeapMonth: Bool
    let birthTime: String?
    let birthPlaceCode: String?
    let birthFold: Int?
    let baziEnabled: Bool
    let mbtiEnabled: Bool
    let zodiacEnabled: Bool
    let revision: Int
    let birthPlaceName: String?
    let birthTimeZone: String?
    let chart: KikiPrivateRelationshipChart?
    let gregorianBirthDate: String?
    let lunarBirthDate: String?
    let lunarBirthLeapMonth: Bool?

    var draft: KikiRelationshipProfileDraft {
        .init(mbtiType: mbtiType, zodiacSign: zodiacSign, birthCalendar: birthCalendar,
              birthDate: birthDate, birthLeapMonth: birthLeapMonth, birthTime: birthTime,
              birthPlaceCode: birthPlaceCode, birthFold: birthFold, baziEnabled: baziEnabled,
              mbtiEnabled: mbtiEnabled, zodiacEnabled: zodiacEnabled)
    }
}

struct KikiRelationshipPlace: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let fullName: String
    let hasChildren: Bool
    let hasCoordinates: Bool
    let timeZone: String
}

struct KikiRelationshipPlaces: Decodable, Sendable { let places: [KikiRelationshipPlace] }

extension Notification.Name {
    static let kikiRelationshipProfileDidChange = Notification.Name("KikiRelationshipProfileDidChange")
}
