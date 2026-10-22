import XCTest
import SwiftUI
import UIKit
@testable import KikiTalk

final class KikiVoiceAPIClientTests: XCTestCase {
    func testRoomTitleUpdateUsesOnlyTitleAndReturnsAuthoritativeState() async throws {
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-session")
            let body = try voiceRequestBody(request)
            XCTAssertEqual(Set(body.keys), ["title"])
            XCTAssertEqual(body["title"] as? String, "新的房间名称")
            var state = labRoomStateFixture
            var room = labRoomFixture; room["title"] = "新的房间名称"
            state["room"] = room; state["revision"] = 9
            return (200, try labJSON(state))
        }
        let state = try await server.client.updateRoomTitle("voice_lab_1", title: "  新的房间名称  ", token: "owner-session")
        XCTAssertEqual(state.room.title, "新的房间名称")
        XCTAssertEqual(state.revision, 9)
        let invalid = KikiVoiceAPIMockServer { _ in XCTFail("Invalid title must fail before network"); return (500, Data()) }
        for title in ["", String(repeating: "a", count: 37), "a\nb"] {
            do { _ = try await invalid.client.updateRoomTitle("voice_lab_1", title: title, token: "owner-session"); XCTFail("Expected invalid title") }
            catch { }
        }
    }

    func testRoomCatalogWatchUsesVoiceSessionAndBoundedLongPoll() async throws {
        let paths = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            paths.append(request.url!.absoluteString)
            XCTAssertEqual(request.url?.path, "/v1/room-catalog/changes")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer voice-session")
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try labJSON(["revision": 7, "changed": true]))
        }
        let initial = try await server.client.rtcRoomCatalogChanges(after: nil, waitSeconds: 0, token: "voice-session")
        let changed = try await server.client.rtcRoomCatalogChanges(after: 6, token: "voice-session")
        XCTAssertEqual(initial.revision, 7)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(paths.values.count, 2)
        let first = try XCTUnwrap(URLComponents(string: paths.values[0]))
        XCTAssertEqual(first.queryItems, [URLQueryItem(name: "waitSeconds", value: "0")])
        let next = try XCTUnwrap(URLComponents(string: paths.values[1]))
        XCTAssertEqual(next.queryItems, [URLQueryItem(name: "waitSeconds", value: "15"), URLQueryItem(name: "after", value: "6")])
        for (after, wait) in [(Optional(-1), 15), (nil, -1), (nil, 16)] {
            do { _ = try await server.client.rtcRoomCatalogChanges(after: after, waitSeconds: wait, token: "voice-session"); XCTFail("Invalid subscription input") }
            catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected input rejection") } }
        }
        XCTAssertEqual(paths.values.count, 2, "Invalid watches must not reach the network")
    }

    func testRoomCatalogWatchRejectsNegativeOrMalformedServerRevision() async throws {
        for payload: [String: Any] in [["revision": -1, "changed": false], ["revision": 1], ["revision": "bad", "changed": false]] {
            let server = KikiVoiceAPIMockServer { _ in (200, try labJSON(payload)) }
            do { _ = try await server.client.rtcRoomCatalogChanges(after: nil, token: "voice-session"); XCTFail("Malformed watch response accepted") }
            catch let error as KikiAPIError { guard case .invalidResponse = error else { return XCTFail("Expected response rejection") } }
        }
    }

    func testRoomListAndParticipantTokenUseIndependentBearerSession() async throws {
        let paths = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lab-session")
            if request.url!.path == "/v1/rooms" {
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, try labJSON(["rooms": [labRoomFixture]]))
            }
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/token")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, try labJSON(["serverURL": "wss://furby.top", "participantToken": "short-room-token", "room": labRoomFixture]))
        }
        let rooms = try await server.client.rtcRooms(token: "lab-session")
        let connection = try await server.client.rtcJoin(roomID: rooms[0].id, token: "lab-session")
        XCTAssertEqual(connection.room.id, "voice_lab_1")
        XCTAssertEqual(connection.participantToken, "short-room-token")
        XCTAssertEqual(paths.values, ["/v1/rooms", "/v1/rooms/voice_lab_1/token"])
    }

    func testVideoAndPathInjectionAreRejectedBeforeNetwork() async throws {
        let server = KikiVoiceAPIMockServer { _ in XCTFail("Unsupported input must not make requests"); return (500, Data()) }
        do {
            _ = try await server.client.reserveRoom(title: "test", category: "生活", isLive: true, theme: 0, token: "lab-session")
            XCTFail("Video must fail closed")
        } catch let error as KikiAPIError { guard case .server(422, _) = error else { return XCTFail("Expected unsupported feature") } }
        for roomID in ["../me", "room?admin=true", "room/other", ""] {
            do { _ = try await server.client.rtcJoin(roomID: roomID, token: "lab-session"); XCTFail("Invalid room ID") }
            catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected endpoint validation") } }
        }
    }

    func testUnauthorizedAndProtocolUpdateRemainRecoverable() async throws {
        let server = KikiVoiceAPIMockServer { _ in (401, try labJSON(["detail": "实验会话已过期"])) }
        do { _ = try await server.client.rtcRooms(token: "expired"); XCTFail("Expected unauthorized") }
        catch let error as KikiAPIError { XCTAssertTrue(error.isUnauthorized); XCTAssertEqual(error.localizedDescription, "实验会话已过期") }
        let broken = KikiVoiceAPIMockServer { _ in (200, Data("{}".utf8)) }
        do { _ = try await broken.client.rtcRooms(token: "lab-session"); XCTFail("Malformed rooms must not become an empty list") }
        catch let error as KikiAPIError { guard case .invalidResponse = error else { return XCTFail("Expected schema failure") } }
    }

    func testAuthenticatedRequestsDoNotFollowRedirects() throws {
        let delegate = KikiHTTPSDelegate()
        let origin = try XCTUnwrap(URL(string: "https://furby.top/v1/me"))
        let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: nil))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        for target in ["https://kiki.group/v1/me", "http://furby.top/v1/me", "https://furby.top/redirected"] {
            let request = URLRequest(url: try XCTUnwrap(URL(string: target)))
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { XCTAssertNil($0) }
        }
    }

    func testRoomStateKeepsAudienceIndependentFromEightSeatsAndUsesAuthoritativeRoles() async throws {
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/state")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer guest-session")
            return (200, try labJSON(labRoomStateFixture))
        }
        let state = try await server.client.roomState(roomID: "voice_lab_1", token: "guest-session")
        XCTAssertEqual(state.seats.count, 8)
        XCTAssertEqual(state.members.count, 10)
        XCTAssertEqual(state.listeners.count, 9)
        XCTAssertNil(state.me.seatIndex)
        XCTAssertFalse(state.me.canPublishAudio)
        XCTAssertTrue(state.me.canPublishData)
        XCTAssertEqual(state.member(on: state.seats[0])?.userID, "lab_user_1")
        XCTAssertEqual(state.seats.filter { $0.userID != nil }.count, 1)
        XCTAssertEqual(state.myRequest?.position, 1)
        XCTAssertEqual(state.myInvitation?.seatIndex, 2)
        XCTAssertEqual(state.availableSeats.count, 6, "Locked empty seat cannot be selected")
        let owner = try XCTUnwrap(state.members.first)
        XCTAssertTrue(owner.canModerate(state.me))
        XCTAssertFalse(state.me.canModerate(owner))
        XCTAssertFalse(owner.canModerate(owner))
    }

    func testModeratorCannotManageOwnerOrPeerAdmin() throws {
        let owner = labRoomMember("owner", role: "owner", seat: 1)
        let admin = labRoomMember("admin", role: "admin")
        let peer = labRoomMember("peer", role: "admin")
        let member = labRoomMember("member")
        let decode = { (value: [String: Any]) throws -> KikiRoomMember in try JSONDecoder().decode(KikiRoomMember.self, from: labJSON(value)) }
        let a = try decode(admin)
        XCTAssertFalse(a.canModerate(try decode(owner)))
        XCTAssertFalse(a.canModerate(try decode(peer)))
        XCTAssertTrue(a.canModerate(try decode(member)))
        XCTAssertTrue(try decode(owner).canModerate(a))
    }

    func testRoomActionsAndLeaveUseServerEndpointsWithoutEndingWholeRoom() async throws {
        let paths = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            paths.append("\(request.httpMethod ?? "") \(request.url!.path)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-session")
            if request.url?.path.hasSuffix("/actions") == true {
                let body = try voiceRequestBody(request)
                XCTAssertEqual(body["action"] as? String, "approve_request")
                XCTAssertEqual(body["targetUserID"] as? String, "listener_1")
                XCTAssertEqual(body["seatIndex"] as? Int, 2)
                XCTAssertNil(body["enabled"])
                return (200, try labJSON(labRoomStateFixture))
            }
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/leave")
            return (200, try labJSON(["ok": true]))
        }
        _ = try await server.client.roomAction(.approveRequest, roomID: "voice_lab_1", targetUserID: "listener_1", seatIndex: 2, token: "owner-session")
        try await server.client.leaveRoom(roomID: "voice_lab_1", token: "owner-session")
        XCTAssertEqual(paths.values, ["POST /v1/rooms/voice_lab_1/actions", "POST /v1/rooms/voice_lab_1/leave"])
    }

    func testRoomActionsRejectInvalidSeatBeforeNetwork() async throws {
        let server = KikiVoiceAPIMockServer { _ in XCTFail("Invalid seat must not make a request"); return (500, Data()) }
        for index in [0, 9, -1] {
            do {
                _ = try await server.client.roomAction(.moveSeat, roomID: "voice_lab_1", seatIndex: index, token: "lab-session")
                XCTFail("Invalid seat must fail")
            } catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected validation") } }
        }
    }

    func testAuthoritativeChatUsesSameNonceAndNeverAcceptsClaimedSender() async throws {
        let nonce = UUID().uuidString
        let calls = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            calls.append(request.httpMethod ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lab-session")
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/messages")
            if request.httpMethod == "POST" {
                let body = try voiceRequestBody(request)
                XCTAssertEqual(Set(body.keys), ["clientMessageID", "text"])
                XCTAssertEqual(body["clientMessageID"] as? String, nonce.lowercased())
                XCTAssertEqual(body["text"] as? String, "你好")
                return (200, try labJSON(labChatMessageFixture(seq: 4, nonce: nonce)))
            }
            XCTAssertEqual(request.url?.query, "afterSeq=0&limit=200")
            return (200, try labJSON(labChatPageFixture(messages: [labChatMessageFixture(seq: 4, nonce: nonce)], cursor: 4)))
        }
        let first = try await server.client.sendRoomMessage(roomID: "voice_lab_1", clientMessageID: nonce, text: " 你好 ", token: "lab-session")
        let retried = try await server.client.sendRoomMessage(roomID: "voice_lab_1", clientMessageID: nonce, text: "你好", token: "lab-session")
        XCTAssertEqual(first, retried)
        let page = try await server.client.roomMessages(roomID: "voice_lab_1", afterSeq: 0, token: "lab-session")
        XCTAssertEqual(page.messages.first?.senderName, "服务端昵称")
        XCTAssertEqual(calls.values, ["POST", "POST", "GET"])
    }

    func testChatValidationBoundsUTF8AndRejectsInvalidCursorBeforeNetwork() async throws {
        let server = KikiVoiceAPIMockServer { _ in XCTFail("Invalid chat must not use network"); return (500, Data()) }
        for value in [" \n", String(repeating: "中", count: 667)] {
            do { _ = try await server.client.sendRoomMessage(roomID: "voice_lab_1", clientMessageID: UUID().uuidString, text: value, token: "s"); XCTFail("Invalid text") }
            catch { }
        }
        do { _ = try await server.client.sendRoomMessage(roomID: "voice_lab_1", clientMessageID: "not-a-uuid", text: "hello", token: "s"); XCTFail("Invalid nonce") }
        catch { }
        do { _ = try await server.client.roomMessages(roomID: "voice_lab_1", afterSeq: -1, token: "s"); XCTFail("Invalid cursor") }
        catch { }
        XCTAssertEqual(try KikiChatMessage.validatedText(String(repeating: "中", count: 666)).utf8.count, 1_998)
    }

    func testChatWindowDoesNotSkipMessagesAfterSendAndRebuildsAfterDeletion() throws {
        func message(_ seq: Int) throws -> KikiChatMessage {
            try JSONDecoder().decode(KikiChatMessage.self, from: labJSON(labChatMessageFixture(seq: seq)))
        }
        func page(_ seqs: [Int], cursor: Int, revision: Int = 0) throws -> KikiChatPage {
            try JSONDecoder().decode(KikiChatPage.self, from: labJSON(labChatPageFixture(messages: seqs.map { labChatMessageFixture(seq: $0) }, cursor: cursor, revision: revision)))
        }
        var window = KikiChatWindow()
        XCTAssertTrue(window.apply(try page([1], cursor: 1), requestedAfterSeq: 0))
        window.appendConfirmed(try message(3))
        XCTAssertEqual(window.afterSeq, 1, "A POST acknowledgement cannot skip another sender's sequence 2")
        XCTAssertTrue(window.apply(try page([2, 3], cursor: 3), requestedAfterSeq: 1))
        XCTAssertEqual(window.messages.map(\.seq), [1, 2, 3])
        XCTAssertFalse(window.apply(try page([], cursor: 3, revision: 1), requestedAfterSeq: 3))
        XCTAssertTrue(window.apply(try page([2, 3], cursor: 3, revision: 1), requestedAfterSeq: 0))
        XCTAssertEqual(window.messages.map(\.seq), [2, 3], "Deleted sender content must disappear after authoritative rebuild")
        XCTAssertFalse(window.apply(try page([1], cursor: 1), requestedAfterSeq: 0), "A stale pre-deletion response cannot resurrect content")
    }

    func testDelayedSendAcknowledgementCannotRestorePrunedMessagesOrDeletedGaps() throws {
        func message(_ seq: Int) throws -> KikiChatMessage {
            try JSONDecoder().decode(KikiChatMessage.self, from: labJSON(labChatMessageFixture(seq: seq)))
        }
        func page(_ seqs: [Int], cursor: Int) throws -> KikiChatPage {
            try JSONDecoder().decode(KikiChatPage.self, from: labJSON(labChatPageFixture(messages: seqs.map { labChatMessageFixture(seq: $0) }, cursor: cursor, revision: 2)))
        }
        var window = KikiChatWindow()
        XCTAssertTrue(window.apply(try page([201, 203], cursor: 203), requestedAfterSeq: 0))
        window.appendConfirmed(try message(2))
        window.appendConfirmed(try message(202))
        XCTAssertTrue(window.apply(try page([], cursor: 203), requestedAfterSeq: 203))
        XCTAssertEqual(window.messages.map(\.seq), [201, 203], "Late acknowledgements must not restore pruned content or a deletion inside the retained window")
        window.appendConfirmed(try message(204))
        XCTAssertEqual(window.messages.map(\.seq), [201, 203, 204])
        XCTAssertEqual(window.afterSeq, 203, "A new acknowledgement must still allow incremental GET to find intervening messages")
    }

    func testHintContainsNoDisplayableMessageAndUnknownStatisticsStayNil() throws {
        let hint = KikiChatSyncHint(version: 1, latestSeq: 42, historyRevision: 3, announcementRevision: 2)
        XCTAssertNotNil(KikiChatSyncHint.decode(try JSONEncoder().encode(hint)))
        XCTAssertNil(KikiChatSyncHint.decode(Data("{\"version\":1,\"text\":\"forged\"}".utf8)))
        XCTAssertNil(KikiChatSyncHint.decode(Data(repeating: 0, count: 513)))
        let metrics = KikiNetworkMetrics.collect([])
        XCTAssertNil(metrics.rttMs)
        XCTAssertNil(metrics.packetLossPercent)
        XCTAssertNil(KikiNetworkMetrics.valid(.nan, upperBound: 100))
        XCTAssertNil(KikiNetworkMetrics.valid(-1, upperBound: 100))
        XCTAssertNil(KikiNetworkMetrics.valid(101, upperBound: 100))
    }

    @MainActor func testAudioInterruptionRequiresManualRestartAndDoesNotTreatEndAsOpenMic() {
        let monitor = KikiRoomAudioMonitor()
        var stopped = 0
        monitor.onUpdate = { _, event in if event?.mustStopCapture == true { stopped += 1 } }
        monitor.refresh(event: .interruptionBegan)
        XCTAssertTrue(monitor.state.interrupted)
        monitor.refresh(event: .interruptionEnded)
        XCTAssertFalse(monitor.state.interrupted)
        XCTAssertEqual(stopped, 1)
        XCTAssertNotNil(monitor.state.notice)
        monitor.refresh(event: .oldDeviceUnavailable)
        monitor.refresh(event: .mediaServicesLost)
        monitor.refresh(event: .mediaServicesReset)
        XCTAssertEqual(stopped, 4)
        XCTAssertFalse(monitor.state.interrupted)
        XCTAssertNotNil(monitor.state.notice)
        monitor.clearNotice()
        XCTAssertNil(monitor.state.notice)
    }

    func testQualityReportOmitsUnavailableNumbersAndRateLimitExposesBackoff() async throws {
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/quality")
            let body = try voiceRequestBody(request)
            XCTAssertEqual(Set(body.keys), ["quality"])
            XCTAssertEqual(body["quality"] as? String, "unknown")
            return (202, try labJSON(["accepted": true]))
        }
        try await server.client.reportRoomQuality(roomID: "voice_lab_1", sample: KikiRoomQualitySample(quality: "unknown", rttMs: nil, jitterMs: nil, packetLossPercent: nil), token: "s")
        let limited = KikiVoiceAPIMockServer { _ in (429, try labJSON(["detail": "稍后再试"])) }
        do { _ = try await limited.client.roomMessages(roomID: "voice_lab_1", afterSeq: 0, token: "s"); XCTFail("Must back off") }
        catch let error as KikiAPIError {
            guard case .rateLimited(let seconds, _) = error else { return XCTFail("Missing retry delay") }
            XCTAssertEqual(seconds, 5)
        }
    }

    func testNetworkRecoveryCannotReopenMicAfterRevocationAndRestorationOrDeviceInterruption() {
        let intent = KikiMicrophoneRecoveryIntent(enabled: true, policy: 3, safety: 2, revision: 5)
        XCTAssertTrue(intent.mayResume(policy: 3, safety: 2, revision: 5, canPublish: true, interrupted: false, hasNotice: false))
        XCTAssertFalse(intent.mayResume(policy: 5, safety: 2, revision: 5, canPublish: true, interrupted: false, hasNotice: false), "Mute then unmute must not reopen a previously authorized microphone")
        XCTAssertFalse(intent.mayResume(policy: 3, safety: 3, revision: 5, canPublish: true, interrupted: false, hasNotice: false), "An interruption invalidates the original capture intention even after it ended")
        XCTAssertFalse(intent.mayResume(policy: 3, safety: 2, revision: 6, canPublish: true, interrupted: false, hasNotice: false), "Any missed room revision is handled conservatively")
        XCTAssertFalse(intent.mayResume(policy: 3, safety: 2, revision: 5, canPublish: false, interrupted: false, hasNotice: false))
        XCTAssertFalse(intent.mayResume(policy: 3, safety: 2, revision: 5, canPublish: true, interrupted: true, hasNotice: false))
        XCTAssertFalse(intent.mayResume(policy: 3, safety: 2, revision: 5, canPublish: true, interrupted: false, hasNotice: true))
        XCTAssertFalse(KikiMicrophoneRecoveryIntent(enabled: false, policy: 3, safety: 2, revision: 5)
            .mayResume(policy: 3, safety: 2, revision: 5, canPublish: true, interrupted: false, hasNotice: false))
    }
}

func labChatMessageFixture(seq: Int, nonce: String = "3616F432-32D5-4A00-A925-B4A665E88578") -> [String: Any] {
    ["id": "message_\(seq)", "seq": seq, "clientMessageID": nonce.lowercased(), "senderUserID": "lab_user_1",
     "senderName": "服务端昵称", "senderAvatarIndex": 0, "text": "你好", "createdAt": 1_800_000_000]
}

func labChatPageFixture(messages: [[String: Any]], cursor: Int, revision: Int = 0) -> [String: Any] {
    ["messages": messages, "nextAfterSeq": cursor, "latestSeq": cursor, "oldestSeq": messages.first?["seq"] ?? 0,
     "truncated": false, "hasMore": false, "historyRevision": revision,
     "announcement": ["text": "", "revision": 0, "updatedAt": 0, "updatedByUserID": NSNull()]]
}

func labRoomMember(_ id: String, role: String = "member", seat: Int? = nil) -> [String: Any] {
    ["userID": id, "name": id, "avatarIndex": 0, "role": role, "seatIndex": seat as Any? ?? NSNull(),
     "audioMuted": false, "chatMuted": false, "online": true, "canPublishAudio": seat != nil, "canPublishData": true]
}

var labRoomStateFixture: [String: Any] {
    let listeners = (1...9).map { labRoomMember("listener_\($0)") }
    return ["room": labRoomFixture, "revision": 4, "me": listeners[0],
            "seats": (1...8).map { ["index": $0, "userID": $0 == 1 ? "lab_user_1" : NSNull(), "locked": $0 == 8, "audioLocked": false] as [String: Any] },
            "members": [labRoomMember("lab_user_1", role: "owner", seat: 1)] + listeners,
            "queue": [["userID": "listener_1", "name": "listener_1", "requestedAt": 1_800_000_000, "position": 1]],
            "invitations": [["userID": "listener_1", "name": "listener_1", "seatIndex": 2, "expiresAt": 2_000_000_000]],
            "bans": []]
}

let labUserFixture: [String: Any] = ["id": "lab_user_1", "sdkUserID": "lab_user_1", "name": "小岛", "bio": "", "avatarIndex": 3, "notificationsEnabled": false, "needsNickname": false]
let labSDKFixture: [String: Any] = ["provider": "livekit", "serverURL": "wss://furby.top", "userID": "lab_user_1", "expiresAt": 2_000_000_000]
let labRoomFixture: [String: Any] = ["id": "voice_lab_1", "title": "LiveKit 语聊", "host": "小岛", "hostID": "lab_user_1", "audience": 1, "isLive": false, "theme": 3, "category": "音乐", "isCreatedByMe": true, "status": "live", "createdAt": 1_800_000_000]
func labJSON(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
func voiceRequestData(_ request: URLRequest) throws -> Data {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return data
}

func voiceRequestBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: voiceRequestData(request)) as? [String: Any])
}

/// Each mock has a unique host so concurrent test sessions cannot share stubs.
final class KikiVoiceAPIMockServer {
    let client: KikiAPIClient
    private let host: String
    private let session: URLSession

    init(contentType: String = "application/json", responder: @escaping KikiVoiceMockURLProtocol.Responder) {
        host = "\(UUID().uuidString.lowercased()).example.invalid"
        KikiVoiceMockURLProtocol.install(responder, host: host, contentType: contentType)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KikiVoiceMockURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAPIClient(baseURL: URL(string: "https://\(host)")!, session: session)
    }

    deinit {
        session.invalidateAndCancel()
        KikiVoiceMockURLProtocol.remove(host: host)
    }
}

final class KikiVoiceMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var responders: [String: (Responder, String)] = [:]

    static func install(_ responder: @escaping Responder, host: String, contentType: String) {
        lock.lock()
        defer { lock.unlock() }
        responders[host] = (responder, contentType)
    }

    static func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        responders.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responder = Self.responders[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            let (handler, contentType) = try XCTUnwrap(responder)
            let (status, data) = try handler(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType, "X-Kiki-Request-ID": "72d30f65-50eb-487b-b9de-43abe63754aa"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LabRequestLog {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ method: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(method)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}


extension KikiVoiceAPIClientTests {
    func testSafetyBlocksAreAccountScopedAndSupportPersistentUnblock() async throws {
        let calls = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer own-voice-session")
            calls.append("\(request.httpMethod!) \(request.url!.path)")
            var state = safetyFixture
            if request.httpMethod == "DELETE" { state["blockedUsers"] = [] }
            return (200, try labJSON(state))
        }
        let state = try await server.client.safety(token: "own-voice-session")
        XCTAssertEqual(state.blockedIDs, ["blocked_1"])
        XCTAssertEqual(state.notices.first?.message, "请遵守社区规则")
        XCTAssertTrue(state.restrictions.isActive(state.restrictions.voiceMutedUntil, now: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(state.restrictions.isActive(state.restrictions.voiceMutedUntil, now: Date(timeIntervalSince1970: 300)))
        let blocked = try await server.client.blockUser("blocked_1", enabled: true, token: "own-voice-session")
        XCTAssertEqual(blocked.blockedUsers.first?.name, "被屏蔽用户")
        let unblocked = try await server.client.blockUser("blocked_1", enabled: false, token: "own-voice-session")
        XCTAssertTrue(unblocked.blockedIDs.isEmpty)
        XCTAssertEqual(calls.values, ["GET /v1/safety", "PUT /v1/safety/blocks/blocked_1", "DELETE /v1/safety/blocks/blocked_1"])
    }

    func testReportRetryKeepsNonceAndCarriesOnlyEvidenceReferences() async throws {
        let nonce = UUID().uuidString.lowercased()
        let calls = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer reporter")
            calls.append(request.url!.path)
            if request.url?.path == "/v1/safety/reports/mine" {
                return (200, try labJSON(["reports": [safetyReportFixture], "retentionDays": 30]))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try voiceRequestBody(request)
            XCTAssertEqual(body["clientRequestID"] as? String, nonce)
            XCTAssertEqual(body["targetType"] as? String, "message")
            XCTAssertEqual(body["targetUserID"] as? String, "blocked_1")
            XCTAssertEqual(body["messageID"] as? String, "msg_1")
            XCTAssertNil(body["reporterID"], "The server, never a claimed request field, identifies the reporter")
            XCTAssertNil(body["evidence"], "Authoritative message evidence is captured on the server")
            return (200, try labJSON(safetyReportFixture))
        }
        let value = KikiSafetyReportRequest(clientRequestID: nonce, targetType: .message, roomID: "voice_lab_1", targetUserID: "blocked_1", messageID: "msg_1", reason: .harassment, details: "重复骚扰")
        let first = try await server.client.submitReport(value, token: "reporter")
        let retry = try await server.client.submitReport(value, token: "reporter")
        XCTAssertEqual(first.id, retry.id)
        let mine = try await server.client.myReports(token: "reporter")
        XCTAssertEqual(mine.retentionDays, 30)
        XCTAssertEqual(mine.reports.first?.statusLabel, "待处理")
        XCTAssertEqual(calls.values, ["/v1/safety/reports", "/v1/safety/reports", "/v1/safety/reports/mine"])
    }

    func testSafetyInputCannotInjectPathsAndMessageReportsRequireTarget() async throws {
        let server = KikiVoiceAPIMockServer { _ in XCTFail("Invalid safety input must not send requests"); return (500, Data()) }
        for id in ["../me", "user?admin=true", "room/user", ""] {
            do { _ = try await server.client.blockUser(id, enabled: true, token: "s"); XCTFail("Invalid user path") }
            catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected security error") } }
        }
        let tooLong = KikiSafetyReportRequest(clientRequestID: UUID().uuidString, targetType: .user, roomID: "voice_lab_1", targetUserID: "blocked_1", messageID: nil, reason: .other, details: String(repeating: "a", count: 501))
        do { _ = try await server.client.submitReport(tooLong, token: "s"); XCTFail("Must match the server's 500-character report limit") }
        catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected security error") } }
        let multiScalar = KikiSafetyReportRequest(clientRequestID: UUID().uuidString, targetType: .user, roomID: "voice_lab_1", targetUserID: "blocked_1", messageID: nil, reason: .other, details: String(repeating: "🇨🇳", count: 251))
        do { _ = try await server.client.submitReport(multiScalar, token: "s"); XCTFail("Count Unicode scalars like the Python service, rather than grapheme clusters") }
        catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected security error") } }
        let invalid = KikiSafetyReportRequest(clientRequestID: UUID().uuidString, targetType: .message, roomID: "voice_lab_1", targetUserID: nil, messageID: nil, reason: .other, details: "")
        do { _ = try await server.client.submitReport(invalid, token: "s"); XCTFail("Missing target") }
        catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected security error") } }
    }

    func testModerationBanIsNotAnExpiredLogin() async throws {
        let server = KikiVoiceAPIMockServer { _ in
            (403, try labJSON(["detail": "语聊服务已封禁，请在社区安全中查看并申诉", "code": "voice_banned", "until": 2_000_000_000, "reason": "违规"]))
        }
        do { _ = try await server.client.rtcJoin(roomID: "voice_lab_1", token: "still-valid"); XCTFail("Ban must reject admission") }
        catch let error as KikiAPIError { XCTAssertFalse(error.isUnauthorized); XCTAssertTrue(error.localizedDescription.contains("封禁")) }
    }

    func testUnknownSafetySchemaFailsClosed() async throws {
        let server = KikiVoiceAPIMockServer { _ in var value = safetyFixture; value["schemaVersion"] = 2; return (200, try labJSON(value)) }
        do { _ = try await server.client.safety(token: "s"); XCTFail("Must not assume an unknown block-list schema is empty") }
        catch let error as KikiAPIError { guard case .invalidResponse = error else { return XCTFail("Expected schema failure") } }
    }
}

private var safetyFixture: [String: Any] {
    ["schemaVersion": 1, "blockedUsers": [["userID": "blocked_1", "name": "被屏蔽用户", "createdAt": 100]],
     "notices": [["id": "notice_1", "message": "请遵守社区规则", "createdAt": 100, "action": "warn", "expiresAt": NSNull()]],
     "restrictions": ["chatMutedUntil": NSNull(), "voiceMutedUntil": 200, "bannedUntil": NSNull()]]
}

private var safetyReportFixture: [String: Any] {
    ["id": "report_1", "status": "pending", "targetType": "message", "roomID": "voice_lab_1", "targetUserID": "blocked_1", "messageID": "msg_1", "reason": "harassment", "details": "重复骚扰", "createdAt": 100, "resolvedAt": NSNull()]
}

extension KikiVoiceAPIClientTests {
    @MainActor
    func testRoomAdmissionFailsBeforeMediaTokenWhenSafetyCannotLoad() async throws {
        let calls = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            calls.append(request.url!.path)
            XCTAssertEqual(request.url?.path, "/v1/safety", "No media admission is allowed before a durable block list is available")
            return (503, try labJSON(["detail": "暂不可用"]))
        }
        let rtc = KikiRTCService.shared
        rtc.configure(api: server.client)
        let credentials = try JSONDecoder().decode(KikiSDKCredentials.self, from: labJSON(labSDKFixture))
        try await rtc.login(credentials: credentials, sessionToken: "fixture-voice-session")
        do {
            try await rtc.presentRoom(roomID: "voice_lab_1", isLive: false, isOwner: false)
            XCTFail("Safety lookup failure must stop admission")
        } catch { XCTAssertFalse(rtc.isPresentingRoom); XCTAssertNil(rtc.currentRoomID) }
        XCTAssertEqual(calls.values, ["/v1/safety"])
        await rtc.logout()
        rtc.configure(api: .shared)
    }

    @MainActor
    func testCommunitySafetyScreensRenderAgainstAuthenticatedFixtures() async throws {
        let server = KikiVoiceAPIMockServer { request in
            let now = Int(Date().timeIntervalSince1970)
            if request.url?.path == "/v1/safety/reports/mine" {
                var report = safetyReportFixture; report["createdAt"] = now
                return (200, try labJSON(["reports": [report], "retentionDays": 30]))
            }
            var state = safetyFixture
            state["notices"] = [["id": "notice_1", "message": "请遵守社区规则", "createdAt": now, "action": "warn", "expiresAt": NSNull()]]
            state["restrictions"] = ["chatMutedUntil": NSNull(), "voiceMutedUntil": now + 3600, "bannedUntil": NSNull()]
            return (200, try labJSON(state))
        }
        let rtc = KikiRTCService.shared
        rtc.configure(api: server.client)
        let credentials = try JSONDecoder().decode(KikiSDKCredentials.self, from: labJSON(labSDKFixture))
        try await rtc.login(credentials: credentials, sessionToken: "fixture-voice-session")
        do {
            try await rtc.refreshSafety(includeReports: true)
            XCTAssertEqual(rtc.safetyState.blockedIDs, ["blocked_1"])
            XCTAssertEqual(rtc.myReports.first?.id, "report_1")
            try await attachSafetyScreen(KikiSafetyCenter(rtc: rtc), name: "p0-community-safety-center")
            try await attachSafetyScreen(KikiSafetyReportForm(rtc: rtc, target: .init(targetType: .message, roomID: "voice_lab_1", targetUserID: "blocked_1", messageID: "msg_1", name: "来自被举报用户的消息")), name: "p0-report-message-form")
        } catch {
            await rtc.logout(); rtc.configure(api: .shared)
            throw error
        }
        await rtc.logout()
        rtc.configure(api: .shared)
    }

    @MainActor
    private func attachSafetyScreen<V: View>(_ view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let controller = KikiSafetySnapshotHost(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        for _ in 0..<100 {
            if controller.didAppear { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.didAppear)
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try image.pngData()?.write(to: url)
        print("KIKI_P0_SCREENSHOT_PATH \(url.path)")
    }
}

@MainActor private final class KikiSafetySnapshotHost<Content: View>: UIHostingController<Content> {
    private(set) var didAppear = false
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); didAppear = true }
}


extension KikiVoiceAPIClientTests {
    @MainActor
    func testTimeoutKeepsAttemptStageAndDoesNotPersistRawErrorOrCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("queue.json")
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { _, _ in })
        outbox.bind(userID: "business-user", token: "secret-account-token")
        let trace = KikiRoomAttempt(operation: .joinRoom, roomID: "lk_" + String(repeating: "a", count: 32), identityEpoch: outbox.identityEpoch)
        trace.enter(.tokenAPI)
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiki-Attempt-ID"), trace.id)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiki-Operation"), "join_room")
            throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "raw-secret-room-token", NSURLErrorFailingURLStringErrorKey: "https://secret.invalid/?jwt=leak"])
        }
        do {
            _ = try await KikiIncidentContext.$attempt.withValue(trace) { try await server.client.rtcJoin(roomID: "voice_lab_1", token: "secret-voice-token") }
            XCTFail("Timeout expected")
        } catch {
            XCTAssertEqual((error as? KikiTransportFailure)?.code, .requestTimeout)
            XCTAssertNotNil(outbox.record(error, trace: trace))
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let event = try XCTUnwrap((body["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(event["attemptID"] as? String, trace.id)
        XCTAssertEqual(event["stage"] as? String, "token_api")
        XCTAssertEqual(event["code"] as? String, "request_timeout")
        for secret in ["raw-secret", "https://", "jwt", "secret-account-token", "secret-voice-token", "business-user"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertNil(outbox.record(URLError(.timedOut), trace: trace), "A failed attempt is recorded once")
        outbox.clear()
    }

    @MainActor
    func testHTTPFailureKeepsSafeServerCodeAndResponseRequestID() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var received: [KikiIncident] = []
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { event, _ in received.append(event) })
        outbox.bind(userID: "user", token: "account-token")
        let trace = KikiRoomAttempt(operation: .createRoom, identityEpoch: outbox.identityEpoch)
        trace.enter(.roomAPI)
        let server = KikiVoiceAPIMockServer { _ in (503, try labJSON(["detail": "raw backend text", "code": "capacity_reached"])) }
        do {
            _ = try await KikiIncidentContext.$attempt.withValue(trace) { try await server.client.reserveRoom(title: "private-title", category: "private-category", isLive: false, theme: 0, token: "voice-token") }
            XCTFail("Capacity rejection expected")
        } catch { outbox.record(error, trace: trace) }
        await outbox.flushNow()
        let event = try XCTUnwrap(received.first)
        XCTAssertEqual(event.operation, .createRoom); XCTAssertEqual(event.code, .capacityReached)
        XCTAssertEqual(event.httpStatus, 503); XCTAssertEqual(event.requestID, "72d30f65-50eb-487b-b9de-43abe63754aa")
        XCTAssertEqual(event.stage, .roomAPI)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(event), as: UTF8.self).contains("private"))
        XCTAssertEqual(outbox.pendingCount, 0)
        outbox.clear()
    }

    @MainActor
    func testIncidentOutboxRetriesAfterOfflineAndKeepsEventIDAcrossRelaunch() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var offline = true
        var sent: [KikiIncident] = []
        let sender: KikiIncidentReporter.Sender = { event, token in
            XCTAssertEqual(token, "account-only")
            sent.append(event)
            if offline { throw KikiTransportFailure(code: .networkUnavailable) }
        }
        let first = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: sender)
        first.bind(userID: "same-business-user", token: "account-only")
        let id = try XCTUnwrap(first.record(code: .mediaDisconnected))
        await first.flushNow()
        XCTAssertEqual(first.pendingCount, 1)
        let restored = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: sender)
        restored.bind(userID: "same-business-user", token: "account-only")
        XCTAssertEqual(restored.pendingCount, 1)
        offline = false
        await restored.flushNow()
        XCTAssertEqual(restored.pendingCount, 0)
        XCTAssertEqual(sent.map(\.eventID), [id, id], "Retries must be idempotent at the server")
        restored.clear(); first.clear()
    }

    @MainActor
    func testIncidentOutboxBoundExpiryPermissionsAndExcludedBackup() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        var received: [KikiIncident] = []
        let outbox = KikiIncidentReporter(queueURL: file, now: { date }, automaticRetry: false, sender: { event, _ in received.append(event) })
        outbox.bind(userID: "user", token: "account")
        for _ in 0..<105 { outbox.record(code: .requestTimeout) }
        XCTAssertEqual(outbox.pendingCount, 100)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        date = date.addingTimeInterval(7 * 86400 + 1)
        await outbox.flushNow()
        XCTAssertEqual(outbox.pendingCount, 0); XCTAssertTrue(received.isEmpty)
        outbox.clear()
    }

    @MainActor
    func testIncidentAccountSwitchLogoutAndStaleCompletionCannotLeakPreviousUser() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var sent: [String] = []
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { _, token in sent.append(token) })
        outbox.bind(userID: "first", token: "first-token")
        let stale = KikiRoomAttempt(operation: .joinRoom, identityEpoch: outbox.identityEpoch)
        outbox.record(code: .requestTimeout)
        outbox.bind(userID: "second", token: "second-token")
        XCTAssertEqual(outbox.pendingCount, 0)
        XCTAssertNil(outbox.record(URLError(.timedOut), trace: stale), "A late completion belongs to the old identity epoch")
        await outbox.flushNow(); XCTAssertTrue(sent.isEmpty)
        outbox.record(code: .networkError); outbox.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(outbox.record(code: .networkError))
    }

    @MainActor
    func testCancelledOperationsAndRepeatedQualityWarningsAreNotFlooded() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var date = Date()
        let outbox = KikiIncidentReporter(queueURL: file, now: { date }, automaticRetry: false, sender: { _, _ in })
        outbox.bind(userID: "user", token: "account")
        XCTAssertNil(outbox.record(CancellationError()))
        XCTAssertNil(outbox.record(URLError(.cancelled)))
        XCTAssertNotNil(outbox.record(code: .qualityPoor, severity: .warning, dedupeKey: "quality"))
        for _ in 0..<50 { XCTAssertNil(outbox.record(code: .qualityPoor, severity: .warning, dedupeKey: "quality")) }
        date = date.addingTimeInterval(301)
        XCTAssertNotNil(outbox.record(code: .qualityPoor, severity: .warning, dedupeKey: "quality"))
        XCTAssertEqual(outbox.pendingCount, 2)
        outbox.clear()
    }
}


extension KikiVoiceAPIClientTests {
    @MainActor
    func testIncidentUploadUsesAccountOriginAndClosedPayloadWithoutVoiceToken() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let requests = LabRequestLog()
        let mock = KikiAPIMockServer { request in
            requests.append(request.url!.path)
            XCTAssertFalse(request.url!.host!.hasPrefix("voice-"))
            XCTAssertEqual(request.url!.path, "/v1/voice/incidents")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-only")
            let body = try voiceRequestBody(request)
            XCTAssertEqual(body["code"] as? String, "request_timeout")
            XCTAssertEqual(body["stage"] as? String, "token_api")
            XCTAssertEqual(body["operation"] as? String, "join_room")
            XCTAssertEqual(Set(body.keys), ["eventID", "attemptID", "operation", "stage", "severity", "code", "occurredAt", "elapsedMs", "platform", "appVersion", "osVersion"])
            XCTAssertNotNil(UUID(uuidString: body["eventID"] as? String ?? ""))
            return (200, try labJSON(["ok": true, "queued": true]))
        }
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { event, token in try await mock.client.reportIncident(event, token: token) })
        outbox.bind(userID: "business-user", token: "account-only")
        let trace = KikiRoomAttempt(operation: .joinRoom, identityEpoch: outbox.identityEpoch)
        trace.enter(.tokenAPI)
        outbox.record(KikiTransportFailure(code: .requestTimeout), trace: trace)
        await outbox.flushNow()
        XCTAssertEqual(requests.values, ["/v1/voice/incidents"])
        XCTAssertEqual(outbox.pendingCount, 0)
        outbox.clear()
    }
}


extension KikiVoiceAPIClientTests {
    @MainActor
    func testNetworkRecoveryTriggerFlushesPersistedIncidentAutomatically() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var offline = true
        var delivered = false
        var attempts = 0
        let outbox = KikiIncidentReporter(queueURL: file, sender: { _, _ in
            attempts += 1
            if offline { throw KikiTransportFailure(code: .networkUnavailable) }
            delivered = true
        })
        outbox.bind(userID: "user", token: "account")
        outbox.record(code: .requestTimeout)
        XCTAssertEqual(outbox.pendingCount, 1, "Recording is local and does not wait for an upload")
        for _ in 0..<100 {
            if attempts > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(attempts, 0)
        XCTAssertEqual(outbox.pendingCount, 1)
        offline = false
        outbox.connectivityChanged(isAvailable: false)
        outbox.connectivityChanged(isAvailable: true)
        for _ in 0..<700 {
            if delivered && outbox.pendingCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(delivered)
        XCTAssertEqual(outbox.pendingCount, 0)
        outbox.clear()
    }
}


extension KikiVoiceAPIClientTests {
    @MainActor
    func testInvalidIncidentConflictDoesNotBlockFollowingEvents() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var calls = 0
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { _, _ in
            calls += 1
            if calls == 1 { throw KikiAPIError.server(409, "duplicate identifier with a conflicting payload") }
        })
        outbox.bind(userID: "user", token: "account")
        outbox.record(code: .requestTimeout); outbox.record(code: .networkError)
        await outbox.flushNow()
        XCTAssertEqual(calls, 2); XCTAssertEqual(outbox.pendingCount, 0)
        outbox.clear()
    }

    @MainActor
    func testIncidentAuthorizationFailureWaitsForFreshLoginWithoutTimedRetries() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var calls: [String] = []
        let outbox = KikiIncidentReporter(queueURL: file, sender: { _, token in
            calls.append(token)
            if token == "expired" { throw KikiAPIError.server(401, "expired") }
        })
        outbox.bind(userID: "user", token: "expired")
        outbox.record(code: .requestTimeout)
        try await Task.sleep(for: .milliseconds(5500))
        XCTAssertEqual(calls, ["expired"], "401 must not schedule the normal 5-second upload retry")
        XCTAssertEqual(outbox.pendingCount, 1)
        outbox.bind(userID: "user", token: "fresh")
        for _ in 0..<100 {
            if outbox.pendingCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(calls, ["expired", "fresh"]); XCTAssertEqual(outbox.pendingCount, 0)
        outbox.clear()
    }
}

extension KikiVoiceAPIClientTests {
    func testSocialSearchEncodesLiteralQueryAndOpaqueCursorOnAccountHostOnly() async throws {
        let query = "穷奇 &?/#_李"
        let cursor = "opaque.value+/=with:signature"
        let server = KikiAPIMockServer { request in
            XCTAssertFalse(request.url!.host!.hasPrefix("voice-"))
            XCTAssertEqual(request.url?.path, "/v1/social/people")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-session")
            let components = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "query" })?.value, query)
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cursor" })?.value, cursor)
            return (200, try labJSON(["people": [], "nextCursor": NSNull()]))
        }
        let result = try await server.client.socialPeople(query: query, cursor: cursor, token: "account-session")
        XCTAssertTrue(result.people.isEmpty)
    }

    func testSocialFollowAndDirectRetryKeepServerIdempotencyKeyWithoutClaimedIdentity() async throws {
        let requestID = UUID()
        let logs = LabRequestLog()
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-only")
            let body = try requestBody(request)
            XCTAssertEqual(body["requestID"] as? String, requestID.uuidString)
            XCTAssertNil(body["senderID"]); XCTAssertNil(body["userID"])
            logs.append(request.httpMethod ?? "")
            return (200, try labJSON(["message": ["id": UUID().uuidString, "seq": 1, "senderID": "kiki_viewer0000", "text": "你好", "createdAt": 1_792_400_000], "conversationID": UUID().uuidString]))
        }
        _ = try await server.client.socialSendDirect("kiki_target0000", text: "你好", requestID: requestID, token: "account-only")
        _ = try await server.client.socialSendDirect("kiki_target0000", text: "你好", requestID: requestID, token: "account-only")
        XCTAssertEqual(logs.values, ["POST", "POST"])
    }

    func testSocialMediaRejectsExternalOrMismatchedPathBeforeAttachingAccountToken() async throws {
        let server = KikiAPIMockServer { _ in XCTFail("Invalid media must not reach network"); return (500, Data()) }
        let id = UUID().uuidString
        for path in ["https://example.com/image.jpg", "/v1/avatars/public.jpg", "/v1/social/media/\(UUID().uuidString).jpg", "/v1/social/media/\(id).jpg?token=bad"] {
            let media = KikiSocialMedia(id: id, path: path, width: 100, height: 100)
            do { _ = try await server.client.socialImage(media, token: "private"); XCTFail("Invalid path must be rejected") }
            catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected security validation") } }
        }
    }

    func testHistoryDeletionUsesVoiceBearerAndSupportsWholeHistory() async throws {
        let methods = LabRequestLog()
        let server = KikiVoiceAPIMockServer { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer voice-only")
            methods.append(request.url!.path)
            return (200, try labJSON(["ok": true]))
        }
        try await server.client.removeHistory(roomID: "lk_" + String(repeating: "a", count: 32), token: "voice-only")
        try await server.client.removeHistory(roomID: nil, token: "voice-only")
        XCTAssertEqual(methods.values, ["/v1/history/lk_" + String(repeating: "a", count: 32), "/v1/history"])
    }

    @MainActor
    func testPhotoProcessorProducesSmallStaticJPEGWithoutLocationMetadata() throws {
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1800)).image { context in
            UIColor.systemPurple.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1800))
        }
        let original = try XCTUnwrap(picture.jpegData(compressionQuality: 1))
        let data = try KikiSocialPhotoProcessor.jpeg(original)
        XCTAssertLessThanOrEqual(data.count, 2 * 1024 * 1024)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(image.size.width, image.size.height), 1600)
    }
}

// Captured from the account backend's real FastAPI handlers using isolated fixture accounts.
extension KikiVoiceAPIClientTests {
    func testRealBackendSocialResponsesDecodeWithoutSchemaDrift() throws {
        let raw = #"""
{
  "person": {
    "person": {
      "id": "kiki_bdf9daeb7db3d0eb",
      "name": "contract-beta",
      "bio": "",
      "avatarIndex": 0,
      "avatarURL": null,
      "following": true,
      "followsYou": true,
      "mutual": true,
      "followingCount": 1,
      "followerCount": 1,
      "currentRoomID": null
    }
  },
  "people": {
    "people": [
      {
        "id": "kiki_bdf9daeb7db3d0eb",
        "name": "contract-beta",
        "bio": "",
        "avatarIndex": 0,
        "avatarURL": null,
        "following": true,
        "followsYou": true,
        "mutual": true,
        "followingCount": 1,
        "followerCount": 1,
        "currentRoomID": null
      }
    ],
    "nextCursor": null
  },
  "followingIDs": {
    "followingIDs": [
      "kiki_bdf9daeb7db3d0eb"
    ],
    "followingCount": 1,
    "followerCount": 1
  },
  "notifications": {
    "notifications": [
      {
        "id": "c950e271-a682-4bd0-826f-145903e1d6db",
        "kind": "follow",
        "actor": {
          "id": "kiki_bdf9daeb7db3d0eb",
          "name": "contract-beta",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": true,
          "followsYou": true,
          "mutual": true,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "text": "关注了你",
        "createdAt": 1792414070,
        "readAt": null,
        "roomID": null,
        "momentID": null
      },
      {
        "id": "728030be-74e4-4d04-9ce1-1fe40a4a7cf3",
        "kind": "system",
        "actor": {
          "id": "kiki_bdf9daeb7db3d0eb",
          "name": "contract-beta",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": true,
          "followsYou": true,
          "mutual": true,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "text": "评论了你的动态",
        "createdAt": 1792414070,
        "readAt": null,
        "roomID": null,
        "momentID": "bde78550-1524-4809-938d-c6665c85e4d9"
      },
      {
        "id": "41a35d2a-93e1-401f-9ca1-900d6121d2e7",
        "kind": "system",
        "actor": {
          "id": "kiki_bdf9daeb7db3d0eb",
          "name": "contract-beta",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": true,
          "followsYou": true,
          "mutual": true,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "text": "赞了你的动态",
        "createdAt": 1792414070,
        "readAt": null,
        "roomID": null,
        "momentID": "bde78550-1524-4809-938d-c6665c85e4d9"
      }
    ],
    "unreadCount": 3,
    "nextCursor": null,
    "retentionDays": 30
  },
  "media": {
    "id": "d967fb81-1092-45d4-8283-c36d7ce365d1",
    "path": "/v1/social/media/d967fb81-1092-45d4-8283-c36d7ce365d1.jpg",
    "width": 240,
    "height": 320
  },
  "moment": {
    "moment": {
      "id": "bde78550-1524-4809-938d-c6665c85e4d9",
      "author": {
        "id": "kiki_6b5907a2d4cb3fb5",
        "name": "contract-alpha",
        "bio": "",
        "avatarIndex": 0,
        "avatarURL": null,
        "following": false,
        "followsYou": false,
        "mutual": false,
        "followingCount": 1,
        "followerCount": 1,
        "currentRoomID": null
      },
      "text": "合约示例：今天一起聊聊音乐。",
      "media": [
        {
          "id": "d967fb81-1092-45d4-8283-c36d7ce365d1",
          "path": "/v1/social/media/d967fb81-1092-45d4-8283-c36d7ce365d1.jpg",
          "width": 240,
          "height": 320
        }
      ],
      "createdAt": 1792414070.640032,
      "likeCount": 1,
      "commentCount": 1,
      "liked": false,
      "canDelete": true
    }
  },
  "moments": {
    "moments": [
      {
        "id": "bde78550-1524-4809-938d-c6665c85e4d9",
        "author": {
          "id": "kiki_6b5907a2d4cb3fb5",
          "name": "contract-alpha",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": false,
          "followsYou": false,
          "mutual": false,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "text": "合约示例：今天一起聊聊音乐。",
        "media": [
          {
            "id": "d967fb81-1092-45d4-8283-c36d7ce365d1",
            "path": "/v1/social/media/d967fb81-1092-45d4-8283-c36d7ce365d1.jpg",
            "width": 240,
            "height": 320
          }
        ],
        "createdAt": 1792414070.640032,
        "likeCount": 1,
        "commentCount": 1,
        "liked": false,
        "canDelete": true
      }
    ],
    "nextCursor": null
  },
  "comment": {
    "comment": {
      "id": "c73f2b0c-6d32-48aa-8677-39bc6522e42a",
      "momentID": "bde78550-1524-4809-938d-c6665c85e4d9",
      "author": {
        "id": "kiki_bdf9daeb7db3d0eb",
        "name": "contract-beta",
        "bio": "",
        "avatarIndex": 0,
        "avatarURL": null,
        "following": false,
        "followsYou": false,
        "mutual": false,
        "followingCount": 1,
        "followerCount": 1,
        "currentRoomID": null
      },
      "text": "合约示例评论。",
      "createdAt": 1792414070.655947,
      "canDelete": true
    }
  },
  "comments": {
    "comments": [
      {
        "id": "c73f2b0c-6d32-48aa-8677-39bc6522e42a",
        "momentID": "bde78550-1524-4809-938d-c6665c85e4d9",
        "author": {
          "id": "kiki_bdf9daeb7db3d0eb",
          "name": "contract-beta",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": true,
          "followsYou": true,
          "mutual": true,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "text": "合约示例评论。",
        "createdAt": 1792414070.655947,
        "canDelete": false
      }
    ],
    "nextCursor": null
  },
  "messageReceipt": {
    "message": {
      "id": "28457d42-576d-46a2-90e5-3745a89b67da",
      "seq": 1,
      "senderID": "kiki_6b5907a2d4cb3fb5",
      "text": "合约示例私聊，无真实用户内容。",
      "createdAt": 1792414070
    },
    "conversationID": "1d4651fa-6e7e-423f-a8cc-e3d7deff8306"
  },
  "messages": {
    "conversationID": "1d4651fa-6e7e-423f-a8cc-e3d7deff8306",
    "messages": [
      {
        "id": "28457d42-576d-46a2-90e5-3745a89b67da",
        "seq": 1,
        "senderID": "kiki_6b5907a2d4cb3fb5",
        "text": "合约示例私聊，无真实用户内容。",
        "createdAt": 1792414070
      }
    ],
    "nextCursor": null,
    "canSend": true,
    "unreadCount": 0
  },
  "conversations": {
    "conversations": [
      {
        "id": "1d4651fa-6e7e-423f-a8cc-e3d7deff8306",
        "person": {
          "id": "kiki_6b5907a2d4cb3fb5",
          "name": "contract-alpha",
          "bio": "",
          "avatarIndex": 0,
          "avatarURL": null,
          "following": true,
          "followsYou": true,
          "mutual": true,
          "followingCount": 1,
          "followerCount": 1,
          "currentRoomID": null
        },
        "lastMessage": {
          "id": "28457d42-576d-46a2-90e5-3745a89b67da",
          "seq": 1,
          "senderID": "kiki_6b5907a2d4cb3fb5",
          "text": "合约示例私聊，无真实用户内容。",
          "createdAt": 1792414070
        },
        "unreadCount": 1,
        "canSend": true
      }
    ],
    "nextCursor": null,
    "unreadCount": 1
  },
  "reportReceipt": {
    "report": {
      "id": "75662da2-f82b-40ee-b8b2-7b5302713055",
      "targetType": "moment",
      "reason": "other",
      "status": "pending",
      "createdAt": 1792414070,
      "resolvedAt": null,
      "lastAction": null
    }
  },
  "reports": {
    "reports": [
      {
        "id": "75662da2-f82b-40ee-b8b2-7b5302713055",
        "targetType": "moment",
        "reason": "other",
        "status": "pending",
        "createdAt": 1792414070,
        "resolvedAt": null,
        "lastAction": null
      }
    ],
    "retentionDays": 30
  }
}
"""#
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        func data(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: XCTUnwrap(values[key])) }
        struct PersonResponse: Decodable { let person: KikiPerson }
        struct MomentResponse: Decodable { let moment: KikiMoment }
        struct CommentResponse: Decodable { let comment: KikiMomentComment }
        let decoder = JSONDecoder()
        _ = try decoder.decode(PersonResponse.self, from: data("person"))
        _ = try decoder.decode(KikiPeoplePage.self, from: data("people"))
        _ = try decoder.decode(KikiFollowingIDs.self, from: data("followingIDs"))
        _ = try decoder.decode(KikiNotificationsPage.self, from: data("notifications"))
        _ = try decoder.decode(KikiSocialMedia.self, from: data("media"))
        _ = try decoder.decode(MomentResponse.self, from: data("moment"))
        _ = try decoder.decode(KikiMomentsPage.self, from: data("moments"))
        _ = try decoder.decode(CommentResponse.self, from: data("comment"))
        _ = try decoder.decode(KikiCommentsPage.self, from: data("comments"))
        _ = try decoder.decode(KikiDirectMessageReceipt.self, from: data("messageReceipt"))
        _ = try decoder.decode(KikiDirectMessagesPage.self, from: data("messages"))
        _ = try decoder.decode(KikiConversationsPage.self, from: data("conversations"))
        _ = try decoder.decode(KikiSocialReportReceipt.self, from: data("reportReceipt"))
        _ = try decoder.decode(KikiSocialReportsPage.self, from: data("reports"))
    }
}

extension KikiVoiceAPIClientTests {
    func testUnifiedInboxOrdersAggregateNotificationsAmongPrivateConversations() {
        let notice = inboxNotice("notice", at: 200)
        let newer = inboxConversation("newer", at: 300, unread: 3)
        let older = inboxConversation("older", at: 100, unread: 0)
        let entries = KikiInboxEntry.merged(conversations: [older, newer], notifications: [notice], notificationUnreadCount: 8)
        XCTAssertEqual(entries.map(\.id), ["direct:newer", "notifications", "direct:older"])
        XCTAssertEqual(entries.map(\.unreadCount), [3, 8, 0])
        XCTAssertEqual(entries[1].name, "通知")
        XCTAssertEqual(entries[1].preview, notice.text)
    }

    func testUnifiedInboxUsesAuthoritativeUnreadCountAndNewestNotificationPreview() {
        let entries = KikiInboxEntry.merged(conversations: [], notifications: [inboxNotice("older", at: 100), inboxNotice("newer", at: 200)], notificationUnreadCount: 155)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].activityAt, 200)
        XCTAssertEqual(entries[0].preview, "newer 的通知")
        XCTAssertEqual(entries[0].unreadLabel, "99+")
        XCTAssertEqual(entries[0].unreadCount, 155, "Only a page is loaded; unread count must not be derived from the two visible items")
    }

    func testUnifiedInboxKeepsEmptyNotificationEntryWithoutInventingActivityAndDeduplicatesConversations() {
        let conversation = inboxConversation("notifications", at: 100, unread: -1)
        let entries = KikiInboxEntry.merged(conversations: [conversation, conversation], notifications: [], notificationUnreadCount: -4)
        XCTAssertEqual(entries.map(\.id), ["direct:notifications", "notifications"], "Typed IDs avoid a conversation colliding with the notification entry")
        XCTAssertNil(entries[1].activityAt, "An empty notification inbox must not pretend to have recent activity")
        XCTAssertNil(entries[0].unreadLabel); XCTAssertNil(entries[1].unreadLabel)
        XCTAssertEqual(entries[1].preview, "关注、点赞、评论与社区提醒")
    }

    func testUnifiedInboxCollapsesMultilinePreviewsAndKeepsDeterministicTimeTies() {
        var first = inboxConversation("a", at: 100, unread: 1)
        first = KikiConversation(id: first.id, person: first.person, lastMessage: KikiDirectMessage(id: "message", seq: 1, senderID: first.person.id, text: "第一行\n\n 第二行\t末尾", createdAt: 100), unreadCount: 1, canSend: true)
        let entries = KikiInboxEntry.merged(conversations: [inboxConversation("b", at: 100, unread: 0), first], notifications: [], notificationUnreadCount: 0)
        XCTAssertEqual(entries.map(\.id), ["direct:a", "direct:b", "notifications"])
        XCTAssertEqual(entries[0].preview, "第一行 第二行 末尾")
    }

    func testInboxTimeUsesLocalDayBoundariesInsteadOfOnlyMonthAndDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
        }
        let now = try date(2026, 10, 19, 10, 0)
        XCTAssertEqual(KikiInboxTime.label(try date(2026, 10, 19, 9, 5).timeIntervalSince1970, now: now, calendar: calendar), "09:05")
        XCTAssertEqual(KikiInboxTime.label(try date(2026, 10, 18, 23, 59).timeIntervalSince1970, now: now, calendar: calendar), "昨天")
        XCTAssertEqual(KikiInboxTime.label(try date(2026, 10, 17, 9, 0).timeIntervalSince1970, now: now, calendar: calendar), "星期六")
        XCTAssertEqual(KikiInboxTime.label(try date(2026, 9, 1, 9, 0).timeIntervalSince1970, now: now, calendar: calendar), "9/1")
        XCTAssertEqual(KikiInboxTime.label(try date(2025, 10, 19, 9, 0).timeIntervalSince1970, now: now, calendar: calendar), "25/10/19")
        XCTAssertNil(KikiInboxTime.label(nil, now: now, calendar: calendar))
        XCTAssertNil(KikiInboxTime.label(.nan, now: now, calendar: calendar))
    }

    func testDirectChatShowsTimeOnlyAcrossMeaningfulGapOrLocalMidnight() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 23, minute: 58))).timeIntervalSince1970
        XCTAssertFalse(KikiDirectTimeline.needsTimestamp(previous: start, current: start + 60, calendar: calendar))
        XCTAssertTrue(KikiDirectTimeline.needsTimestamp(previous: start, current: start + 120, calendar: calendar), "Crossing midnight needs context even with a short gap")
        XCTAssertTrue(KikiDirectTimeline.needsTimestamp(previous: start - 1000, current: start - 700, calendar: calendar))
    }
}

private func inboxPerson() -> KikiPerson {
    KikiPerson(id: "kiki_inboxfixture", name: "小岛", bio: "", avatarIndex: 4, avatarURL: nil, following: true, followsYou: true, mutual: true, followingCount: 1, followerCount: 1, currentRoomID: nil)
}
private func inboxNotice(_ id: String, at time: Double) -> KikiSocialNotification {
    KikiSocialNotification(id: id, kind: "follow", actor: inboxPerson(), text: id + " 的通知", createdAt: time, readAt: nil, roomID: nil, momentID: nil)
}
private func inboxConversation(_ id: String, at time: Double, unread: Int) -> KikiConversation {
    KikiConversation(id: id, person: inboxPerson(), lastMessage: KikiDirectMessage(id: "message-" + id, seq: 1, senderID: "kiki_inboxfixture", text: "晚上好", createdAt: time), unreadCount: unread, canSend: true)
}
