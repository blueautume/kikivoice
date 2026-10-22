import CoreFoundation
import Foundation
import XCTest
@testable import KikiTalk

final class KikiInboxActionsTests: XCTestCase {
    func testCancelledInboxLoadsAndMutationsRemainCancellationInsteadOfUserFacingFailures() async throws {
        let server = KikiAPIMockServer { _ in throw URLError(.cancelled) }
        let operations: [() async throws -> Void] = [
            { _ = try await server.client.socialNotifications(cursor: nil, token: "account-inbox-only") },
            { _ = try await server.client.socialConversations(cursor: nil, token: "account-inbox-only") },
            { try await server.client.socialSetConversationPinned("kiki_target0000", pinned: true, requestID: UUID(), token: "account-inbox-only") },
            { try await server.client.socialClearConversation("kiki_target0000", throughMessageID: UUID().uuidString, requestID: UUID(), token: "account-inbox-only") }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("A cancelled URLSession request must not succeed") }
            catch is CancellationError { }
            catch { XCTFail("Inbox UI catches CancellationError; transport cancellation must not become \(error)") }
            XCTAssertFalse(Task.isCancelled, "The API must normalize transport cancellation even when its caller was not cancelled")
        }
    }

    func testRealInboxLoadAndMutationFailuresStillReachTheCaller() async throws {
        let message = "消息服务暂不可用"
        let server = KikiAPIMockServer { _ in (503, try inboxActionsJSON(["detail": message])) }
        let operations: [() async throws -> Void] = [
            { _ = try await server.client.socialNotifications(cursor: nil, token: "account-inbox-only") },
            { _ = try await server.client.socialConversations(cursor: nil, token: "account-inbox-only") },
            { try await server.client.socialSetConversationPinned("kiki_target0000", pinned: true, requestID: UUID(), token: "account-inbox-only") },
            { try await server.client.socialClearConversation("kiki_target0000", throughMessageID: UUID().uuidString, requestID: UUID(), token: "account-inbox-only") }
        ]
        for operation in operations {
            do { try await operation(); XCTFail("A genuine service failure must remain visible to the inbox") }
            catch let error as KikiAPIError {
                guard case .server(let status, let detail) = error else { return XCTFail("Unexpected inbox error: \(error)") }
                XCTAssertEqual(status, 503)
                XCTAssertEqual(detail, message)
                XCTAssertEqual(error.localizedDescription, message)
            } catch { XCTFail("Unexpected inbox error: \(error)") }
        }
    }

    func testConversationPinAndUnpinUseAccountBearerStrictBooleanAndStableRetryID() async throws {
        for pinned in [true, false] {
            let nonce = UUID()
            let calls = KikiInboxActionsRequestLog()
            let server = KikiAPIMockServer { request in
                try self.assertMutation(request, path: "/v1/social/conversations/kiki_target0000/pin", method: "PUT")
                let body = try requestBody(request)
                XCTAssertEqual(Set(body.keys), ["requestID", "pinned"])
                XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), nonce)
                self.assertJSONBoolean(body["pinned"], equals: pinned)
                calls.append(request)
                return (200, try inboxActionsJSON(["ok": true]))
            }
            try await server.client.socialSetConversationPinned("kiki_target0000", pinned: pinned, requestID: nonce, token: "account-inbox-only")
            try await server.client.socialSetConversationPinned("kiki_target0000", pinned: pinned, requestID: nonce, token: "account-inbox-only")
            XCTAssertEqual(calls.requests.count, 2)
            XCTAssertEqual(try requestBody(calls.requests[0])["requestID"] as? String,
                           try requestBody(calls.requests[1])["requestID"] as? String)
        }
    }

    func testClearConversationSendsOnlyViewedMessageHighWatermarkAndStableRetryID() async throws {
        let nonce = UUID()
        let through = UUID().uuidString.lowercased()
        let calls = KikiInboxActionsRequestLog()
        let server = KikiAPIMockServer { request in
            try self.assertMutation(request, path: "/v1/social/conversations/kiki_target0000/clear", method: "POST")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["requestID", "throughMessageID"])
            XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), nonce)
            XCTAssertEqual(body["throughMessageID"] as? String, through)
            XCTAssertNil(body["senderID"])
            XCTAssertNil(body["userID"])
            XCTAssertNil(body["deleteForEveryone"])
            calls.append(request)
            return (200, try inboxActionsJSON(["ok": true]))
        }
        try await server.client.socialClearConversation("kiki_target0000", throughMessageID: through, requestID: nonce, token: "account-inbox-only")
        try await server.client.socialClearConversation("kiki_target0000", throughMessageID: through, requestID: nonce, token: "account-inbox-only")
        XCTAssertEqual(calls.requests.count, 2)
    }

    func testAggregateNotificationPinAndUnpinHaveIndependentAccountRoutes() async throws {
        for pinned in [true, false] {
            let nonce = UUID()
            let calls = KikiInboxActionsRequestLog()
            let server = KikiAPIMockServer { request in
                try self.assertMutation(request, path: "/v1/social/notifications/pin", method: "PUT")
                let body = try requestBody(request)
                XCTAssertEqual(Set(body.keys), ["requestID", "pinned"])
                XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), nonce)
                self.assertJSONBoolean(body["pinned"], equals: pinned)
                calls.append(request)
                return (200, try inboxActionsJSON(["ok": true]))
            }
            try await server.client.socialSetNotificationsPinned(pinned: pinned, requestID: nonce, token: "account-inbox-only")
            try await server.client.socialSetNotificationsPinned(pinned: pinned, requestID: nonce, token: "account-inbox-only")
            XCTAssertEqual(calls.requests.count, 2)
        }
    }

    func testClearAggregateNotificationsSendsViewedNotificationAndStableRetryID() async throws {
        let nonce = UUID()
        let through = UUID().uuidString.lowercased()
        let calls = KikiInboxActionsRequestLog()
        let server = KikiAPIMockServer { request in
            try self.assertMutation(request, path: "/v1/social/notifications/clear", method: "POST")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["requestID", "throughNotificationID"])
            XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), nonce)
            XCTAssertEqual(body["throughNotificationID"] as? String, through)
            calls.append(request)
            return (200, try inboxActionsJSON(["ok": true]))
        }
        try await server.client.socialClearNotifications(throughNotificationID: through, requestID: nonce, token: "account-inbox-only")
        try await server.client.socialClearNotifications(throughNotificationID: through, requestID: nonce, token: "account-inbox-only")
        XCTAssertEqual(calls.requests.count, 2)
    }

    func testConversationActionsRejectInvalidPersonBeforeAttachingBearerOrSendingRequest() async throws {
        let server = KikiAPIMockServer { _ in
            XCTFail("Invalid account identifiers must fail before the network")
            return (500, Data())
        }
        let through = UUID().uuidString
        for personID in ["", "../me", "kiki_short", "kiki_target0000/messages", "kiki_target0000?admin=true", "kiki_用户用户用户用户"] {
            await assertSecurityFailure {
                try await server.client.socialSetConversationPinned(personID, pinned: true, requestID: UUID(), token: "private")
            }
            await assertSecurityFailure {
                try await server.client.socialClearConversation(personID, throughMessageID: through, requestID: UUID(), token: "private")
            }
        }
    }

    func testClearActionsRejectInvalidContentUUIDBeforeNetwork() async throws {
        let server = KikiAPIMockServer { _ in
            XCTFail("Invalid high-watermark content identifiers must not be sent")
            return (500, Data())
        }
        for invalid in ["", "not-a-uuid", "../messages", UUID().uuidString + "?all=true", "12345678-1234-1234-1234-123456789xyy"] {
            await assertSecurityFailure {
                try await server.client.socialClearConversation("kiki_target0000", throughMessageID: invalid, requestID: UUID(), token: "private")
            }
            await assertSecurityFailure {
                try await server.client.socialClearNotifications(throughNotificationID: invalid, requestID: UUID(), token: "private")
            }
        }
    }

    func testInboxMutationDoesNotTurnUnauthorizedOrMalformedAcknowledgementIntoSuccess() async throws {
        let unauthorized = KikiAPIMockServer { _ in (401, try inboxActionsJSON(["detail": "登录已过期"])) }
        do {
            try await unauthorized.client.socialClearConversation("kiki_target0000", throughMessageID: UUID().uuidString,
                                                                   requestID: UUID(), token: "account-inbox-only")
            XCTFail("Deletion must not be acknowledged after authentication failure")
        } catch let error as KikiAPIError { XCTAssertTrue(error.isUnauthorized) }
        let malformed = KikiAPIMockServer { _ in (200, try inboxActionsJSON([:])) }
        do {
            try await malformed.client.socialSetNotificationsPinned(pinned: true, requestID: UUID(), token: "account-inbox-only")
            XCTFail("Missing acknowledgement must fail")
        } catch let error as KikiAPIError {
            guard case .invalidResponse = error else { return XCTFail("Expected acknowledgement schema failure") }
        }
    }

    func testConversationAndNotificationModelsDecodePreviousServerSchemaWithSafeDefaults() throws {
        let conversation = try decode(KikiConversation.self, inboxActionsConversation(id: "old", time: 100))
        XCTAssertFalse(conversation.isPinned)
        let notifications = try decode(KikiNotificationsPage.self, [
            "notifications": [], "unreadCount": 0, "nextCursor": NSNull(), "retentionDays": 30
        ])
        XCTAssertFalse(notifications.inboxState.isPinned)
        XCTAssertFalse(notifications.inboxState.isHidden)
        XCTAssertNil(notifications.inboxState.throughNotificationID)
        XCTAssertEqual(notifications.inboxState.clearedThroughSeq, 0)
        let messages = try decode(KikiDirectMessagesPage.self, [
            "conversationID": "old-conversation", "messages": [], "nextCursor": NSNull(), "canSend": true, "unreadCount": 0
        ])
        XCTAssertEqual(messages.clearedThroughSeq, 0)
        XCTAssertTrue(messages.messages.isEmpty)
    }

    func testUpdatedSchemasPreserveAuthoritativePinHiddenAndClearState() throws {
        var value = inboxActionsConversation(id: "pinned", time: 100)
        value["isPinned"] = true
        XCTAssertTrue(try decode(KikiConversation.self, value).isPinned)
        let through = UUID().uuidString
        let notifications = try decode(KikiNotificationsPage.self, [
            "notifications": [], "unreadCount": 0, "nextCursor": NSNull(), "retentionDays": 30,
            "inboxState": ["isPinned": false, "isHidden": true, "throughNotificationID": through, "clearedThroughSeq": 42]
        ])
        XCTAssertTrue(notifications.inboxState.isHidden)
        XCTAssertEqual(notifications.inboxState.throughNotificationID, through)
        XCTAssertEqual(notifications.inboxState.clearedThroughSeq, 42)
        let messages = try decode(KikiDirectMessagesPage.self, [
            "conversationID": "cleared-conversation", "messages": [], "nextCursor": NSNull(), "canSend": true,
            "unreadCount": 0, "clearedThroughSeq": 17
        ])
        XCTAssertEqual(messages.clearedThroughSeq, 17)
    }

    func testPinnedConversationsSortBeforeRecentUnpinnedEntriesIncludingAggregateNotifications() throws {
        var oldPinned = inboxActionsConversation(id: "old-pinned", time: 100)
        oldPinned["isPinned"] = true
        let conversations = try [inboxActionsConversation(id: "newer", time: 500), oldPinned]
            .map { try decode(KikiConversation.self, $0) }
        let notice = inboxActionsNotice(id: "latest-notice", time: 400)
        let normal = KikiInboxEntry.merged(conversations: conversations, notifications: [notice], notificationUnreadCount: 6)
        XCTAssertEqual(normal.map(\.id), ["direct:old-pinned", "direct:newer", "notifications"])
        let withPinnedNotice = KikiInboxEntry.merged(conversations: conversations, notifications: [notice], notificationUnreadCount: 6,
            notificationState: KikiNotificationInboxState(isPinned: true))
        XCTAssertEqual(withPinnedNotice.map(\.id), ["notifications", "direct:old-pinned", "direct:newer"])
        XCTAssertTrue(withPinnedNotice[0].isPinned)
        XCTAssertEqual(withPinnedNotice[0].unreadCount, 6)
    }

    func testClearedAggregateIsHiddenUntilNewVisibleNotificationsReturn() throws {
        let conversation = try decode(KikiConversation.self, inboxActionsConversation(id: "chat", time: 300))
        let hidden = KikiNotificationInboxState(isHidden: true, clearedThroughSeq: 30)
        let cleared = KikiInboxEntry.merged(conversations: [conversation], notifications: [], notificationUnreadCount: 0, notificationState: hidden)
        XCTAssertEqual(cleared.map(\.id), ["direct:chat"])
        let fresh = KikiInboxEntry.merged(conversations: [conversation], notifications: [inboxActionsNotice(id: "new-visible", time: 500, seq: 31)],
            notificationUnreadCount: 2, notificationState: hidden)
        XCTAssertEqual(fresh.map(\.id), ["notifications", "direct:chat"])
        XCTAssertEqual(fresh[0].preview, "new-visible 的通知")
        XCTAssertEqual(fresh[0].unreadCount, 2)
    }

    func testTimelineClearWatermarkRemovesOlderMessagesFromBothCachedAndFreshPages() {
        let now = 1_800_000_000.0
        let oldCache = [message("a", seq: 1, at: now - 100), message("b", seq: 4, at: now - 80), message("keep", seq: 7, at: now - 60)]
        let staleInFlightPage = [message("older-page", seq: 2, at: now - 90), message("at-watermark", seq: 5, at: now - 70), message("new", seq: 8, at: now - 20)]
        let ownTimeline = KikiDirectTimeline.merged(existing: oldCache, fresh: staleInFlightPage, clearedThroughSeq: 5, now: now)
        XCTAssertEqual(ownTimeline.map(\.id), ["keep", "new"])
        XCTAssertEqual(ownTimeline.map(\.seq), [7, 8])
        let otherSide = KikiDirectTimeline.merged(existing: oldCache, fresh: staleInFlightPage, clearedThroughSeq: 0, now: now)
        XCTAssertEqual(otherSide.map(\.seq), [1, 2, 5, 8], "Fresh visible history is authoritative within its sequence range")
        XCTAssertEqual(oldCache.map(\.seq), [1, 4, 7], "An account-specific clear fence must not mutate the shared input messages")
    }

    func testLatestRefreshPreservesPreviouslyLoadedHistoryButFreshContentWinsAtSameSequence() {
        let now = 1_800_000_000.0
        let older = message("older", seq: 3, at: now - 300)
        let cached = message("same", seq: 6, text: "缓存内容", at: now - 100)
        let fresh = message("same", seq: 6, text: "服务端内容", at: now - 100)
        let result = KikiDirectTimeline.merged(existing: [cached, older], fresh: [message("new", seq: 7, at: now - 20), fresh], clearedThroughSeq: 0, now: now)
        XCTAssertEqual(result.map(\.seq), [3, 6, 7])
        XCTAssertEqual(result.map(\.id), ["older", "same", "new"])
        XCTAssertEqual(result[1].text, "服务端内容")
    }

    func testTimelineDropsThirtyDayExpiredCacheAndDeduplicatesOverlappingPagesBySequence() {
        let now = 1_800_000_000.0
        let day = 86_400.0
        let expired = message("expired", seq: 1, at: now - 31 * day)
        let history = message("history", seq: 2, at: now - 29 * day)
        let overlap = message("overlap", seq: 3, at: now - 100)
        let duplicateSequence = message("duplicate-overlap", seq: 3, at: now - 100)
        let result = KikiDirectTimeline.merged(existing: [expired, history, overlap, duplicateSequence],
            fresh: [expired, overlap, message("new", seq: 4, at: now - 20)], clearedThroughSeq: 0, now: now)
        XCTAssertEqual(result.map(\.seq), [2, 3, 4])
        XCTAssertEqual(result.filter { $0.seq == 3 }.count, 1)
        XCTAssertFalse(result.contains { $0.id == "expired" })
    }

    func testAuthoritativeEmptyLatestPageRemovesCachedModeratedMessages() {
        let now = 1_800_000_000.0
        let cached = [message("removed-by-moderation", seq: 5, at: now - 20)]
        XCTAssertTrue(KikiDirectTimeline.merged(existing: cached, fresh: [], clearedThroughSeq: 0, now: now).isEmpty)
        XCTAssertTrue(KikiDirectTimeline.merged(existing: cached, fresh: cached, clearedThroughSeq: 5, now: now).isEmpty)
    }

    func testConversationPaginationTransportsOpaqueCursorLiterallyAndPreservesUpdatedSchema() async throws {
        let cursor = "opaque.pin-order+/=v2:&signature"
        let next = "next.server-cursor+/="
        let calls = KikiInboxActionsRequestLog()
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/social/conversations")
            XCTAssertFalse(try XCTUnwrap(request.url?.host).hasPrefix("voice-"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-inbox-only")
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first { $0.name == "cursor" }?.value, cursor)
            XCTAssertEqual(components.queryItems?.first { $0.name == "limit" }?.value, "20")
            calls.append(request)
            var value = inboxActionsConversation(id: "pinned", time: 100)
            value["isPinned"] = true
            return (200, try inboxActionsJSON(["conversations": [value], "nextCursor": next, "unreadCount": 4]))
        }
        let first = try await server.client.socialConversations(cursor: cursor, token: "account-inbox-only")
        let retry = try await server.client.socialConversations(cursor: cursor, token: "account-inbox-only")
        XCTAssertEqual(calls.requests.count, 2)
        XCTAssertEqual(first.nextCursor, next)
        XCTAssertEqual(retry.nextCursor, next)
        XCTAssertEqual(first.conversations, retry.conversations)
        XCTAssertTrue(try XCTUnwrap(first.conversations.first).isPinned)
    }

    private func assertMutation(_ request: URLRequest, path: String, method: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(request.url?.path, path, file: file, line: line)
        XCTAssertNil(request.url?.query, file: file, line: line)
        XCTAssertEqual(request.httpMethod, method, file: file, line: line)
        XCTAssertFalse(try XCTUnwrap(request.url?.host).hasPrefix("voice-"), file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-inbox-only", file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json", file: file, line: line)
    }

    private func assertJSONBoolean(_ value: Any?, equals expected: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let number = value as? NSNumber else { return XCTFail("Expected a JSON boolean", file: file, line: line) }
        XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID(), "The strict API rejects numeric or string booleans", file: file, line: line)
        XCTAssertEqual(number.boolValue, expected, file: file, line: line)
    }

    private func assertSecurityFailure(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected local identifier validation", file: file, line: line) }
        catch let error as KikiAPIError {
            guard case .security = error else { return XCTFail("Expected security validation, received \(error)", file: file, line: line) }
        } catch { XCTFail("Unexpected error \(error)", file: file, line: line) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: inboxActionsJSON(value))
    }

    private func message(_ id: String, seq: Int, text: String = "消息", at time: Double) -> KikiDirectMessage {
        KikiDirectMessage(id: id, seq: seq, senderID: "kiki_target0000", text: text, createdAt: time)
    }
}

private func inboxActionsJSON(_ value: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
}

private func inboxActionsConversation(id: String, time: Double) -> [String: Any] {
    ["id": id,
     "person": ["id": "kiki_target0000", "name": "小岛", "bio": "", "avatarIndex": 4,
                "following": true, "followsYou": true, "mutual": true, "followingCount": 1, "followerCount": 1],
     "lastMessage": ["id": "message-" + id, "seq": 1, "senderID": "kiki_target0000", "text": "晚上好", "createdAt": time],
     "unreadCount": 4, "canSend": true]
}

private func inboxActionsNotice(id: String, time: Double, seq: Int = 0) -> KikiSocialNotification {
    KikiSocialNotification(id: id, kind: "follow", actor: nil, text: id + " 的通知", createdAt: time, readAt: nil, roomID: nil, momentID: nil, seq: seq)
}

private final class KikiInboxActionsRequestLog {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    func append(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }; storage.append(request)
    }
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return storage
    }
}
