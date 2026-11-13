import Foundation
import Observation

/// App language is independent of account, consent, and active room state.
enum KikiAppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese, english
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return KikiL10n.text("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

@Observable
final class KikiLanguageSettings {
    static let shared = KikiLanguageSettings()
    static let preferenceKey = "kikitalk.appLanguage"
    var selection: KikiAppLanguage {
        didSet {
            guard selection != oldValue else { return }
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            NotificationCenter.default.post(name: .kikiLanguageDidChange, object: nil)
        }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.preferenceKey).flatMap(KikiAppLanguage.init(rawValue:)) ?? .system
    }
}

extension Notification.Name {
    static let kikiLanguageDidChange = Notification.Name("kikitalk.languageDidChange")
}

/// Only app-owned copy is localized. Names, messages, room announcements, IDs,
/// dates used by protocols, and server classification codes keep their value.
enum KikiL10n {
    static var languageCode: String {
        resolvedLanguage(KikiLanguageSettings.shared.selection, preferredLanguages: Locale.preferredLanguages)
    }
    static var isEnglish: Bool { languageCode == "en" }
    static var locale: Locale { Locale(identifier: languageCode) }

    static func resolvedLanguage(_ selection: KikiAppLanguage, preferredLanguages: [String]) -> String {
        switch selection {
        case .simplifiedChinese: return "zh-Hans"
        case .english: return "en"
        case .system:
            for language in preferredLanguages {
                let code = language.lowercased()
                if code == "zh" || code.hasPrefix("zh-") || code.hasPrefix("zh_") { return "zh-Hans" }
                if code == "en" || code.hasPrefix("en-") || code.hasPrefix("en_") { return "en" }
            }
            return "en"
        }
    }

    /// Display-only romanization of the built-in China directory. Never use
    /// this value as a place ID or write it back into a birth profile.
    static func placeName(_ original: String) -> String {
        guard isEnglish else { return original }
        let provinces = ["北京市": "Beijing", "天津市": "Tianjin", "上海市": "Shanghai", "重庆市": "Chongqing",
            "河北省": "Hebei", "山西省": "Shanxi", "辽宁省": "Liaoning", "吉林省": "Jilin", "黑龙江省": "Heilongjiang",
            "江苏省": "Jiangsu", "浙江省": "Zhejiang", "安徽省": "Anhui", "福建省": "Fujian", "江西省": "Jiangxi",
            "山东省": "Shandong", "河南省": "Henan", "湖北省": "Hubei", "湖南省": "Hunan", "广东省": "Guangdong",
            "海南省": "Hainan", "四川省": "Sichuan", "贵州省": "Guizhou", "云南省": "Yunnan", "陕西省": "Shaanxi",
            "甘肃省": "Gansu", "青海省": "Qinghai", "台湾省": "Taiwan", "内蒙古自治区": "Inner Mongolia",
            "广西壮族自治区": "Guangxi", "西藏自治区": "Tibet", "宁夏回族自治区": "Ningxia", "新疆维吾尔自治区": "Xinjiang",
            "香港特别行政区": "Hong Kong", "澳门特别行政区": "Macao", "香港": "Hong Kong", "澳门": "Macao", "台湾": "Taiwan"]
        var remaining = original
        var parts: [String] = []
        if let prefix = provinces.keys.sorted(by: { $0.count > $1.count }).first(where: { remaining.hasPrefix($0) }) {
            parts.append(provinces[prefix]!); remaining.removeFirst(prefix.count)
        }
        let suffixes = [("特别行政区", ""), ("自治区", " Autonomous Region"), ("自治州", " Autonomous Prefecture"),
                        ("自治县", " Autonomous County"), ("地区", " Prefecture"), ("省", ""),
                        ("市", " City"), ("区", " District"), ("县", " County"), ("盟", " League"), ("旗", " Banner")]
        let pattern = ".+?(?:" + suffixes.map(\.0).joined(separator: "|") + ")"
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let matches = expression.matches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining))
            var end = remaining.startIndex
            for match in matches {
                guard let range = Range(match.range, in: remaining) else { continue }
                parts.append(romanizedPlaceComponent(String(remaining[range]), suffixes: suffixes)); end = range.upperBound
            }
            if end < remaining.endIndex { parts.append(romanizedPlaceComponent(String(remaining[end...]), suffixes: suffixes)) }
        } else if !remaining.isEmpty { parts.append(romanizedPlaceComponent(remaining, suffixes: suffixes)) }
        return parts.isEmpty ? original : parts.reversed().joined(separator: ", ")
    }

    private static func romanizedPlaceComponent(_ name: String, suffixes: [(String, String)]) -> String {
        let suffix = suffixes.first { name.hasSuffix($0.0) }
        let stem = suffix.map { String(name.dropLast($0.0.count)) } ?? name
        let common = ["重庆": "Chongqing", "厦门": "Xiamen", "长沙": "Changsha", "朝阳": "Chaoyang",
                      "六安": "Lu’an", "蚌埠": "Bengbu", "丽水": "Lishui", "乐山": "Leshan"]
        let latin = common[stem] ?? (stem.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .replacingOccurrences(of: " ", with: "").lowercased().capitalized ?? stem)
        return latin + (suffix?.1 ?? "")
    }

    static func text(_ key: String) -> String {
        guard let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        var template = text(key)
        // Explicit singular entries are reserved for keys whose first argument
        // is a count. Names or user text never select an inferred grammar rule.
        if isEnglish, let count = arguments.first, String(describing: count) == "1" {
            let singularKey = key + ".__one"
            let singular = text(singularKey)
            if singular != singularKey { template = singular }
        }
        return String(format: template, locale: locale, arguments: arguments)
    }
}
