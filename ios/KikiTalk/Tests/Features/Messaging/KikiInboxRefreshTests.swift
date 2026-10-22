import Foundation
import XCTest
@testable import KikiTalk

@MainActor
final class KikiInboxRefreshTests: XCTestCase {
    private func fixture() async throws -> InboxRefreshFixture {
        let domain = "KikiInboxRefreshTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        return try await InboxRefreshFixture(defaults: UserDefaults(suiteName: domain)!)
    }

    func testSummaryPollUsesOnlyInboxRoutesAndPublishesAcceptedUnreadTotalsAndNewIncomingMessages() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push
        fixture.responses.notifications(["notice-old"], unread: 2)
        fixture.responses.conversation(messageID: "direct-old", unread: 3)
        let requestStart = fixture.responses.requests.count
        await store.refreshInboxSummary()
        XCTAssertEqual(store.unreadMessageCount, 5)
        XCTAssertNil(push.foregroundNotice, "Each stream's first successful response seeds its baseline")
        XCTAssertEqual(Array(fixture.responses.requests.dropFirst(requestStart)).sorted(),
                       ["/v1/social/conversations", "/v1/social/notifications"])

        fixture.responses.conversation(messageID: "direct-new", unread: 6)
        await store.refreshInboxSummary()
        XCTAssertEqual(store.unreadNotificationCount, 2)
        XCTAssertEqual(store.unreadDirectMessageCount, 6)
        XCTAssertEqual(store.unreadMessageCount, 8, "The tab badge uses server totals, not the visible page's row count")
        XCTAssertEqual(push.foregroundNotice?.candidate, .init(id: "direct-new", kind: .direct(personID: InboxRefreshResponses.peer)))
        push.dismissForegroundNotice()
        await store.refreshInboxSummary()
        XCTAssertNil(push.foregroundNotice, "Repeated accepted pages cannot replay an alert")

        fixture.responses.conversation(messageID: "my-reply", senderID: InboxRefreshResponses.me, unread: 6)
        await store.refreshInboxSummary()
        XCTAssertNil(push.foregroundNotice, "Our own latest message cannot become an incoming-message banner")
        XCTAssertEqual(store.unreadMessageCount, 8)
        let pollRoutes = fixture.responses.requests.dropFirst(requestStart)
        XCTAssertTrue(pollRoutes.allSatisfy { ["/v1/social/notifications", "/v1/social/conversations"].contains($0) },
                      "Foreground inbox polling must not fetch profile or following metadata")
        await store.logout()
    }

    func testUnifiedInboxTotalsAndBulkOperationsPreserveNewUnreadAndDrafts() async throws {
        for clear in [false, true] {
            let fixture = try await fixture()
            let store = fixture.store
            fixture.responses.notifications(["before-notice"], unread: 80)
            fixture.responses.conversation(messageID: "before-direct", unread: 90)
            let page = try await store.socialInbox()
            XCTAssertEqual(page.entries.count, 2)
            XCTAssertEqual(store.unreadMessageCount, 170, "Only one page is visible; total badges still cover every existing item")
            store.updateDirectDraft("确认期间新输入的草稿", personID: InboxRefreshResponses.peer)
            let snapshot = try await store.inboxSnapshot(), requestID = UUID()
            // Model messages arriving after the signed snapshot but before the
            // action's acknowledgement. The authoritative post-write total wins.
            fixture.responses.notifications(["after-notice"], unread: 2)
            fixture.responses.conversation(messageID: "after-direct", unread: 3)
            try await store.mutateInbox(snapshot: snapshot, clear: clear, requestID: requestID)
            XCTAssertEqual(store.unreadNotificationCount, 2)
            XCTAssertEqual(store.unreadDirectMessageCount, 3)
            XCTAssertEqual(store.unreadMessageCount, 5)
            XCTAssertEqual(store.directDrafts[InboxRefreshResponses.peer], "确认期间新输入的草稿")
            XCTAssertEqual(store.directContentRevision, clear ? 1 : 0)
            XCTAssertEqual(store.notificationHistoryRevision, clear ? 1 : 0)
            let body = try XCTUnwrap(fixture.responses.bulkBodies.last)
            XCTAssertEqual(body["snapshot"] as? String, snapshot.snapshot)
            XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), requestID)
            await store.logout()
        }
    }

    func testUncertainBulkClearKeepsItsOriginalSnapshotAndRequestIDForRetry() async throws {
        let fixture = try await fixture(), requestID = UUID()
        let store = fixture.store
        store.updateDirectDraft("尚未发送", personID: InboxRefreshResponses.peer)
        fixture.responses.notifications(["unread-notice"], unread: 7)
        fixture.responses.conversation(messageID: "unread-direct", unread: 8)
        _ = try await store.socialInbox()
        let snapshot = try await store.inboxSnapshot()
        fixture.responses.setBulkStatus(503)
        do { try await store.mutateInbox(snapshot: snapshot, clear: true, requestID: requestID); XCTFail("Uncertain acknowledgement must remain a failure") }
        catch { }
        XCTAssertEqual(store.directContentRevision, 0)
        XCTAssertEqual(store.unreadMessageCount, 15)
        XCTAssertEqual(store.directDrafts[InboxRefreshResponses.peer], "尚未发送")
        fixture.responses.setBulkStatus(200)
        fixture.responses.notifications([], unread: 0)
        fixture.responses.conversation(messageID: "new-after-cutoff", unread: 1)
        try await store.mutateInbox(snapshot: snapshot, clear: true, requestID: requestID)
        XCTAssertEqual(store.unreadMessageCount, 1, "A successful retry must refresh the surviving new message badge")
        XCTAssertEqual(store.directContentRevision, 1)
        XCTAssertEqual(fixture.responses.bulkBodies.count, 2)
        for body in fixture.responses.bulkBodies {
            XCTAssertEqual(body["snapshot"] as? String, snapshot.snapshot)
            XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), requestID)
        }
        await store.logout()
    }

    func testVisibleConversationSuppressesIncomingBannerWhileItsOverlayAllowsIt() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push, owner = UUID()
        fixture.responses.conversation(messageID: "baseline", unread: 1)
        _ = try await store.socialConversations()
        store.setDirectConversationVisibility(owner: owner, personID: InboxRefreshResponses.peer, isVisible: true, hasOverlay: false)
        fixture.responses.conversation(messageID: "visible-message", unread: 2)
        _ = try await store.socialConversations()
        XCTAssertNil(push.foregroundNotice)
        XCTAssertEqual(store.unreadDirectMessageCount, 2, "Suppression affects presentation, not authoritative unread totals")

        store.setDirectConversationVisibility(owner: owner, personID: InboxRefreshResponses.peer, isVisible: true, hasOverlay: true)
        fixture.responses.conversation(messageID: "under-overlay", unread: 3)
        _ = try await store.socialConversations()
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "under-overlay")
        store.setDirectConversationVisibility(owner: owner, personID: InboxRefreshResponses.peer, isVisible: true, hasOverlay: false)
        XCTAssertNil(push.foregroundNotice, "Closing the overlay reveals the conversation and dismisses its banner")
        store.setDirectConversationVisibility(owner: owner, personID: InboxRefreshResponses.peer, isVisible: false, hasOverlay: false)
        _ = try await store.socialConversations()
        XCTAssertNil(push.foregroundNotice, "Leaving the conversation cannot replay its suppressed messages")
        await store.logout()
    }

    func testCoveredParentCannotReplaceTheUncoveredNestedConversationContext() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push
        let parent = UUID(), child = UUID(), parentPerson = "kiki_inboxparent"
        fixture.responses.conversation(messageID: "nested-baseline", unread: 1)
        _ = try await store.socialConversations()
        store.setDirectConversationVisibility(owner: parent, personID: parentPerson, isVisible: true, hasOverlay: true)
        store.setDirectConversationVisibility(owner: child, personID: InboxRefreshResponses.peer, isVisible: true, hasOverlay: false)
        // Scene restoration can deliver a covered parent's callback after its
        // nested sheet. The actual uncovered conversation still owns suppression.
        store.setDirectConversationVisibility(owner: parent, personID: parentPerson, isVisible: true, hasOverlay: true)
        fixture.responses.conversation(messageID: "nested-incoming", unread: 2)
        _ = try await store.socialConversations()
        XCTAssertEqual(store.foregroundNotificationContext.conversationPersonID, InboxRefreshResponses.peer)
        XCTAssertNil(push.foregroundNotice)

        store.setDirectConversationVisibility(owner: child, personID: InboxRefreshResponses.peer, isVisible: false, hasOverlay: false)
        fixture.responses.conversation(messageID: "parent-under-profile", personID: parentPerson, senderID: parentPerson, unread: 3)
        _ = try await store.socialConversations()
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "parent-under-profile", "The remaining parent is still covered by its profile sheet")
        store.setDirectConversationVisibility(owner: parent, personID: parentPerson, isVisible: true, hasOverlay: false)
        XCTAssertNil(push.foregroundNotice)
        fixture.responses.conversation(messageID: "parent-now-visible", personID: parentPerson, senderID: parentPerson, unread: 4)
        _ = try await store.socialConversations()
        XCTAssertNil(push.foregroundNotice)
        await store.logout()
    }

    func testFailedNotificationPollStillRefreshesDirectUnreadAndDoesNotConsumeItsOwnBaseline() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push
        fixture.responses.notifications([], unread: 0, status: 503)
        fixture.responses.conversation(messageID: "direct-during-notification-outage", unread: 4)
        await store.refreshInboxSummary()
        XCTAssertEqual(store.unreadNotificationCount, 0)
        XCTAssertEqual(store.unreadDirectMessageCount, 4)
        XCTAssertNil(push.foregroundNotice)

        fixture.responses.notifications(["first-recovered-notice"], unread: 2)
        _ = try await store.socialNotifications()
        XCTAssertNil(push.foregroundNotice, "Only a successful response seeds the notification baseline")
        fixture.responses.notifications(["second-recovered-notice"], unread: 3)
        _ = try await store.socialNotifications()
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "second-recovered-notice")
        await store.logout()
    }

    func testNotificationAndDirectStreamsHaveIndependentBaselinesAndPaginationDoesNotAlert() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push
        fixture.responses.notifications(["notice-first"], unread: 1)
        _ = try await store.socialNotifications()
        XCTAssertNil(push.foregroundNotice)
        fixture.responses.notifications(["notice-new", "notice-first"], unread: 2)
        _ = try await store.socialNotifications()
        XCTAssertEqual(push.foregroundNotice?.candidate, .init(id: "notice-new", kind: .notifications))
        push.dismissForegroundNotice()

        fixture.responses.conversation(messageID: "first-direct-response", unread: 4)
        _ = try await store.socialConversations()
        XCTAssertNil(push.foregroundNotice, "Loading notifications first cannot consume the direct stream's independent baseline")
        fixture.responses.notifications(["unseen-history-notice"], unread: 2, isPage: true)
        fixture.responses.conversation(messageID: "unseen-history-message", unread: 4, isPage: true)
        _ = try await store.socialNotifications(cursor: "older-notifications")
        _ = try await store.socialConversations(cursor: "older-conversations")
        XCTAssertNil(push.foregroundNotice, "Historical pages are not incoming activity")

        fixture.responses.conversation(messageID: "next-direct-message", unread: 5)
        _ = try await store.socialConversations()
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "next-direct-message")
        await store.logout()
    }

    func testPrivacyAndSessionChangesClearPresentationAndResetBothInboxBaselines() async throws {
        let fixture = try await fixture()
        let store = fixture.store, push = fixture.push
        await store.refreshInboxSummary()
        fixture.responses.notifications(["before-privacy"], unread: 1)
        _ = try await store.socialNotifications()
        XCTAssertNotNil(push.foregroundNotice)
        let firstScope = try XCTUnwrap(push.currentForegroundScope)
        store.socialPolicyChanged(userID: InboxRefreshResponses.peer, blocked: false)
        XCTAssertNil(push.foregroundNotice)
        XCTAssertNotEqual(push.currentForegroundScope, firstScope)
        fixture.responses.notifications(["privacy-baseline"], unread: 2)
        fixture.responses.conversation(messageID: "privacy-direct-baseline", unread: 3)
        await store.refreshInboxSummary()
        XCTAssertNil(push.foregroundNotice)
        fixture.responses.conversation(messageID: "after-privacy", unread: 4)
        _ = try await store.socialConversations()
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "after-privacy")

        let previousSession = store.pushSessionKey
        await store.logout()
        XCTAssertNil(push.foregroundNotice)
        XCTAssertEqual(store.unreadMessageCount, 0)
        try await store.loginWithApple()
        XCTAssertNotEqual(store.pushSessionKey, previousSession)
        store.setAppForeground(true)
        fixture.responses.notifications(["new-session-notice"], unread: 5)
        fixture.responses.conversation(messageID: "new-session-direct", unread: 6)
        await store.refreshInboxSummary()
        XCTAssertNil(push.foregroundNotice)
        XCTAssertEqual(store.unreadMessageCount, 11)
        await store.logout()
    }
}

@MainActor
private final class InboxRefreshFixture {
    let responses = InboxRefreshResponses()
    let server: KikiAPIMockServer
    let store: KikiAppStore
    let push: KikiPushController

    init(defaults: UserDefaults) async throws {
        let documents = try XCTUnwrap(KikiLegalBundle.bundled)
        let responses = self.responses
        server = KikiAPIMockServer { try responses.respond($0, documents: documents) }
        let server = self.server
        let identity = InboxRefreshIdentity()
        let consent = KikiConsentStore(documents: documents, defaults: defaults, identity: identity,
                                      apiProvider: { server.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let createdStore = KikiAppStore(consent: consent, identity: identity, apiProvider: { server.client },
                                       voiceAPIProvider: { server.voiceClient }, rtcProvider: { InboxRefreshRTC() },
                                       appleProvider: { InboxRefreshApple() })
        store = createdStore
        push = KikiPushController(system: InboxRefreshPushSystem(), identity: identity, environment: { nil })
        push.attach(createdStore)
        push.foregroundContext = { [weak createdStore] in createdStore?.foregroundNotificationContext ?? .init(isActive: false) }
        await createdStore.start()
        XCTAssertTrue(createdStore.isAuthenticated)
        createdStore.setAppForeground(true)
    }
}

private final class InboxRefreshResponses: @unchecked Sendable {
    static let me = "kiki_inboxself00"
    static let peer = "kiki_inboxpeer00"
    private let lock = NSLock()
    private var paths: [String] = []
    private var notificationBody = Data(#"{"notifications":[],"unreadCount":0,"nextCursor":null,"retentionDays":30}"#.utf8)
    private var conversationBody = Data(#"{"conversations":[],"unreadCount":0,"nextCursor":null}"#.utf8)
    private var notificationPage: Data?
    private var conversationPage: Data?
    private var notificationStatus = 200
    private var bulkStatus = 200
    private var bulkRequests: [[String: Any]] = []
    var bulkBodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bulkRequests }
    func setBulkStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; bulkStatus = value }
    var requests: [String] { lock.lock(); defer { lock.unlock() }; return paths }

    func notifications(_ ids: [String], unread: Int, isPage: Bool = false, status: Int = 200) {
        let notices: [[String: Any]] = ids.enumerated().map { offset, id in
            ["id": id, "kind": "follow", "actor": Self.person, "text": "收到一条互动消息", "createdAt": Date().timeIntervalSince1970 - Double(offset),
             "readAt": NSNull(), "roomID": NSNull(), "momentID": NSNull(), "seq": ids.count - offset]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["notifications": notices, "unreadCount": unread, "nextCursor": NSNull(), "retentionDays": 30])
        lock.lock(); defer { lock.unlock() }
        if isPage { notificationPage = data } else { notificationBody = data; notificationStatus = status }
    }

    func conversation(messageID: String, personID: String = InboxRefreshResponses.peer, senderID: String = InboxRefreshResponses.peer, unread: Int, isPage: Bool = false) {
        let message: [String: Any] = ["id": messageID, "seq": 1, "senderID": senderID, "text": "新的私信内容", "createdAt": Date().timeIntervalSince1970]
        var person = Self.person; person["id"] = personID
        let conversation: [String: Any] = ["id": "inbox-conversation-" + personID, "person": person, "lastMessage": message, "unreadCount": unread, "canSend": true]
        let data = try! JSONSerialization.data(withJSONObject: ["conversations": [conversation], "unreadCount": unread, "nextCursor": NSNull()])
        lock.lock(); defer { lock.unlock() }
        if isPage { conversationPage = data } else { conversationBody = data }
    }

    func respond(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data) {
        let path = try XCTUnwrap(request.url?.path)
        lock.lock(); paths.append(path)
        let isPage = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
        let notifications = isPage ? notificationPage ?? notificationBody : notificationBody
        let status = isPage ? 200 : notificationStatus
        let conversations = isPage ? conversationPage ?? conversationBody : conversationBody
        let currentBulkStatus = bulkStatus
        if ["/v1/social/inbox/read", "/v1/social/inbox/clear"].contains(path) { bulkRequests.append(try requestBody(request)) }
        lock.unlock()
        let user: [String: Any] = ["id": Self.me, "sdkUserID": Self.me, "name": "测试昵称", "bio": "", "avatarIndex": 0, "notificationsEnabled": true, "needsNickname": false]
        let sdk: [String: Any] = ["provider": "livekit", "serverURL": "wss://furby.top", "userID": Self.me, "expiresAt": 2_000_000_000]
        let versions: [String: Any] = ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash]
        let body: [String: Any]
        switch path {
        case "/v1/social/inbox":
            let noticePage = try XCTUnwrap(JSONSerialization.jsonObject(with: notifications) as? [String: Any])
            let directPage = try XCTUnwrap(JSONSerialization.jsonObject(with: conversations) as? [String: Any])
            let notices = (noticePage["notifications"] as? [[String: Any]] ?? []).map { ["kind": "notification", "notification": $0] as [String: Any] }
            let direct = (directPage["conversations"] as? [[String: Any]] ?? []).map { ["kind": "direct", "conversation": $0] as [String: Any] }
            body = ["entries": notices + direct, "nextCursor": NSNull(),
                    "unreadNotificationCount": noticePage["unreadCount"] ?? 0, "unreadDirectMessageCount": directPage["unreadCount"] ?? 0]
        case "/v1/social/inbox/snapshot": body = ["snapshot": "signed-owner-watermarks"]
        case "/v1/social/inbox/read", "/v1/social/inbox/clear":
            return currentBulkStatus == 200 ? (200, Data(#"{"ok":true}"#.utf8)) : (currentBulkStatus, Data(#"{"detail":"操作结果未确认"}"#.utf8))
        case "/v1/social/notifications":
            return status == 200 ? (200, notifications) : (status, Data(#"{"detail":"互动通知服务暂不可用"}"#.utf8))
        case "/v1/social/conversations": return (200, conversations)
        case "/v1/me/legal-consent":
            var receipt = versions; receipt["acceptedAt"] = 1_792_180_000; receipt["withdrawnAt"] = NSNull()
            body = ["requiredVersions": versions, "requiresAcceptance": false, "legalConsent": receipt]
        case "/v1/auth/refresh": body = ["user": user]
        case "/v1/voice/session": body = ["token": "inbox-voice-session", "expiresAt": 2_000_000_000, "user": user, "sdk": sdk]
        case "/v1/auth/apple/challenge": body = ["challengeID": "inbox-challenge", "nonce": "inbox-nonce", "expiresAt": 2_000_000_000]
        case "/v1/auth/apple": body = ["token": "inbox-new-account-session", "user": user]
        case "/v1/auth/logout": body = ["ok": true]
        case "/v1/rooms": body = ["rooms": []]
        case "/v1/library": body = ["favorites": [], "recents": [], "created": []]
        case "/v1/push/status": body = ["enabled": true, "registered": false, "badgeCount": 0, "accountTag": "inbox-fixture-account"]
        default:
            if path.hasPrefix("/v1/push/devices/") { body = ["ok": true] }
            else { XCTFail("Unexpected inbox refresh request: \(path)"); body = ["detail": "Unexpected route"]; return (404, try JSONSerialization.data(withJSONObject: body)) }
        }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }

    private static var person: [String: Any] {
        ["id": peer, "name": "消息好友", "bio": "", "avatarIndex": 1, "following": true, "followsYou": true,
         "mutual": true, "followingCount": 1, "followerCount": 1]
    }
}

private final class InboxRefreshIdentity: KikiIdentityStoring {
    private var values = ["sessionToken": "inbox-account-session", "appleSubject": "inbox-apple-subject", "appleSessionVersion": "2"]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

@MainActor
private final class InboxRefreshRTC: KikiRTCServicing {
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?
    var isLoggedIn = false
    var isPresentingRoom = false
    var currentSDKRoomID: String?
    func isCurrentRoom(_ roomID: String) -> Bool { currentSDKRoomID == roomID }
    func requireNoActiveRoom() throws { }
    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws { isLoggedIn = true }
    func logout() async { isLoggedIn = false }
    func stopMediaForPrivacy() { isPresentingRoom = false; currentSDKRoomID = nil }
    func logoutForPrivacy() async throws { await logout() }
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws { }
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws { }
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws { }
}

@MainActor
private final class InboxRefreshApple: KikiAppleAuthorizing {
    func authorize(nonce: String, state: String) async throws -> KikiAppleCredential {
        .init(subject: "inbox-apple-subject", identityToken: "inbox-apple-token", authorizationCode: "inbox-apple-code")
    }
    func credentialState(subject: String) async throws -> KikiAppleCredentialState { .authorized }
    func cancel() { }
}

@MainActor
private final class InboxRefreshPushSystem: KikiPushSystem {
    func permission() async -> KikiPushPermission { .denied }
    func requestPermission() async throws { }
    func register() { }
    func unregister() { }
    func setBadge(_ count: Int) { }
    func clearNotifications() { }
}
