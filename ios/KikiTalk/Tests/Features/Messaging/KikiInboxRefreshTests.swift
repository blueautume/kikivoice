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
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "direct-new")
        XCTAssertEqual(push.foregroundNotice?.candidate.kind, .direct(personID: InboxRefreshResponses.peer))
        XCTAssertEqual(push.foregroundNotice?.title, "消息好友")
        XCTAssertEqual(push.foregroundNotice?.message, "新的私信内容")
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

    func testMomentNotificationsSeedThenInvalidateReadInteractionsWithoutPushOrAccountAlerts() async throws {
        let fixture = try await fixture(), store = fixture.store
        try await store.setNotificationsEnabled(false)
        store.pushController = nil
        let initial = store.momentContentRevision
        fixture.responses.momentNotifications([.init(id: "old-comment", seq: 10)], status: 503)
        do { _ = try await store.socialNotifications(); XCTFail("Failed snapshots must not establish a baseline") } catch { }
        fixture.responses.momentNotifications([.init(id: "old-comment", seq: 10)])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 1, "A first snapshot may contain an interaction newer than the initial feed GET")
        fixture.responses.momentNotifications([.init(id: "new-comment", seq: 11, kind: "comment", read: true),
                                               .init(id: "new-like", seq: 12, kind: "like", read: true)])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.unreadNotificationCount, 0)
        XCTAssertEqual(store.momentContentRevision, initial + 2, "Read interactions still invalidate content; one accepted page produces one revision")
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 2)
        fixture.responses.momentNotifications([.init(id: "new-follow", seq: 13, kind: "follow", momentID: nil),
                                               .init(id: "invalid-moment", seq: 14, momentID: "untrusted-id")])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 2)
        fixture.responses.momentNotifications([.init(id: "historical-page", seq: 100)], isPage: true)
        _ = try await store.socialNotifications(cursor: "older-page")
        XCTAssertEqual(store.momentContentRevision, initial + 2, "Loading history must not invalidate or advance the live high-water mark")
        fixture.responses.momentNotifications([.init(id: "same-second-next", seq: 15, read: true)])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 3, "Sequence order detects same-second events even after a historical page")
        await store.logout()
    }

    func testFirstNotificationSnapshotInvalidatesAnEarlierFeedWithoutReplayingOldBanner() async throws {
        let fixture = try await fixture(), store = fixture.store, push = fixture.push
        fixture.responses.setMomentFeedCommentCount(0)
        let earlierFeed = try await store.socialMoments(kind: .all)
        XCTAssertEqual(earlierFeed.moments.first?.commentCount, 0)
        XCTAssertTrue(earlierFeed.moments.first?.commentPreview.isEmpty == true)
        let initial = store.momentContentRevision

        // The first inbox snapshot arrives after the feed GET. Treating it as
        // a completely silent content baseline would leave this comment stale.
        fixture.responses.setMomentFeedCommentCount(1)
        fixture.responses.momentNotifications([.init(id: "first-system-interaction", seq: 1, read: true)])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 1)
        XCTAssertNil(push.foregroundNotice, "A content refresh does not turn the initial inbox snapshot into a banner")
        let refreshedFeed = try await store.socialMoments(kind: .all)
        XCTAssertEqual(refreshedFeed.moments.first?.commentCount, 1)
        XCTAssertEqual(refreshedFeed.moments.first?.commentPreview.first?.text, "远端新增评论")
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, initial + 1, "The same first-snapshot sequence cannot trigger another refresh")
        XCTAssertFalse(fixture.responses.requests.contains { $0.hasPrefix("/v1/social/moments/") }, "Refreshing uses the ordinary permission-checked feed, with no detail-page round trip")
        await store.logout()
    }

    func testLegacyMomentNotificationDeduplicationSurvivesPrivacyAndSessionRebaselines() async throws {
        let fixture = try await fixture(), store = fixture.store
        fixture.responses.momentNotifications([.init(id: "legacy-old")])
        _ = try await store.socialNotifications()
        let baseline = store.momentContentRevision
        fixture.responses.momentNotifications([.init(id: "legacy-new", read: true), .init(id: "legacy-old")])
        _ = try await store.socialNotifications()
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, baseline + 1)
        store.socialPolicyChanged(userID: InboxRefreshResponses.peer, blocked: true)
        let afterPrivacy = store.momentContentRevision
        XCTAssertEqual(afterPrivacy, baseline + 2, "Privacy resets invalidate old view writes immediately")
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, afterPrivacy + 1, "The new privacy scope requests one safe content refresh without replaying a banner")
        await store.logout()
        let afterLogout = store.momentContentRevision
        XCTAssertGreaterThan(afterLogout, afterPrivacy)
        try await store.loginWithApple()
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, afterLogout + 1)
        fixture.responses.momentNotifications([.init(id: "next-session-comment", seq: 20)])
        _ = try await store.socialNotifications()
        XCTAssertEqual(store.momentContentRevision, afterLogout + 2)
        await store.logout()
    }

    func testLateMomentNotificationResponseCannotCrossPrivacyOrSessionScope() async throws {
        for switchSession in [false, true] {
            let fixture = try await fixture(), store = fixture.store
            fixture.responses.momentNotifications([.init(id: "baseline", seq: 10)])
            _ = try await store.socialNotifications()
            fixture.responses.momentNotifications([.init(id: "late-before-boundary", seq: 11)])
            let arrived = expectation(description: "old notification response is held")
            let gate = fixture.responses.holdNextResponse(path: "/v1/social/notifications") { arrived.fulfill() }
            defer { gate.signal() }
            let old = Task { try await store.socialNotifications() }
            await fulfillment(of: [arrived], timeout: 2)
            if switchSession { await store.logout(); try await store.loginWithApple() }
            else { store.socialPolicyChanged(userID: InboxRefreshResponses.peer, blocked: true) }
            let boundary = store.momentContentRevision
            fixture.responses.momentNotifications([.init(id: "new-scope-baseline", seq: 100)])
            _ = try await store.socialNotifications()
            gate.signal()
            if case .success = await old.result { XCTFail("The old response must fail its account/privacy gate") }
            XCTAssertEqual(store.momentContentRevision, boundary + 1)
            fixture.responses.momentNotifications([.init(id: "new-scope-event", seq: 101)])
            _ = try await store.socialNotifications()
            XCTAssertEqual(store.momentContentRevision, boundary + 2)
            await store.logout()
        }
    }

    func testVerifiedForegroundPushInvalidatesMomentsWithoutReadingOpaqueContentOrFetchingDetails() async throws {
        let fixture = try await fixture(), store = fixture.store, push = fixture.push
        await push.refresh()
        let initial = store.momentContentRevision, directInitial = store.directContentRevision
        let wrong = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "another-account",
                                                       "momentID": InboxRefreshResponses.momentID, "body": "untrusted text"]))
        push.receiveForeground(wrong)
        push.receiveForeground(nil)
        XCTAssertEqual(store.momentContentRevision, initial)
        let valid = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "inbox-fixture-account",
                                                       "momentID": "forged-moment", "body": "untrusted text"]))
        push.receiveForeground(valid)
        let deadline = Date().addingTimeInterval(2)
        while store.momentContentRevision == initial, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.momentContentRevision, initial + 1, "A verified APNs hint covers empty/cleared notification snapshots too")
        XCTAssertEqual(store.directContentRevision, directInitial + 1, "Existing direct-chat invalidation remains intact")
        XCTAssertFalse(fixture.responses.requests.contains { $0.hasPrefix("/v1/social/moments") }, "The hint must not fetch an untrusted target or bypass feed permissions")
        let oldScope = try XCTUnwrap(push.currentForegroundScope)
        store.socialPolicyChanged(userID: InboxRefreshResponses.peer, blocked: true)
        let boundary = store.momentContentRevision
        store.momentContentPushReceived(scope: oldScope)
        XCTAssertEqual(store.momentContentRevision, boundary)
        await store.logout()
    }

    func testOnlyConfirmedCurrentScopeMomentMutationsInvalidateContent() async throws {
        let fixture = try await fixture(), store = fixture.store
        let moment = try JSONDecoder().decode(KikiMoment.self, from: JSONSerialization.data(withJSONObject: InboxRefreshResponses.moment))
        let initial = store.momentContentRevision
        _ = try await store.publishMoment(requestID: UUID(), text: "动态", mediaIDs: [])
        XCTAssertEqual(store.momentContentRevision, initial + 1)
        _ = try await store.likeMoment(moment)
        XCTAssertEqual(store.momentContentRevision, initial + 2)
        _ = try await store.commentMoment(moment.id, text: "评论", requestID: UUID())
        XCTAssertEqual(store.momentContentRevision, initial + 3)
        try await store.deleteComment(InboxRefreshResponses.commentID)
        XCTAssertEqual(store.momentContentRevision, initial + 4)
        try await store.deleteMoment(moment.id)
        XCTAssertEqual(store.momentContentRevision, initial + 5)
        fixture.responses.setMomentMutationStatus(503)
        do { _ = try await store.publishMoment(requestID: UUID(), text: "失败", mediaIDs: []); XCTFail("Failed publish accepted") } catch { }
        do { _ = try await store.likeMoment(moment); XCTFail("Failed like accepted") } catch { }
        do { _ = try await store.commentMoment(moment.id, text: "失败", requestID: UUID()); XCTFail("Failed comment accepted") } catch { }
        do { try await store.deleteComment(InboxRefreshResponses.commentID); XCTFail("Failed comment deletion accepted") } catch { }
        do { try await store.deleteMoment(moment.id); XCTFail("Failed moment deletion accepted") } catch { }
        XCTAssertEqual(store.momentContentRevision, initial + 5)
        fixture.responses.setMomentMutationStatus(200)
        let arrived = expectation(description: "comment confirmation is waiting")
        let gate = fixture.responses.holdNextResponse(path: "/v1/social/moments/" + moment.id + "/comments") { arrived.fulfill() }
        defer { gate.signal() }
        let old = Task { try await store.commentMoment(moment.id, text: "迟到", requestID: UUID()) }
        await fulfillment(of: [arrived], timeout: 2)
        store.socialPolicyChanged(userID: InboxRefreshResponses.peer, blocked: true)
        let boundary = store.momentContentRevision
        gate.signal()
        if case .success = await old.result { XCTFail("An old-scope confirmation must not publish an invalidation") }
        XCTAssertEqual(store.momentContentRevision, boundary)
        await store.logout()
    }

    func testContentPreferenceDefaultsToDetailsHidesImmediatelyAndDoesNotReplayWhenRestored() async throws {
        let fixture = try await fixture(), store = fixture.store, push = fixture.push
        XCTAssertFalse(store.hideNotificationContent)
        await store.refreshInboxSummary()
        fixture.responses.conversation(messageID: "visible-details", unread: 1)
        await store.refreshInboxSummary()
        XCTAssertEqual(push.foregroundNotice?.title, "消息好友")
        XCTAssertEqual(push.foregroundNotice?.message, "新的私信内容")

        try await store.setHideNotificationContent(true)
        XCTAssertTrue(store.hideNotificationContent)
        XCTAssertNil(push.foregroundNotice, "Enabling privacy immediately removes a detailed banner")
        XCTAssertTrue(store.notificationsEnabled, "Content privacy is independent of the account notification opt-in")
        fixture.responses.conversation(messageID: "hidden-details", unread: 2)
        await store.refreshInboxSummary()
        XCTAssertEqual(push.foregroundNotice?.title, "收到新消息")
        XCTAssertEqual(push.foregroundNotice?.message, "收到一条新私信，可在消息页查看。")
        try await store.setHideNotificationContent(false)
        XCTAssertNil(push.foregroundNotice)
        await store.refreshInboxSummary()
        XCTAssertNil(push.foregroundNotice, "Changing preview preferences never resets the event deduplication baseline")
        fixture.responses.notifications(["new-community-details"], unread: 1)
        await store.refreshInboxSummary()
        XCTAssertEqual(push.foregroundNotice?.title, "消息好友")
        XCTAssertEqual(push.foregroundNotice?.message, "收到一条互动消息")
        XCTAssertEqual(fixture.responses.preferenceBodies.count, 2)
        for body in fixture.responses.preferenceBodies { XCTAssertEqual(Set(body.keys), ["hideNotificationContent"]) }
        await store.logout()
    }

    func testRemoteContentPreferenceRefreshClearsVisibleDetailsAndUsesLatestSettingForCandidates() async throws {
        let fixture = try await fixture(), store = fixture.store, push = fixture.push
        await store.refreshInboxSummary()
        fixture.responses.conversation(messageID: "before-other-device-setting", unread: 1)
        await store.refreshInboxSummary()
        XCTAssertEqual(push.foregroundNotice?.title, "消息好友")
        fixture.responses.setHiddenContent(true)
        _ = try await store.pushStatus()
        XCTAssertTrue(store.hideNotificationContent)
        XCTAssertNil(push.foregroundNotice)
        fixture.responses.conversation(messageID: "after-other-device-setting", unread: 2)
        await store.refreshInboxSummary()
        XCTAssertEqual(push.foregroundNotice?.title, "收到新消息")
        XCTAssertEqual(push.foregroundNotice?.message, "收到一条新私信，可在消息页查看。")
        await store.logout()
    }

    func testOlderProfileResponseCannotOverwriteNewerNotificationContentPreference() async throws {
        let fixture = try await fixture(), store = fixture.store
        let arrived = expectation(description: "older profile snapshot is waiting")
        let gate = fixture.responses.holdNextProfilePatch(key: "notificationsEnabled") { arrived.fulfill() }
        defer { gate.signal() }
        let older = Task { try await store.setNotificationsEnabled(true) }
        await fulfillment(of: [arrived], timeout: 2)
        try await store.setHideNotificationContent(true)
        XCTAssertTrue(store.hideNotificationContent)
        gate.signal()
        try await older.value
        XCTAssertTrue(store.hideNotificationContent, "A pre-mutation whole-user snapshot must preserve the newer preference")
        await store.logout()
    }

    func testCancelledFailedAndOldSessionPreferenceResponsesCannotCommitOrLeaveBusyState() async throws {
        for switchSession in [false, true] {
            let fixture = try await fixture(), store = fixture.store, push = fixture.push
            await store.refreshInboxSummary()
            let arrived = expectation(description: "content preference patch is waiting")
            let gate = fixture.responses.holdNextProfilePatch(key: "hideNotificationContent") { arrived.fulfill() }
            defer { gate.signal() }
            let update = Task { try await store.setHideNotificationContent(true) }
            await fulfillment(of: [arrived], timeout: 2)
            XCTAssertTrue(store.isUpdatingNotificationContent)
            fixture.responses.conversation(messageID: "while-privacy-saving", unread: 1)
            await store.refreshInboxSummary()
            XCTAssertEqual(push.foregroundNotice?.title, "收到新消息", "A late HTTPS candidate must stay generic during the privacy write")
            if switchSession {
                let previous = store.pushSessionKey
                await store.logout()
                fixture.responses.setHiddenContent(false)
                try await store.loginWithApple()
                XCTAssertNotEqual(store.pushSessionKey, previous)
            } else { update.cancel() }
            gate.signal()
            if case .success = await update.result { XCTFail("Cancelled/old-session preference write must not commit to the current store") }
            XCTAssertFalse(store.isUpdatingNotificationContent)
            XCTAssertFalse(store.hideNotificationContent)
            fixture.responses.setProfileStatus(503)
            do { try await store.setHideNotificationContent(true); XCTFail("Rejected preference write unexpectedly succeeded") }
            catch { }
            XCTAssertFalse(store.isUpdatingNotificationContent)
            XCTAssertFalse(store.hideNotificationContent)
            fixture.responses.setProfileStatus(200)
            try await store.setHideNotificationContent(false)
            XCTAssertFalse(store.isUpdatingNotificationContent)
            XCTAssertFalse(store.hideNotificationContent)
            await store.logout()
        }
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
        XCTAssertEqual(push.foregroundNotice?.candidate.id, "notice-new")
        XCTAssertEqual(push.foregroundNotice?.candidate.kind, .notifications)
        XCTAssertEqual(push.foregroundNotice?.title, "消息好友")
        XCTAssertEqual(push.foregroundNotice?.message, "收到一条互动消息")
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
    let server: InboxRefreshMockServer
    let store: KikiAppStore
    let push: KikiPushController

    init(defaults: UserDefaults) async throws {
        let documents = try XCTUnwrap(KikiLegalBundle.bundled)
        let responses = self.responses
        server = InboxRefreshMockServer { try responses.respond($0, documents: documents) }
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

/// Held profile responses run independently, so ordering/cancellation tests
/// cannot block URLProtocol's loading thread or deliver after stopLoading.
private final class InboxRefreshMockServer {
    let client: KikiAccountAPIClient
    let voiceClient: KikiAPIClient
    private let host = UUID().uuidString.lowercased() + ".example.invalid"
    private let session: URLSession

    init(responder: @escaping InboxRefreshProtocol.Responder) {
        InboxRefreshProtocol.install(responder, host: host)
        InboxRefreshProtocol.install(responder, host: "voice-" + host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxRefreshProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAccountAPIClient(baseURL: URL(string: "https://" + host)!, session: session)
        voiceClient = KikiAPIClient(baseURL: URL(string: "https://voice-" + host)!, session: session)
    }
    deinit {
        session.invalidateAndCancel()
        InboxRefreshProtocol.remove(host: host)
        InboxRefreshProtocol.remove(host: "voice-" + host)
    }
}

private final class InboxRefreshProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var responders: [String: Responder] = [:]
    private let completionLock = NSRecursiveLock()
    private var completed = false

    static func install(_ responder: @escaping Responder, host: String) {
        lock.lock(); defer { lock.unlock() }; responders[host] = responder
    }
    static func remove(host: String) { lock.lock(); defer { lock.unlock() }; responders[host] = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let responder = Self.responders[request.url?.host ?? ""]; Self.lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try XCTUnwrap(responder)(request) }
            completionLock.lock(); defer { completionLock.unlock() }
            guard !completed else { return }
            completed = true
            switch result {
            case .success(let (status, data)):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error): client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
    override func stopLoading() { completionLock.lock(); defer { completionLock.unlock() }; completed = true }
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
    private var hideContent = false
    private var profileStatus = 200
    private var profileBodies: [[String: Any]] = []
    private var profileHold: (key: String, gate: DispatchSemaphore, arrived: () -> Void)?
    private var responseHold: (path: String, gate: DispatchSemaphore, arrived: () -> Void)?
    private var accountNotificationsEnabled = true
    private var momentMutationStatus = 200
    private var momentFeedCommentCount = 0
    static let momentID = "11111111-1111-4111-8111-111111111111"
    static let commentID = "22222222-2222-4222-8222-222222222222"
    struct MomentNotice {
        let id: String
        var seq = 0
        var kind = "system"
        var momentID: String? = InboxRefreshResponses.momentID
        var read = false
    }
    func holdNextResponse(path: String, arrived: @escaping () -> Void) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); defer { lock.unlock() }
        responseHold = (path, gate, arrived)
        return gate
    }
    func setMomentMutationStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; momentMutationStatus = value }
    func setMomentFeedCommentCount(_ value: Int) { lock.lock(); defer { lock.unlock() }; momentFeedCommentCount = value }
    func momentNotifications(_ values: [MomentNotice], isPage: Bool = false, status: Int = 200) {
        let notices = values.map { value -> [String: Any] in
            ["id": value.id, "kind": value.kind, "actor": Self.person, "text": "新的动态互动", "createdAt": 1_792_260_000,
             "readAt": value.read ? 1_792_260_001 as Any : NSNull(), "roomID": NSNull(),
             "momentID": value.momentID as Any? ?? NSNull(), "seq": value.seq]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["notifications": notices, "unreadCount": values.filter { !$0.read }.count, "nextCursor": NSNull()])
        lock.lock(); defer { lock.unlock() }
        if isPage { notificationPage = data } else { notificationBody = data; notificationStatus = status }
    }
    var preferenceBodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return profileBodies }
    func setHiddenContent(_ value: Bool) { lock.lock(); defer { lock.unlock() }; hideContent = value }
    func setProfileStatus(_ value: Int) { lock.lock(); defer { lock.unlock() }; profileStatus = value }
    func holdNextProfilePatch(key: String, arrived: @escaping () -> Void) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); defer { lock.unlock() }
        profileHold = (key, gate, arrived)
        return gate
    }
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
        let mutationStatus = momentMutationStatus
        let feedCommentCount = momentFeedCommentCount
        let heldResponse = responseHold?.path == path ? responseHold : nil
        if heldResponse != nil { responseHold = nil }
        if ["/v1/social/inbox/read", "/v1/social/inbox/clear"].contains(path) { bulkRequests.append(try requestBody(request)) }
        lock.unlock()
        heldResponse?.arrived(); _ = heldResponse?.gate.wait(timeout: .now() + 5)
        lock.lock(); let hidden = hideContent, enabled = accountNotificationsEnabled; lock.unlock()
        var user: [String: Any] = ["id": Self.me, "sdkUserID": Self.me, "name": "测试昵称", "bio": "", "avatarIndex": 0, "notificationsEnabled": enabled, "needsNickname": false,
                                   "hideNotificationContent": hidden]
        let sdk: [String: Any] = ["provider": "livekit", "serverURL": "wss://furby.top", "userID": Self.me, "expiresAt": 2_000_000_000]
        let versions: [String: Any] = ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash]
        let body: [String: Any]
        switch path {
        case "/v1/me":
            let input = try requestBody(request)
            lock.lock()
            profileBodies.append(input)
            let currentStatus = profileStatus
            if currentStatus == 200, let hidden = input["hideNotificationContent"] as? Bool { hideContent = hidden }
            if currentStatus == 200, let enabled = input["notificationsEnabled"] as? Bool { accountNotificationsEnabled = enabled }
            user["hideNotificationContent"] = hideContent
            user["notificationsEnabled"] = accountNotificationsEnabled
            let held = profileHold.flatMap { input[$0.key] != nil ? $0 : nil }
            if held != nil { profileHold = nil }
            lock.unlock()
            held?.arrived(); _ = held?.gate.wait(timeout: .now() + 5)
            if currentStatus != 200 { return (currentStatus, Data(#"{"detail":"设置暂时无法保存"}"#.utf8)) }
            body = user
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
        case "/v1/social/people/" + Self.me:
            var me = Self.person; me["id"] = Self.me; body = ["person": me]
        case "/v1/social/relationships/ids": body = ["followingIDs": [], "followingCount": 0, "followerCount": 0]
        case "/v1/social/moments" where request.httpMethod == "GET":
            var moment = Self.moment
            moment["commentCount"] = feedCommentCount
            moment["commentPreview"] = feedCommentCount > 0
                ? [["id": Self.commentID, "momentID": Self.momentID, "author": Self.person,
                    "text": "远端新增评论", "createdAt": 1_792_260_001, "canDelete": false]] : []
            body = ["moments": [moment], "nextCursor": NSNull()]
        case "/v1/social/moments", "/v1/social/moments/" + Self.momentID + "/like":
            if mutationStatus != 200 { return (mutationStatus, Data(#"{"detail":"动态操作未完成"}"#.utf8)) }
            body = ["moment": Self.moment]
        case "/v1/social/moments/" + Self.momentID + "/comments":
            if mutationStatus != 200 { return (mutationStatus, Data(#"{"detail":"评论操作未完成"}"#.utf8)) }
            body = ["comment": ["id": Self.commentID, "momentID": Self.momentID, "author": Self.person,
                                 "text": "已确认评论", "createdAt": 1_792_260_000, "canDelete": true]]
        case "/v1/social/moments/" + Self.momentID, "/v1/social/comments/" + Self.commentID:
            if mutationStatus != 200 { return (mutationStatus, Data(#"{"detail":"删除未完成"}"#.utf8)) }
            body = ["ok": true]
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
        case "/v1/push/status": body = ["enabled": enabled, "registered": false, "badgeCount": 0, "accountTag": "inbox-fixture-account", "hideNotificationContent": hidden]
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
    static var moment: [String: Any] {
        ["id": momentID, "author": person, "text": "动态内容", "media": [], "createdAt": 1_792_260_000,
         "likeCount": 1, "commentCount": 1, "liked": true, "canDelete": true, "commentPreview": []]
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
