import ImageIO
import SDWebImage
import XCTest
@testable import KikiTalk
@testable import TUILiveKit

@MainActor
final class KikiGiftTests: XCTestCase {
    func testFivePackagedGIFsAreAnimatedAndHavePosters() throws {
        for id in KikiGift.knownIDs {
            let url = try XCTUnwrap(Bundle.main.url(forResource: id, withExtension: "gif", subdirectory: "Gifts"))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertGreaterThan(CGImageSourceGetCount(source), 1, id)
            let animated = try XCTUnwrap(SDAnimatedImage(contentsOfFile: url.path))
            XCTAssertLessThanOrEqual(animated.size.width, 480)
            XCTAssertLessThanOrEqual(animated.size.height, 640)
            XCTAssertNotNil(Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Gifts"))
        }
    }

    func testGiftQueueDeduplicatesLocalAcknowledgementAndBoundsBusyRoom() throws {
        var queue = KikiGiftEventQueue(capacity: 3)
        let first = try event("1", sequence: 1)
        queue.append(first); queue.append(first)
        XCTAssertEqual(queue.pending.count, 1)
        queue.append(try event("2", sequence: 2)); queue.append(try event("3", sequence: 3)); queue.append(try event("4", sequence: 4))
        XCTAssertEqual(queue.pending.map(\.id), ["2", "3", "4"])
        XCTAssertEqual(queue.next()?.id, "2")
        queue.clear()
        XCTAssertNil(queue.next())
        queue.append(first)
        XCTAssertEqual(queue.next()?.id, "1")
    }

    func testFiftyRecipientBatchConfirmsEveryChatButQueuesOneSharedAnimationAcrossPages() throws {
        var queue = KikiGiftEventQueue()
        let events = try (0..<50).map { try batchEvent(id: "batch-child-\($0)", batchID: "batch-a", recipientCount: 50, sequence: Int64($0 + 1)) }
        var confirmedChatIDs: [String] = []
        // The first 30 events and next 20 model the server's bounded poll pages.
        for page in [Array(events.prefix(30)), Array(events.suffix(20))] {
            for event in page where queue.append(event) { confirmedChatIDs.append(event.id) }
            XCTAssertEqual(queue.pending.count, 1)
        }
        XCTAssertEqual(confirmedChatIDs.count, 50)
        XCTAssertEqual(Set(confirmedChatIDs).count, 50)
        XCTAssertFalse(queue.append(events[0]), "Local acknowledgement and poll duplicate must not repeat chat")
        let sharedAnimation = try XCTUnwrap(queue.next())
        XCTAssertEqual(sharedAnimation.batchID, "batch-a")
        XCTAssertEqual(sharedAnimation.batchRecipientCount, 50)
        XCTAssertEqual(sharedAnimation.quantity, 99, "A fifty-person batch shares ninety-nine loops, not 4,950")
        XCTAssertNil(queue.next())
        // A later child must not replay a batch whose animation already started.
        XCTAssertTrue(queue.append(try batchEvent(id: "late-child", batchID: "batch-a", recipientCount: 50, sequence: 51)))
        XCTAssertNil(queue.next())
    }

    func testBatchQueueKeepsOtherBatchesAndLegacySingleEventsIndependent() throws {
        var queue = KikiGiftEventQueue(capacity: 3)
        XCTAssertTrue(queue.append(try batchEvent(id: "a-1", batchID: "a", recipientCount: 2, sequence: 1)))
        XCTAssertTrue(queue.append(try batchEvent(id: "a-2", batchID: "a", recipientCount: 2, sequence: 2)))
        XCTAssertTrue(queue.append(try batchEvent(id: "b-1", batchID: "b", recipientCount: 2, sequence: 3)))
        let single = try event("single", sequence: 4)
        XCTAssertNil(single.batchID)
        XCTAssertNil(single.batchRecipientCount)
        XCTAssertTrue(queue.append(single))
        XCTAssertEqual(queue.pending.map(\.id), ["a-1", "b-1", "single"])
        XCTAssertTrue(queue.append(try batchEvent(id: "c-1", batchID: "c", recipientCount: 50, sequence: 5)))
        XCTAssertEqual(queue.pending.map(\.id), ["b-1", "single", "c-1"], "Capacity bounds transactions, not recipient count")
        queue.clear()
        XCTAssertTrue(queue.append(try batchEvent(id: "a-1", batchID: "a", recipientCount: 2, sequence: 1)))
        XCTAssertEqual(queue.next()?.batchID, "a")
    }

    func testFirstPollEstablishesCursorAndLaterPollUsesIt() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_kiki_test/gifts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gift-test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "after" }) {
                XCTAssertEqual(query.first(where: { $0.name == "after" })?.value, "45")
                return (200, try data(["events": [eventFixture(id: "46", sequence: 46)], "nextCursor": 46, "hasMore": false]))
            }
            return (200, try data(["events": [], "nextCursor": 45, "hasMore": false]))
        }
        let initial = try await server.client.giftEvents(roomID: "voice_kiki_test", after: nil, token: "gift-test-token")
        XCTAssertTrue(initial.events.isEmpty)
        let later = try await server.client.giftEvents(roomID: "voice_kiki_test", after: initial.nextCursor, token: "gift-test-token")
        XCTAssertEqual(later.events.map(\.id), ["46"])
        XCTAssertEqual(later.nextCursor, 46)
    }

    func testAmbiguousFailureRetriesSameRequestIDAndOnlyUpdatesConfirmedWallet() async throws {
        let attempts = GiftTestRequests()
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["giftID", "quantity", "requestID", "noticeVersion"])
            XCTAssertEqual(body["noticeVersion"] as? String, "2026-10-18")
            let count = attempts.append(try XCTUnwrap(body["requestID"] as? String))
            if count == 1 { return (503, try data(["detail": "结果暂未确认"])) }
            if count == 2 { return (429, try data(["detail": "请稍后重试"])) }
            return (200, try data(["event": eventFixture(id: "confirmed", sequence: 46), "wallet": walletFixture.merging(["balance": 99_999_999]) { _, new in new }]))
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        XCTAssertNotNil(gifts.pendingSend)
        await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        XCTAssertNotNil(gifts.pendingSend)
        await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        XCTAssertEqual(attempts.values.count, 3)
        XCTAssertEqual(attempts.values[0], attempts.values[1])
        XCTAssertEqual(attempts.values[0], attempts.values[2])
        XCTAssertEqual(gifts.wallet?.balance, 99_999_999)
        XCTAssertNil(gifts.pendingSend)
        XCTAssertEqual(gifts.lastSent?.id, "confirmed")
    }

    func testGiftOnlyNoticeUpdateDoesNotInvokeGlobalPrivacyWithdrawal() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            return (412, try data(["detail": "礼物说明已更新，请重新加载礼物面板。 "]))
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        XCTAssertNil(gifts.catalog)
        XCTAssertNil(gifts.pendingSend)
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        XCTAssertNotNil(gifts.errorMessage)
    }

    func testResetErasesWalletAndPendingSendWithoutNetwork() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            return (503, try data(["detail": "结果未确认"]))
        }
        let gifts = KikiGiftStore()
        gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load(); await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        gifts.reset()
        XCTAssertNil(gifts.wallet); XCTAssertNil(gifts.pendingSend); XCTAssertNil(gifts.lastSent); XCTAssertNil(gifts.catalog)
        do { _ = try await gifts.events(roomID: "voice_kiki_test", after: nil); XCTFail("Session reset must prevent requests") }
        catch is CancellationError { }
    }

    func testLateWalletRefreshCannotUndoConfirmedDebitAndConcurrentLoadsShareRequest() async throws {
        let waiting = expectation(description: "wallet refresh suspended")
        let state = DelayedGiftState(walletRequested: { waiting.fulfill() })
        DelayedGiftURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedGiftURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); DelayedGiftURLProtocol.install(nil) }
        let api = KikiAPIClient(baseURL: URL(string: "https://delayed-gifts.example.invalid")!, session: session)
        let gifts = KikiGiftStore(); gifts.configure(api: api, token: "gift-test-token")
        await gifts.load()
        let refresh = Task { await gifts.load() }
        await fulfillment(of: [waiting], timeout: 3)
        let secondCaller = Task { await gifts.load() }
        await gifts.send(roomID: "voice_kiki_test", giftID: "heart", quantity: 1)
        XCTAssertEqual(gifts.wallet?.balance, 99_999_999)
        state.releaseWallet()
        await refresh.value; await secondCaller.value
        XCTAssertEqual(gifts.wallet?.balance, 99_999_999)
        XCTAssertEqual(state.walletRequestCount, 2)
    }

    func testPendingOldRoomCanBeConfirmedBeforeSendingInNewRoom() async throws {
        let attempts = GiftTestRequests()
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            let body = try requestBody(request)
            let count = attempts.append(try XCTUnwrap(body["requestID"] as? String))
            if count == 1 { return (503, try data(["detail": "原房间赠送结果未确认"])) }
            if count == 2 { XCTAssertTrue(request.url!.path.contains("old_room")) }
            if count == 3 { XCTAssertTrue(request.url!.path.contains("new_room")) }
            return (200, try data(["event": eventFixture(id: String(count), sequence: Int64(count)), "wallet": walletFixture]))
        }
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        await gifts.send(roomID: "old_room", giftID: "heart", quantity: 1)
        let original = try XCTUnwrap(gifts.pendingSend)
        await gifts.send(roomID: "new_room", giftID: "heart", quantity: 1)
        XCTAssertEqual(attempts.values.count, 1)
        await gifts.send(roomID: original.roomID, giftID: original.giftID, quantity: original.quantity)
        XCTAssertNil(gifts.pendingSend)
        await gifts.send(roomID: "new_room", giftID: "heart", quantity: 1)
        XCTAssertEqual(attempts.values[0], attempts.values[1])
        XCTAssertNotEqual(attempts.values[1], attempts.values[2])
    }

    func testMinimizeDuringCatalogLoadCannotClearRestoredGIFPlayer() async throws {
        let waiting = expectation(description: "reload awaiting wallet")
        let state = DelayedGiftState(walletRequested: { waiting.fulfill() })
        DelayedGiftURLProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedGiftURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); DelayedGiftURLProtocol.install(nil) }
        let api = KikiAPIClient(baseURL: URL(string: "https://delayed-gifts.example.invalid")!, session: session)
        let gifts = KikiGiftStore(); gifts.configure(api: api, token: "first")
        await gifts.load()
        gifts.configure(api: api, token: "second")
        let loading = Task { await gifts.load() }
        await fulfillment(of: [waiting], timeout: 3)
        let controller = UIViewController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let presenter = KikiRoomGiftPresenter(controller: controller, roomID: "test", gifts: gifts, hostName: { "房主" })
        presenter.setVisible(true)
        gifts.onConfirmedGift?("test", try namedEvent("old", name: "旧动画"))
        await Task.yield()
        presenter.setVisible(false)
        presenter.setVisible(true)
        gifts.onConfirmedGift?("test", try namedEvent("restored", name: "恢复后的动画"))
        state.releaseWallet()
        await loading.value
        try await Task.sleep(nanoseconds: 150_000_000)
        let overlay = try XCTUnwrap(controller.view.subviews.last)
        let image = try XCTUnwrap(overlay.subviews.compactMap { $0 as? SDAnimatedImageView }.first)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertNotNil(image.image)
        gifts.onConfirmedGift?("test", try namedEvent("queued", name: "应当排队"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(image.accessibilityIdentifier, "gift.animation.restored")
        presenter.setVisible(false)
        XCTAssertTrue(overlay.isHidden)
        XCTAssertNil(image.image)
        presenter.stop(); gifts.reset()
    }

    func testGiftChatMessageKeepsQuantityAndRejectsDuplicateOrOtherRoom() throws {
        var messages = KikiVoiceGiftMessageBuffer()
        let info: [AnyHashable: Any] = ["roomID": "voice_test", "eventID": "gift-99", "senderID": "sender",
            "senderName": "送礼用户", "recipientName": "房主", "giftName": "星光花雨", "quantity": 99]
        XCTAssertNil(messages.takeMessage(info, roomID: "another_room"))
        let message = try XCTUnwrap(messages.takeMessage(info, roomID: "voice_test"))
        XCTAssertEqual(message.liveID, "voice_test")
        XCTAssertEqual(message.sender.userName, "送礼用户")
        XCTAssertEqual(message.textContent, "送给 房主 星光花雨 ×99")
        XCTAssertEqual(message.extensionInfo?["gift_count"], "99")
        XCTAssertNil(messages.takeMessage(info, roomID: "voice_test"))
    }

    func testTopReceiptUpdatesImmediatelyWithThumbnailWithoutInterruptingNinetyNineLoops() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            return (200, try data(["events": [], "nextCursor": 0, "hasMore": false]))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(red: 0.18, green: 0.12, blue: 0.40, alpha: 1)
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 24, left: 7, bottom: 0, right: 9)
        window.rootViewController = controller; window.makeKeyAndVisible()
        let underlyingControl = UIButton(type: .system)
        controller.view.addSubview(underlyingControl)
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        let presenter = KikiRoomGiftPresenter(controller: controller, roomID: "voice_test", gifts: gifts, hostName: { "房主" })
        defer {
            presenter.stop(); gifts.reset()
            window.isHidden = true; oldKeyWindow?.makeKeyAndVisible()
        }
        presenter.setVisible(true)
        var first = eventFixture(id: "long-99", sequence: 1)
        first["quantity"] = 99
        gifts.onConfirmedGift?("voice_test", try JSONDecoder().decode(KikiGiftEvent.self, from: data(first)))
        let overlay = try XCTUnwrap(controller.view.subviews.last)
        let imageView = try XCTUnwrap(overlay.subviews.compactMap { $0 as? SDAnimatedImageView }.first)
        let banner = try XCTUnwrap(overlay.subviews.compactMap { $0 as? KikiGiftTopBanner }.first)
        for _ in 0..<100 {
            if imageView.image != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(imageView.animationRepeatCount, 99)
        var batch = eventFixture(id: "batch-first", sequence: 2)
        batch["senderName"] = "第二位发送者昵称比较长"; batch["recipientName"] = "收礼人甲"
        batch["giftID"] = "flower_rain"; batch["giftName"] = "星光花雨"; batch["quantity"] = 10
        batch["batchID"] = "receipt-batch"; batch["batchRecipientCount"] = 2
        gifts.onConfirmedGift?("voice_test", try JSONDecoder().decode(KikiGiftEvent.self, from: data(batch)))
        XCTAssertFalse(banner.isHidden)
        XCTAssertEqual(banner.senderLabel.text, "第二位发送者昵称比较长")
        XCTAssertEqual(banner.recipientLabel.text, "收礼人甲")
        XCTAssertEqual(banner.detailLabel.text, "2人 · 每人 星光花雨 ×10")
        XCTAssertNotNil(banner.thumbnailView.image)
        XCTAssertEqual(banner.thumbnailView.image?.pngData(), KikiGift.poster(for: "flower_rain")?.pngData())
        XCTAssertEqual(imageView.accessibilityIdentifier, "gift.animation.long-99", "New receipts must not skip the long-running gift")

        controller.view.layoutIfNeeded()
        let safeFrame = overlay.safeAreaLayoutGuide.layoutFrame
        XCTAssertEqual(banner.frame.minY, safeFrame.minY + 8, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(banner.frame.minX, safeFrame.minX + 15.5)
        XCTAssertLessThanOrEqual(banner.frame.maxX, safeFrame.maxX - 15.5)
        XCTAssertLessThanOrEqual(banner.frame.width, 480.5)
        XCTAssertEqual(banner.thumbnailView.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertFalse(overlay.isUserInteractionEnabled); XCTAssertFalse(banner.isUserInteractionEnabled)
        underlyingControl.frame = banner.convert(banner.bounds, to: controller.view)
        XCTAssertTrue(controller.view.hitTest(CGPoint(x: underlyingControl.frame.midX, y: underlyingControl.frame.midY), with: nil) === underlyingControl,
                      "The top receipt must leave underlying room controls tappable")
        let preview = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: preview)
        attachment.name = "gift-top-banner-preview"; attachment.lifetime = .keepAlways
        add(attachment)

        gifts.onConfirmedGift?("voice_test", try namedEvent("latest", name: "最新提醒"))
        let latestText = banner.senderLabel.text
        batch["id"] = "batch-late"; batch["sequence"] = 3; batch["recipientName"] = "收礼人乙"
        gifts.onConfirmedGift?("voice_test", try JSONDecoder().decode(KikiGiftEvent.self, from: data(batch)))
        XCTAssertEqual(banner.senderLabel.text, latestText, "Another child of an announced batch must not repeat its top receipt")
        for _ in 0..<80 {
            if banner.isHidden { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(banner.isHidden, "Receipts disappear independently after three seconds")
        XCTAssertNil(banner.thumbnailView.image)
        XCTAssertFalse(overlay.isHidden)
        XCTAssertNotNil(imageView.image)
        XCTAssertEqual(imageView.accessibilityIdentifier, "gift.animation.long-99")
        XCTAssertEqual(imageView.animationRepeatCount, 99)
    }

    func testActualGIFCompletesOneTenAndNinetyNineLoopsBeforeNextGift() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            return (200, try data(["events": [], "nextCursor": 0, "hasMore": false]))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; oldKeyWindow?.makeKeyAndVisible() }

        for quantity in [1, 10, 99] {
            let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
            await gifts.load()
            let presenter = KikiRoomGiftPresenter(controller: controller, roomID: "voice_test", gifts: gifts, hostName: { "房主" })
            defer { presenter.stop(); gifts.reset() }
            presenter.setVisible(true)
            var notices: [String] = []
            let observer = NotificationCenter.default.addObserver(forName: Notification.Name("KikiGiftEventConfirmed"), object: nil, queue: .main) {
                if let id = $0.userInfo?["eventID"] as? String { notices.append(id) }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            var payload = eventFixture(id: "repeat-\(quantity)", sequence: Int64(quantity))
            payload["quantity"] = quantity; payload["senderName"] = "播放\(quantity)轮"
            let current = try JSONDecoder().decode(KikiGiftEvent.self, from: data(payload))
            gifts.onConfirmedGift?("voice_test", current)
            gifts.onConfirmedGift?("voice_test", current)
            let overlay = try XCTUnwrap(controller.view.subviews.last)
            let imageView = try XCTUnwrap(overlay.subviews.compactMap { $0 as? SDAnimatedImageView }.first)
            for _ in 0..<100 {
                if imageView.image != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(imageView.animationRepeatCount, quantity)
            // Exercise real display-link loops with a tiny, non-looping GIF,
            // avoiding several minutes of full-size asset playback in tests.
            imageView.stopAnimating()
            let animated = try fastTwoFrameGIF()
            XCTAssertEqual(animated.animatedImageLoopCount, 1)
            imageView.image = animated
            let player = try XCTUnwrap(imageView.player)
            XCTAssertEqual(player.totalLoopCount, UInt(quantity))
            let originalHandler = player.animationLoopHandler
            let finished = expectation(description: "GIF completed \(quantity) loops")
            var completedLoops: [Int] = []
            player.animationLoopHandler = { count in
                originalHandler?(count)
                completedLoops.append(Int(count))
                if count < UInt(quantity) { XCTAssertEqual(imageView.accessibilityIdentifier, "gift.animation.\(current.id)") }
                if count == UInt(quantity) { finished.fulfill() }
            }
            imageView.startAnimating()
            gifts.onConfirmedGift?("voice_test", try namedEvent("next-\(quantity)", name: "下一笔礼物"))
            XCTAssertEqual(notices, [current.id, "next-\(quantity)"], "Chat should acknowledge once, without waiting for 99 animation loops")
            await fulfillment(of: [finished], timeout: 15)
            for _ in 0..<100 {
                if imageView.accessibilityIdentifier == "gift.animation.next-\(quantity)" { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(completedLoops, Array(1...quantity))
            XCTAssertEqual(imageView.accessibilityIdentifier, "gift.animation.next-\(quantity)")
            presenter.setVisible(false)
            XCTAssertTrue(overlay.isHidden); XCTAssertNil(imageView.image)
            XCTAssertFalse(player.isPlaying)
        }
    }
    func testRecipientSelectionDefaultsToHostAndDoesNotAddLaterArrivals() {
        let host = recipient("host", host: true)
        let listener = recipient("listener")
        let newcomer = recipient("newcomer")
        var selected = KikiGiftRecipientSelection()
        selected.reconcile([])
        selected.reconcile([host, listener])
        XCTAssertEqual(selected.recipientIDs, ["host"])
        selected.selectAll([host, listener])
        selected.reconcile([host, listener, newcomer])
        XCTAssertEqual(selected.recipientIDs, ["host", "listener"], "All is a current snapshot, not a subscription to newcomers")
        selected.reconcile([host, newcomer])
        XCTAssertEqual(selected.recipientIDs, ["host"], "Leaving members must be removed before calculating cost")
        selected.clear()
        selected.reconcile([host, listener])
        XCTAssertTrue(selected.recipientIDs.isEmpty, "User clearing selection must not silently reselect the host")
    }

    func testRecipientSelectionLimitsFiftyAndCalculatesPerPersonQuantity() {
        let members = (0..<51).map { recipient("user-\($0)") }
        var selected = KikiGiftRecipientSelection()
        selected.selectAll(members + [members[0]])
        XCTAssertEqual(selected.selectedIDs.count, 50)
        XCTAssertFalse(selected.toggle(members[50].id), "The fifty-first click must be rejected explicitly")
        XCTAssertFalse(selected.selectedIDs.contains(members[50].id))
        XCTAssertTrue(selected.toggle(members[0].id))
        XCTAssertTrue(selected.toggle(members[50].id))
        selected.clear(); selected.toggle("host"); selected.toggle("listener")
        XCTAssertEqual(selected.totalCost(price: 999, quantity: 99), 197_802)
        XCTAssertNil(selected.totalCost(price: Int.max, quantity: 99))
        selected.clear()
        XCTAssertEqual(selected.totalCost(price: 999, quantity: 99), 0)
    }

    func testBatchCanonicalizesRecipientsAndConfirmsOneEventPerRecipient() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            XCTAssertEqual(request.url?.path, "/v1/rooms/voice_test/gifts/batch")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["giftID", "quantity", "recipientIDs", "requestID", "noticeVersion"])
            XCTAssertEqual(body["recipientIDs"] as? [String], ["host", "listener"])
            XCTAssertEqual(body["quantity"] as? Int, 99)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["requestID"] as? String)))
            return (200, try data(batchFixture(recipients: ["host", "listener"], quantity: 99)))
        }
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        var confirmed: [KikiGiftEvent] = []
        gifts.onConfirmedGift = { roomID, event in XCTAssertEqual(roomID, "voice_test"); confirmed.append(event) }
        await gifts.sendBatch(roomID: "voice_test", giftID: "heart", quantity: 99, recipientIDs: ["listener", "host", "listener"])
        XCTAssertEqual(confirmed.map(\.recipientID), ["host", "listener"])
        XCTAssertEqual(confirmed.map(\.quantity), [99, 99])
        XCTAssertEqual(Set(confirmed.map(\.id)).count, 2)
        XCTAssertEqual(gifts.wallet?.balance, 99_999_802)
        XCTAssertNil(gifts.pendingSend)
    }

    func testBatchAmbiguousRetryFreezesOriginalTargetsAcrossRoomsAndLegacySend() async throws {
        let attempts = GiftTestRequests()
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            XCTAssertEqual(request.url?.path, "/v1/rooms/old_room/gifts/batch")
            let body = try requestBody(request)
            XCTAssertEqual(body["recipientIDs"] as? [String], ["host", "listener"])
            let count = attempts.append(try XCTUnwrap(body["requestID"] as? String))
            if count == 1 { return (503, try data(["detail": "结果尚未确认"])) }
            return (200, try data(batchFixture(recipients: ["host", "listener"], quantity: 10)))
        }
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        await gifts.sendBatch(roomID: "old_room", giftID: "heart", quantity: 10, recipientIDs: ["host", "listener"])
        let pending = try XCTUnwrap(gifts.pendingSend)
        await gifts.sendBatch(roomID: "old_room", giftID: "heart", quantity: 10, recipientIDs: ["host"])
        await gifts.sendBatch(roomID: "new_room", giftID: "heart", quantity: 10, recipientIDs: ["host", "listener"])
        await gifts.send(roomID: "old_room", giftID: "heart", quantity: 10)
        XCTAssertEqual(gifts.pendingSend, pending)
        XCTAssertEqual(attempts.values.count, 1)
        await gifts.retryPending()
        XCTAssertEqual(attempts.values, [pending.requestID, pending.requestID])
        XCTAssertEqual(gifts.wallet?.balance, 99_999_980)
        XCTAssertNil(gifts.pendingSend)
    }

    func testBatchRejectsEmptyOrOversizedRecipientSelectionBeforeNetwork() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            XCTFail("Invalid recipient selection must not reach API")
            return (500, Data())
        }
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        for ids in [[], [""], (0..<51).map { "recipient-\($0)" }] {
            await gifts.sendBatch(roomID: "voice_test", giftID: "heart", quantity: 1, recipientIDs: ids)
            XCTAssertNil(gifts.pendingSend)
            XCTAssertNotNil(gifts.errorMessage)
        }
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
    }

    func testBatchDefinitiveRecipientFailureReleasesFrozenSelectionWithoutDebit() async throws {
        let server = KikiAPIMockServer { request in
            if request.url!.path.hasSuffix("catalog") { return (200, try data(catalogFixture)) }
            if request.url!.path.hasSuffix("wallet") { return (200, try data(walletFixture)) }
            return (409, try data(["detail": "收礼人已离开房间，请重新选择。 "]))
        }
        let gifts = KikiGiftStore(); gifts.configure(api: server.client, token: "gift-test-token")
        await gifts.load()
        await gifts.sendBatch(roomID: "voice_test", giftID: "heart", quantity: 99, recipientIDs: ["host", "listener"])
        XCTAssertNil(gifts.pendingSend)
        XCTAssertEqual(gifts.wallet?.balance, 100_000_000)
        XCTAssertNotNil(gifts.errorMessage)
    }

}

private func fastTwoFrameGIF() throws -> SDAnimatedImage {
    let storage = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(storage, "com.compuserve.gif" as CFString, 2, nil))
    for color in [UIColor.systemPink, .systemPurple] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.02]] as CFDictionary
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties)
    }
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return try XCTUnwrap(SDAnimatedImage(data: storage as Data))
}

private let walletFixture: [String: Any] = ["balance": 100_000_000, "currency": "diamond", "initialGrant": 100_000_000]
private let catalogFixture: [String: Any] = [
    "currency": "diamond", "initialBalance": 100_000_000,
    "notice": ["version": "2026-10-18", "title": "免费礼物体验说明", "text": "体验钻石免费发放，不支持充值、转让或提现。赠送记录仅用于房间同步，保留7天。", "url": "https://kiki.group/gifts/notice/"],
    "gifts": [["id": "heart", "name": "初见心动", "price": 1, "animationAsset": "heart.gif", "effectTier": 1, "durationMilliseconds": 2000]]
]
private func eventFixture(id: String, sequence: Int64) -> [String: Any] {
    ["sequence": sequence, "id": id, "giftID": "heart", "giftName": "初见心动", "unitPrice": 1,
     "quantity": 1, "totalCost": 1, "senderID": "sender", "senderName": "送礼用户", "senderAvatarIndex": 1,
     "senderAvatarURL": NSNull(), "recipientID": "owner", "recipientName": "房主", "createdAt": 1_792_260_000]
}
private func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
private func event(_ id: String, sequence: Int64) throws -> KikiGiftEvent {
    try JSONDecoder().decode(KikiGiftEvent.self, from: data(eventFixture(id: id, sequence: sequence)))
}
private func namedEvent(_ id: String, name: String) throws -> KikiGiftEvent {
    var value = eventFixture(id: id, sequence: 1); value["senderName"] = name
    return try JSONDecoder().decode(KikiGiftEvent.self, from: data(value))
}
private final class GiftTestRequests: @unchecked Sendable {
    private let lock = NSLock(); private var storage: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: String) -> Int { lock.lock(); defer { lock.unlock() }; storage.append(value); return storage.count }
}

private final class DelayedGiftState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var pending: DelayedGiftURLProtocol?
    let walletRequested: () -> Void
    init(walletRequested: @escaping () -> Void) { self.walletRequested = walletRequested }
    var walletRequestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    func receive(_ request: DelayedGiftURLProtocol) throws {
        let path = request.request.url!.path
        if path.hasSuffix("catalog") { request.respond(try data(catalogFixture)); return }
        if path.hasSuffix("wallet") {
            lock.lock(); count += 1
            if count == 2 { pending = request; lock.unlock(); walletRequested(); return }
            lock.unlock(); request.respond(try data(walletFixture)); return
        }
        request.respond(try data(["event": eventFixture(id: "confirmed", sequence: 1), "wallet": walletFixture.merging(["balance": 99_999_999]) { _, new in new }]))
    }
    func releaseWallet() {
        lock.lock(); let request = pending; pending = nil; lock.unlock()
        request?.respond(try! data(walletFixture))
    }
}
private final class DelayedGiftURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var state: DelayedGiftState?
    static func install(_ value: DelayedGiftState?) { lock.lock(); state = value; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delayed-gifts.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let state = Self.state; Self.lock.unlock()
        do { try state?.receive(self) } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
    func respond(_ bytes: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes); client?.urlProtocolDidFinishLoading(self)
    }
}

private func recipient(_ id: String, host: Bool = false) -> KikiGiftRecipient {
    KikiGiftRecipient(id: id, name: id, avatarURL: nil, isHost: host, isOnSeat: host)
}
private func batchFixture(recipients: [String], quantity: Int) -> [String: Any] {
    let events = recipients.enumerated().map { index, recipient -> [String: Any] in
        var value = eventFixture(id: "batch-\(recipient)", sequence: Int64(index + 1))
        value["recipientID"] = recipient; value["recipientName"] = recipient
        value["quantity"] = quantity; value["totalCost"] = quantity
        value["batchID"] = "test-batch"; value["batchRecipientCount"] = recipients.count
        return value
    }
    return ["events": events, "wallet": walletFixture.merging(["balance": 100_000_000 - quantity * recipients.count]) { _, new in new },
            "totalCost": quantity * recipients.count, "recipientCount": recipients.count, "quantityPerRecipient": quantity]
}

private func batchEvent(id: String, batchID: String, recipientCount: Int, sequence: Int64) throws -> KikiGiftEvent {
    var value = eventFixture(id: id, sequence: sequence)
    value["batchID"] = batchID; value["batchRecipientCount"] = recipientCount
    value["quantity"] = 99; value["totalCost"] = 99
    return try JSONDecoder().decode(KikiGiftEvent.self, from: data(value))
}
