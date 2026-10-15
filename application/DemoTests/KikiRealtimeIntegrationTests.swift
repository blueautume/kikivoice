import AtomicXCore
import Foundation
import Kingfisher
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
