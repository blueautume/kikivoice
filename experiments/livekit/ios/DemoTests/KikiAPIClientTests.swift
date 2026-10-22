import XCTest
@testable import KikiLiveKitLab

final class KikiAPIClientTests: XCTestCase {
    func testLabLoginSendsOnlyNicknameAccessCodeAndConsent() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/lab")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["name", "accessCode", "legalConsent"])
            XCTAssertEqual(body["name"] as? String, "小岛")
            XCTAssertEqual(body["accessCode"] as? String, "test-only-code")
            let legal = try XCTUnwrap(body["legalConsent"] as? [String: Any])
            XCTAssertEqual(legal["accepted"] as? Bool, true)
            XCTAssertEqual(legal["adultConfirmed"] as? Bool, true)
            return (200, try labJSON(["token": "lab-session", "user": labUserFixture, "sdk": labSDKFixture]))
        }
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let acceptance = KikiLegalAcceptance(versions: docs.versions, accepted: true, adultConfirmed: true)
        let response = try await server.client.loginForLab(name: "  小岛  ", accessCode: "test-only-code", legalConsent: acceptance)
        XCTAssertEqual(response.token, "lab-session")
        XCTAssertEqual(response.sdk.provider, "livekit")
        XCTAssertEqual(response.sdk.serverURL, "wss://furby.top")
    }

    func testRoomListAndParticipantTokenUseIndependentBearerSession() async throws {
        let paths = LabRequestLog()
        let server = KikiAPIMockServer { request in
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
        let server = KikiAPIMockServer { _ in XCTFail("Unsupported input must not make requests"); return (500, Data()) }
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
        let server = KikiAPIMockServer { _ in (401, try labJSON(["detail": "实验会话已过期"])) }
        do { _ = try await server.client.me(token: "expired"); XCTFail("Expected unauthorized") }
        catch let error as KikiAPIError { XCTAssertTrue(error.isUnauthorized); XCTAssertEqual(error.localizedDescription, "实验会话已过期") }
        let broken = KikiAPIMockServer { _ in (200, Data("{}".utf8)) }
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
        let server = KikiAPIMockServer { request in
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
        let server = KikiAPIMockServer { request in
            paths.append("\(request.httpMethod ?? "") \(request.url!.path)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer owner-session")
            if request.url?.path.hasSuffix("/actions") == true {
                let body = try requestBody(request)
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
        let server = KikiAPIMockServer { _ in XCTFail("Invalid seat must not make a request"); return (500, Data()) }
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
        let server = KikiAPIMockServer { request in
            calls.append(request.httpMethod ?? "")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lab-session")
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/messages")
            if request.httpMethod == "POST" {
                let body = try requestBody(request)
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
        let server = KikiAPIMockServer { _ in XCTFail("Invalid chat must not use network"); return (500, Data()) }
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
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_lab_1/quality")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["quality"])
            XCTAssertEqual(body["quality"] as? String, "unknown")
            return (202, try labJSON(["accepted": true]))
        }
        try await server.client.reportRoomQuality(roomID: "voice_lab_1", sample: KikiRoomQualitySample(quality: "unknown", rttMs: nil, jitterMs: nil, packetLossPercent: nil), token: "s")
        let limited = KikiAPIMockServer { _ in (429, try labJSON(["detail": "稍后再试"])) }
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
func requestData(_ request: URLRequest) throws -> Data {
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

func requestBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: requestData(request)) as? [String: Any])
}

/// Each mock has a unique host so concurrent test sessions cannot share stubs.
final class KikiAPIMockServer {
    let client: KikiAPIClient
    private let host: String
    private let session: URLSession

    init(contentType: String = "application/json", responder: @escaping KikiMockURLProtocol.Responder) {
        host = "\(UUID().uuidString.lowercased()).example.invalid"
        KikiMockURLProtocol.install(responder, host: host, contentType: contentType)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KikiMockURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAPIClient(baseURL: URL(string: "https://\(host)")!, session: session)
    }

    deinit {
        session.invalidateAndCancel()
        KikiMockURLProtocol.remove(host: host)
    }
}

final class KikiMockURLProtocol: URLProtocol, @unchecked Sendable {
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
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType]))
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

