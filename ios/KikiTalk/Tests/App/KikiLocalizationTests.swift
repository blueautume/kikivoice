import XCTest
import CryptoKit
import SwiftUI
import UIKit
@testable import KikiTalk

@MainActor
final class KikiLocalizationTests: XCTestCase {
    func testSystemLanguageUsesFirstSupportedPreferenceAndEnglishFallback() {
        XCTAssertEqual(KikiL10n.resolvedLanguage(.system, preferredLanguages: ["en-GB", "zh-Hans"]), "en")
        XCTAssertEqual(KikiL10n.resolvedLanguage(.system, preferredLanguages: ["fr-FR", "zh-Hant-TW", "en"]), "zh-Hans")
        XCTAssertEqual(KikiL10n.resolvedLanguage(.system, preferredLanguages: ["fr-FR"]), "en")
        XCTAssertEqual(KikiL10n.resolvedLanguage(.simplifiedChinese, preferredLanguages: ["en-US"]), "zh-Hans")
        XCTAssertEqual(KikiL10n.resolvedLanguage(.english, preferredLanguages: ["zh-Hans"]), "en")
    }

    func testLanguagePreferencePersistsWithoutAccountOrDeviceIdentifiers() {
        let suite = "KikiLocalizationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = KikiLanguageSettings(defaults: defaults)
        XCTAssertEqual(first.selection, .system)
        first.selection = .english
        let next = KikiLanguageSettings(defaults: defaults)
        XCTAssertEqual(next.selection, .english)
        XCTAssertEqual(defaults.string(forKey: KikiLanguageSettings.preferenceKey), "english")
        XCTAssertNil(defaults.string(forKey: "sessionToken"))
        XCTAssertNil(defaults.string(forKey: "pushInstallationID"))
    }

    func testPackagedEnglishAndChineseResourcesResolveAndFormatArguments() throws {
        let previous = KikiLanguageSettings.shared.selection
        defer { KikiLanguageSettings.shared.selection = previous }
        KikiLanguageSettings.shared.selection = .english
        XCTAssertEqual(KikiL10n.text("Kiki"), "kikitalk")
        XCTAssertEqual(KikiL10n.text("跟随系统"), "Follow System")
        XCTAssertEqual(KikiL10n.format("%@ 条未读消息", "12"), "12 unread messages")
        XCTAssertEqual(KikiL10n.format("%@ 条未读消息", "1"), "1 unread message")
        XCTAssertEqual(KikiL10n.format("%@ 个房间", "1"), "1 room")
        XCTAssertEqual(KikiL10n.format("%@ 个房间", "0"), "0 rooms")
        XCTAssertEqual(KikiL10n.format("%@ 条待处理申请", "2"), "2 pending requests")
        XCTAssertEqual(KikiL10n.format("对方回复前，还可发送 %@ 条消息。", "1"), "You can send 1 more message before they reply.")
        XCTAssertEqual(KikiL10n.format("%@\n问题编号：%@", "Try again.", "ABC123"), "Try again.\nReference: ABC123")
        let englishPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let info = try XCTUnwrap(NSDictionary(contentsOfFile: englishPath + "/InfoPlist.strings"))
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "kikitalk")
        KikiLanguageSettings.shared.selection = .simplifiedChinese
        XCTAssertEqual(KikiL10n.text("跟随系统"), "跟随系统")
        XCTAssertEqual(KikiL10n.text("tab.rooms"), "语聊")
        XCTAssertEqual(KikiL10n.text("tab.profile"), "我")
        XCTAssertEqual(KikiL10n.format("%@ 条未读消息", "12"), "12 条未读消息")
    }

    func testEnglishPlaceNamesAreDisplayOnlyAndChineseNamesAreUnchanged() {
        let previous = KikiLanguageSettings.shared.selection
        defer { KikiLanguageSettings.shared.selection = previous }
        let original = "北京市朝阳区"
        KikiLanguageSettings.shared.selection = .english
        XCTAssertEqual(KikiL10n.placeName(original), "Chaoyang District, Beijing")
        XCTAssertEqual(KikiL10n.placeName("浙江省杭州市西湖区"), "Xihu District, Hangzhou City, Zhejiang")
        XCTAssertEqual(KikiL10n.placeName("重庆市"), "Chongqing")
        XCTAssertEqual(KikiL10n.placeName("香港特别行政区"), "Hong Kong")
        XCTAssertEqual(original, "北京市朝阳区")
        KikiLanguageSettings.shared.selection = .simplifiedChinese
        XCTAssertEqual(KikiL10n.placeName(original), original)
    }

    func testEnglishLegalTextIsCompleteAndBoundToCanonicalConsent() throws {
        let canonical = try XCTUnwrap(KikiLegalBundle.bundled)
        let translated = try XCTUnwrap(KikiLegalEnglish.bundled(canonical: canonical))
        XCTAssertTrue(translated.matches(canonical))
        XCTAssertEqual(translated.sourceDocumentHash, canonical.documentHash)
        XCTAssertEqual(translated.documents.map(\.id), canonical.documents.map(\.id))
        XCTAssertEqual(translated.documents.flatMap(\.sections).flatMap(\.paragraphs).count, 78)
        XCTAssertEqual(translated.documents.first { $0.id == "privacy" }?.title, "kikitalk Privacy Policy")
        let data = try XCTUnwrap(translated.validatedData)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["sourceDocumentHash"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try KikiLegalEnglish.decodeValidated(rehashEnglish(object), canonical: canonical))
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var documents = try XCTUnwrap(object["documents"] as? [[String: Any]])
        var sections = try XCTUnwrap(documents[0]["sections"] as? [[String: Any]])
        var paragraphs = try XCTUnwrap(sections[0]["paragraphs"] as? [String])
        paragraphs.removeLast(); sections[0]["paragraphs"] = paragraphs
        documents[0]["sections"] = sections; object["documents"] = documents
        XCTAssertThrowsError(try KikiLegalEnglish.decodeValidated(rehashEnglish(object), canonical: canonical),
                             "A self-consistent checksum cannot authorize incomplete translated text")
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["minimumAge"] = 17
        XCTAssertThrowsError(try KikiLegalEnglish.decodeValidated(rehashEnglish(object), canonical: canonical))
    }

    func testEnglishConsentKeepsCanonicalReceiptAndNoIdentityAccess() throws {
        let previous = KikiLanguageSettings.shared.selection
        KikiLanguageSettings.shared.selection = .english
        defer { KikiLanguageSettings.shared.selection = previous }
        let suite = "KikiEnglishConsent." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = NoAccessIdentity()
        let store = KikiConsentStore(defaults: defaults, identity: identity, requiresRemoteDocuments: false)
        XCTAssertTrue(store.canAccept)
        try store.accept()
        XCTAssertEqual(store.receipt?.versions.documentHash, store.documents?.documentHash)
        let accepted = store.receipt
        KikiLanguageSettings.shared.selection = .simplifiedChinese
        XCTAssertTrue(store.hasCurrentConsent)
        XCTAssertEqual(store.receipt, accepted)
        XCTAssertEqual(identity.accesses, 0)
    }

    func testSystemNotificationsTranslateWithoutChangingPeopleOrPrivateMessages() {
        let previous = KikiLanguageSettings.shared.selection
        KikiLanguageSettings.shared.selection = .english
        defer { KikiLanguageSettings.shared.selection = previous }
        let actor = KikiPerson(id: "island", name: "小岛", bio: "关注了你", avatarIndex: 0,
                               avatarURL: nil, following: true, followsYou: true, mutual: true,
                               followingCount: 1, followerCount: 1, currentRoomID: nil)
        let original = "小岛关注了你"
        let notice = KikiSocialNotification(id: "follow", kind: "follow", actor: actor, text: original,
                                           createdAt: 1, readAt: nil, roomID: nil)
        XCTAssertEqual(notice.displayText, "小岛 started following you.")
        XCTAssertEqual(notice.text, original)
        XCTAssertEqual(KikiInboxEntry(notification: notice).preview, original)
        XCTAssertEqual(KikiInboxEntry(notification: notice).localizedPreview, "小岛 started following you.")
        for kind in ["mutual_follow", "room_started", "room_invite"] {
            let value = KikiSocialNotification(id: kind, kind: kind, actor: actor, text: original,
                                              createdAt: 1, readAt: nil, roomID: nil)
            XCTAssertTrue(value.displayText.contains(actor.name))
            XCTAssertFalse(value.displayText.contains("关注了你"))
        }
        let custom = KikiSocialNotification(id: "custom", kind: "custom", actor: actor, text: "请联系小岛", createdAt: 1, readAt: nil, roomID: nil)
        XCTAssertEqual(custom.displayText, custom.text)
        let message = KikiDirectMessage(id: "message", seq: 1, senderID: actor.id, text: original, createdAt: 1)
        let conversation = KikiConversation(id: "conversation", person: actor, lastMessage: message,
                                            unreadCount: 1, canSend: true)
        XCTAssertEqual(KikiInboxEntry(conversation: conversation).localizedPreview, original)
        XCTAssertEqual(actor.bio, "关注了你")
        KikiLanguageSettings.shared.selection = .simplifiedChinese
        XCTAssertEqual(notice.displayText, original)
    }

    func testEnglishLegalRequestIsPublicAndLanguageDoesNotChangeUserContent() async throws {
        let previous = KikiLanguageSettings.shared.selection
        KikiLanguageSettings.shared.selection = .english
        defer { KikiLanguageSettings.shared.selection = previous }
        let canonical = try XCTUnwrap(KikiLegalBundle.bundled)
        let englishData = try XCTUnwrap(KikiLegalEnglish.bundled(canonical: canonical)?.validatedData)
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "en")
            if request.url?.path == "/v1/legal/documents/en" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "X-Kiki-Event-ID"))
                XCTAssertFalse(request.httpShouldHandleCookies)
                return (200, englishData)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
            return (200, try JSONSerialization.data(withJSONObject: ["id":"island", "sdkUserID":"island",
                "name":"完成", "bio":"关注了你", "avatarIndex":0, "notificationsEnabled":false]))
        }
        let receivedEnglish = try await server.client.legalDocumentsEnglish()
        XCTAssertEqual(receivedEnglish, englishData)
        let person = try await server.client.me(token: "fixture")
        XCTAssertEqual(person.name, "完成")
        XCTAssertEqual(person.bio, "关注了你")
        XCTAssertEqual(KikiAPIError.server(429, "请求较多，请稍后重试。").localizedDescription,
                       "Too many requests. Please wait a moment and try again.")
    }

    private func rehashEnglish(_ input: [String: Any]) throws -> Data {
        var value = input; value.removeValue(forKey: "renderingHash")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        value["renderingHash"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testChangingLanguageRedrawsExistingViewWithoutRecreatingItsState() async throws {
        let previous = KikiLanguageSettings.shared.selection
        defer { KikiLanguageSettings.shared.selection = previous }
        KikiLanguageSettings.shared.selection = .simplifiedChinese
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let recorder = LanguageRecorder()
        let host = UIHostingController(rootView: LanguageFixture(recorder: recorder))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(recorder.texts.contains("跟随系统"))
        KikiLanguageSettings.shared.selection = .english
        try await Task.sleep(nanoseconds: 200_000_000)
        window.layoutIfNeeded()
        XCTAssertTrue(recorder.texts.contains("Follow System"), "Static localization helpers must participate in SwiftUI observation")
        XCTAssertEqual(Set(recorder.identities).count, 1, "Changing language must preserve state instead of replacing the view root")
        XCTAssertTrue(window.rootViewController === host)
    }
}

private final class LanguageRecorder {
    var texts: [String] = []
    var identities: [UUID] = []
    func record(_ text: String, identity: UUID) { texts.append(text); identities.append(identity) }
}

private struct LanguageFixture: View {
    let recorder: LanguageRecorder
    @State private var identity = UUID()
    var body: some View {
        let title = KikiL10n.text("跟随系统")
        let _ = recorder.record(title, identity: identity)
        Text(title)
    }
}

private final class NoAccessIdentity: KikiIdentityStoring {
    var accesses = 0
    func read(_ key: String) -> String? { accesses += 1; return nil }
    func write(_ value: String, key: String) throws { accesses += 1 }
    func remove(_ key: String) { accesses += 1 }
}
