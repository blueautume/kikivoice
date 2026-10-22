import Foundation
import XCTest
@testable import KikiTalk

final class KikiDirectMessageAccessTests: XCTestCase {
    private func page(_ access: [String: Any]) throws -> KikiDirectMessagesPage {
        var value = access
        value["messages"] = []; value["unreadCount"] = 0
        return try JSONDecoder().decode(KikiDirectMessagesPage.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testLegacyPageKeepsAuthoritativeDenialWithoutInventingAnIntroductionAllowance() throws {
        let value = try page(["canSend": false])
        XCTAssertFalse(value.canSend)
        XCTAssertNil(value.directAccess.remainingBeforeReply)
        XCTAssertNil(value.directAccess.requiresReply)
        XCTAssertFalse(value.directAccess.explanation?.contains("互相") == true)
        XCTAssertFalse(value.directAccess.explanation?.contains("5 条") == true)
    }

    func testServerAdmissionOverridesRemainingAndFollowIndependentPresentation() throws {
        let value = try page(["canSend": false, "remainingBeforeReply": 5, "requiresReply": false, "replyEstablished": false, "initialMessageLimit": 5])
        XCTAssertFalse(value.canSend, "An available count cannot override an explicit server denial")
        let introduction = try page(["canSend": true, "remainingBeforeReply": 5, "requiresReply": false, "replyEstablished": false, "initialMessageLimit": 5])
        XCTAssertTrue(introduction.canSend)
        XCTAssertEqual(introduction.directAccess.explanation, "对方回复前，还可发送 5 条消息。")
    }

    func testFifthCommittedReceiptImmediatelyCarriesWaitingState() throws {
        let value = try JSONDecoder().decode(KikiDirectMessageReceipt.self, from: Data(#"{"conversationID":"pair","message":{"id":"fifth","seq":5,"senderID":"kiki_sender","text":"你好","createdAt":100},"canSend":false,"remainingBeforeReply":0,"requiresReply":true,"replyEstablished":false,"initialMessageLimit":5}"#.utf8))
        let access = try XCTUnwrap(value.directAccess)
        XCTAssertFalse(access.canSend); XCTAssertEqual(access.remainingBeforeReply, 0)
        XCTAssertEqual(access.explanation, "已发送 5 条消息，等待对方回复后可继续聊天。")
    }

    func testLegacyReceiptDoesNotManufactureAnAccessDecision() throws {
        let value = try JSONDecoder().decode(KikiDirectMessageReceipt.self, from: Data(#"{"conversationID":"pair","message":{"id":"first","seq":1,"senderID":"kiki_sender","text":"你好","createdAt":100}}"#.utf8))
        XCTAssertNil(value.directAccess)
    }

    func testReplyEstablishedWithNullCountHasNoWaitingPrompt() throws {
        let value = try page(["canSend": true, "remainingBeforeReply": NSNull(), "requiresReply": false, "replyEstablished": true, "initialMessageLimit": 5])
        XCTAssertTrue(value.canSend); XCTAssertEqual(value.directAccess.replyEstablished, true)
        XCTAssertNil(value.directAccess.remainingBeforeReply); XCTAssertNil(value.directAccess.explanation)
    }

    func testConversationDecodesTheSameAdmissionMetadataAsMessagePage() throws {
        let person: [String: Any] = ["id": "kiki_recipient", "name": "朋友", "bio": "", "avatarIndex": 0,
                                   "following": false, "followsYou": false, "mutual": false, "followingCount": 0, "followerCount": 0]
        let value: [String: Any] = ["id": "pair", "person": person, "unreadCount": 0, "canSend": false,
                                  "remainingBeforeReply": 0, "requiresReply": true, "replyEstablished": false, "initialMessageLimit": 5]
        let conversation = try JSONDecoder().decode(KikiConversation.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertFalse(conversation.canSend); XCTAssertFalse(conversation.person.mutual)
        XCTAssertEqual(conversation.directAccess.requiresReply, true)
    }

    func testStructuredSixthMessageRejectionIsAConfirmedNonRetryableAdmissionDecision() async throws {
        let mock = KikiAPIMockServer { _ in
            (403, Data(#"{"detail":{"code":"direct_message_reply_required","message":"等待对方回复","canSend":false,"remainingBeforeReply":0,"requiresReply":true,"replyEstablished":false,"initialMessageLimit":5}}"#.utf8))
        }
        do {
            _ = try await mock.client.socialSendDirect("kiki_recipient", text: "第六条", requestID: UUID(), token: "test-token")
            XCTFail("The server rejected the introduction")
        } catch let error as KikiDirectMessageAdmissionError {
            XCTAssertFalse(error.access.canSend); XCTAssertEqual(error.access.requiresReply, true)
            XCTAssertEqual(error.localizedDescription, "等待对方回复")
            XCTAssertFalse(KikiSocialMutation.needsSameIDRetry(error))
        }
    }

    func testMalformedAdmissionObjectFallsBackToTheExplicitHTTPDenial() async throws {
        let mock = KikiAPIMockServer { _ in
            (403, Data(#"{"detail":{"code":"direct_message_reply_required","message":"bad state","canSend":true,"requiresReply":true}}"#.utf8))
        }
        do {
            _ = try await mock.client.socialSendDirect("kiki_recipient", text: "你好", requestID: UUID(), token: "test-token")
            XCTFail("Malformed admission cannot become an approval")
        } catch let error as KikiAPIError {
            guard case .server(403, _) = error else { return XCTFail("Keep the server's explicit denial") }
            XCTAssertFalse(KikiSocialMutation.needsSameIDRetry(error))
        }
    }

    func testDirectRefreshRequiresVisibleForegroundPageWithoutAProfileOrReportSheet() {
        XCTAssertTrue(KikiDirectRefreshScope(personID: "peer", isForeground: true, isVisible: true, hasOverlay: false).permitsRefresh)
        XCTAssertFalse(KikiDirectRefreshScope(personID: "peer", isForeground: false, isVisible: true, hasOverlay: false).permitsRefresh)
        XCTAssertFalse(KikiDirectRefreshScope(personID: "peer", isForeground: true, isVisible: false, hasOverlay: false).permitsRefresh)
        XCTAssertFalse(KikiDirectRefreshScope(personID: "peer", isForeground: true, isVisible: true, hasOverlay: true).permitsRefresh)
        XCTAssertEqual(KikiDirectRefreshScope.fallbackNanoseconds, 15_000_000_000)
    }
}
