import XCTest
@testable import KikiTalk

final class KikiRoomRuntimeTests: XCTestCase {
    func testRoomTitlePolicyUsesNicknameDefaultAndTrimsExplicitNames() throws {
        XCTAssertEqual(try KikiRoomTitlePolicy.resolved(" \n ", nickname: "小岛"), "小岛的房间")
        XCTAssertEqual(try KikiRoomTitlePolicy.resolved("  今天聊电影 😀  ", nickname: "小岛"), "今天聊电影 😀")
        XCTAssertEqual(KikiRoomTitlePolicy.defaultTitle(nickname: ""), "我的房间")
        XCTAssertEqual(try KikiRoomTitlePolicy.validated(String(repeating: "中", count: 33)).utf8.count, 99)
    }

    func testRoomTitleDefaultPreservesSuffixAndUnicodeBoundariesWhenNicknameIsLong() throws {
        for nickname in [String(repeating: "中", count: 100), String(repeating: "a", count: 100),
                         String(repeating: "👩🏽‍💻", count: 100), "\u{0}\n"] {
            let title = KikiRoomTitlePolicy.defaultTitle(nickname: nickname)
            XCTAssertTrue(title.hasSuffix("的房间"))
            XCTAssertLessThanOrEqual(title.count, 36)
            XCTAssertLessThanOrEqual(title.utf8.count, 100)
            XCTAssertEqual(try KikiRoomTitlePolicy.validated(title), title)
        }
        for invalid in [String(repeating: "a", count: 37), String(repeating: "中", count: 34), "a\nb", "a\u{0}b"] {
            XCTAssertThrowsError(try KikiRoomTitlePolicy.resolved(invalid, nickname: "小岛"))
        }
    }

    @MainActor
    func testSafetyReadCoalescesAndCancellingAWaiterDoesNotCancelTheCallsRead() async throws {
        let owner = KikiSafetyReadOwner()
        let scope = KikiSafetyReadOwner.Scope(lifecycle: 1, mutation: 0, privacy: 0)
        let started = expectation(description: "one shared safety GET")
        let secondWaiting = expectation(description: "second waiter joins")
        var continuation: CheckedContinuation<Void, Error>?
        var requests = 0, applied = 0
        let first = Task {
            try await owner.read(scope: scope) { lease in
                requests += 1
                try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                    continuation = pending; started.fulfill()
                }
                if owner.isCurrent(lease) { applied += 1 }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let second = Task {
            secondWaiting.fulfill()
            try await owner.read(scope: scope) { _ in XCTFail("A concurrent screen must share the service-owned read") }
        }
        await fulfillment(of: [secondWaiting], timeout: 1)
        first.cancel()
        XCTAssertTrue(owner.isReading, "A disappearing screen must not cancel the live call's shared safety check")
        continuation?.resume()
        try await second.value
        do { try await first.value; XCTFail("The cancelled waiter must not continue its own UI work") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(applied, 1)
        XCTAssertFalse(owner.isReading)
    }

    @MainActor
    func testSafetyReadFailureIsHandledOnceForCoalescedWaiters() async throws {
        let owner = KikiSafetyReadOwner()
        let scope = KikiSafetyReadOwner.Scope(lifecycle: 1, mutation: 0, privacy: 0)
        let started = expectation(description: "shared network request")
        let joined = expectation(description: "second waiter")
        var continuation: CheckedContinuation<Void, Error>?
        var fences = 0
        let first = Task {
            try await owner.read(scope: scope) { lease in
                do {
                    try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                        continuation = pending; started.fulfill()
                    }
                } catch {
                    if owner.isCurrent(lease) { fences += 1 }
                    throw error
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        let second = Task {
            joined.fulfill()
            try await owner.read(scope: scope) { _ in XCTFail("Do not create a second safety request") }
        }
        await fulfillment(of: [joined], timeout: 1)
        first.cancel()
        continuation?.resume(throwing: URLError(.timedOut))
        do { try await first.value; XCTFail("Cancelled waiter resumed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await second.value; XCTFail("The real read failure must reach the active caller") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(fences, 1, "The service applies fail-closed once, even when the screen's waiter has gone away")
        XCTAssertFalse(owner.isReading)
    }

    @MainActor
    func testPrivacyOrMutationBoundaryRejectsLateSafetySuccessAndFailure() async throws {
        for oldReadFails in [false, true] {
            let owner = KikiSafetyReadOwner()
            let original = KikiSafetyReadOwner.Scope(lifecycle: 1, mutation: 0, privacy: 0)
            let updated = KikiSafetyReadOwner.Scope(lifecycle: 1, mutation: 0, privacy: 1)
            let started = expectation(description: "old HTTP snapshot held")
            var continuation: CheckedContinuation<Void, Error>?
            var blocked = false, failures = 0
            let old = Task {
                try await owner.read(scope: original) { lease in
                    do {
                        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                            continuation = pending; started.fulfill()
                        }
                        if owner.isCurrent(lease) { blocked = false }
                    } catch {
                        if owner.isCurrent(lease) { failures += 1 }
                        throw error
                    }
                }
            }
            await fulfillment(of: [started], timeout: 1)
            try await owner.read(scope: updated) { lease in
                XCTAssertTrue(owner.isCurrent(lease))
                blocked = true
            }
            if oldReadFails { continuation?.resume(throwing: URLError(.timedOut)) }
            else { continuation?.resume() }
            _ = await old.result
            XCTAssertTrue(blocked, "A pre-block HTTP snapshot cannot undo the verified block list")
            XCTAssertEqual(failures, 0, "A superseded failure cannot pause the newer audio session")
            XCTAssertFalse(owner.isReading)
        }
    }

    @MainActor
    func testExplicitSafetyOwnerCancellationFencesLateCompletionAndDoesNotClearANewRead() async throws {
        let owner = KikiSafetyReadOwner()
        let scope = KikiSafetyReadOwner.Scope(lifecycle: 1, mutation: 0, privacy: 0)
        let started = expectation(description: "old lifecycle read")
        let newerStarted = expectation(description: "new lifecycle read")
        var firstContinuation: CheckedContinuation<Void, Error>?
        var nextContinuation: CheckedContinuation<Void, Error>?
        var applied = 0
        let first = Task {
            try await owner.read(scope: scope) { lease in
                try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                    firstContinuation = pending; started.fulfill()
                }
                if owner.isCurrent(lease) { applied += 100 }
            }
        }
        await fulfillment(of: [started], timeout: 1)
        owner.cancel()
        XCTAssertFalse(owner.isReading)
        let next = Task {
            try await owner.read(scope: .init(lifecycle: 2, mutation: 0, privacy: 0)) { lease in
                try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                    nextContinuation = pending; newerStarted.fulfill()
                }
                if owner.isCurrent(lease) { applied += 1 }
            }
        }
        await fulfillment(of: [newerStarted], timeout: 1)
        firstContinuation?.resume()
        _ = await first.result
        XCTAssertTrue(owner.isReading, "An old task's defer must not clear the replacement task")
        XCTAssertEqual(applied, 0)
        nextContinuation?.resume()
        try await next.value
        XCTAssertEqual(applied, 1)
        XCTAssertFalse(owner.isReading)
    }

    func testRoomSyncHintsOnlyInvalidateKnownResources() throws {
        let hint = KikiRoomSyncHint(version: 1, resources: [.state, .gifts])
        XCTAssertEqual(KikiRoomSyncHint.decode(try JSONEncoder().encode(hint))?.resources, [.state, .gifts])
        for invalid in [
            "{\"version\":2,\"resources\":[\"state\"]}",
            "{\"version\":1,\"resources\":[]}",
            "{\"version\":1,\"resources\":[\"state\",\"state\"]}",
            "{\"version\":1,\"resources\":[\"permissions\"]}",
            "{\"version\":1,\"text\":\"forged message\"}"
        ] { XCTAssertNil(KikiRoomSyncHint.decode(Data(invalid.utf8))) }
        XCTAssertNil(KikiRoomSyncHint.decode(Data(repeating: 0, count: 513)))
    }

    func testRoomSyncGateCombinesBurstAndKeepsTrailingInvalidation() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        var gate = KikiRoomSyncHintGate(minimumInterval: 1.5)
        XCTAssertNil(gate.delay(now: now))
        gate.invalidate([.state])
        gate.invalidate([.chat, .gifts])
        XCTAssertEqual(gate.delay(now: now), 0)
        XCTAssertEqual(gate.take(now: now), [.state, .chat, .gifts])
        XCTAssertNil(gate.delay(now: now))
        // A new event while the previous GET is in flight cannot be discarded.
        gate.invalidate([.chat])
        gate.invalidate([.chat])
        XCTAssertEqual(try XCTUnwrap(gate.delay(now: now.addingTimeInterval(0.5))), 1, accuracy: 0.0001)
        XCTAssertTrue(gate.take(now: now.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(gate.pending, [.chat])
        XCTAssertEqual(gate.take(now: now.addingTimeInterval(1.5)), [.chat])
        XCTAssertEqual(gate.invalidationCount, 4)
        XCTAssertEqual(gate.batchCount, 2)
        XCTAssertNil(gate.delay(now: now.addingTimeInterval(2)))
    }

    func testRoomSyncHintFloodHasBoundedReadBatchesAndDeliversFinalResource() {
        let start = Date(timeIntervalSince1970: 1_000)
        var gate = KikiRoomSyncHintGate(minimumInterval: 1.5)
        var delivered: Set<KikiRoomSyncHint.Resource> = []
        for index in 0..<100 {
            let now = start.addingTimeInterval(Double(index) / 10)
            gate.invalidate(index == 99 ? [.gifts] : [.state])
            delivered.formUnion(gate.take(now: now))
        }
        XCTAssertEqual(gate.invalidationCount, 100)
        XCTAssertLessThanOrEqual(gate.batchCount, 7, "A packet flood must not become 100 HTTPS requests")
        XCTAssertTrue(gate.pending.contains(.gifts), "The final packet remains queued through the cooldown")
        delivered.formUnion(gate.take(now: start.addingTimeInterval(12)))
        XCTAssertEqual(delivered, [.state, .gifts])
        XCTAssertTrue(gate.pending.isEmpty)
        XCTAssertLessThanOrEqual(gate.batchCount, 8)
    }

    func testAppDeclaresBackgroundAudioForOngoingRoomCalls() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        XCTAssertTrue(modes?.contains("audio") == true,
                      "A live room's microphone and playback need the audio background capability")
    }

    func testUnexpiredVoiceAuthorizationSurvivesTemporaryControlPlaneFailures() {
        let now = Date(timeIntervalSince1970: 1_000)
        let failures: [Error] = [
            URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
            URLError(.cannotFindHost), URLError(.dnsLookupFailed), URLError(.networkConnectionLost),
            KikiTransportFailure(code: .requestTimeout), KikiTransportFailure(code: .networkUnavailable),
            KikiTransportFailure(code: .networkConnectionLost), KikiTransportFailure(code: .networkError),
            KikiAPIError.rateLimited(5, "请求较多"), KikiAPIError.server(408, "request timeout"),
            KikiAPIError.server(500, "temporary failure"), KikiAPIError.server(503, "unavailable"),
            KikiAPIError.server(599, "upstream unavailable")
        ]
        for failure in failures {
            XCTAssertTrue(KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: failure, expiresAt: 1_100, now: now),
                          "The existing valid media lease should survive \(failure)")
        }
    }

    func testVoiceAuthorizationNeverRecoversFromDefinitiveOrUntrustedFailures() {
        let now = Date(timeIntervalSince1970: 1_000)
        let failures: [Error] = [
            KikiAPIError.server(401, "revoked"), KikiAPIError.server(403, "forbidden"),
            KikiAPIError.server(404, "missing authorization"), KikiAPIError.server(422, "invalid identity"),
            KikiAPIError.security("identity changed"), KikiAPIError.legalUpdateRequired("同意新协议", nil),
            KikiAPIError.invalidResponse, KikiTransportFailure(code: .networkTLSFailed),
            URLError(.serverCertificateUntrusted), URLError(.secureConnectionFailed),
            URLError(.userAuthenticationRequired), URLError(.cancelled), CancellationError(),
            NSError(domain: "UnexpectedAuthorizationError", code: 1)
        ]
        for failure in failures {
            XCTAssertFalse(KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: failure, expiresAt: 1_100, now: now),
                           "A valid timestamp cannot override authorization, consent, trust, or cancellation: \(failure)")
        }
    }

    func testTemporaryNetworkFailureCannotExtendVoiceAuthorizationPastExpiry() {
        let failure = URLError(.timedOut)
        XCTAssertTrue(KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: failure, expiresAt: 1_000,
                                                                          now: Date(timeIntervalSince1970: 999.9)))
        let timestamps: [TimeInterval] = [1_000, 1_000.1, 1_001]
        for timestamp in timestamps {
            XCTAssertFalse(KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: failure, expiresAt: 1_000,
                                                                               now: Date(timeIntervalSince1970: timestamp)),
                           "The original signed expiry remains the hard deadline")
        }
        XCTAssertFalse(KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: failure, expiresAt: 0,
                                                                           now: Date(timeIntervalSince1970: 999)))
    }

    func testOrderedSeatStateDecodesPresenceAndRetainsLegacyCompatibility() throws {
        let member: [String: Any] = ["userID": "listener", "name": "听众", "avatarIndex": 2,
            "role": "member", "seatIndex": NSNull(), "audioMuted": false, "chatMuted": false,
            "online": true, "canPublishAudio": false, "canPublishData": true]
        let legacy = try JSONDecoder().decode(KikiRoomMember.self, from: JSONSerialization.data(withJSONObject: member))
        XCTAssertNil(legacy.offlineSince)
        XCTAssertNil(legacy.reconnectDeadline)
        XCTAssertEqual(legacy.seatRequestStatus, "none")
        var current = member
        current["online"] = false; current["offlineSince"] = 1_800_000_000
        current["reconnectDeadline"] = 1_800_000_060; current["seatRequestStatus"] = "approved"
        let offline = try JSONDecoder().decode(KikiRoomMember.self, from: JSONSerialization.data(withJSONObject: current))
        XCTAssertFalse(offline.online)
        XCTAssertEqual(offline.reconnectDeadline! - offline.offlineSince!, 60)
        XCTAssertEqual(offline.seatRequestStatus, "approved")
        XCTAssertEqual(try JSONDecoder().decode(KikiRoomMember.self, from: JSONEncoder().encode(offline)), offline)

        let request: [String: Any] = ["userID": "listener", "name": "听众", "requestedAt": 1, "position": 1]
        let oldRequest = try JSONDecoder().decode(KikiSeatRequest.self, from: JSONSerialization.data(withJSONObject: request))
        XCTAssertEqual(oldRequest.status, "pending")
        XCTAssertTrue(oldRequest.online)
        let approved = KikiSeatRequest(userID: "listener", name: "听众", requestedAt: 1, position: 1, status: "approved", online: false)
        XCTAssertEqual(try JSONDecoder().decode(KikiSeatRequest.self, from: JSONEncoder().encode(approved)), approved)
    }

    func testConfirmedMessageKeepsServerAvatarAfterSenderLeavesRoom() {
        let confirmed = KikiChatMessage(id: "message-departed", seq: 12, clientMessageID: "client-12",
                                        senderUserID: "departed", senderName: "已离开的朋友", senderAvatarIndex: 9,
                                        text: "稍后见 😀", createdAt: 1_800_000_100)
        // This mapping must not need the current membership list: history outlives presence.
        let displayed = KikiVoiceMessage(confirmed: confirmed, localUserID: "viewer")
        XCTAssertEqual(displayed.id, confirmed.id)
        XCTAssertEqual(displayed.senderID, confirmed.senderUserID)
        XCTAssertEqual(displayed.senderName, confirmed.senderName)
        XCTAssertEqual(displayed.senderAvatarIndex, 9)
        XCTAssertEqual(displayed.text, "稍后见 😀")
        XCTAssertEqual(displayed.createdAt, confirmed.createdAt)
        XCTAssertEqual(displayed.sequence, confirmed.seq)
        XCTAssertFalse(displayed.isLocal)
    }

    func testConfirmedMessageLocalFlagRequiresMatchingAuthenticatedIdentity() {
        let confirmed = KikiChatMessage(id: "message-me", seq: 13, clientMessageID: "client-13",
                                        senderUserID: "me", senderName: "我", senderAvatarIndex: 5,
                                        text: "本人发言", createdAt: 1_800_000_101)
        let mine = KikiVoiceMessage(confirmed: confirmed, localUserID: "me")
        XCTAssertTrue(mine.isLocal)
        XCTAssertEqual(mine.senderAvatarIndex, 5)
        XCTAssertFalse(KikiVoiceMessage(confirmed: confirmed, localUserID: "someone-else").isLocal)
        XCTAssertFalse(KikiVoiceMessage(confirmed: confirmed, localUserID: nil).isLocal,
                       "An unavailable session identity must not label another person's history as local")
    }

}
