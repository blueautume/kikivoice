import Combine
import Foundation
import XCTest
@testable import KikiTalk

@MainActor
final class KikiGiftTests: XCTestCase {
    func testGiftHintDuringOlderReadPerformsTrailingReadFromConfirmedCursor() async throws {
        let requests = ExperienceLocked<[String?]>([])
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let waiting = expectation(description: "older gift GET is pending")
        let server = ExperienceMockServer { exchange in
            let after = URLComponents(url: exchange.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value
            let count = requests.withValue { $0.append(after); return $0.count }
            if count == 1 { try exchange.respond(KikiGiftEventPage(events: [], cursor: 10, hasMore: false)) }
            else if count == 2 { pending.withValue { $0 = exchange }; waiting.fulfill() }
            else { try exchange.respond(KikiGiftEventPage(events: [experienceEvent("new-after-hint", seq: 11)], cursor: 11, hasMore: false)) }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.pollRoom(roomID: "voice_one")
        let older = Task { await gifts.pollRoom(roomID: "voice_one") }
        await fulfillment(of: [waiting], timeout: 2)
        let hint = Task { await gifts.pollRoom(roomID: "voice_one", invalidated: true) }
        await Task.yield()
        try await experienceAssertEventually { gifts.hasPendingRoomInvalidation }
        XCTAssertEqual(requests.value.count, 2, "A hint must join the existing request, then invalidate its older snapshot")
        try pending.value?.respond(KikiGiftEventPage(events: [], cursor: 10, hasMore: false))
        await older.value; await hint.value
        XCTAssertEqual(requests.value, [nil, "10", "10"], "The trailing read must retain the authoritative cursor, not reset the baseline")
        XCTAssertEqual(gifts.events.map(\.id), ["new-after-hint"])
        XCTAssertEqual(gifts.roomCursor, 11)
        XCTAssertFalse(gifts.hasPendingRoomInvalidation)
    }

    func testGiftHintDuringFirstBaselineKeepsNewEventWithoutReplayingHistory() async throws {
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let requests = ExperienceLocked<[String?]>([])
        let waiting = expectation(description: "first gift baseline is pending")
        let server = ExperienceMockServer { exchange in
            let after = URLComponents(url: exchange.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "after" }?.value
            let count = requests.withValue { $0.append(after); return $0.count }
            if count == 1 { pending.withValue { $0 = exchange }; waiting.fulfill() }
            else { try exchange.respond(KikiGiftEventPage(events: [experienceEvent("fresh", seq: 11)], cursor: 11, hasMore: false)) }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        let baseline = Task { await gifts.pollRoom(roomID: "voice_one") }
        await fulfillment(of: [waiting], timeout: 2)
        let hint = Task { await gifts.pollRoom(roomID: "voice_one", invalidated: true) }
        try await experienceAssertEventually { gifts.hasPendingRoomInvalidation }
        try pending.value?.respond(KikiGiftEventPage(events: [experienceEvent("historical", seq: 9)], cursor: 10, hasMore: false))
        await baseline.value; await hint.value
        XCTAssertEqual(requests.value, [nil, "10"])
        XCTAssertEqual(gifts.events.map(\.id), ["fresh"], "Only post-baseline gifts may animate after the trailing read")
        XCTAssertEqual(gifts.roomCursor, 11)
    }

    func testGiftRetryAfterSurvivesFiftyHintsAndRetriesPendingAtDeadline() async throws {
        let time = ExperienceLocked(Date(timeIntervalSince1970: 1_000))
        let requests = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            let count = requests.withValue { $0 += 1; return $0 }
            if count == 1 { try exchange.respond(KikiGiftEventPage(events: [], cursor: 10, hasMore: false)) }
            else if count == 2 { try exchange.respondError(429, headers: ["Retry-After": "60"]) }
            else { try exchange.respond(KikiGiftEventPage(events: [experienceEvent("after-retry", seq: 11)], cursor: 11, hasMore: false)) }
        }
        let gifts = KikiGiftStore(now: { time.value })
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.pollRoom(roomID: "voice_one")
        await gifts.pollRoom(roomID: "voice_one", invalidated: true)
        XCTAssertEqual(gifts.nextAllowedRoomPollAt, Date(timeIntervalSince1970: 1_060))
        for _ in 0..<50 { await gifts.pollRoom(roomID: "voice_one", invalidated: true) }
        XCTAssertEqual(requests.value, 2, "Reliable hint bursts cannot override server Retry-After")
        XCTAssertTrue(gifts.hasPendingRoomInvalidation)
        time.withValue { $0 = Date(timeIntervalSince1970: 1_059.9) }
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(requests.value, 2)
        time.withValue { $0 = Date(timeIntervalSince1970: 1_060) }
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(requests.value, 3)
        XCTAssertEqual(gifts.events.map(\.id), ["after-retry"])
        XCTAssertFalse(gifts.hasPendingRoomInvalidation)
        XCTAssertEqual(gifts.roomPollFailureCount, 0)
    }

    func testGiftServerFailuresUseExponentialBackoffWithoutLosingPendingHint() async throws {
        let time = ExperienceLocked(Date(timeIntervalSince1970: 1_000))
        let requests = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in requests.withValue { $0 += 1 }; try exchange.respondError(503) }
        let gifts = KikiGiftStore(now: { time.value })
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        for (failure, start, deadline) in [(1, 1_000.0, 1_002.0), (2, 1_002.0, 1_006.0), (3, 1_006.0, 1_014.0)] {
            time.withValue { $0 = Date(timeIntervalSince1970: start) }
            await gifts.pollRoom(roomID: "voice_one", invalidated: true)
            XCTAssertEqual(gifts.roomPollFailureCount, failure)
            XCTAssertEqual(gifts.nextAllowedRoomPollAt, Date(timeIntervalSince1970: deadline))
            for _ in 0..<10 { await gifts.pollRoom(roomID: "voice_one", invalidated: true) }
            XCTAssertEqual(requests.value, failure)
            XCTAssertTrue(gifts.hasPendingRoomInvalidation)
        }
        gifts.stopRoom()
        XCTAssertEqual(gifts.roomPollFailureCount, 0)
        XCTAssertFalse(gifts.hasPendingRoomInvalidation)
    }

    func testUnchangedExperienceRevalidationDoesNotPublishOrFlashLoading() async throws {
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot())
            case "/v1/decorations/users": try exchange.respond(KikiPublicDecorationPage(users: []))
            default: XCTFail("Unexpected refresh endpoint"); try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        await gifts.refreshDecorations(userIDs: ["host", "me"])
        var publications = 0
        var loadingStates: [Bool] = []
        let observation = gifts.objectWillChange.sink { publications += 1 }
        let loadingObservation = gifts.$isLoading.dropFirst().sink { loadingStates.append($0) }
        await gifts.refresh()
        await gifts.refreshDecorations(userIDs: ["host", "me"])
        XCTAssertEqual(publications, 0, "An unchanged server snapshot must not redraw the room or dim usable controls")
        XCTAssertTrue(loadingStates.isEmpty, "Only the first empty load needs a loading indicator")
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        observation.cancel()
        loadingObservation.cancel()
    }

    func testGiftInvalidationIsEmittedOnlyAfterServerConfirmation() async throws {
        let attempts = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/rooms/voice_one/gifts":
                let attempt = attempts.withValue { $0 += 1; return $0 }
                if attempt == 1 { try exchange.respondError(503) }
                else { try exchange.respond(KikiGiftSendResult(events: [], wallet: experienceWallet(99), totalCost: 1)) }
            default: XCTFail("Unexpected send endpoint"); try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        var invalidatedRooms: [String] = []
        gifts.onRoomGiftCommitted = { [weak gifts] roomID in
            XCTAssertEqual(gifts?.wallet?.balance, 99, "Authoritative receipt must be applied before notifying peers")
            invalidatedRooms.append(roomID)
        }
        do {
            _ = try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1,
                                     recipientIDs: ["host"], requestID: UUID())
            XCTFail("The first send should fail")
        } catch { }
        XCTAssertTrue(invalidatedRooms.isEmpty, "An unconfirmed send must not emit an event")
        _ = try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1,
                                 recipientIDs: ["host"], requestID: UUID())
        XCTAssertEqual(invalidatedRooms, ["voice_one"])
    }

    func testExperienceAPIsUseVoiceBearerAndExactServerOwnedPayloads() async throws {
        let log = ExperienceLocked<[String]>([])
        let requestID = UUID()
        let server = ExperienceMockServer { exchange in
            let request = exchange.request
            let path = request.url!.path
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer voice-session")
            log.withValue { $0.append("\(request.httpMethod!) \(path)\(request.url!.query.map { "?" + $0 } ?? "")") }
            switch path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot())
            case "/v1/me/wallet": try exchange.respond(experienceWallet())
            case "/v1/rooms/voice_one/gifts" where request.httpMethod == "POST":
                let body = try experienceBody(request)
                XCTAssertEqual(Set(body.keys), ["giftID", "quantity", "recipientIDs", "requestID"])
                XCTAssertEqual(body["giftID"] as? String, "heart")
                XCTAssertEqual(body["quantity"] as? Int, 10)
                XCTAssertEqual(body["recipientIDs"] as? [String], ["host", "listener"])
                XCTAssertEqual(body["requestID"] as? String, requestID.uuidString.lowercased())
                try exchange.respond(KikiGiftSendResult(events: [experienceEvent("sent", seq: 8)], wallet: experienceWallet(99_999_980), totalCost: 20))
            case "/v1/rooms/voice_one/gifts":
                try exchange.respond(KikiGiftEventPage(events: [], cursor: 7, hasMore: false))
            case "/v1/me/decorations/purchase":
                let body = try experienceBody(request)
                XCTAssertEqual(Set(body.keys), ["decorationID", "requestID"])
                XCTAssertEqual(body["decorationID"] as? String, "frame_violet")
                try exchange.respond(KikiDecorationPurchaseResult(wallet: experienceWallet(99_998_001), inventory: experienceInventory))
            case "/v1/me/decorations/equipped":
                XCTAssertEqual(request.httpMethod, "PUT")
                let body = try experienceBody(request)
                XCTAssertEqual(body["kind"] as? String, "avatarFrame")
                XCTAssertTrue(body["decorationID"] is NSNull, "Unequip must send an explicit null")
                try exchange.respond(KikiDecorationInventory(ownedIDs: ["frame_violet"], equipped: .empty))
            case "/v1/decorations/users":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "host,listener")
                try exchange.respond(KikiPublicDecorationPage(users: []))
            default: XCTFail("Unexpected experience endpoint: \(path)"); try exchange.respondError(404)
            }
        }
        let catalog = try await server.client.experienceCatalog(token: "voice-session")
        let snapshot = try await server.client.experience(token: "voice-session")
        let wallet = try await server.client.giftWallet(token: "voice-session")
        XCTAssertEqual(catalog, experienceCatalog)
        XCTAssertEqual(snapshot.wallet.balance, 100_000_000)
        XCTAssertEqual(wallet.currency, "diamond")
        _ = try await server.client.giftEvents(roomID: "voice_one", after: nil, token: "voice-session")
        _ = try await server.client.giftEvents(roomID: "voice_one", after: 7, token: "voice-session")
        _ = try await server.client.sendGift(roomID: "voice_one", giftID: "heart", quantity: 10, recipientIDs: ["host", "listener"], requestID: requestID, token: "voice-session")
        _ = try await server.client.purchaseDecoration(decorationID: "frame_violet", requestID: requestID, token: "voice-session")
        _ = try await server.client.equipDecoration(kind: .avatarFrame, decorationID: nil, token: "voice-session")
        _ = try await server.client.userDecorations(userIDs: ["listener", "host", "host"], token: "voice-session")
        XCTAssertTrue(log.value.contains("GET /v1/rooms/voice_one/gifts"))
        XCTAssertTrue(log.value.contains("GET /v1/rooms/voice_one/gifts?after=7"))
    }

    func testInvalidExperienceInputNeverReachesNetwork() async throws {
        let server = ExperienceMockServer { exchange in XCTFail("Invalid request reached network"); try exchange.respondError(500) }
        for (room, gift, quantity, recipients) in [
            ("../wallet", "heart", 1, ["host"]), ("voice_one", "../heart", 1, ["host"]),
            ("voice_one", "heart", 0, ["host"]), ("voice_one", "heart", 100, ["host"]),
            ("voice_one", "heart", 1, []), ("voice_one", "heart", 1, ["host", "host"]),
            ("voice_one", "heart", 1, ["host?admin=true"]),
            ("voice_one", "heart", 1, (0..<51).map { "user_\($0)" })
        ] {
            do {
                _ = try await server.client.sendGift(roomID: room, giftID: gift, quantity: quantity, recipientIDs: recipients, requestID: UUID(), token: "voice-session")
                XCTFail("Invalid gift input was accepted")
            } catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected input validation") } }
        }
        do { _ = try await server.client.giftEvents(roomID: "voice_one", after: -1, token: "voice-session"); XCTFail("Negative cursor accepted") }
        catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected cursor validation") } }
        do { _ = try await server.client.userDecorations(userIDs: (0..<101).map { "user_\($0)" }, token: "voice-session"); XCTFail("Unbounded query accepted") }
        catch let error as KikiAPIError { guard case .security = error else { return XCTFail("Expected query validation") } }
    }

    func testServerWalletAndOwnedEquipmentReloadAfterResetAndTokenRenewal() async throws {
        let persisted = ExperienceLocked(experienceSnapshot())
        let tokens = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            tokens.withValue { $0.append(exchange.request.value(forHTTPHeaderField: "Authorization") ?? "") }
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(persisted.value)
            case "/v1/me/decorations/purchase":
                persisted.withValue { $0 = experienceSnapshot(balance: 99_998_001, inventory: KikiDecorationInventory(ownedIDs: ["frame_violet"], equipped: .empty)) }
                try exchange.respond(KikiDecorationPurchaseResult(wallet: persisted.value.wallet, inventory: persisted.value.inventory))
            case "/v1/me/decorations/equipped":
                persisted.withValue { $0 = experienceSnapshot(balance: $0.wallet.balance, inventory: experienceInventory) }
                try exchange.respond(persisted.value.inventory)
            default: XCTFail("Unexpected request"); try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-old", userID: "me")
        XCTAssertNil(gifts.wallet, "Configuration must not grant client-side diamonds")
        await gifts.refresh()
        try await gifts.purchase(experienceDecoration, requestID: UUID())
        try await gifts.equip(kind: .avatarFrame, decorationID: "frame_violet")
        XCTAssertEqual(gifts.appearance(for: "me").avatarFrame, "frame_violet")
        gifts.configure(api: server.client, token: "voice-renewed", userID: "me")
        XCTAssertEqual(gifts.wallet?.balance, 99_998_001, "Token renewal must preserve the account snapshot")
        await gifts.refresh()
        XCTAssertTrue(tokens.value.contains("Bearer voice-renewed"))
        gifts.reset()
        XCTAssertFalse(gifts.isAvailable)
        XCTAssertNil(gifts.wallet)
        XCTAssertEqual(gifts.inventory, .empty)
        XCTAssertTrue(gifts.publicDecorations.isEmpty)
        gifts.configure(api: server.client, token: "voice-relogin", userID: "me")
        await gifts.refresh()
        XCTAssertEqual(gifts.wallet?.balance, 99_998_001)
        XCTAssertEqual(gifts.inventory, experienceInventory)
        XCTAssertEqual(gifts.entries.count, 1)
    }

    func testStaleSnapshotCannotUndoConfirmedDebitAndRefreshCoalesces() async throws {
        let waiting = expectation(description: "old snapshot waiting")
        let debited = expectation(description: "confirmed debit published")
        let oldSnapshot = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let snapshots = ExperienceLocked(0)
        let currentBalance = ExperienceLocked(100_000_000)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                let count = snapshots.withValue { $0 += 1; return $0 }
                if count == 2 { oldSnapshot.withValue { $0 = exchange }; waiting.fulfill() }
                else { try exchange.respond(experienceSnapshot(balance: currentBalance.value)) }
            case "/v1/me/decorations/purchase":
                currentBalance.withValue { $0 = 99_998_001 }
                try exchange.respond(KikiDecorationPurchaseResult(wallet: experienceWallet(99_998_001), inventory: experienceInventory))
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let observation = gifts.$wallet.sink { if $0?.balance == 99_998_001 { debited.fulfill() } }
        let refresh = Task { await gifts.refresh() }
        await fulfillment(of: [waiting], timeout: 2)
        let coalesced = Task { await gifts.refresh() }
        let purchase = Task { try await gifts.purchase(experienceDecoration, requestID: UUID()) }
        await fulfillment(of: [debited], timeout: 2)
        observation.cancel()
        XCTAssertEqual(gifts.wallet?.balance, 99_998_001)
        try oldSnapshot.value?.respond(experienceSnapshot())
        await refresh.value
        await coalesced.value
        try await purchase.value
        XCTAssertEqual(gifts.wallet?.balance, 99_998_001)
        XCTAssertEqual(snapshots.value, 3, "Readers share the stale request, then fetch one fresh snapshot")
        XCTAssertFalse(gifts.isLoading)
    }

    func testAccountSwitchRejectsLateMutationAndClearsPrivateAppearance() async throws {
        let waiting = expectation(description: "old account mutation waiting")
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                let isNew = exchange.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-account"
                try exchange.respond(experienceSnapshot(balance: isNew ? 55 : 100_000_000))
            case "/v1/me/decorations/purchase": pending.withValue { $0 = exchange }; waiting.fulfill()
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "old-account", userID: "old")
        await gifts.refresh()
        let purchase = Task { try await gifts.purchase(experienceDecoration, requestID: UUID()) }
        await fulfillment(of: [waiting], timeout: 2)
        gifts.configure(api: server.client, token: "new-account", userID: "new")
        await gifts.refresh()
        try pending.value?.respond(KikiDecorationPurchaseResult(wallet: experienceWallet(99_998_001), inventory: experienceInventory))
        do { try await purchase.value; XCTFail("Old account mutation must not complete in a new account") }
        catch is CancellationError { }
        XCTAssertEqual(gifts.userID, "new")
        XCTAssertEqual(gifts.wallet?.balance, 55)
        XCTAssertEqual(gifts.inventory, .empty)
        XCTAssertEqual(gifts.appearance(for: "old"), .empty)
        XCTAssertNil(gifts.errorMessage)
    }

    func testConcurrentEquipmentWritesWaitForEarlierResponse() async throws {
        let waiting = expectation(description: "first equipment write waiting")
        let prematureSecond = expectation(description: "second write cannot overtake the first")
        prematureSecond.isInverted = true
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let released = ExperienceLocked(false)
        let requested = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            let body = try experienceBody(exchange.request)
            let id = try XCTUnwrap(body["decorationID"] as? String)
            requested.withValue { $0.append(id) }
            if id == "frame_violet" { pending.withValue { $0 = exchange }; waiting.fulfill() }
            else {
                if !released.value { prematureSecond.fulfill() }
                let equipped = KikiEquippedDecorations(avatarFrame: "frame_gold", micEffect: nil, chatBubble: nil, roomBackground: nil)
                try exchange.respond(KikiDecorationInventory(ownedIDs: ["frame_violet", "frame_gold"], equipped: equipped))
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        let first = Task { try await gifts.equip(kind: .avatarFrame, decorationID: "frame_violet") }
        await fulfillment(of: [waiting], timeout: 2)
        let second = Task { try await gifts.equip(kind: .avatarFrame, decorationID: "frame_gold") }
        await fulfillment(of: [prematureSecond], timeout: 0.05)
        released.withValue { $0 = true }
        try pending.value?.respond(experienceInventory)
        try await first.value
        try await second.value
        XCTAssertEqual(requested.value, ["frame_violet", "frame_gold"])
        XCTAssertEqual(gifts.inventory.equipped.avatarFrame, "frame_gold")
    }

    func testResetPreventsQueuedSecondMutationFromReachingNetwork() async throws {
        let waiting = expectation(description: "first write waiting")
        let secondStarted = expectation(description: "second caller entered")
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let requested = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            let body = try experienceBody(exchange.request)
            let id = try XCTUnwrap(body["decorationID"] as? String)
            requested.withValue { $0.append(id) }
            if id == "frame_violet" { pending.withValue { $0 = exchange }; waiting.fulfill() }
            else { XCTFail("A queued write must not start after reset"); try exchange.respond(experienceInventory) }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        let first = Task { try await gifts.equip(kind: .avatarFrame, decorationID: "frame_violet") }
        await fulfillment(of: [waiting], timeout: 2)
        let second = Task {
            secondStarted.fulfill()
            try await gifts.equip(kind: .avatarFrame, decorationID: "frame_gold")
        }
        await fulfillment(of: [secondStarted], timeout: 2)
        await Task.yield()
        gifts.reset()
        try pending.value?.respond(experienceInventory)
        for mutation in [first, second] {
            do { try await mutation.value; XCTFail("An old epoch's mutation must be cancelled") }
            catch is CancellationError { }
        }
        XCTAssertEqual(requested.value, ["frame_violet"])
        XCTAssertFalse(gifts.isAvailable)
        XCTAssertEqual(gifts.inventory, .empty)
        XCTAssertTrue(gifts.publicDecorations.isEmpty)
        XCTAssertNil(gifts.errorMessage)
    }

    func testRoomCursorDoesNotReplayHistoryAndDeduplicatesSendAndPagedPolls() async throws {
        let queries = ExperienceLocked<[String]>([])
        let sent = ExperienceLocked(false)
        let server = ExperienceMockServer { exchange in
            let request = exchange.request
            switch request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: sent.value ? 99_999_999 : 100_000_000))
            case "/v1/rooms/voice_one/gifts" where request.httpMethod == "POST":
                sent.withValue { $0 = true }
                let event = experienceEvent("sent", seq: 15)
                try exchange.respond(KikiGiftSendResult(events: [event, event], wallet: experienceWallet(99_999_999), totalCost: 1))
            case "/v1/rooms/voice_one/gifts":
                let after = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                queries.withValue { $0.append(after ?? "initial") }
                let page: KikiGiftEventPage
                switch after {
                case nil: page = KikiGiftEventPage(events: [experienceEvent("history", seq: 9)], cursor: 10, hasMore: false)
                case "10": page = KikiGiftEventPage(events: [experienceEvent("a", seq: 11), experienceEvent("b", seq: 12)], cursor: 12, hasMore: true)
                case "12": page = KikiGiftEventPage(events: [experienceEvent("b", seq: 12), experienceEvent("c", seq: 13), experienceEvent("other-room", seq: 14, roomID: "voice_other")], cursor: 14, hasMore: false)
                case "14": page = KikiGiftEventPage(events: [experienceEvent("sent", seq: 15), experienceEvent("next", seq: 16)], cursor: 16, hasMore: false)
                default: page = KikiGiftEventPage(events: [], cursor: 16, hasMore: false)
                }
                try exchange.respond(page)
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertTrue(gifts.events.isEmpty, "The first response is only a baseline, even if it contains history")
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(gifts.events.map(\.id), ["a", "b", "c"])
        try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["host"], requestID: UUID())
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(gifts.events.map(\.id), ["a", "b", "c", "sent", "next"])
        XCTAssertEqual(queries.value, ["initial", "10", "12", "14"])
        gifts.stopRoom()
        XCTAssertTrue(gifts.events.isEmpty)
        XCTAssertEqual(gifts.wallet?.balance, 99_999_999)
    }

    func testRoomPollingBoundsPagesAndEventMemory() async throws {
        let polls = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            polls.withValue { $0 += 1 }
            let after = URLComponents(url: exchange.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value.flatMap(Int.init)
            guard let after else { try exchange.respond(KikiGiftEventPage(events: [], cursor: 0, hasMore: false)); return }
            let events = (1...100).map { experienceEvent("event_\(after + $0)", seq: after + $0) }
            try exchange.respond(KikiGiftEventPage(events: events, cursor: after + 100, hasMore: true))
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.pollRoom(roomID: "voice_one")
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(polls.value, 5, "One driver tick performs at most four pages")
        XCTAssertEqual(gifts.events.count, 200)
        XCTAssertEqual(gifts.events.first?.seq, 201)
        XCTAssertEqual(gifts.events.last?.seq, 400)
    }

    func testConfirmedSendAppearsBeforeAnyPollAndSurvivesFirstCursorBaseline() async throws {
        let queries = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 99_999_999))
            case "/v1/rooms/voice_one/gifts" where exchange.request.httpMethod == "POST":
                try exchange.respond(KikiGiftSendResult(events: [experienceEvent("confirmed", seq: 22)], wallet: experienceWallet(99_999_999), totalCost: 1))
            case "/v1/rooms/voice_one/gifts":
                queries.withValue { $0.append(exchange.request.url!.query ?? "initial") }
                try exchange.respond(KikiGiftEventPage(events: [experienceEvent("history", seq: 21), experienceEvent("confirmed", seq: 22)], cursor: 22, hasMore: false))
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["host"], requestID: UUID())
        XCTAssertEqual(gifts.events.map(\.id), ["confirmed"], "No poll is required to publish a confirmed send")
        XCTAssertTrue(queries.value.isEmpty)
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(gifts.events.map(\.id), ["confirmed"])
        XCTAssertEqual(queries.value, ["initial"], "A send must not invent a poll cursor")
    }

    func testPendingSendDoesNotAdvanceCursorPastOtherMembersNewEvents() async throws {
        let waiting = expectation(description: "first send waiting")
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let queries = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 99_999_999))
            case "/v1/rooms/voice_one/gifts" where exchange.request.httpMethod == "POST":
                pending.withValue { $0 = exchange }; waiting.fulfill()
            case "/v1/rooms/voice_one/gifts":
                let after = URLComponents(url: exchange.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
                queries.withValue { $0.append(after ?? "initial") }
                if after == nil { try exchange.respond(KikiGiftEventPage(events: [], cursor: 20, hasMore: false)) }
                else {
                    try exchange.respond(KikiGiftEventPage(events: [experienceEvent("other-new", seq: 21), experienceEvent("confirmed", seq: 22)], cursor: 22, hasMore: false))
                }
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        let send = Task { try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["host"], requestID: UUID()) }
        await fulfillment(of: [waiting], timeout: 2)
        // Poll while delivery is pending, so its cursor predates this and the
        // other member's confirmation. Sending must not replace that cursor.
        await gifts.pollRoom(roomID: "voice_one")
        try pending.value?.respond(KikiGiftSendResult(events: [experienceEvent("confirmed", seq: 22)], wallet: experienceWallet(99_999_999), totalCost: 1))
        try await send.value
        XCTAssertEqual(gifts.events.map(\.id), ["confirmed"])
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(gifts.events.map(\.id), ["other-new", "confirmed"])
        XCTAssertEqual(queries.value, ["initial", "20"])
    }

    func testRoomSwitchRejectsLateSendPresentationWhileKeepingConfirmedWallet() async throws {
        let waiting = expectation(description: "send waiting")
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 99_999_999))
            case "/v1/rooms/voice_one/gifts" where exchange.request.httpMethod == "POST": pending.withValue { $0 = exchange }; waiting.fulfill()
            default: try exchange.respond(KikiGiftEventPage(events: [], cursor: 0, hasMore: false))
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.pollRoom(roomID: "voice_one")
        let send = Task { try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["host"], requestID: UUID()) }
        await fulfillment(of: [waiting], timeout: 2)
        await gifts.pollRoom(roomID: "voice_two")
        try pending.value?.respond(KikiGiftSendResult(events: [experienceEvent("late", seq: 1)], wallet: experienceWallet(99_999_999), totalCost: 1))
        try await send.value
        XCTAssertTrue(gifts.events.isEmpty, "An old room's confirmation must not animate in the new room")
        XCTAssertEqual(gifts.wallet?.balance, 99_999_999)
    }

    func testPublicAppearanceCannotOverwriteOwnInventoryAndQueriesAreBounded() async throws {
        let ids = ExperienceLocked<[String]>([])
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(inventory: experienceInventory))
            case "/v1/decorations/users":
                let query = URLComponents(url: exchange.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value ?? ""
                ids.withValue { $0 = query.components(separatedBy: ",") }
                let stale = KikiEquippedDecorations(avatarFrame: "frame_gold", micEffect: nil, chatBubble: nil, roomBackground: nil)
                try exchange.respond(KikiPublicDecorationPage(users: [KikiPublicDecoration(userID: "a_me", equipped: stale), KikiPublicDecoration(userID: "a_other", equipped: stale)]))
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "a_me")
        await gifts.refresh()
        await gifts.refreshDecorations(userIDs: ["a_me", "a_other", "a_other"] + (0..<150).map { "user_\($0)" })
        XCTAssertEqual(ids.value.count, 100)
        XCTAssertEqual(Set(ids.value).count, 100)
        XCTAssertEqual(gifts.appearance(for: "a_me").avatarFrame, "frame_violet")
        XCTAssertEqual(gifts.appearance(for: "a_other").avatarFrame, "frame_gold")
        XCTAssertEqual(gifts.appearance(for: "unknown"), .empty)
    }

    func testMissingPublicUsersClearTheirCachedAppearance() async throws {
        let queries = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(inventory: experienceInventory))
            case "/v1/decorations/users":
                let count = queries.withValue { $0 += 1; return $0 }
                let equipped = KikiEquippedDecorations(avatarFrame: "frame_gold", micEffect: nil, chatBubble: nil, roomBackground: nil)
                try exchange.respond(KikiPublicDecorationPage(users: count == 1 ? [KikiPublicDecoration(userID: "host", equipped: equipped)] : []))
            default: XCTFail("Unexpected request"); try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        await gifts.refreshDecorations(userIDs: ["host"])
        XCTAssertEqual(gifts.appearance(for: "host").avatarFrame, "frame_gold")
        await gifts.refreshDecorations(userIDs: ["host", "me"])
        XCTAssertNil(gifts.publicDecorations["host"], "A missing or hidden user must lose their stale cached gear")
        XCTAssertEqual(gifts.appearance(for: "host"), .empty)
        XCTAssertEqual(gifts.appearance(for: "me"), experienceInventory.equipped)
    }

    func testCancelledPublicAppearanceRefreshDoesNotStartNetworkRequest() async throws {
        let server = ExperienceMockServer { exchange in XCTFail("A cancelled refresh must not reach the server"); try exchange.respond(KikiPublicDecorationPage(users: [])) }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        let refresh = Task { await gifts.refreshDecorations(userIDs: ["host"]) }
        refresh.cancel()
        await refresh.value
        XCTAssertTrue(gifts.publicDecorations.isEmpty)
        XCTAssertNil(gifts.errorMessage)
    }

    func testGiftInventoryDecodesOlderResponsesAndPreservesCurrentServerFields() throws {
        var oldSnapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(experienceSnapshot())) as? [String: Any])
        oldSnapshot.removeValue(forKey: "giftInventory")
        let decodedSnapshot = try JSONDecoder().decode(KikiExperienceSnapshot.self, from: JSONSerialization.data(withJSONObject: oldSnapshot))
        XCTAssertEqual(decodedSnapshot.giftInventory, [], "An older server response must not fabricate backpack items")

        let current = KikiGiftSendResult(events: [experienceEvent("mixed", seq: 1)], wallet: experienceWallet(19), totalCost: 1,
                                         giftInventory: [KikiGiftInventoryItem(giftID: "flower_rain", quantity: 3)],
                                         inventoryUsed: 2, diamondQuantity: 1, totalQuantity: 3)
        XCTAssertEqual(try JSONDecoder().decode(KikiGiftSendResult.self, from: JSONEncoder().encode(current)), current)
        var oldSend = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        for key in ["giftInventory", "inventoryUsed", "diamondQuantity", "totalQuantity"] { oldSend.removeValue(forKey: key) }
        let decodedSend = try JSONDecoder().decode(KikiGiftSendResult.self, from: JSONSerialization.data(withJSONObject: oldSend))
        XCTAssertEqual(decodedSend.giftInventory, [])
        XCTAssertEqual(decodedSend.inventoryUsed, 0)
        XCTAssertEqual(decodedSend.diamondQuantity, 0)
        XCTAssertEqual(decodedSend.totalQuantity, 0)
        XCTAssertEqual(decodedSend.wallet.balance, 19)
        XCTAssertEqual(decodedSend.totalCost, 1)
    }

    func testBackpackReloadsFromServerOrdersOwnedFirstAndReceivingDoesNotCreateInventory() async throws {
        let bag = [KikiGiftInventoryItem(giftID: "heart", quantity: 10), KikiGiftInventoryItem(giftID: "aurora_car", quantity: 1)]
        let catalog = KikiExperienceCatalog(gifts: [experienceFlower, experienceGift, experienceCar], decorations: [], initialGrant: 100_000_000)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(catalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(giftInventory: bag))
            default:
                let hasCursor = exchange.request.url!.query != nil
                try exchange.respond(KikiGiftEventPage(events: hasCursor ? [experienceEvent("received", seq: 1, senderID: "friend", recipientID: "me")] : [], cursor: hasCursor ? 1 : 0, hasMore: false))
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        XCTAssertEqual(gifts.giftInventory, [], "Configuration must wait for the server's one-time package")
        await gifts.refresh()
        XCTAssertEqual(gifts.giftCount("heart"), 10)
        XCTAssertEqual(gifts.giftCount("unknown"), 0)
        XCTAssertEqual(gifts.orderedGiftItems.map(\.id), ["heart", "aurora_car", "flower_rain"])
        await gifts.pollRoom(roomID: "voice_one")
        await gifts.pollRoom(roomID: "voice_one")
        XCTAssertEqual(gifts.events.map(\.id), ["received"])
        XCTAssertEqual(gifts.giftInventory, bag, "Receiving gifts never creates transferable backpack stock")
        gifts.reset()
        XCTAssertTrue(gifts.giftInventory.isEmpty)
        gifts.configure(api: server.client, token: "renewed-session", userID: "me")
        await gifts.refresh()
        XCTAssertEqual(gifts.giftInventory, bag, "Reinstallation or relogin reloads the existing server grant")
    }

    func testMixedBackpackAndDiamondSendUsesAuthoritativeResponseWithoutLocalGrant() async throws {
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                try exchange.respond(experienceSnapshot(balance: 20, giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]))
            case "/v1/rooms/voice_one/gifts":
                let body = try experienceBody(exchange.request)
                XCTAssertEqual(body["quantity"] as? Int, 1)
                XCTAssertEqual(Set(body["recipientIDs"] as? [String] ?? []), ["a", "b", "c"])
                try exchange.respond(KikiGiftSendResult(events: [experienceEvent("mixed", seq: 1)], wallet: experienceWallet(19), totalCost: 1,
                                                       giftInventory: [], inventoryUsed: 2, diamondQuantity: 1, totalQuantity: 3))
            default: try exchange.respondError(404)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let result = try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["a", "b", "c"], requestID: UUID())
        XCTAssertEqual(result.inventoryUsed, 2)
        XCTAssertEqual(result.diamondQuantity, 1)
        XCTAssertEqual(result.totalQuantity, 3)
        XCTAssertEqual(gifts.wallet?.balance, 19)
        XCTAssertEqual(gifts.giftCount("heart"), 0)
        XCTAssertTrue(gifts.giftInventory.isEmpty)
    }

    func testGiftRecipientsRequirePositiveSeatAndExcludeSenderAudienceOfflineAndDuplicates() {
        func member(_ id: String, _ name: String, role: KikiRoomRole = .member, online: Bool = true,
                    seat: Int? = 1) -> KikiRoomMember {
            KikiRoomMember(userID: id, name: name, avatarIndex: 0, avatarURL: nil, role: role,
                           seatIndex: seat, audioMuted: true, chatMuted: false, online: online,
                           canPublishAudio: false, canPublishData: true)
        }
        let owner = member("owner", "Zoe", role: .owner)
        let alice = member("alice", "Alice")
        let bob = member("bob", "Bob")
        let members = [bob, member("offline", "Aaron", online: false), owner, alice,
                       member("", "Empty ID"), bob, member("audience", "Audience", seat: nil),
                       member("zero", "Zero seat", seat: 0), member("negative", "Negative seat", seat: -1)]

        XCTAssertEqual(KikiGiftRecipientPolicy.eligibleMembers(members, senderID: "owner", hostID: "owner").map(\.userID),
                       ["alice", "bob"], "The owner must not appear in their own recipient picker")
        XCTAssertEqual(KikiGiftRecipientPolicy.eligibleMembers(members, senderID: "bob", hostID: "owner").map(\.userID),
                       ["owner", "alice"], "An ordinary member must be excluded while the other owner stays first")
        XCTAssertTrue(KikiGiftRecipientPolicy.eligibleMembers([owner], senderID: "owner", hostID: "owner").isEmpty)
        XCTAssertTrue(KikiGiftRecipientPolicy.eligibleMembers([bob], senderID: "bob", hostID: "owner").isEmpty)
        XCTAssertTrue(KikiGiftRecipientPolicy.eligibleMembers(members, senderID: nil, hostID: "owner").isEmpty)
        XCTAssertTrue(KikiGiftRecipientPolicy.eligibleMembers(members, senderID: "", hostID: "owner").isEmpty)
    }

    func testSelfAndMixedSelfGiftRequestsNeverReachNetworkOrChangeWalletInventoryQueueOrRoomEvents() async throws {
        let requests = ExperienceLocked<[String]>([])
        let bag = [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]
        let requestID = UUID()
        let confirmed = experienceEvent("other-confirmed", seq: 1)
        let server = ExperienceMockServer { exchange in
            let request = exchange.request
            requests.withValue { $0.append("\(request.httpMethod!) \(request.url!.path)") }
            switch request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                try exchange.respond(experienceSnapshot(balance: 20, inventory: experienceInventory, giftInventory: bag))
            case "/v1/rooms/voice_one/gifts":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer voice-session")
                let body = try experienceBody(request)
                XCTAssertEqual(body["recipientIDs"] as? [String], ["host"])
                XCTAssertEqual(body["quantity"] as? Int, 1)
                XCTAssertEqual(body["requestID"] as? String, requestID.uuidString.lowercased())
                try exchange.respond(KikiGiftSendResult(events: [confirmed], wallet: experienceWallet(20), totalCost: 0,
                                                       giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 1)],
                                                       inventoryUsed: 1, diamondQuantity: 0, totalQuantity: 1))
            default: XCTFail("A rejected self gift must not issue any request"); try exchange.respondError(500)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let originalWallet = gifts.wallet
        let originalEntries = gifts.entries
        let originalRequests = requests.value
        let queue = gifts.sendQueue(for: "voice_rejected")

        for recipients in [["me"], ["host", "me"], ["me", "host"]] {
            XCTAssertNil(queue.nextQuote(gift: experienceGift, recipientIDs: recipients))
            XCTAssertFalse(queue.enqueue(gift: experienceGift, recipientIDs: recipients))
            do {
                _ = try await gifts.send(roomID: "voice_rejected", gift: experienceGift, quantity: 1,
                                         recipientIDs: recipients, requestID: UUID())
                XCTFail("Any batch containing the sender must be rejected as a whole")
            } catch let error as KikiAPIError {
                guard case .server(422, _) = error else { return XCTFail("Expected self-gift validation") }
            }
        }
        await Task.yield()
        XCTAssertEqual(requests.value, originalRequests)
        XCTAssertEqual(gifts.wallet, originalWallet)
        XCTAssertEqual(gifts.entries, originalEntries)
        XCTAssertEqual(gifts.giftInventory, bag)
        XCTAssertEqual(gifts.inventory, experienceInventory)
        XCTAssertTrue(gifts.events.isEmpty)
        XCTAssertNil(gifts.roomCursor)
        XCTAssertNil(gifts.errorMessage)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertFalse(queue.isSending)
        XCTAssertFalse(queue.isPaused)
        XCTAssertNil(queue.lastCombo)

        let quote = try XCTUnwrap(queue.nextQuote(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertEqual(quote.inventoryUsed, 1, "Rejected taps must not reserve backpack items")
        XCTAssertEqual(quote.totalCost, 0)
        XCTAssertTrue(quote.isAffordable)
        _ = try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1,
                                 recipientIDs: ["host"], requestID: requestID)
        XCTAssertEqual(requests.value.count, originalRequests.count + 1)
        XCTAssertEqual(gifts.giftCount("heart"), 1)
        XCTAssertEqual(gifts.wallet?.balance, 20)
        XCTAssertEqual(gifts.events, [confirmed], "Rejected sends must not bind the store to the rejected room")
    }

    func testQueueQuoteReservesBackpackAndDiamondsBeforeConfirmationAndRejectsUnaffordableTap() async throws {
        let waiting = expectation(description: "send remains unconfirmed")
        let pending = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                try exchange.respond(experienceSnapshot(balance: 1, giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]))
            default: pending.withValue { $0 = exchange }; waiting.fulfill()
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let queue = gifts.sendQueue(for: "voice_one")
        let firstQuote = try XCTUnwrap(queue.nextQuote(gift: experienceGift, recipientIDs: ["a", "b", "c"]))
        XCTAssertEqual(firstQuote.inventoryUsed, 2)
        XCTAssertEqual(firstQuote.diamondQuantity, 1)
        XCTAssertEqual(firstQuote.totalQuantity, 3)
        XCTAssertEqual(firstQuote.totalCost, 1)
        XCTAssertTrue(firstQuote.isAffordable)
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["a", "b", "c"]))
        await fulfillment(of: [waiting], timeout: 2)
        let reserved = try XCTUnwrap(queue.nextQuote(gift: experienceGift, recipientIDs: ["a", "b", "c"]))
        XCTAssertEqual(reserved.inventoryUsed, 0)
        XCTAssertEqual(reserved.diamondQuantity, 3)
        XCTAssertEqual(reserved.totalCost, 3)
        XCTAssertFalse(reserved.isAffordable)
        XCTAssertFalse(queue.enqueue(gift: experienceGift, recipientIDs: ["a", "b", "c"]))
        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertNil(queue.lastCombo, "A tap must not announce ×1 before a server confirmation")
        XCTAssertEqual(gifts.giftCount("heart"), 2, "Reservations must not mutate the authoritative inventory")
        XCTAssertEqual(gifts.wallet?.balance, 1)
        gifts.reset()
        try pending.value?.respond(KikiGiftSendResult(events: [], wallet: experienceWallet(0), totalCost: 1,
                                                     giftInventory: [], inventoryUsed: 2, diamondQuantity: 1, totalQuantity: 3))
    }

    func testQueueSendsFrozenSingleUnitsInFIFOAndCountsOnlyConfirmedSameTargetCombo() async throws {
        let requests = ExperienceLocked<[(ExperienceMockProtocol, [String: Any])]>([])
        let snapshotCount = ExperienceLocked(0)
        let persisted = ExperienceLocked(experienceSnapshot(balance: 1_000))
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(KikiExperienceCatalog(gifts: [experienceGift, experienceFlower], decorations: [], initialGrant: 100_000_000))
            case "/v1/me/experience": snapshotCount.withValue { $0 += 1 }; try exchange.respond(persisted.value)
            default:
                let body = try experienceBody(exchange.request)
                requests.withValue { $0.append((exchange, body)) }
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let queue = gifts.sendQueue(for: "voice_one")
        var selected = ["host", "listener"]
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: selected))
        selected = ["other"]
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["listener", "host"]))
        XCTAssertTrue(queue.enqueue(gift: experienceFlower, recipientIDs: selected))
        XCTAssertNil(queue.lastCombo)
        try await experienceAssertEventually { requests.value.count == 1 }
        XCTAssertEqual(queue.pendingCount, 3)
        XCTAssertEqual(Set(requests.value[0].1["recipientIDs"] as? [String] ?? []), ["host", "listener"])
        XCTAssertEqual(requests.value[0].1["quantity"] as? Int, 1)
        try requests.value[0].0.respond(KikiGiftSendResult(events: [experienceEvent("one", seq: 1)], wallet: experienceWallet(998), totalCost: 2,
                                                        giftInventory: [], inventoryUsed: 0, diamondQuantity: 2, totalQuantity: 2))
        try await experienceAssertEventually { requests.value.count == 2 }
        XCTAssertEqual(queue.lastCombo?.count, 1)
        XCTAssertEqual(queue.lastCombo?.totalCost, 2)
        XCTAssertEqual(queue.lastCombo?.inventoryUsed, 0)
        XCTAssertEqual(Set(queue.lastCombo?.recipientIDs ?? []), ["host", "listener"])
        XCTAssertEqual(Set(requests.value[1].1["recipientIDs"] as? [String] ?? []), ["host", "listener"])
        try requests.value[1].0.respond(KikiGiftSendResult(events: [experienceEvent("two", seq: 2)], wallet: experienceWallet(996), totalCost: 2,
                                                        giftInventory: [], inventoryUsed: 0, diamondQuantity: 2, totalQuantity: 2))
        try await experienceAssertEventually { requests.value.count == 3 }
        XCTAssertEqual(queue.lastCombo?.count, 2, "Changing recipient display order must preserve the same-target combo")
        XCTAssertEqual(queue.lastCombo?.totalCost, 4)
        XCTAssertEqual(requests.value[2].1["giftID"] as? String, "flower_rain")
        XCTAssertEqual(requests.value[2].1["recipientIDs"] as? [String], ["other"])
        persisted.withValue { $0 = experienceSnapshot(balance: 897) }
        try requests.value[2].0.respond(KikiGiftSendResult(events: [experienceEvent("three", seq: 3, gift: experienceFlower, recipientID: "other")], wallet: experienceWallet(897), totalCost: 99,
                                                        giftInventory: [], inventoryUsed: 0, diamondQuantity: 1, totalQuantity: 1))
        try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
        XCTAssertEqual(queue.lastCombo?.giftID, "flower_rain")
        XCTAssertEqual(queue.lastCombo?.count, 1)
        XCTAssertEqual(queue.lastCombo?.totalCost, 99)
        XCTAssertEqual(gifts.wallet?.balance, 897)
        let ids = requests.value.compactMap { $0.1["requestID"] as? String }
        XCTAssertEqual(Set(ids).count, 3, "Every physical tap owns a different idempotency key")
        try await experienceAssertEventually { snapshotCount.value == 2 }
        XCTAssertEqual(snapshotCount.value, 2, "A drained queue refreshes the ledger once, rather than after each tap")
        queue.resetCombo()
        XCTAssertNil(queue.lastCombo)
    }

    func testTransientFailureAndRateLimitRecoverOriginalUUIDWithoutPausingOrDuplicateDebit() async throws {
        for status in [Int?.none, 500, 408, 429] {
            let requests = ExperienceLocked<[[String: Any]]>([])
            let persisted = ExperienceLocked(experienceSnapshot(balance: 40, giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]))
            let receipts = ExperienceLocked<[String: KikiGiftSendResult]>([:])
            let server = ExperienceMockServer { exchange in
                switch exchange.request.url!.path {
                case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
                case "/v1/me/experience": try exchange.respond(persisted.value)
                default:
                    let body = try experienceBody(exchange.request)
                    let count = requests.withValue { $0.append(body); return $0.count }
                    if count == 1, status == 429 {
                        try exchange.respondError(429, headers: ["Retry-After": "60"])
                        return
                    }
                    // Simulate the difficult case: the server committed, but
                    // its first response was lost. Only a new UUID can debit.
                    let requestID = try XCTUnwrap(body["requestID"] as? String)
                    let receipt = receipts.withValue { receipts -> KikiGiftSendResult in
                        if let receipt = receipts[requestID] { return receipt }
                        let sequence = receipts.count + 1
                        let remaining = 2 - sequence
                        let bag = remaining > 0 ? [KikiGiftInventoryItem(giftID: "heart", quantity: remaining)] : []
                        let receipt = KikiGiftSendResult(events: [experienceEvent("confirmed_\(sequence)", seq: sequence)], wallet: experienceWallet(40), totalCost: 0,
                                                        giftInventory: bag, inventoryUsed: 1, diamondQuantity: 0, totalQuantity: 1)
                        receipts[requestID] = receipt
                        persisted.withValue { $0 = experienceSnapshot(balance: 40, giftInventory: bag) }
                        return receipt
                    }
                    if count == 1 {
                        if let status { try exchange.respondError(status) }
                        else { throw URLError(.networkConnectionLost) }
                    } else { try exchange.respond(receipt) }
                }
            }
            let gifts = KikiGiftStore()
            gifts.configure(api: server.client, token: "voice-session", userID: "me")
            await gifts.refresh()
            let clock = ExperienceQueueClock()
            let queue = KikiGiftSendQueue(gifts: gifts, roomID: "voice_one", now: { clock.date }, sleep: { try await clock.sleep($0) })
            clock.onSleep = {
                XCTAssertFalse(queue.isPaused)
                XCTAssertNil(queue.errorMessage, "Automatic recovery must not present a normal burst as a failed send")
                XCTAssertNil(gifts.errorMessage, "The shared experience store must not leak a transient queue error")
            }
            defer { clock.onSleep = nil }
            XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
            XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
            try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
            XCTAssertEqual(requests.value.count, 3)
            XCTAssertFalse(queue.isPaused)
            XCTAssertNil(queue.errorMessage)
            XCTAssertEqual(receipts.value.count, 2, "Exactly two physical taps may consume inventory")
            if status == 429 { XCTAssertGreaterThanOrEqual(clock.delays.first ?? 0, 60) }
            XCTAssertGreaterThanOrEqual(clock.delays.last ?? 0, 0.59, "The next physical tap must be paced even after the retry succeeded")
            XCTAssertEqual(requests.value[0]["requestID"] as? String, requests.value[1]["requestID"] as? String)
            XCTAssertEqual(requests.value[0]["recipientIDs"] as? [String], requests.value[1]["recipientIDs"] as? [String])
            XCTAssertNotEqual(requests.value[1]["requestID"] as? String, requests.value[2]["requestID"] as? String)
            XCTAssertEqual(queue.lastCombo?.count, 2, "A successful retry confirms the original tap exactly once")
            XCTAssertEqual(queue.lastCombo?.inventoryUsed, 2)
            XCTAssertEqual(queue.lastCombo?.totalCost, 0)
            XCTAssertEqual(gifts.giftCount("heart"), 0)
        }
    }

    func testSustainedNetworkFailureRetainsOriginalHeadForManualRecovery() async throws {
        let requests = ExperienceLocked<[[String: Any]]>([])
        let recovering = ExperienceLocked(false)
        let persisted = ExperienceLocked(experienceSnapshot(balance: 40))
        let receipts = ExperienceLocked<[String: KikiGiftSendResult]>([:])
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(persisted.value)
            default:
                let body = try experienceBody(exchange.request)
                requests.withValue { $0.append(body) }
                guard recovering.value else { throw URLError(.networkConnectionLost) }
                let id = try XCTUnwrap(body["requestID"] as? String)
                let receipt = receipts.withValue { receipts -> KikiGiftSendResult in
                    if let receipt = receipts[id] { return receipt }
                    let count = receipts.count + 1
                    let receipt = KikiGiftSendResult(events: [experienceEvent("recovered_\(count)", seq: count)], wallet: experienceWallet(40 - count), totalCost: 1,
                                                    giftInventory: [], inventoryUsed: 0, diamondQuantity: 1, totalQuantity: 1)
                    receipts[id] = receipt
                    persisted.withValue { $0 = experienceSnapshot(balance: 40 - count) }
                    return receipt
                }
                try exchange.respond(receipt)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let clock = ExperienceQueueClock()
        let queue = KikiGiftSendQueue(gifts: gifts, roomID: "voice_one", now: { clock.date }, sleep: { try await clock.sleep($0) })
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        try await experienceAssertEventually { queue.isPaused && !queue.isSending }
        XCTAssertEqual(requests.value.count, 4, "A persistent failure must stop automatic network attempts")
        XCTAssertEqual(Set(requests.value.compactMap { $0["requestID"] as? String }).count, 1)
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertEqual(queue.errorMessage, "网络暂不可用，请重试。")
        XCTAssertNil(queue.lastCombo)
        XCTAssertEqual(gifts.wallet?.balance, 40)
        XCTAssertEqual(queue.updateEligibleRecipients([]), 1, "A departed recipient cancels the unsent tail, but cannot discard an uncertain receipt")
        queue.cancelWaiting()
        XCTAssertEqual(queue.pendingCount, 1)
        recovering.withValue { $0 = true }
        queue.retry()
        try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
        XCTAssertEqual(requests.value[0]["requestID"] as? String, requests.value[4]["requestID"] as? String)
        XCTAssertEqual(requests.value.count, 5)
        XCTAssertEqual(receipts.value.count, 1)
        XCTAssertEqual(queue.lastCombo?.count, 1)
        XCTAssertEqual(gifts.wallet?.balance, 39)
    }

    func testCancellingRateLimitSleepRemovesUnsubmittedHeadAndNeverResendsIt() async throws {
        let requests = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 40))
            default:
                requests.withValue { $0 += 1 }
                try exchange.respondError(429, headers: ["Retry-After": "60"])
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        var waiting: CheckedContinuation<Void, Never>?
        defer { waiting?.resume() }
        let queue = KikiGiftSendQueue(gifts: gifts, roomID: "voice_one", sleep: { delay in
            XCTAssertGreaterThan(delay, 59)
            // Deliberately finish after cancellation to exercise the old
            // worker's generation guard, rather than relying on Task.sleep.
            await withCheckedContinuation { waiting = $0 }
        })
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        try await experienceAssertEventually { waiting != nil }
        XCTAssertTrue(queue.isSending)
        XCTAssertTrue(queue.isRetrying)
        XCTAssertFalse(queue.isPaused)
        XCTAssertNil(queue.errorMessage)
        queue.cancelWaiting()
        XCTAssertEqual(queue.pendingCount, 0, "A rejected 429 has no uncertain debit to retain")
        XCTAssertFalse(queue.isSending)
        waiting?.resume(); waiting = nil
        await Task.yield()
        XCTAssertEqual(requests.value, 1)
        XCTAssertNil(queue.lastCombo)
        XCTAssertEqual(gifts.wallet?.balance, 40)
    }

    func testReceiptRecoveryAfterStopRoomUpdatesWalletWithoutRestoringEventsOrRoomHint() async throws {
        for reopenSameRoom in [false, true] {
            let requests = ExperienceLocked<[[String: Any]]>([])
            let roomReads = ExperienceLocked(0)
            let bag = [KikiGiftInventoryItem(giftID: "heart", quantity: 1)]
            let receipt = KikiGiftSendResult(events: presentationBatch("committed-before-stop", seq: 1, second: 0, recipientIDs: ["host", "alice"]), wallet: experienceWallet(39), totalCost: 1,
                                            giftInventory: [], inventoryUsed: 1, diamondQuantity: 1, totalQuantity: 2)
            let persisted = ExperienceLocked(experienceSnapshot(balance: 40, giftInventory: bag))
            let server = ExperienceMockServer { exchange in
                switch exchange.request.url!.path {
                case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
                case "/v1/me/experience": try exchange.respond(persisted.value)
                default:
                    if exchange.request.httpMethod == "GET" {
                        roomReads.withValue { $0 += 1 }
                        try exchange.respond(KikiGiftEventPage(events: [], cursor: 10, hasMore: false))
                    } else {
                        let body = try experienceBody(exchange.request)
                        let count = requests.withValue { $0.append(body); return $0.count }
                        if count == 1 {
                            // The server committed the first UUID, but this
                            // response did not deliver its receipt.
                            persisted.withValue { $0 = experienceSnapshot(balance: 39) }
                            try exchange.respondError(503)
                        } else { try exchange.respond(receipt) }
                    }
                }
            }
            let gifts = KikiGiftStore()
            gifts.configure(api: server.client, token: "voice-session", userID: "me")
            await gifts.refresh()
            var invalidatedRooms: [String] = []
            gifts.onRoomGiftCommitted = { invalidatedRooms.append($0) }
            var waiting: CheckedContinuation<Void, Never>?
            defer { waiting?.resume() }
            let queue = KikiGiftSendQueue(gifts: gifts, roomID: "voice_one", sleep: { _ in
                await withCheckedContinuation { waiting = $0 }
            })
            XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host", "alice"]))
            try await experienceAssertEventually { waiting != nil }
            XCTAssertEqual(requests.value.count, 1)
            gifts.stopRoom()
            XCTAssertTrue(gifts.events.isEmpty)
            XCTAssertNil(gifts.roomCursor)
            if reopenSameRoom { await gifts.pollRoom(roomID: "voice_one") }
            waiting?.resume(); waiting = nil
            try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
            XCTAssertEqual(requests.value.count, 2, "Recovery is a second send invocation after stopRoom, rather than a late first response")
            XCTAssertEqual(requests.value[0]["requestID"] as? String, requests.value[1]["requestID"] as? String)
            XCTAssertEqual(gifts.wallet?.balance, 39)
            XCTAssertEqual(gifts.giftCount("heart"), 0)
            XCTAssertTrue(gifts.events.isEmpty, "An old receipt must not animate in a stopped or newly reopened presentation")
            XCTAssertTrue(invalidatedRooms.isEmpty, "Receipt-only recovery must not emit an old-room RTC hint")
            XCTAssertEqual(roomReads.value, reopenSameRoom ? 1 : 0)
            XCTAssertEqual(gifts.roomCursor, reopenSameRoom ? 10 : nil)
            XCTAssertEqual(queue.lastCombo?.count, 1, "The original monetary receipt is still confirmed once")
        }
    }

    func testDepartedSeatCancelsWholeWaitingTapAndKeepsActualInFlightReceipt() async throws {
        let requests = ExperienceLocked<[(ExperienceMockProtocol, [String: Any])]>([])
        let persisted = ExperienceLocked(experienceSnapshot(balance: 40))
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(persisted.value)
            default:
                let body = try experienceBody(exchange.request)
                requests.withValue { $0.append((exchange, body)) }
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let queue = gifts.sendQueue(for: "voice_one")
        XCTAssertEqual(queue.updateEligibleRecipients(["host", "alice"]), 0)
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["alice", "host"]))
        try await experienceAssertEventually { requests.value.count == 1 }
        XCTAssertEqual(queue.updateEligibleRecipients([]), 1)
        XCTAssertEqual(queue.pendingCount, 1, "The already submitted head must still accept its original receipt")
        XCTAssertNil(queue.nextQuote(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertFalse(queue.enqueue(gift: experienceGift, recipientIDs: ["alice"]))
        persisted.withValue { $0 = experienceSnapshot(balance: 39) }
        try requests.value[0].0.respond(KikiGiftSendResult(events: [experienceEvent("seat-left-after-send", seq: 1)], wallet: experienceWallet(39), totalCost: 1,
                                                        giftInventory: [], inventoryUsed: 0, diamondQuantity: 1, totalQuantity: 1))
        try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
        XCTAssertEqual(requests.value.count, 1, "A multi-recipient waiting tap is cancelled whole, never rewritten under its UUID")
        XCTAssertEqual(queue.lastCombo?.recipientIDs, ["host"])
        XCTAssertEqual(queue.lastCombo?.count, 1)
        XCTAssertEqual(gifts.wallet?.balance, 39)
    }

    func testCancellingHeadWaitingBehindAnotherExperienceWriteNeverSubmitsGift() async throws {
        let equipment = ExperienceLocked<ExperienceMockProtocol?>(nil)
        let giftRequests = ExperienceLocked(0)
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 40, inventory: experienceInventory))
            case "/v1/me/decorations/equipped":
                if equipment.value == nil { equipment.withValue { $0 = exchange } }
                else { try exchange.respond(experienceInventory) }
            default:
                giftRequests.withValue { $0 += 1 }
                try exchange.respondError(409)
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let equip = Task { try await gifts.equip(kind: .avatarFrame, decorationID: "frame_violet") }
        try await experienceAssertEventually { equipment.value != nil }
        let queue = gifts.sendQueue(for: "voice_one")
        XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        await Task.yield()
        XCTAssertTrue(queue.isSending)
        queue.cancelWaiting()
        XCTAssertEqual(queue.pendingCount, 0, "A worker awaiting another mutation has not submitted its head")
        XCTAssertFalse(queue.isSending)
        try equipment.value?.respond(experienceInventory)
        try await equip.value
        // A subsequent write waits for the cancelled gift's mutation tail,
        // proving it cannot submit later after this assertion has passed.
        try await gifts.equip(kind: .avatarFrame, decorationID: "frame_violet")
        XCTAssertEqual(giftRequests.value, 0)
        XCTAssertNil(queue.lastCombo)
        XCTAssertEqual(gifts.wallet?.balance, 40)
    }

    func testDefinitiveRejectionCancelsUnsentTailAndNeverChangesWalletInventoryOrCombo() async throws {
        for status in [403, 409, 422] {
            let requests = ExperienceLocked(0)
            let server = ExperienceMockServer { exchange in
                switch exchange.request.url!.path {
                case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
                case "/v1/me/experience": try exchange.respond(experienceSnapshot(balance: 40, giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]))
                default: requests.withValue { $0 += 1 }; try exchange.respondError(status, message: "收礼人已离开房间")
                }
            }
            let gifts = KikiGiftStore()
            gifts.configure(api: server.client, token: "voice-session", userID: "me")
            await gifts.refresh()
            let queue = gifts.sendQueue(for: "voice_one")
            XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
            XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
            try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
            XCTAssertEqual(requests.value, 1)
            XCTAssertNotNil(queue.errorMessage)
            XCTAssertNil(queue.lastCombo)
            XCTAssertEqual(gifts.wallet?.balance, 40)
            XCTAssertEqual(gifts.giftCount("heart"), 2)
            queue.retry()
            await Task.yield()
            XCTAssertEqual(requests.value, 1, "A definitive rejection has no uncertain request to retry")
        }
    }

    func testQueueSurvivesPanelReopenBoundsTwentyTapsAndCancelsOnlyWaitingTail() async throws {
        let requests = ExperienceLocked<[ExperienceMockProtocol]>([])
        let persisted = ExperienceLocked(experienceSnapshot(balance: 100))
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience": try exchange.respond(persisted.value)
            default: requests.withValue { $0.append(exchange) }
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        let queue = gifts.sendQueue(for: "voice_one")
        for _ in 0..<20 { XCTAssertTrue(queue.enqueue(gift: experienceGift, recipientIDs: ["host"])) }
        XCTAssertFalse(queue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertEqual(queue.pendingCount, 20)
        try await experienceAssertEventually { requests.value.count == 1 }
        let reopened = gifts.sendQueue(for: "voice_one")
        XCTAssertTrue(queue === reopened, "Reopening the sheet must not create a second sending worker")
        XCTAssertFalse(queue === gifts.sendQueue(for: "voice_two"))
        XCTAssertEqual(reopened.pendingCount, 20)
        queue.cancelWaiting()
        XCTAssertEqual(queue.pendingCount, 1, "The in-flight request cannot be recalled by cancelling the unsent tail")
        persisted.withValue { $0 = experienceSnapshot(balance: 99) }
        try requests.value[0].respond(KikiGiftSendResult(events: [experienceEvent("kept-head", seq: 1)], wallet: experienceWallet(99), totalCost: 1,
                                                       giftInventory: [], inventoryUsed: 0, diamondQuantity: 1, totalQuantity: 1))
        try await experienceAssertEventually { queue.pendingCount == 0 && !queue.isSending }
        XCTAssertEqual(requests.value.count, 1)
        XCTAssertEqual(queue.lastCombo?.count, 1)
        XCTAssertEqual(gifts.wallet?.balance, 99)
    }

    func testAccountSwitchInvalidatesRoomQueueAndRejectsLateConfirmation() async throws {
        let requests = ExperienceLocked<[ExperienceMockProtocol]>([])
        let server = ExperienceMockServer { exchange in
            switch exchange.request.url!.path {
            case "/v1/gifts/catalog": try exchange.respond(experienceCatalog)
            case "/v1/me/experience":
                let isNew = exchange.request.value(forHTTPHeaderField: "Authorization") == "Bearer new-account"
                try exchange.respond(experienceSnapshot(balance: isNew ? 7 : 40, giftInventory: isNew ? [] : [KikiGiftInventoryItem(giftID: "heart", quantity: 2)]))
            default: requests.withValue { $0.append(exchange) }
            }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "old-account", userID: "old")
        await gifts.refresh()
        let oldQueue = gifts.sendQueue(for: "voice_one")
        XCTAssertTrue(oldQueue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        XCTAssertTrue(oldQueue.enqueue(gift: experienceGift, recipientIDs: ["host"]))
        try await experienceAssertEventually { requests.value.count == 1 }
        gifts.configure(api: server.client, token: "new-account", userID: "new")
        await gifts.refresh()
        try requests.value[0].respond(KikiGiftSendResult(events: [experienceEvent("old-confirmed", seq: 1)], wallet: experienceWallet(40), totalCost: 0,
                                                       giftInventory: [KikiGiftInventoryItem(giftID: "heart", quantity: 1)], inventoryUsed: 1, diamondQuantity: 0, totalQuantity: 1))
        try await experienceAssertEventually { oldQueue.pendingCount == 0 && !oldQueue.isSending }
        XCTAssertEqual(requests.value.count, 1, "The old account's queued second tap must never reach the server")
        XCTAssertNil(oldQueue.lastCombo)
        XCTAssertFalse(oldQueue === gifts.sendQueue(for: "voice_one"))
        XCTAssertFalse(oldQueue.enqueue(gift: experienceGift, recipientIDs: ["host"]), "An orphaned sheet must not revive an old account's queue")
        XCTAssertEqual(gifts.userID, "new")
        XCTAssertEqual(gifts.wallet?.balance, 7)
        XCTAssertTrue(gifts.giftInventory.isEmpty)
        XCTAssertTrue(gifts.events.isEmpty)
    }

    func testGiftPresentationCountsMultiRecipientBatchesOnceAndExtendsStableCombo() throws {
        var state = KikiGiftPresentationState()
        let first = presentationBatch("first", seq: 1, second: 0)
        state.ingest(first + first, at: presentationDate(0))
        let initial = try XCTUnwrap(state.active)
        XCTAssertEqual(initial.quantity, 1)
        XCTAssertEqual(initial.batchCount, 1)
        XCTAssertEqual(initial.recipientIDs, ["a", "b"])
        XCTAssertEqual(state.seenBatchCount, 1)
        state.ingest(first, at: presentationDate(0.5))
        XCTAssertEqual(state.active, initial, "The send receipt and repeated polling must not refresh a batch's combo or timer")
        let second = presentationBatch("second", seq: 3, second: 1, recipientIDs: ["b", "a"])
        state.ingest(first + second, at: presentationDate(1))
        XCTAssertEqual(state.active?.quantity, 2)
        XCTAssertEqual(state.active?.batchCount, 2)
        let third = presentationBatch("third", seq: 5, second: 2)
        state.ingest(first + second + third, at: presentationDate(2))
        XCTAssertEqual(state.active?.quantity, 3)
        XCTAssertEqual(state.active?.batchCount, 3)
        XCTAssertEqual(state.active?.id, initial.id, "A combo update must keep the GIF's identity instead of restarting it")
        XCTAssertGreaterThan(state.active?.revision ?? 0, initial.revision)
        XCTAssertEqual(state.active?.expiresAt, presentationDate(6))
        XCTAssertTrue(state.queue.isEmpty)
    }

    func testGiftPresentationNeverCombinesDifferentSendersGiftsTargetsOrRooms() throws {
        var state = KikiGiftPresentationState()
        state.ingest(presentationBatch("original", seq: 1, second: 0), at: presentationDate(0))
        let originalID = try XCTUnwrap(state.active?.id)
        state.ingest(presentationBatch("other_sender", seq: 3, second: 1, senderID: "friend"), at: presentationDate(1))
        state.ingest(presentationBatch("other_gift", seq: 5, second: 1, giftID: "flower_rain"), at: presentationDate(1))
        state.ingest(presentationBatch("other_targets", seq: 7, second: 1, recipientIDs: ["a", "c"]), at: presentationDate(1))
        state.ingest(presentationBatch("other_room", seq: 9, second: 1, roomID: "voice_other"), at: presentationDate(1))
        XCTAssertEqual(state.active?.id, originalID)
        XCTAssertEqual(state.active?.quantity, 1)
        XCTAssertEqual(state.queue.count, 4)
        XCTAssertTrue(state.queue.allSatisfy { $0.quantity == 1 && $0.batchCount == 1 })
    }

    func testGiftPresentationTreatsSplitOrFilteredRecipientBatchesConservatively() throws {
        var state = KikiGiftPresentationState()
        let first = presentationBatch("split", seq: 1, second: 0)
        state.ingest([first[0]], at: presentationDate(0))
        let initial = try XCTUnwrap(state.active)
        XCTAssertTrue(initial.recipientIDs.isEmpty, "A partial page cannot establish the whole target set")
        state.ingest(first, at: presentationDate(0.2))
        XCTAssertEqual(state.active, initial, "Completing the same multi-target batch never adds another ×1")
        let next = presentationBatch("complete_next", seq: 3, second: 1)
        state.ingest(first + next, at: presentationDate(1))
        XCTAssertEqual(state.active?.quantity, 1)
        XCTAssertEqual(state.queue.count, 1, "A complete new batch must not merge with the earlier unknown target set")
        XCTAssertEqual(state.queue.first?.recipientIDs, ["a", "b"])
        state.ingest(first + next, at: presentationDate(2))
        XCTAssertEqual(state.queue.first?.quantity, 1)
        state.advance(at: presentationDate(4))
        let queuedID = try XCTUnwrap(state.active?.id)
        state.ingest(presentationBatch("complete_third", seq: 5, second: 3), at: presentationDate(4.5))
        XCTAssertEqual(state.active?.id, queuedID)
        XCTAssertEqual(state.active?.quantity, 2, "Later fully known batches may form their own combo")
    }

    func testGiftPresentationIgnoresOldSequenceAndDuplicateBatchesWithoutGrowingNewCombo() throws {
        var state = KikiGiftPresentationState()
        let first = presentationBatch("newer", seq: 10, second: 2, recipientIDs: ["a"])
        state.ingest(first, at: presentationDate(2))
        let confirmed = try XCTUnwrap(state.active)
        state.ingest(presentationBatch("late_old", seq: 9, second: 1, recipientIDs: ["a"]), at: presentationDate(2.1))
        XCTAssertEqual(state.active, confirmed)
        XCTAssertTrue(state.queue.isEmpty)
        state.ingest(first + presentationBatch("next", seq: 11, second: 3, recipientIDs: ["a"]), at: presentationDate(3))
        let combo = try XCTUnwrap(state.active)
        XCTAssertEqual(combo.quantity, 2)
        state.ingest(first.reversed() + first, at: presentationDate(3.1))
        XCTAssertEqual(state.active, combo)
        state.ingest(presentationBatch("server_time_went_back", seq: 12, second: 1, recipientIDs: ["a"]), at: presentationDate(3.2))
        XCTAssertEqual(state.active, combo, "A higher sequence with older server time must not grow the current combo")
        XCTAssertEqual(state.queue.count, 1)
    }

    func testGiftPresentationRequiresBothServerAndArrivalGapsWithinFourSeconds() throws {
        var exact = KikiGiftPresentationState()
        exact.ingest(presentationBatch("first", seq: 1, second: 0), at: presentationDate(0))
        let firstID = try XCTUnwrap(exact.active?.id)
        exact.ingest(presentationBatch("four_seconds", seq: 3, second: 4), at: presentationDate(4))
        XCTAssertEqual(exact.active?.id, firstID)
        XCTAssertEqual(exact.active?.quantity, 2)

        var serverGap = KikiGiftPresentationState()
        serverGap.ingest(presentationBatch("first", seq: 1, second: 0), at: presentationDate(0))
        serverGap.ingest(presentationBatch("old_after_network_delay", seq: 3, second: 5), at: presentationDate(1))
        XCTAssertEqual(serverGap.active?.quantity, 1)
        XCTAssertEqual(serverGap.queue.count, 1, "Events fetched together do not become a combo if their server times are too far apart")

        var arrivalGap = KikiGiftPresentationState()
        arrivalGap.ingest(presentationBatch("first", seq: 1, second: 0), at: presentationDate(0))
        let expiredID = try XCTUnwrap(arrivalGap.active?.id)
        arrivalGap.ingest(presentationBatch("late_arrival", seq: 3, second: 1), at: presentationDate(4.01))
        XCTAssertNotEqual(arrivalGap.active?.id, expiredID)
        XCTAssertEqual(arrivalGap.active?.quantity, 1)
    }

    func testGiftPresentationCapsComboScreenTimeAndQueuedComboStartsItsOwnTimer() throws {
        var state = KikiGiftPresentationState()
        var sequence = 1
        for second in [0, 3, 6, 9, 11] {
            state.ingest(presentationBatch("batch_\(second)", seq: sequence, second: second), at: presentationDate(Double(second)))
            sequence += 2
        }
        XCTAssertEqual(state.active?.quantity, 5)
        XCTAssertEqual(state.active?.expiresAt, presentationDate(12), "Continuous sending cannot keep one animation over the room indefinitely")
        state.ingest(presentationBatch("new_group_after_cap", seq: sequence, second: 12), at: presentationDate(12.1))
        XCTAssertEqual(state.active?.quantity, 1)
        XCTAssertEqual(state.active?.expiresAt, presentationDate(16.1))

        var queued = KikiGiftPresentationState()
        queued.ingest(presentationBatch("on_screen", seq: 1, second: 0), at: presentationDate(0))
        queued.ingest(presentationBatch("waiting_1", seq: 3, second: 1, senderID: "friend"), at: presentationDate(1))
        queued.ingest(presentationBatch("waiting_2", seq: 5, second: 2, senderID: "friend"), at: presentationDate(2))
        XCTAssertEqual(queued.queue.count, 1)
        XCTAssertEqual(queued.queue.first?.quantity, 2)
        queued.advance(at: presentationDate(4))
        XCTAssertEqual(queued.active?.quantity, 2)
        XCTAssertEqual(queued.active?.expiresAt, presentationDate(8), "A waiting group gets a full, bounded display after it reaches the front")
    }

    func testGiftPresentationBoundsWaitingAndSeenMemoryWithoutReplayingEvictedBatches() throws {
        var state = KikiGiftPresentationState()
        let events = (1...300).flatMap { index in
            presentationBatch("batch_\(index)", seq: index, second: 0, senderID: "sender_\(index)", recipientIDs: ["a"])
        }
        state.ingest(events, at: presentationDate(0))
        XCTAssertEqual(state.active?.event.batchID, "batch_1")
        XCTAssertEqual(state.queue.count, 8)
        XCTAssertEqual(state.queue.first?.event.batchID, "batch_293")
        XCTAssertEqual(state.queue.last?.event.batchID, "batch_300")
        XCTAssertEqual(state.seenBatchCount, 256)
        let unchanged = state
        state.ingest(Array(events.prefix(20)), at: presentationDate(1))
        XCTAssertEqual(state.active, unchanged.active)
        XCTAssertEqual(state.queue, unchanged.queue, "The sequence waterline prevents replay after old seen keys leave the 256-item cache")
        XCTAssertEqual(state.seenBatchCount, 256)
    }

    func testGiftPresentationResetBaselinesHistoryAndClearsRoomOrAccountState() throws {
        var state = KikiGiftPresentationState(displayDuration: 1.8, maximumDisplayDuration: 5.4)
        let history = presentationBatch("old", seq: 1, second: 0)
        state.reset(baseline: history)
        state.ingest(history, at: presentationDate(1))
        XCTAssertNil(state.active)
        XCTAssertTrue(state.queue.isEmpty)
        state.ingest(history + presentationBatch("fresh", seq: 3, second: 1), at: presentationDate(1))
        XCTAssertEqual(state.active?.quantity, 1)
        XCTAssertEqual(state.active?.expiresAt, presentationDate(2.8))
        let current = history + presentationBatch("fresh", seq: 3, second: 1)
        state.reset(baseline: current)
        XCTAssertNil(state.active)
        XCTAssertTrue(state.queue.isEmpty)
        state.ingest(current, at: presentationDate(2))
        XCTAssertNil(state.active, "Remounting, returning from background or changing account establishes a fresh baseline")
        state.reset()
        XCTAssertNil(state.active)
        XCTAssertTrue(state.queue.isEmpty)
        XCTAssertEqual(state.seenBatchCount, 0)
    }

    func testGiftFailuresPreserveWalletAndConfiguredVoiceSession() async throws {
        let failing = ExperienceLocked(false)
        let server = ExperienceMockServer { exchange in
            if failing.value { try exchange.respondError(409, message: "收礼人已离开房间"); return }
            if exchange.request.url!.path.hasSuffix("catalog") { try exchange.respond(experienceCatalog) }
            else { try exchange.respond(experienceSnapshot()) }
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "voice-session", userID: "me")
        await gifts.refresh()
        failing.withValue { $0 = true }
        do { try await gifts.send(roomID: "voice_one", gift: experienceGift, quantity: 1, recipientIDs: ["host"], requestID: UUID()); XCTFail("Failed send accepted") }
        catch let error as KikiAPIError { guard case .server(409, _) = error else { return XCTFail("Expected server conflict") } }
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        XCTAssertTrue(gifts.events.isEmpty)
        XCTAssertTrue(gifts.isAvailable)
        XCTAssertEqual(gifts.errorMessage, "收礼人已离开房间")
        await gifts.refresh()
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        XCTAssertTrue(gifts.isAvailable)
    }
}

private let experienceGift = KikiGiftItem(id: "heart", name: "初见心动", price: 1, animationAsset: "heart.gif", posterAsset: "heart.png")
private let experienceFlower = KikiGiftItem(id: "flower_rain", name: "繁花心语", price: 99, animationAsset: "flower_rain.gif", posterAsset: "flower_rain.png")
private let experienceCar = KikiGiftItem(id: "aurora_car", name: "极光座驾", price: 999, animationAsset: "aurora_car.gif", posterAsset: "aurora_car.png")
private let experienceDecoration = KikiDecorationItem(id: "frame_violet", name: "紫晶星环", summary: "紫色头像框", style: "violet", kind: .avatarFrame, price: 1_999)
private let experienceCatalog = KikiExperienceCatalog(gifts: [experienceGift], decorations: [experienceDecoration], initialGrant: 100_000_000)
private let experienceInventory = KikiDecorationInventory(ownedIDs: ["frame_violet"], equipped: KikiEquippedDecorations(avatarFrame: "frame_violet", micEffect: nil, chatBubble: nil, roomBackground: nil))
private func experienceWallet(_ balance: Int = 100_000_000) -> KikiGiftWallet { KikiGiftWallet(balance: balance, initialGrant: 100_000_000, currency: "diamond") }
private func experienceSnapshot(balance: Int = 100_000_000, inventory: KikiDecorationInventory = .empty, giftInventory: [KikiGiftInventoryItem] = []) -> KikiExperienceSnapshot {
    KikiExperienceSnapshot(wallet: experienceWallet(balance), inventory: inventory, entries: [KikiWalletEntry(id: "initial", kind: "initial_grant", title: "免费体验钻石", amount: 100_000_000, balanceAfter: 100_000_000, createdAt: 1_792_260_000)], giftInventory: giftInventory)
}
private func experienceEvent(_ id: String, seq: Int, roomID: String = "voice_one", gift: KikiGiftItem = experienceGift, senderID: String = "me", recipientID: String = "host") -> KikiGiftEvent {
    KikiGiftEvent(id: id, roomID: roomID, batchID: "batch_\(id)", senderUserID: senderID, senderName: "我", recipientUserID: recipientID, recipientName: "房主", giftID: gift.id, giftName: gift.name, seq: seq, quantity: 1, unitPrice: gift.price, batchRecipientCount: 1, createdAt: 1_792_260_000)
}
private func presentationDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 2_000_000_000 + seconds)
}
private func presentationBatch(_ id: String, seq: Int, second: Int, senderID: String = "me", giftID: String = "heart",
                               recipientIDs: [String] = ["a", "b"], roomID: String = "voice_one") -> [KikiGiftEvent] {
    recipientIDs.enumerated().map { offset, recipient in
        KikiGiftEvent(id: id + "-" + recipient, roomID: roomID, batchID: id,
            senderUserID: senderID, senderName: senderID, recipientUserID: recipient, recipientName: recipient,
            giftID: giftID, giftName: giftID, seq: seq + offset, quantity: 1, unitPrice: 1,
            batchRecipientCount: recipientIDs.count, createdAt: 2_000_000_000 + second)
    }
}
@MainActor
private final class ExperienceQueueClock {
    var date = Date(timeIntervalSince1970: 2_000_000_000)
    var delays: [TimeInterval] = []
    var onSleep: (() -> Void)?

    func sleep(_ seconds: TimeInterval) async throws {
        try Task.checkCancellation()
        delays.append(seconds)
        date = date.addingTimeInterval(seconds)
        onSleep?()
        await Task.yield()
        try Task.checkCancellation()
    }
}

@MainActor
private func experienceAssertEventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    guard condition() else {
        XCTFail("Asynchronous experience state did not settle", file: file, line: line)
        throw URLError(.timedOut)
    }
}

private func experienceBody(_ request: URLRequest) throws -> [String: Any] {
    let bytes: Data
    if let body = request.httpBody { bytes = body }
    else if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var body = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            body.append(buffer, count: count)
        }
        bytes = body
    } else { bytes = Data() }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
}

private final class ExperienceLocked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { withValue { $0 } }
    @discardableResult func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }; return operation(&storage)
    }
}

/// Deferred responses let concurrency tests control completion order without
/// blocking URLSession's protocol queue or relying on timing sleeps.
private final class ExperienceMockServer {
    let client: KikiAPIClient
    private let session: URLSession
    private let host = UUID().uuidString.lowercased() + ".experience.example.invalid"
    init(handler: @escaping ExperienceMockProtocol.Handler) {
        ExperienceMockProtocol.install(handler, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ExperienceMockProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAPIClient(baseURL: URL(string: "https://" + host)!, session: session)
    }
    deinit { session.invalidateAndCancel(); ExperienceMockProtocol.remove(host: host) }
}

private final class ExperienceMockProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = (ExperienceMockProtocol) throws -> Void
    private static let handlers = ExperienceLocked<[String: Handler]>([:])
    private let completed = ExperienceLocked(false)
    static func install(_ handler: @escaping Handler, host: String) { handlers.withValue { $0[host] = handler } }
    static func remove(host: String) { handlers.withValue { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handlers.value[request.url?.host ?? ""] else { throw URLError(.resourceUnavailable) }
            try handler(self)
        } catch { fail(error) }
    }
    override func stopLoading() { completed.withValue { $0 = true } }
    func respond<Value: Encodable>(_ value: Value, status: Int = 200, headers: [String: String] = [:]) throws {
        let bytes = try JSONEncoder().encode(value)
        let shouldComplete = completed.withValue { current in let result = !current; current = true; return result }
        guard shouldComplete else { return }
        let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"].merging(headers) { _, provided in provided }))
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    func respondError(_ status: Int, message: String = "体验服务暂不可用", headers: [String: String] = [:]) throws {
        try respond(["detail": message], status: status, headers: headers)
    }
    private func fail(_ error: Error) {
        let shouldComplete = completed.withValue { current in let result = !current; current = true; return result }
        if shouldComplete { client?.urlProtocol(self, didFailWithError: error) }
    }
}
