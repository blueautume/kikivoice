import AVFoundation
import Foundation
import LiveKit
import UIKit
import XCTest
@testable import KikiTalk

/// Opt-in only. The runner injects two disposable server-issued voice sessions
/// in memory after a real account-to-voice exchange. This never signs in with
/// Apple, reads account credentials, or adds a production login bypass.
final class KikiProductionVoiceIntegrationTests: XCTestCase {
    @MainActor
    func testMigratedRoomPermissionsChatMinimizeAnnouncementAndEnd() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_PRODUCTION_VOICE_ACCOUNTS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需在私密测试环境注入两份可注销的正式语聊换票结果；不使用 Apple 登录。")
        }
        let sessions: [KikiVoiceSessionResponse]
        do { sessions = try JSONDecoder().decode([KikiVoiceSessionResponse].self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密测试会话格式不符合换票契约。"); return }
        guard sessions.count >= 2 else { XCTFail("需要两份独立语聊会话。"); return }
        let host = sessions[0], guest = sessions[1]
        guard host.user.id != guest.user.id,
              [host, guest].allSatisfy({ !$0.token.isEmpty && $0.expiresAt > Int(Date().timeIntervalSince1970) + 60 &&
                  $0.sdk.provider == "livekit" && $0.sdk.serverURL == "wss://furby.top" &&
                  $0.sdk.userID == $0.user.id }) else {
            XCTFail("测试会话必须是未过期的独立正式语聊授权。"); return
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        rtc.renewAuthorization = nil // Fixtures are server-leased; this test never uses account tokens.
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api)
        let peer = Room()
        var roomID: String?
        do {
            let created = try await api.reserveRoom(title: "正式迁移链路验收", category: "随心聊", isLive: false, theme: 0, token: host.token)
            roomID = created.id
            try await rtc.login(credentials: host.sdk, sessionToken: host.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: created.theme)
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertFalse(rtc.microphoneEnabled)
            _ = try await api.setRoomStatus(created.id, status: "live", token: host.token)
            let grant = try await api.rtcJoin(roomID: created.id, token: guest.token)
            try await peer.connect(url: grant.serverURL, token: grant.participantToken)
            try await waitFor("两端连接与成员同步") { rtc.participants.count == 2 && peer.remoteParticipants.count == 1 }
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            XCTAssertFalse(peer.localParticipant.permissions.canPublish)
            let audience = try await api.roomState(roomID: created.id, token: guest.token)
            XCTAssertEqual(audience.seatMode, "ordered")
            XCTAssertEqual(audience.members.first { $0.userID == host.user.id }?.seatIndex, 1)
            XCTAssertNil(audience.me.seatIndex)
            XCTAssertEqual(audience.me.seatRequestStatus, "none")
            XCTAssertFalse(audience.me.canPublishAudio)
            let requested = try await api.roomAction(.requestSeat, roomID: created.id, token: guest.token)
            XCTAssertEqual(requested.me.seatRequestStatus, "pending")
            await rtc.performRoomAction(.approveRequest, targetUserID: guest.sdk.userID)
            try await waitFor("批准上麦与真实 SDK 权限同步") {
                peer.localParticipant.permissions.canPublish && rtc.roomState?.seats.first(where: { $0.index == 2 })?.userID == guest.sdk.userID
            }
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled(), "上麦不能自动采集麦克风。")
            let sent = await rtc.sendMessage("正式迁入主端消息")
            XCTAssertTrue(sent)
            let page = try await api.roomMessages(roomID: created.id, afterSeq: 0, token: guest.token)
            XCTAssertTrue(page.messages.contains { $0.text == "正式迁入主端消息" && $0.senderUserID == host.sdk.userID })
            let sid = rtc.currentRoomSID
            let controller = rtc.roomPresentationID
            rtc.messageDraft = "迁入后保留草稿"
            await rtc.minimizeRoom()
            XCTAssertTrue(rtc.isVoiceRoomMinimized)
            let nonce = UUID().uuidString
            let reply = try await api.sendRoomMessage(roomID: created.id, clientMessageID: nonce, text: "最小化期间成员回复", token: guest.token)
            let duplicate = try await api.sendRoomMessage(roomID: created.id, clientMessageID: nonce, text: "最小化期间成员回复", token: guest.token)
            XCTAssertTrue(reply.id == duplicate.id)
            try await waitFor("最小化期间聊天同步") { rtc.messages.contains { $0.id == reply.id && $0.senderID == guest.sdk.userID } }
            try await rtc.resumeRoom()
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertTrue(rtc.currentRoomSID == sid)
            XCTAssertTrue(rtc.roomPresentationID == controller)
            XCTAssertEqual(rtc.messageDraft, "迁入后保留草稿")
            let announcementSaved = await rtc.saveAnnouncement("文明交流 · 正式迁移验收")
            XCTAssertTrue(announcementSaved)
            let announced = try await api.roomMessages(roomID: created.id, afterSeq: 0, token: guest.token)
            XCTAssertEqual(announced.announcement.text, "文明交流 · 正式迁移验收")
            await rtc.performRoomAction(.muteChat, targetUserID: guest.sdk.userID, enabled: true)
            try await waitFor("文字禁言下发") { !peer.localParticipant.permissions.canPublishData }
            do {
                _ = try await api.sendRoomMessage(roomID: created.id, clientMessageID: UUID().uuidString, text: "禁言期间不得写入", token: guest.token)
                XCTFail("服务端应拒绝被禁言成员的消息。")
            } catch let error as KikiAPIError {
                guard case .server(403, _) = error else { throw error }
            }
            await rtc.performRoomAction(.muteAudio, targetUserID: guest.sdk.userID, enabled: true)
            try await waitFor("禁麦下发") { !peer.localParticipant.permissions.canPublish }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            try await waitFor("系统音频中断可见") { rtc.audioState.interrupted }
            NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
            try await waitFor("中断结束继续保持手动开麦") { !rtc.audioState.interrupted && rtc.audioState.notice != nil }
            XCTAssertFalse(rtc.microphoneEnabled)
            await rtc.leaveRoom(endRoom: true)
            try await waitFor("房主结束房间并断开双方") { rtc.currentSDKRoomID == nil && peer.connectionState == .disconnected }
            let rooms = try await api.rtcRooms(token: guest.token)
            XCTAssertFalse(rooms.contains { $0.id == created.id })
            await rtc.logout()
            await peer.disconnect()
        } catch {
            // Ensure the experimental voice service has no abandoned room even
            // when a test assertion or transport check fails. Root owns disposal
            // of the isolated account fixtures after the test run.
            if let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: host.token) }
            await rtc.logout()
            await peer.disconnect()
            XCTFail("正式语聊集成验收未完成（凭据及底层错误原文已隐藏）。")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 1)
        }
    }

    @MainActor
    func testMinimizedRoomIsReleasedWhenHostCloses() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_PRODUCTION_VOICE_ACCOUNTS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需在私密测试环境注入两份可注销的正式语聊换票结果；不使用 Apple 登录。")
        }
        let sessions: [KikiVoiceSessionResponse]
        do { sessions = try JSONDecoder().decode([KikiVoiceSessionResponse].self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密测试会话格式不符合换票契约。"); return }
        guard sessions.count >= 2 else { XCTFail("需要两份独立语聊会话。"); return }
        let host = sessions[0], listener = sessions[1]
        guard host.user.id != listener.user.id,
              [host, listener].allSatisfy({ !$0.token.isEmpty && $0.expiresAt > Int(Date().timeIntervalSince1970) + 60 &&
                  $0.sdk.provider == "livekit" && $0.sdk.serverURL == "wss://furby.top" &&
                  $0.sdk.userID == $0.user.id }) else {
            XCTFail("测试会话必须是未过期的独立正式语聊授权。"); return
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api)
        let peer = Room()
        var roomID: String?
        var minimizedBeforeClosure = false
        var overlayWasVisible = false
        var overlayHidden = false
        var roomReleased = false
        var peerDisconnected = false
        var microphonesRemainOff = false
        var succeeded = false
        var stage = "configured"
        var safeFailureStage: String?
        var safeErrorType: String?
        func classifyFailure(_ error: Error) -> String {
            if let apiError = error as? KikiAPIError {
                switch apiError {
                case .server(let status, _): return "KikiAPIError.server.\(status)"
                case .rateLimited: return "KikiAPIError.rateLimited"
                case .security: return "KikiAPIError.security"
                case .legalUpdateRequired: return "KikiAPIError.legalUpdateRequired"
                case .invalidResponse: return "KikiAPIError.invalidResponse"
                }
            }
            if let sdkError = error as? LiveKitError { return "LiveKitError.type.\(sdkError.type.rawValue)" }
            if let urlError = error as? URLError { return "URLError.code.\(urlError.code.rawValue)" }
            if error is CancellationError { return "CancellationError" }
            if error is KikiRTCError { return "KikiRTCError" }
            return "UnexpectedError"
        }
        defer {
            let metadata: [String: Any] = [
                "roomID": roomID ?? "", "device": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone",
                "minimizedBeforeClosure": minimizedBeforeClosure, "overlayWasVisible": overlayWasVisible,
                "overlayHidden": overlayHidden, "roomReleased": roomReleased,
                "peerDisconnected": peerDisconnected, "microphonesRemainOff": microphonesRemainOff,
                "succeeded": succeeded, "stage": stage,
                "safeFailureStage": safeFailureStage ?? "", "safeErrorType": safeErrorType ?? ""
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/kiki-minimized-close-result.json"), options: .atomic)
            }
        }
        do {
            // A is a direct SDK owner and B is the app's actual UIKit room.
            // Neither endpoint requests or publishes microphone capture.
            // App startup suspends the shared LiveKit audio engine for privacy;
            // normal authenticated RTC login restores it before either SDK connects.
            stage = "listenerLogin"
            try await rtc.login(credentials: listener.sdk, sessionToken: listener.token)
            stage = "reserveRoom"
            let created = try await api.reserveRoom(title: "最小化后房主关闭自动验收", category: "随心聊", isLive: false, theme: 0, token: host.token)
            roomID = created.id
            stage = "ownerGrant"
            let grant = try await api.rtcJoin(roomID: created.id, token: host.token)
            stage = "directOwnerConnect"
            try await peer.connect(url: grant.serverURL, token: grant.participantToken)
            stage = "markRoomLive"
            _ = try await api.setRoomStatus(created.id, status: "live", token: host.token)
            stage = "presentListenerRoom"
            try await rtc.presentRoom(roomID: created.id, isLive: false, isOwner: false)
            stage = "awaitBothClientsAndPresentation"
            try await waitFor("最小化验收双方入房与听众页面展示") {
                rtc.participants.count == 2 && peer.remoteParticipants.count == 1 &&
                    self.presentedRoomController(for: rtc)?.viewIfLoaded?.window != nil
            }
            XCTAssertFalse(rtc.isRoomOwner)
            XCTAssertNil(rtc.roomState?.me.seatIndex)
            XCTAssertFalse(rtc.canPublishAudio)
            XCTAssertFalse(rtc.microphoneEnabled)
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            stage = "minimizeListenerRoom"
            await rtc.minimizeRoom()
            stage = "awaitFloatingWindow"
            try await waitFor("真实房间已最小化并显示悬浮入口") {
                rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom && self.visibleVoiceRoomOverlayWindow() != nil
            }
            let overlay = try XCTUnwrap(visibleVoiceRoomOverlayWindow())
            minimizedBeforeClosure = rtc.isVoiceRoomMinimized
            overlayWasVisible = !overlay.isHidden
            XCTAssertEqual(rtc.currentRoomID, created.id)
            XCTAssertNotNil(rtc.currentSDKRoomID)
            XCTAssertFalse(overlay.isKeyWindow)
            stage = "closeHostRoom"
            _ = try await api.setRoomStatus(created.id, status: "ended", token: host.token)
            // Do not resume the room or invoke any local leave operation. The
            // real remote close/state-error path must clear the minimized room.
            stage = "awaitMinimizedRoomRelease"
            try await waitFor("远端房主结束后悬浮球隐藏且最小化房间自动释放") {
                rtc.currentRoomID == nil && rtc.currentSDKRoomID == nil && rtc.roomState == nil &&
                    !rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom && overlay.isHidden &&
                    self.visibleVoiceRoomOverlayWindow() == nil && peer.connectionState == .disconnected
            }
            overlayHidden = overlay.isHidden && visibleVoiceRoomOverlayWindow() == nil
            roomReleased = rtc.currentRoomID == nil && rtc.currentSDKRoomID == nil && rtc.roomState == nil &&
                !rtc.isVoiceRoomMinimized && !rtc.isPresentingRoom
            peerDisconnected = peer.connectionState == .disconnected
            microphonesRemainOff = !rtc.microphoneEnabled && !peer.localParticipant.isMicrophoneEnabled()
            XCTAssertTrue(overlayHidden)
            XCTAssertTrue(roomReleased)
            XCTAssertTrue(peerDisconnected)
            XCTAssertTrue(microphonesRemainOff)
            stage = "verifyRoomRemovedFromListing"
            let rooms = try await api.rtcRooms(token: listener.token)
            XCTAssertFalse(rooms.contains { $0.id == created.id })
            stage = "logoutListener"
            await rtc.logout()
            stage = "disconnectDirectOwner"
            await peer.disconnect()
            succeeded = minimizedBeforeClosure && overlayWasVisible && overlayHidden && roomReleased && peerDisconnected && microphonesRemainOff
            stage = "completed"
        } catch {
            safeFailureStage = stage
            safeErrorType = classifyFailure(error)
            if let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: host.token) }
            await rtc.logout(); await peer.disconnect()
            XCTFail("正式最小化房间远端关闭验收未完成（凭据及底层错误原文已隐藏）。")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 6)
        }
    }

    @MainActor
    func testOrderedSeatRequestsAndOwnerClosure() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_PRODUCTION_VOICE_ACCOUNTS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需在私密测试环境注入两份可注销的正式语聊换票结果；不使用 Apple 登录。")
        }
        let sessions: [KikiVoiceSessionResponse]
        do { sessions = try JSONDecoder().decode([KikiVoiceSessionResponse].self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密测试会话格式不符合换票契约。"); return }
        guard sessions.count >= 2 else { XCTFail("需要两份独立语聊会话。"); return }
        let host = sessions[0], guest = sessions[1]
        guard host.user.id != guest.user.id,
              [host, guest].allSatisfy({ !$0.token.isEmpty && $0.expiresAt > Int(Date().timeIntervalSince1970) + 60 &&
                  $0.sdk.provider == "livekit" && $0.sdk.serverURL == "wss://furby.top" &&
                  $0.sdk.userID == $0.user.id }) else {
            XCTFail("测试会话必须是未过期的独立正式语聊授权。"); return
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api)
        let peer = Room()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        var roomID: String?
        var pendingAutomaticallySynced = false
        var pendingIndicatorAccessible = false
        var requestSheetOpened = false
        var approvalActivatedInUI = false
        var rejectionActivatedInUI = false
        var guestSeatIndex = 0
        var guestOfflinePreserved = false
        var guestReconnectedSeatIndex = 0
        var guestRejected = false
        var ownerCloseNoTransfer = false
        var peerDisconnected = false
        var microphonesRemainOff = false
        var closedStateStatus = 0
        var succeeded = false
        defer {
            // Only isolated room metadata crosses the runner boundary. Tokens,
            // account exchange bodies and underlying network errors stay private.
            let metadata: [String: Any] = [
                "roomID": roomID ?? "", "device": device,
                "pendingAutomaticallySynced": pendingAutomaticallySynced,
                "pendingIndicatorAccessible": pendingIndicatorAccessible,
                "requestSheetOpened": requestSheetOpened,
                "approvalActivatedInUI": approvalActivatedInUI,
                "rejectionActivatedInUI": rejectionActivatedInUI,
                "guestSeatIndex": guestSeatIndex, "guestRejected": guestRejected,
                "guestOfflinePreserved": guestOfflinePreserved,
                "guestReconnectedSeatIndex": guestReconnectedSeatIndex,
                "ownerCloseNoTransfer": ownerCloseNoTransfer,
                "peerDisconnected": peerDisconnected, "microphonesRemainOff": microphonesRemainOff,
                "closedStateStatus": closedStateStatus, "succeeded": succeeded
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/kiki-ordered-room-result.json"), options: .atomic)
            }
        }
        do {
            let created = try await api.reserveRoom(title: "顺位上麦与房主关闭验收", category: "随心聊", isLive: false, theme: 0, token: host.token)
            roomID = created.id
            try await rtc.login(credentials: host.sdk, sessionToken: host.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: created.theme)
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertFalse(rtc.microphoneEnabled)
            let grant = try await api.rtcJoin(roomID: created.id, token: guest.token)
            try await peer.connect(url: grant.serverURL, token: grant.participantToken)
            try await waitFor("顺位验收双方在线与真实 UIKit 房间展示") {
                rtc.participants.count == 2 && peer.remoteParticipants.count == 1 &&
                    self.presentedRoomController(for: rtc)?.viewIfLoaded?.window != nil &&
                    rtc.roomState?.members.first(where: { $0.userID == guest.user.id })?.online == true
            }
            let controller = try XCTUnwrap(presentedRoomController(for: rtc))
            let window = try XCTUnwrap(controller.viewIfLoaded?.window)
            let audience = try await api.roomState(roomID: created.id, token: guest.token)
            XCTAssertEqual(audience.seatMode, "ordered")
            XCTAssertEqual(audience.disconnectGraceSeconds, 60)
            XCTAssertEqual(audience.ownerDisconnectGraceSeconds, 15)
            XCTAssertEqual(audience.members.first { $0.userID == host.user.id }?.seatIndex, 1)
            XCTAssertNil(audience.me.seatIndex)
            XCTAssertEqual(audience.me.seatRequestStatus, "none")
            XCTAssertFalse(peer.localParticipant.permissions.canPublish)
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())

            let request = try await api.roomAction(.requestSeat, roomID: created.id, token: guest.token)
            XCTAssertEqual(request.me.seatRequestStatus, "pending")
            XCTAssertNil(request.me.seatIndex)
            // No manual host refresh: KikiRTCService's ordinary room-state
            // driver must deliver the peer's request into the actual room UI.
            try await waitFor("房主自动收到 pending 上麦申请") {
                (rtc.roomState?.revision ?? 0) >= request.revision &&
                    rtc.roomState?.queue.contains { $0.userID == guest.user.id && $0.status == "pending" } == true
            }
            pendingAutomaticallySynced = true
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            if let hand = roomAccessibilityNode(in: controller.view, identifier: "livekit.room.seatRequests") {
                pendingIndicatorAccessible = hand.accessibilityValue?.contains("1 条待处理申请") == true
            }
            try captureOrderedScreenshot(window, name: device + "-kiki-ordered-room")
            let diagnostics = roomAccessibilityNodes(in: controller.view).compactMap { node -> [String: String]? in
                guard let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier,
                      identifier.hasPrefix("livekit.room.") else { return nil }
                return ["identifier": identifier.replacingOccurrences(of: guest.user.id, with: "<applicant>"),
                        "label": node.accessibilityLabel ?? "", "value": node.accessibilityValue ?? ""]
            }
            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/" + device + "-kiki-ordered-room-accessibility.json"), options: .atomic)
            }

            // UIKit/SwiftUI exposes native buttons through the public
            // accessibility container APIs. Activation uses the real action,
            // with no test-only state setter in production views.
            requestSheetOpened = await openOrderedRequestSheet(from: controller)
            if requestSheetOpened, let sheet = controller.presentedViewController {
                try await Task.sleep(nanoseconds: 350_000_000)
                try captureOrderedScreenshot(window, name: device + "-kiki-ordered-requests")
                if let approve = roomAccessibilityNode(in: sheet.view, identifier: "livekit.room.approveSeatRequest." + guest.user.id) {
                    approvalActivatedInUI = activateRoomAccessibilityNode(approve)
                }
            }
            if !approvalActivatedInUI {
                // A simulator's in-process accessibility bridge may not vend
                // SwiftUI virtual nodes. The room screenshot and automatic
                // state assertion remain valid; use the same normal RTC action.
                await rtc.performRoomAction(.approveRequest, targetUserID: guest.user.id)
            }
            try await waitFor("同意后自动安排第二号麦并更新 SFU 权限") {
                rtc.roomState?.members.first(where: { $0.userID == guest.user.id })?.seatIndex == 2 &&
                    peer.localParticipant.permissions.canPublish
            }
            let seated = try await api.roomState(roomID: created.id, token: guest.token)
            guestSeatIndex = seated.me.seatIndex ?? 0
            XCTAssertEqual(guestSeatIndex, 2)
            XCTAssertEqual(seated.me.seatRequestStatus, "seated")
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled(), "同意上麦不会自动采集麦克风。")
            XCTAssertFalse(rtc.microphoneEnabled)
            await closeOrderedRequestSheet(from: controller)

            // A transport loss is not a leave. The host's normal state driver
            // must retain the second seat and expose offline presence to the
            // actual grey-avatar renderer during the reconnect grace period.
            await peer.disconnect()
            try await waitFor("短暂断线后房主自动看到灰头像与保留的二号麦") {
                guard let member = rtc.roomState?.members.first(where: { $0.userID == guest.user.id }) else { return false }
                return !member.online && member.seatIndex == 2 && member.offlineSince != nil && member.reconnectDeadline != nil
            }
            let offline = try XCTUnwrap(rtc.roomState?.members.first { $0.userID == guest.user.id })
            guestOfflinePreserved = !offline.online && offline.seatIndex == 2
            XCTAssertTrue(guestOfflinePreserved)
            XCTAssertNotNil(offline.offlineSince)
            XCTAssertNotNil(offline.reconnectDeadline)
            if let since = offline.offlineSince, let deadline = offline.reconnectDeadline {
                XCTAssertEqual(deadline - since, 60)
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            try captureOrderedScreenshot(window, name: device + "-kiki-ordered-offline")
            let reconnect = try await api.rtcJoin(roomID: created.id, token: guest.token)
            try await peer.connect(url: reconnect.serverURL, token: reconnect.participantToken)
            try await waitFor("宽限期重连恢复在线二号麦且权限保持") {
                rtc.roomState?.members.first(where: { $0.userID == guest.user.id })?.online == true &&
                    rtc.roomState?.members.first(where: { $0.userID == guest.user.id })?.seatIndex == 2 &&
                    peer.remoteParticipants.count == 1 && peer.localParticipant.permissions.canPublish
            }
            guestReconnectedSeatIndex = rtc.roomState?.members.first { $0.userID == guest.user.id }?.seatIndex ?? 0
            XCTAssertEqual(guestReconnectedSeatIndex, 2)
            XCTAssertNil(rtc.roomState?.members.first { $0.userID == guest.user.id }?.offlineSince)
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled(), "重连恢复麦位不能自动开麦。")
            XCTAssertFalse(rtc.microphoneEnabled)

            let leftSeat = try await api.roomAction(.leaveSeat, roomID: created.id, token: guest.token)
            XCTAssertNil(leftSeat.me.seatIndex)
            try await waitFor("主动下麦撤销真实发布权限") { !peer.localParticipant.permissions.canPublish }
            let secondRequest = try await api.roomAction(.requestSeat, roomID: created.id, token: guest.token)
            XCTAssertEqual(secondRequest.me.seatRequestStatus, "pending")
            try await waitFor("房主自动收到第二次申请") {
                (rtc.roomState?.revision ?? 0) >= secondRequest.revision &&
                    rtc.roomState?.queue.contains { $0.userID == guest.user.id && $0.status == "pending" } == true
            }
            if await openOrderedRequestSheet(from: controller), let sheet = controller.presentedViewController {
                requestSheetOpened = true
                if let reject = roomAccessibilityNode(in: sheet.view, identifier: "livekit.room.rejectSeatRequest." + guest.user.id) {
                    rejectionActivatedInUI = activateRoomAccessibilityNode(reject)
                }
            }
            if !rejectionActivatedInUI { await rtc.performRoomAction(.rejectRequest, targetUserID: guest.user.id) }
            try await waitFor("房主确认拒绝并移除待处理队列") {
                rtc.roomState?.members.first(where: { $0.userID == guest.user.id })?.seatRequestStatus == "rejected" &&
                    rtc.roomState?.queue.contains { $0.userID == guest.user.id } == false
            }
            let rejected = try await api.roomState(roomID: created.id, token: guest.token)
            guestRejected = rejected.me.seatRequestStatus == "rejected"
            XCTAssertTrue(guestRejected)
            XCTAssertNil(rejected.me.seatIndex)
            XCTAssertFalse(rejected.me.canPublishAudio)
            await closeOrderedRequestSheet(from: controller)
            microphonesRemainOff = !rtc.microphoneEnabled && !peer.localParticipant.isMicrophoneEnabled()
            XCTAssertTrue(microphonesRemainOff)

            // Exercise the normal leave endpoint, with its default endRoom=false.
            // An owner departure must still close the room and the SFU, never
            // assign the remaining listener as the next owner.
            await rtc.leaveRoom()
            try await waitFor("房主主动离开关闭整个房间与真实双方连接") {
                rtc.currentSDKRoomID == nil && peer.connectionState == .disconnected
            }
            peerDisconnected = peer.connectionState == .disconnected
            let rooms = try await api.rtcRooms(token: guest.token)
            XCTAssertFalse(rooms.contains { $0.id == created.id })
            do {
                _ = try await api.roomState(roomID: created.id, token: guest.token)
                XCTFail("房主离开后不应向剩余成员返回可用房间或转交房主。")
            } catch let error as KikiAPIError {
                guard case .server(let status, _) = error, [404, 409, 410].contains(status) else { throw error }
                closedStateStatus = status
            }
            ownerCloseNoTransfer = peerDisconnected && !rooms.contains { $0.id == created.id } && closedStateStatus != 0
            XCTAssertTrue(ownerCloseNoTransfer)
            await rtc.logout(); await peer.disconnect()
            succeeded = pendingAutomaticallySynced && guestSeatIndex == 2 && guestOfflinePreserved &&
                guestReconnectedSeatIndex == 2 && guestRejected && ownerCloseNoTransfer && microphonesRemainOff
        } catch {
            if let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: host.token) }
            await rtc.logout(); await peer.disconnect()
            XCTFail("正式顺位上麦与房主关闭验收未完成（凭据及底层错误原文已隐藏）。")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 5)
        }
    }

    @MainActor
    private func visibleVoiceRoomOverlayWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { !$0.isHidden && $0.accessibilityIdentifier == "voiceRoomFloatingWindow" }
    }

    @MainActor
    private func captureOrderedScreenshot(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/" + name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    private func roomAccessibilityNodes(in root: UIView) -> [NSObject] {
        var nodes: [NSObject] = [], seen: Set<ObjectIdentifier> = []
        func append(_ object: NSObject) {
            guard nodes.count < 2_000, seen.insert(ObjectIdentifier(object)).inserted else { return }
            nodes.append(object)
            if let view = object as? UIView { for child in view.subviews { append(child) } }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { append(element) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 500 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { append(element) }
                }
            }
        }
        append(root)
        return nodes
    }

    @MainActor
    private func roomAccessibilityNode(in root: UIView, identifier: String) -> NSObject? {
        roomAccessibilityNodes(in: root).first { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier }
    }

    @MainActor
    private func activateRoomAccessibilityNode(_ node: NSObject) -> Bool {
        if node.accessibilityActivate() { return true }
        guard let control = node as? UIControl, control.isEnabled else { return false }
        if control.allControlEvents.contains(.primaryActionTriggered) { control.sendActions(for: .primaryActionTriggered) }
        else if control.allControlEvents.contains(.touchUpInside) { control.sendActions(for: .touchUpInside) }
        else { return false }
        return true
    }

    @MainActor
    private func openOrderedRequestSheet(from controller: UIViewController) async -> Bool {
        if controller.presentedViewController?.viewIfLoaded?.window != nil { return true }
        guard let button = roomAccessibilityNode(in: controller.view, identifier: "livekit.room.seatRequests"),
              activateRoomAccessibilityNode(button) else { return false }
        let deadline = Date().addingTimeInterval(3)
        while controller.presentedViewController?.viewIfLoaded?.window == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return controller.presentedViewController?.viewIfLoaded?.window != nil
    }

    @MainActor
    private func closeOrderedRequestSheet(from controller: UIViewController) async {
        guard let sheet = controller.presentedViewController else { return }
        let done = roomAccessibilityNodes(in: sheet.view).first { $0.accessibilityLabel == "完成" }
        if let done, activateRoomAccessibilityNode(done) {
            let deadline = Date().addingTimeInterval(2)
            while controller.presentedViewController != nil, Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        }
        if controller.presentedViewController != nil { sheet.dismiss(animated: false) }
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    @MainActor
    private func presentedRoomController(for rtc: KikiRTCService) -> UIViewController? {
        guard let identifier = rtc.roomPresentationID else { return nil }
        func find(in controller: UIViewController) -> UIViewController? {
            if ObjectIdentifier(controller) == identifier { return controller }
            if let presented = controller.presentedViewController, let match = find(in: presented) { return match }
            for child in controller.children { if let match = find(in: child) { return match } }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !window.isHidden {
                if let root = window.rootViewController, let match = find(in: root) { return match }
            }
        }
        return nil
    }

    @MainActor private func waitFor(_ stage: String, predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard predicate() else {
            XCTFail("正式语聊验收超时：\(stage)")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 2)
        }
    }
}
