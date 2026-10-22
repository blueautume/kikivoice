import AVFoundation
import Foundation
import LiveKit
import UIKit
import XCTest
@testable import KikiLiveKitLab

final class KikiLiveKitTransportTests: XCTestCase {
    func testChatPacketBoundsAndValidation() throws {
        let (packet, encoded) = try KikiVoiceChatPacket.encode("  你好 LiveKit  ")
        XCTAssertEqual(packet.text, "你好 LiveKit")
        XCTAssertEqual(KikiVoiceChatPacket.decode(encoded)?.id, packet.id)
        XCTAssertThrowsError(try KikiVoiceChatPacket.encode(" \n "))
        XCTAssertThrowsError(try KikiVoiceChatPacket.encode(String(repeating: "a", count: 2_001)))
        XCTAssertNil(KikiVoiceChatPacket.decode(Data(repeating: 0, count: 4_097)))
        XCTAssertNil(KikiVoiceChatPacket.decode(Data("{\"version\":1,\"id\":\"bad\",\"text\":\"hello\"}".utf8)))
        let unknown = "{\"version\":9,\"id\":\"\(UUID().uuidString)\",\"text\":\"hello\"}"
        XCTAssertNil(KikiVoiceChatPacket.decode(Data(unknown.utf8)))
    }

    /// Opt-in: no mic or speaker capture. Exercises the exact Swift SDK used by
    /// the app against the public HTTPS/WSS lab endpoint, with disposable users.
    @MainActor func testRealSwiftRoomReliableChatAndHostEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["KIKI_LAB_INTEGRATION"] == "1",
              let code = env["KIKI_LAB_ACCESS_CODE"], !code.isEmpty else {
            throw XCTSkip("通过环境变量启用真实 LiveKit 集成测试；邀请码不得写入源码或 scheme。")
        }
        let api = KikiAPIClient.shared
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let consent = KikiLegalAcceptance(versions: docs.versions, accepted: true, adultConfirmed: true)
        let guestEvents = KikiLiveKitTestEvents()
        let rtc = KikiRTCService.shared
        let guestRoom = Room(delegate: guestEvents)
        var host: KikiLoginResponse?
        var guest: KikiLoginResponse?
        var reserved: DemoRoom?
        do {
            let hostSession = try await api.loginForLab(name: "Swift验证房主", accessCode: code, legalConsent: consent)
            host = hostSession
            let guestSession = try await api.loginForLab(name: "Swift验证成员", accessCode: code, legalConsent: consent)
            guest = guestSession
            let created = try await api.reserveRoom(title: "Swift 真实链路验证", category: "随心聊", isLive: false, theme: 0, token: hostSession.token)
            reserved = created
            try await rtc.login(credentials: hostSession.sdk, sessionToken: hostSession.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: 0)
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertEqual(rtc.currentSDKRoomID, created.id)
            XCTAssertFalse(rtc.microphoneEnabled)
            _ = try await api.setRoomStatus(created.id, status: "live", token: hostSession.token)
            let guestGrant = try await api.rtcJoin(roomID: created.id, token: guestSession.token)
            try await guestRoom.connect(url: guestGrant.serverURL, token: guestGrant.participantToken)
            try await waitFor("双方成员列表同步") { rtc.participants.count == 2 && guestRoom.remoteParticipants.count == 1 }
            XCTAssertEqual(guestRoom.localParticipant.identity?.stringValue, guestSession.sdk.userID)
            XCTAssertFalse(guestRoom.localParticipant.isMicrophoneEnabled())
            XCTAssertFalse(guestRoom.localParticipant.permissions.canPublish)
            var state = try await api.roomState(roomID: created.id, token: guestSession.token)
            XCTAssertNil(state.me.seatIndex)
            XCTAssertFalse(state.me.canPublishAudio)
            XCTAssertEqual(state.listeners.map(\.userID), [guestSession.sdk.userID])
            state = try await api.roomAction(.requestSeat, roomID: created.id, token: guestSession.token)
            XCTAssertEqual(state.myRequest?.position, 1)
            _ = try await api.roomAction(.approveRequest, roomID: created.id, targetUserID: guestSession.sdk.userID, seatIndex: 2, token: hostSession.token)
            try await waitFor("上麦批准同步真实 SDK 权限") { guestRoom.localParticipant.permissions.canPublish && rtc.roomState?.seats.first(where: { $0.index == 2 })?.userID == guestSession.sdk.userID }
            XCTAssertFalse(guestRoom.localParticipant.isMicrophoneEnabled(), "上麦批准不能自动申请麦克风或采集")

            let firstText = "Swift 主端发送可靠消息"
            let sent = await rtc.sendMessage(firstText)
            XCTAssertTrue(sent)
            let guestPage = try await api.roomMessages(roomID: created.id, afterSeq: 0, token: guestSession.token)
            XCTAssertEqual(guestPage.messages.last?.text, firstText)
            XCTAssertEqual(guestPage.messages.last?.senderUserID, hostSession.sdk.userID)
            XCTAssertEqual(guestPage.messages.last?.senderName, hostSession.user.name)

            let replyNonce = UUID().uuidString
            let reply = try await api.sendRoomMessage(roomID: created.id, clientMessageID: replyNonce, text: "Swift 成员回复", token: guestSession.token)
            let repeated = try await api.sendRoomMessage(roomID: created.id, clientMessageID: replyNonce, text: "Swift 成员回复", token: guestSession.token)
            XCTAssertEqual(reply.id, repeated.id)
            try await waitFor("房主收到真实成员消息") { rtc.messages.contains { $0.text == reply.text && $0.senderID == guestSession.sdk.userID } }
            XCTAssertEqual(rtc.messages.last?.senderName, guestSession.user.name)
            XCTAssertEqual(rtc.messages.last?.isLocal, false)
            XCTAssertEqual(rtc.participants.filter(\.isHost).first?.id, hostSession.sdk.userID)
            XCTAssertTrue(rtc.canUseRoom)

            let (_, forged) = try KikiVoiceChatPacket.encode("绕过HTTP的旧data消息不应展示")
            try await guestRoom.localParticipant.publish(data: forged, options: DataPublishOptions(topic: KikiVoiceChatPacket.topic, reliable: true))
            try await Task.sleep(nanoseconds: 1_800_000_000)
            XCTAssertFalse(rtc.messages.contains { $0.text == "绕过HTTP的旧data消息不应展示" })

            await rtc.performRoomAction(.muteChat, targetUserID: guestSession.sdk.userID, enabled: true)
            try await waitFor("文字禁言下发到实际 Swift SDK") { !guestRoom.localParticipant.permissions.canPublishData }
            XCTAssertEqual(rtc.roomState?.members.first(where: { $0.userID == guestSession.sdk.userID })?.chatMuted, true)
            do {
                _ = try await api.sendRoomMessage(roomID: created.id, clientMessageID: UUID().uuidString, text: "禁言期间拒绝写入", token: guestSession.token)
                XCTFail("Server must reject text muted user")
            } catch let error as KikiAPIError { guard case .server(403, _) = error else { throw error } }
            _ = try await api.roomMessages(roomID: created.id, afterSeq: 0, token: guestSession.token)
            await rtc.performRoomAction(.muteAudio, targetUserID: guestSession.sdk.userID, enabled: true)
            try await waitFor("禁麦下发到实际 Swift SDK") { !guestRoom.localParticipant.permissions.canPublish }
            XCTAssertEqual(rtc.roomState?.members.first(where: { $0.userID == guestSession.sdk.userID })?.seatIndex, 2)
            await rtc.performRoomAction(.muteChat, targetUserID: guestSession.sdk.userID, enabled: false)
            await rtc.performRoomAction(.muteAudio, targetUserID: guestSession.sdk.userID, enabled: false)
            try await waitFor("解除禁言和禁麦权限恢复") { guestRoom.localParticipant.permissions.canPublish && guestRoom.localParticipant.permissions.canPublishData }
            XCTAssertFalse(guestRoom.localParticipant.isMicrophoneEnabled(), "解禁不能自动打开麦克风")
            _ = try await api.roomAction(.leaveSeat, roomID: created.id, token: guestSession.token)
            try await waitFor("下麦恢复独立听众，收回媒体权限") {
                !guestRoom.localParticipant.permissions.canPublish && rtc.roomState?.listeners.first?.userID == guestSession.sdk.userID
            }
            // Capture the actual connected room, including both authenticated
            // participants and delivered messages, for visual review in xcresult.
            try await Task.sleep(nanoseconds: 250_000_000)
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) {
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "LiveKit connected room with two real participants"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            await rtc.leaveRoom(endRoom: true)
            try await waitFor("结束房间断开双方连接") {
                rtc.currentSDKRoomID == nil && guestRoom.connectionState == .disconnected
            }
            XCTAssertEqual(guestEvents.disconnectType, .roomDeleted)
            let rooms = try await api.rtcRooms(token: guestSession.token)
            XCTAssertFalse(rooms.contains { $0.id == created.id })
            await rtc.logout()
            await guestRoom.disconnect()
            try await api.deleteAccount(token: guestSession.token)
            guest = nil
            try await api.deleteAccount(token: hostSession.token)
            host = nil
        } catch {
            await rtc.logout()
            await guestRoom.disconnect()
            if let host, let reserved { _ = try? await api.setRoomStatus(reserved.id, status: "ended", token: host.token) }
            if let guest { try? await api.deleteAccount(token: guest.token) }
            if let host { try? await api.deleteAccount(token: host.token) }
            throw error
        }
    }

    @MainActor func testRealSwiftMinimizeRestoreChatHistoryAnnouncementAndInterruption() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["KIKI_LAB_INTEGRATION"] == "1", let code = env["KIKI_LAB_ACCESS_CODE"], !code.isEmpty else {
            throw XCTSkip("通过环境变量启用实验房间最小化、聊天补偿及音频中断验证。")
        }
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let acceptance = KikiLegalAcceptance(versions: docs.versions, accepted: true, adultConfirmed: true)
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let guestRoom = Room()
        var host: KikiLoginResponse?
        var guest: KikiLoginResponse?
        var roomID: String?
        do {
            let h = try await api.loginForLab(name: "Swift恢复房主", accessCode: code, legalConsent: acceptance)
            host = h
            let g = try await api.loginForLab(name: "Swift恢复听众", accessCode: code, legalConsent: acceptance)
            guest = g
            let created = try await api.reserveRoom(title: "Swift P1 恢复验证", category: "随心聊", isLive: false, theme: 0, token: h.token)
            roomID = created.id
            try await rtc.login(credentials: h.sdk, sessionToken: h.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: 0)
            _ = try await api.setRoomStatus(created.id, status: "live", token: h.token)
            let grant = try await api.rtcJoin(roomID: created.id, token: g.token)
            try await guestRoom.connect(url: grant.serverURL, token: grant.participantToken)
            try await waitFor("成员入房") { rtc.participants.count == 2 }
            let saved = await rtc.saveAnnouncement("请文明交流 · Swift 公告验证")
            XCTAssertTrue(saved)
            let guestPage = try await api.roomMessages(roomID: created.id, afterSeq: 0, token: g.token)
            XCTAssertEqual(guestPage.announcement.text, "请文明交流 · Swift 公告验证")
            do {
                _ = try await api.setRoomAnnouncement(roomID: created.id, text: "听众不可改", token: g.token)
                XCTFail("Listener cannot edit announcement")
            } catch let error as KikiAPIError { guard case .server(403, _) = error else { throw error } }

            let originalSID = try XCTUnwrap(rtc.currentRoomSID)
            let presentationID = try XCTUnwrap(rtc.roomPresentationID)
            rtc.messageDraft = "最小化前尚未发送的草稿"
            await rtc.minimizeRoom()
            XCTAssertTrue(rtc.isVoiceRoomMinimized)
            XCTAssertFalse(rtc.isPresentingRoom)
            XCTAssertEqual(rtc.currentSDKRoomID, created.id)
            XCTAssertEqual(rtc.currentRoomSID, originalSID)
            XCTAssertEqual(rtc.connectionState, .connected)
            XCTAssertEqual(guestRoom.remoteParticipants.count, 1)
            let message = try await api.sendRoomMessage(roomID: created.id, clientMessageID: UUID().uuidString, text: "最小化期间消息仍补齐", token: g.token)
            try await waitFor("悬浮房间补齐HTTP聊天") { rtc.messages.contains { $0.id == message.id } }
            try await rtc.resumeRoom()
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertFalse(rtc.isVoiceRoomMinimized)
            XCTAssertEqual(rtc.currentRoomSID, originalSID)
            XCTAssertEqual(rtc.roomPresentationID, presentationID)
            XCTAssertEqual(rtc.messageDraft, "最小化前尚未发送的草稿")
            XCTAssertEqual(rtc.participants.count, 2)
            XCTAssertTrue(rtc.messages.contains { $0.id == message.id })
            await rtc.loadServerDiagnostics()
            XCTAssertNil(rtc.diagnosticsError)
            XCTAssertNotNil(rtc.serverDiagnostics)
            if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) {
                let rendered = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "LiveKit P1 restored room with server chat and announcement"
                attachment.lifetime = .keepAlways
                add(attachment)
            }

            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await waitFor("音频中断状态可见") { rtc.audioState.interrupted }
            XCTAssertFalse(rtc.microphoneEnabled)
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
            try await waitFor("音频中断结束仍需手动开麦") { !rtc.audioState.interrupted && rtc.audioState.notice != nil }
            XCTAssertFalse(rtc.microphoneEnabled)

            await rtc.minimizeRoom()
            await rtc.leaveRoom()
            XCTAssertFalse(rtc.isVoiceRoomMinimized)
            XCTAssertNil(rtc.currentSDKRoomID)
            XCTAssertEqual(guestRoom.connectionState, .connected)
            _ = try await api.setRoomStatus(created.id, status: "ended", token: g.token)
            await rtc.logout()
            await guestRoom.disconnect()
            try await api.deleteAccount(token: g.token)
            guest = nil
            try await api.deleteAccount(token: h.token)
            host = nil
        } catch {
            await rtc.logout()
            await guestRoom.disconnect()
            if let guest, let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: guest.token) }
            if let host, let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: host.token) }
            if let guest { try? await api.deleteAccount(token: guest.token) }
            if let host { try? await api.deleteAccount(token: host.token) }
            throw error
        }
    }

    @MainActor func testRealSwiftOwnerAccountRevocationTransfersRoomWithoutDisconnectingListener() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["KIKI_LAB_INTEGRATION"] == "1", let code = env["KIKI_LAB_ACCESS_CODE"], !code.isEmpty else {
            throw XCTSkip("通过环境变量启用真实房主账号撤销转交验证。")
        }
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let consent = KikiLegalAcceptance(versions: docs.versions, accepted: true, adultConfirmed: true)
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let originalHostRoom = Room()
        var host: KikiLoginResponse?
        var listener: KikiLoginResponse?
        var roomID: String?
        do {
            let h = try await api.loginForLab(name: "Swift转交房主", accessCode: code, legalConsent: consent)
            host = h
            let l = try await api.loginForLab(name: "Swift接任成员", accessCode: code, legalConsent: consent)
            listener = l
            let created = try await api.reserveRoom(title: "Swift 房主退出隔离", category: "随心聊", isLive: false, theme: 0, token: h.token)
            roomID = created.id
            let grant = try await api.rtcJoin(roomID: created.id, token: h.token)
            try await originalHostRoom.connect(url: grant.serverURL, token: grant.participantToken)
            _ = try await api.setRoomStatus(created.id, status: "live", token: h.token)
            try await rtc.login(credentials: l.sdk, sessionToken: l.token)
            try await rtc.presentRoom(roomID: created.id, isLive: false, isOwner: false)
            XCTAssertFalse(rtc.isRoomOwner)
            XCTAssertNil(rtc.roomState?.me.seatIndex)
            XCTAssertFalse(rtc.canPublishAudio)
            _ = try await api.roomAction(.setAdmin, roomID: created.id, targetUserID: l.sdk.userID, enabled: true, token: h.token)
            try await waitFor("真实客户端同步管理员身份") { rtc.roomState?.me.role == .admin }
            try await api.deleteAccount(token: h.token)
            host = nil
            try await waitFor("原房主退出只移除本人，新房主在原连接上接任") {
                rtc.isRoomOwner && rtc.roomState?.me.role == .owner && rtc.connectionState == .connected
                    && originalHostRoom.connectionState == .disconnected
            }
            XCTAssertEqual(rtc.currentSDKRoomID, created.id)
            XCTAssertNil(rtc.disconnectionReason)
            XCTAssertTrue(rtc.canSendChat)
            await rtc.performRoomAction(.requestSeat)
            try await waitFor("新房主主动上麦获得发布权限") { rtc.canPublishAudio && rtc.roomState?.me.seatIndex != nil }
            XCTAssertFalse(rtc.microphoneEnabled)
            await rtc.leaveRoom(endRoom: true)
            XCTAssertNil(rtc.currentSDKRoomID)
            await rtc.logout()
            await originalHostRoom.disconnect()
            try await api.deleteAccount(token: l.token)
            listener = nil
        } catch {
            if let listener, let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: listener.token) }
            if let host, let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: host.token) }
            await rtc.logout()
            await originalHostRoom.disconnect()
            if let listener { try? await api.deleteAccount(token: listener.token) }
            if let host { try? await api.deleteAccount(token: host.token) }
            throw error
        }
    }

    @MainActor private func waitFor(_ description: String, predicate: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(20)
        while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(predicate(), description)
        if !predicate() { throw KikiRTCError.unavailable("集成验证超时：\(description)") }
    }
}

/// LiveKit delegate callbacks run on SDK queues; test observations use a lock.
private final class KikiLiveKitTestEvents: NSObject, RoomDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (id: String, text: String, sender: String?, name: String?)?
    private var disconnected: LiveKitErrorType?
    var receivedID: String? { lock.withLock { latest?.id } }
    var receivedText: String? { lock.withLock { latest?.text } }
    var senderID: String? { lock.withLock { latest?.sender } }
    var senderName: String? { lock.withLock { latest?.name } }
    var disconnectType: LiveKitErrorType? { lock.withLock { disconnected } }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == KikiVoiceChatPacket.topic, let packet = KikiVoiceChatPacket.decode(data) else { return }
        lock.withLock { latest = (packet.id, packet.text, participant?.identity?.stringValue, participant?.name) }
    }
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        lock.withLock { disconnected = error?.type }
    }
}
