import AtomicXCore
import Foundation
import Kingfisher
import TUILiveKit
import UIKit
import XCTest
@testable import KikiTalk

/// Opt-in, real network verification. The voice test needs an existing host on
/// another device. Normal test runs skip these tests and create no accounts.
final class KikiRealtimeIntegrationTests: XCTestCase {
    @MainActor
    func testRealPeerCanJoinHostRoomAndSendMessage() async throws {
        guard let roomID = ProcessInfo.processInfo.environment["KIKI_TEST_ROOM_ID"], !roomID.isEmpty else {
            throw XCTSkip("设置 KIKI_TEST_ROOM_ID 后执行真实跨设备联调。")
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let account = "qa_peer_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        let deviceSecret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let response = try await api.login(userID: account, deviceSecret: deviceSecret)
        var primaryError: Error?

        do {
            _ = try await api.updateProfile(name: "验证访客", bio: "真实跨设备联调", avatarIndex: 1, token: response.token)
            try await rtc.login(sdkAppID: response.sdk.sdkAppID, userID: response.sdk.userID, userSig: response.sdk.userSig)
            try await rtc.updateProfile(userID: response.sdk.userID, name: "验证访客", bio: "真实跨设备联调", avatarURL: KikiAvatarSource.url(for: 1).absoluteString)
            let listings = try await rtc.fetchRooms()
            _ = try XCTUnwrap(listings.first(where: { $0.id == roomID }), "腾讯云房间列表中应存在另一设备创建的房间")
            let joined: LiveInfo = try await sdkResult { completion in
                LiveListStore.shared.joinLive(liveID: roomID, completion: completion)
            }
            XCTAssertEqual(joined.liveID, roomID)
            XCTAssertNotEqual(joined.liveOwner.userID, response.sdk.userID)
            print("KIKI_REALTIME_PEER_JOINED room=\(roomID)")

            try await sdkComplete { completion in
                BarrageStore.create(liveID: roomID).sendTextMessage(text: "真实跨设备消息验证", extensionInfo: nil, completion: completion)
            }
            print("KIKI_REALTIME_MESSAGE_SENT room=\(roomID)")

            if ProcessInfo.processInfo.environment["KIKI_TEST_REQUEST_SEAT"] == "1" {
                print("KIKI_REALTIME_SEAT_APPLICATION_STARTED")
                try await sdkComplete { completion in
                    CoGuestStore.create(liveID: roomID).applyForSeat(seatIndex: 1, timeout: 60, extraInfo: nil, completion: completion)
                }
                let seats = LiveSeatStore.create(liveID: roomID)
                for _ in 0..<100 {
                    if seats.state.value.seatList.contains(where: { $0.userInfo.userID == response.sdk.userID }) { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertEqual(seats.state.value.seatList.count, 8)
                XCTAssertTrue(seats.state.value.seatList.contains(where: { $0.index == 1 && $0.userInfo.userID == response.sdk.userID }))
                print("KIKI_REALTIME_EIGHT_SEAT_GUEST_ACCEPTED")
            }

            let gifts = GiftStore.create(liveID: roomID)
            gifts.setLanguage("zh-Hans")
            do {
                try await sdkComplete { completion in gifts.refreshUsableGifts(completion: completion) }
                let count = gifts.state.value.usableGifts.reduce(0) { $0 + $1.giftList.count }
                print("KIKI_REALTIME_GIFT_CATALOG count=\(count)")
            } catch let error as ErrorInfo {
                print("KIKI_REALTIME_GIFT_CATALOG errorCode=\(error.code)")
            }

            // Let the host display the audience and the incoming message for a
            // human review/screenshot, without capturing audio or requesting mic.
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
            primaryError = error
        }

        do {
            if rtc.isCurrentRoom(roomID) {
                try await sdkComplete { completion in LiveListStore.shared.leaveLive(completion: completion) }
            }
            await rtc.logout()
            try await api.deleteAccount(token: response.token)
            print("KIKI_REALTIME_CLEANUP_COMPLETE")
        } catch {
            XCTFail("联调账号或房间清理失败：\(error.localizedDescription)")
        }
        if let primaryError { throw primaryError }
    }

    /// Checks the actual video-room lifecycle without opening a camera, creating
    /// synthetic frames, or claiming to verify physical video capture.
    @MainActor
    func testRealVideoRoomCanStartPublishAndEnd() async throws {
        guard ProcessInfo.processInfo.environment["KIKI_TEST_VIDEO"] == "1" else {
            throw XCTSkip("设置 KIKI_TEST_VIDEO=1 后执行真实视频房间联调。")
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let account = "qa_video_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        let deviceSecret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let response = try await api.login(userID: account, deviceSecret: deviceSecret)
        var reserved: DemoRoom?
        var primaryError: Error?

        do {
            _ = try await api.updateProfile(name: "视频联调", bio: "", avatarIndex: 0, token: response.token)
            try await rtc.login(sdkAppID: response.sdk.sdkAppID, userID: response.sdk.userID, userSig: response.sdk.userSig)
            let room = try await api.reserveRoom(title: "视频房间联调验证", category: "生活", isLive: true, theme: 0, token: response.token)
            reserved = room
            XCTAssertTrue(room.isLive)
            var info = LiveInfo(seatTemplate: .videoDynamicGrid9Seats)
            info.liveID = room.id
            info.liveName = room.title
            info.isPublicVisible = true
            info.keepOwnerOnSeat = true
            info.seatMode = .apply
            info.isGiftEnabled = false
            let started: LiveInfo = try await sdkResult { completion in
                LiveListStore.shared.startLive(info, completion: completion)
            }
            XCTAssertEqual(started.liveID, room.id)
            XCTAssertEqual(started.liveOwner.userID, response.sdk.userID)
            let published = try await api.setRoomStatus(room.id, status: "live", token: response.token)
            XCTAssertTrue(published.isLive)
            XCTAssertEqual(published.status, "live")
            let listings = try await rtc.fetchRooms()
            let listed = try XCTUnwrap(listings.first(where: { $0.id == room.id }), "腾讯云应返回刚创建的视频房间")
            XCTAssertTrue(listed.isLive)
            print("KIKI_REALTIME_VIDEO_STARTED_AND_LISTED room=\(room.id)")
        } catch {
            primaryError = error
        }

        if let room = reserved {
            do {
                if rtc.isCurrentRoom(room.id) {
                    _ = try await sdkResult { completion in LiveListStore.shared.endLive(completion: completion) }
                }
                let ended = try await api.setRoomStatus(room.id, status: "ended", token: response.token)
                XCTAssertEqual(ended.status, "ended")
                print("KIKI_REALTIME_VIDEO_ENDED")
            } catch {
                XCTFail("视频房间清理失败：\(error.localizedDescription)")
            }
        }
        await rtc.logout()
        do {
            try await api.deleteAccount(token: response.token)
            print("KIKI_REALTIME_VIDEO_ACCOUNT_CLEANED")
        } catch {
            XCTFail("视频联调账号清理失败：\(error.localizedDescription)")
        }
        if let primaryError { throw primaryError }
    }

    /// Verifies onboarding enforcement, actual photo storage, both pinned image
    /// loaders and the cloud's eight-seat configuration. No microphone is opened.
    @MainActor
    func testRealNicknamePhotoAndEightSeatRoom() async throws {
        guard ProcessInfo.processInfo.environment["KIKI_TEST_PROFILE"] == "1" else {
            throw XCTSkip("设置 KIKI_TEST_PROFILE=1 后验证真实昵称、相册头像与八麦房间。")
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let account = "qa_profile_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(18)
        let deviceSecret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let response = try await api.login(userID: account, deviceSecret: deviceSecret)
        var reserved: DemoRoom?
        var primaryError: Error?
        do {
            XCTAssertTrue(response.user.needsNickname)
            do {
                _ = try await api.reserveRoom(title: "应先填写昵称", category: "随心聊", isLive: false, theme: 0, token: response.token)
                XCTFail("未完成昵称的账号不能创建房间")
            } catch let error as KikiAPIError {
                guard case .server(409, _) = error else { throw error }
            }
            let named = try await api.updateProfile(name: "八麦联调", bio: "真实相册头像验证", avatarIndex: 0, token: response.token)
            XCTAssertFalse(named.needsNickname)
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 320)).image { context in
                UIColor(red: 0.48, green: 0.30, blue: 0.92, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
                ("K" as NSString).draw(at: CGPoint(x: 96, y: 68), withAttributes: [
                    .font: UIFont.boldSystemFont(ofSize: 160), .foregroundColor: UIColor.white
                ])
            }
            let jpeg = try XCTUnwrap(image.jpegData(compressionQuality: 0.85))
            let updated = try await api.uploadAvatar(jpegData: jpeg, token: response.token)
            let avatarURL = try XCTUnwrap(updated.avatarURL)
            let loaded = try await api.loadAvatar(avatarURL)
            XCTAssertGreaterThan(loaded.size.width, 0)
            KikiSDKAvatarTrust.install()
            let sdkImage: UIImage = try await withCheckedThrowingContinuation { continuation in
                KingfisherManager.shared.retrieveImage(with: URL(string: avatarURL)!, options: [.forceRefresh]) { result in
                    continuation.resume(with: result.map(\.image))
                }
            }
            XCTAssertGreaterThan(sdkImage.size.width, 0)
            try await rtc.login(sdkAppID: response.sdk.sdkAppID, userID: response.sdk.userID, userSig: response.sdk.userSig)
            try await rtc.updateProfile(userID: response.sdk.userID, name: named.name, bio: named.bio, avatarURL: avatarURL)
            let room = try await api.reserveRoom(title: "八麦真实功能验证", category: "随心聊", isLive: false, theme: 0, token: response.token)
            reserved = room
            let seats = LiveSeatStore.create(liveID: room.id)
            var info = LiveInfo(seatTemplate: .audioSalon(seatCount: 8))
            info.liveID = room.id
            info.liveName = room.title
            info.isPublicVisible = true
            info.keepOwnerOnSeat = true
            info.isGiftEnabled = false
            let _: LiveInfo = try await sdkResult { LiveListStore.shared.startLive(info, completion: $0) }
            for _ in 0..<50 {
                if seats.state.value.seatList.count == 8 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(seats.state.value.seatList.count, 8)
            _ = try await api.setRoomStatus(room.id, status: "live", token: response.token)
            let metadata = try await api.roomMetadata(ids: [room.id], token: response.token)
            XCTAssertEqual(metadata.first?.hostAvatarURL, avatarURL)
            print("KIKI_PROFILE_AVATAR_AND_EIGHT_SEATS_VERIFIED")
        } catch {
            primaryError = error
        }
        if let room = reserved {
            if rtc.isCurrentRoom(room.id) {
                _ = try? await sdkResult { LiveListStore.shared.endLive(completion: $0) }
            }
            _ = try? await api.setRoomStatus(room.id, status: "ended", token: response.token)
        }
        await rtc.logout()
        do {
            try await api.deleteAccount(token: response.token)
            print("KIKI_PROFILE_TEST_ACCOUNT_CLEANED")
        } catch {
            XCTFail("头像与八麦联调账号清理失败：\(error.localizedDescription)")
        }
        if let primaryError { throw primaryError }
    }

    /// Uses a dedicated account and the real room UI. Run only on a clean QA
    /// simulator/device with microphone permission granted; never replace an
    /// existing signed-in user's SDK session.
    @MainActor
    func testRealVoiceRoomFloatingLifecycle() async throws {
        guard ProcessInfo.processInfo.environment["KIKI_TEST_FLOATING"] == "1" else {
            throw XCTSkip("设置 KIKI_TEST_FLOATING=1 后验证真实语聊悬浮球生命周期。")
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        guard !rtc.isLoggedIn, rtc.currentSDKRoomID == nil else {
            throw XCTSkip("悬浮球联调需要未登录的专用 QA 模拟器，避免替换已有账号或房间。")
        }
        let appWindow = try XCTUnwrap(floatingTestWindows().first(where: { $0.isKeyWindow && !$0.isHidden }))
        let initialPresenter = try XCTUnwrap(floatingTestTopController(appWindow.rootViewController))
        let account = "qa_float_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        let deviceSecret = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let response = try await api.login(userID: account, deviceSecret: deviceSecret)
        let previousRoomClosed = rtc.onRoomClosed
        var closedRoomIDs: [String] = []
        rtc.onRoomClosed = { closedRoomIDs.append($0) }
        defer { rtc.onRoomClosed = previousRoomClosed }
        var reserved: DemoRoom?
        var temporarySheet: UIViewController?
        var primaryError: Error?

        do {
            _ = try await api.updateProfile(name: "悬浮球联调", bio: "", avatarIndex: 0, token: response.token)
            try await rtc.login(sdkAppID: response.sdk.sdkAppID, userID: response.sdk.userID, userSig: response.sdk.userSig)
            try await rtc.updateProfile(userID: response.sdk.userID, name: "悬浮球联调", bio: "", avatarURL: KikiAvatarSource.url(for: 0).absoluteString)
            let room = try await api.reserveRoom(title: "悬浮球生命周期验证", category: "随心聊", isLive: false, theme: 0, token: response.token)
            reserved = room
            try await rtc.createRoom(roomID: room.id, title: room.title, category: room.category, isLive: false, theme: room.theme)
            _ = try await api.setRoomStatus(room.id, status: "live", token: response.token)
            let originalController = try XCTUnwrap(floatingTestTopController(appWindow.rootViewController) as? TUIVoiceRoomViewController)
            let seats = LiveSeatStore.create(liveID: room.id)
            try await waitForFloatingCondition("房主应在真实的八麦房间内") {
                seats.state.value.seatList.count == 8 && seats.state.value.seatList.contains(where: { $0.userInfo.userID == response.sdk.userID })
            }
            seats.muteMicrophone()
            try await waitForFloatingCondition("房主静音状态应同步到真实麦位") {
                seats.state.value.seatList.first(where: { $0.userInfo.userID == response.sdk.userID })?.userInfo.microphoneStatus == .off
            }
            let originalSeat = try XCTUnwrap(seats.state.value.seatList.first(where: { $0.userInfo.userID == response.sdk.userID }))
            let originalMicrophone = DeviceStore.shared.state.value.microphoneStatus
            let barrage = BarrageStore.create(liveID: room.id)
            let message = "最小化前的真实消息 " + UUID().uuidString.prefix(8)
            try await sdkComplete { barrage.sendTextMessage(text: message, extensionInfo: nil, completion: $0) }
            try await waitForFloatingCondition("真实发送的消息应写入聊天室") {
                barrage.state.value.messageList.contains(where: { $0.textContent == message })
            }

            let minimizeButton = try XCTUnwrap(floatingTestButton(identifier: "voice.room.minimize", in: originalController.view))
            minimizeButton.sendActions(for: .touchUpInside)
            XCTAssertTrue(rtc.isVoiceRoomMinimized, "房间顶部的最小化按钮应接通真实最小化流程")
            XCTAssertFalse(rtc.minimizeVoiceRoom(), "正在最小化时的重复操作不应启动另一次转换")
            try await waitForFloatingCondition("最小化应隐藏房间并显示全局悬浮球") {
                rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom && originalController.presentingViewController == nil && self.floatingTestButton() != nil
            }
            XCTAssertEqual(rtc.currentRoomID, room.id)
            XCTAssertEqual(rtc.currentSDKRoomID, room.id)
            XCTAssertEqual(seats.state.value.seatList.count, 8)
            XCTAssertEqual(seats.state.value.seatList.first(where: { $0.userInfo.userID == response.sdk.userID }), originalSeat)
            XCTAssertEqual(DeviceStore.shared.state.value.microphoneStatus, originalMicrophone)
            XCTAssertTrue(closedRoomIDs.isEmpty, "临时最小化不能发出真实退房通知")
            let firstBubble = try XCTUnwrap(floatingTestButton())
            let overlayWindow = try XCTUnwrap(firstBubble.window)
            XCTAssertFalse(overlayWindow.isKeyWindow, "悬浮球窗口不能抢占键盘与页面焦点")
            let bubbleCenter = firstBubble.convert(CGPoint(x: firstBubble.bounds.midX, y: firstBubble.bounds.midY), to: overlayWindow)
            XCTAssertNotNil(overlayWindow.hitTest(bubbleCenter, with: nil))
            XCTAssertNil(overlayWindow.hitTest(CGPoint(x: overlayWindow.bounds.midX, y: 120), with: nil), "球外触摸应穿透到原页面")
            XCTAssertTrue(appWindow.isKeyWindow)

            let sheet = UIViewController()
            sheet.modalPresentationStyle = .pageSheet
            sheet.view.backgroundColor = .systemBackground
            temporarySheet = sheet
            await withCheckedContinuation { continuation in
                initialPresenter.present(sheet, animated: true) { continuation.resume() }
            }
            let sheetBubble = try XCTUnwrap(floatingTestButton(), "临时资料 sheet 上应仍能访问全局悬浮球")
            XCTAssertFalse(try XCTUnwrap(sheetBubble.window).isKeyWindow)
            sheetBubble.sendActions(for: .touchUpInside)
            sheetBubble.sendActions(for: .touchUpInside)
            try await waitForFloatingCondition("点击悬浮球应从资料 sheet 恢复原房间") {
                rtc.isPresentingRoom && !rtc.isVoiceRoomMinimized && originalController.presentingViewController === sheet && !originalController.isBeingPresented
            }
            XCTAssertTrue(floatingTestTopController(appWindow.rootViewController) === originalController)
            XCTAssertNil(originalController.presentedViewController, "快速连点不能创建第二个房间控制器")
            XCTAssertNil(floatingTestButton())
            XCTAssertEqual(rtc.currentSDKRoomID, room.id)
            XCTAssertEqual(seats.state.value.seatList.first(where: { $0.userInfo.userID == response.sdk.userID }), originalSeat)
            XCTAssertEqual(DeviceStore.shared.state.value.microphoneStatus, originalMicrophone)
            XCTAssertTrue(barrage.state.value.messageList.contains(where: { $0.textContent == message }))
            XCTAssertTrue(closedRoomIDs.isEmpty)

            XCTAssertTrue(rtc.minimizeVoiceRoom())
            try await waitForFloatingCondition("再次最小化应保留当前房间") {
                rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom && originalController.presentingViewController == nil && self.floatingTestButton() != nil
            }
            // A different room need not exist: refusal must happen before a
            // cloud fetch or room creation can disturb the current connection.
            let blockedRoomID = "voice_kiki_blocked_" + UUID().uuidString.prefix(8)
            do {
                try await rtc.presentRoom(roomID: blockedRoomID, isLive: false, isOwner: false)
                XCTFail("最小化期间不能加入另一个房间")
            } catch {
                guard let rtcError = error as? KikiRTCError, case .unavailable = rtcError else { throw error }
            }
            do {
                try await rtc.createRoom(roomID: blockedRoomID, title: "不能创建的房间", category: "随心聊", isLive: false, theme: 0)
                XCTFail("最小化期间不能创建另一个房间")
            } catch {
                guard let rtcError = error as? KikiRTCError, case .unavailable = rtcError else { throw error }
            }
            XCTAssertEqual(rtc.currentSDKRoomID, room.id)
            XCTAssertTrue(closedRoomIDs.isEmpty)

            _ = try await sdkResult { LiveListStore.shared.endLive(completion: $0) }
            try await waitForFloatingCondition("真实房间结束后应清理悬浮球与房间状态") {
                !rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom && rtc.currentRoomID == nil && rtc.currentSDKRoomID == nil && self.floatingTestButton() == nil && closedRoomIDs.contains(room.id)
            }
            print("KIKI_FLOATING_REAL_LIFECYCLE_VERIFIED")
        } catch {
            primaryError = error
        }

        // RTC/UI verification can outlast an idle HTTP connection. Use a fresh
        // pinned session for cleanup instead of reusing the preparation socket.
        let cleanupAPI = KikiAPIClient()
        if let room = reserved {
            do {
                if rtc.isCurrentRoom(room.id) {
                    _ = try await sdkResult { LiveListStore.shared.endLive(completion: $0) }
                }
                _ = try await cleanupAPI.setRoomStatus(room.id, status: "ended", token: response.token)
            } catch {
                XCTFail("悬浮球联调房间清理失败：\(error.localizedDescription)")
            }
        }
        await rtc.logout()
        if let sheet = temporarySheet, sheet.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                sheet.dismiss(animated: false) { continuation.resume() }
            }
        }
        do {
            try await cleanupAPI.deleteAccount(token: response.token)
            print("KIKI_FLOATING_TEST_ACCOUNT_CLEANED")
        } catch {
            XCTFail("悬浮球联调账号清理失败：\(error.localizedDescription)")
        }
        if let primaryError { throw primaryError }
    }

    @MainActor
    private func floatingTestWindows() -> [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }

    @MainActor
    private func floatingTestButton(identifier: String = "voiceRoomFloatingBubble", in root: UIView? = nil) -> UIButton? {
        func find(in view: UIView) -> UIButton? {
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
            if let button = view as? UIButton, button.accessibilityIdentifier == identifier { return button }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        if let root { return find(in: root) }
        return floatingTestWindows().lazy.compactMap { find(in: $0) }.first
    }

    @MainActor
    private func floatingTestTopController(_ root: UIViewController?) -> UIViewController? {
        guard let root else { return nil }
        if let presented = root.presentedViewController { return floatingTestTopController(presented) }
        if let navigation = root as? UINavigationController { return floatingTestTopController(navigation.visibleViewController) }
        if let tabs = root as? UITabBarController { return floatingTestTopController(tabs.selectedViewController) }
        return root
    }

    @MainActor
    private func waitForFloatingCondition(_ description: String, timeout: TimeInterval = 10, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw NSError(domain: "KikiFloatingIntegrationTest", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private func sdkComplete(_ invoke: (@escaping CompletionClosure) -> Void) async throws {
        let _: Void = try await sdkResult(invoke)
    }

    @MainActor
    private func sdkResult<Value>(_ invoke: (@escaping (Result<Value, ErrorInfo>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            invoke { continuation.resume(with: $0) }
        }
    }
}
