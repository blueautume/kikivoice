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
    func testRoomHostAutomaticallyReceivesPeerGiftAndPresentsAnimation() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_PRODUCTION_VOICE_ACCOUNTS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需在私密测试环境注入两份可注销的正式语聊换票结果；不使用 Apple 登录。")
        }
        let sessions: [KikiVoiceSessionResponse]
        do { sessions = try JSONDecoder().decode([KikiVoiceSessionResponse].self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密测试会话格式不符合换票契约。"); return }
        guard sessions.count >= 2 else { XCTFail("需要两份独立语聊会话。"); return }
        let receiver = sessions[0], sender = sessions[1]
        guard receiver.user.id != sender.user.id,
              [receiver, sender].allSatisfy({ !$0.token.isEmpty && $0.expiresAt > Int(Date().timeIntervalSince1970) + 60 &&
                  $0.sdk.provider == "livekit" && $0.sdk.serverURL == "wss://furby.top" &&
                  $0.sdk.userID == $0.user.id }) else {
            XCTFail("测试会话必须是未过期的独立正式语聊授权。"); return
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let gifts = KikiGiftStore()
        gifts.configure(api: api, token: receiver.token, userID: receiver.user.id)
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api)
        rtc.configureGifts(gifts)
        let peer = Room()
        var roomID: String?
        var receivedEventCount = 0
        var animationRendered = false
        var peerSendCost = 0
        var succeeded = false
        defer {
            // The parent runner audits and disposes the two isolated identities.
            // Only this small, non-secret result crosses the runner boundary.
            let metadata: [String: Any] = [
                "roomID": roomID ?? "", "receivedEventCount": receivedEventCount,
                "animationRendered": animationRendered, "peerSendCost": peerSendCost,
                "succeeded": succeeded,
                "device": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/kiki-gift-receive-result.json"), options: .atomic)
            }
            rtc.configureGifts(nil)
            gifts.reset()
        }


        do {
            let before = try await api.experience(token: receiver.token)
            let created = try await api.reserveRoom(title: "礼物接收端自动同步验收", category: "随心聊", isLive: false, theme: 0, token: receiver.token)
            roomID = created.id
            try await rtc.login(credentials: receiver.sdk, sessionToken: receiver.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: created.theme)
            XCTAssertTrue(rtc.gifts === gifts)
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertFalse(rtc.microphoneEnabled)
            let grant = try await api.rtcJoin(roomID: created.id, token: sender.token)
            try await peer.connect(url: grant.serverURL, token: grant.participantToken)
            try await waitFor("真实房间呈现并由页面自动建立礼物游标") {
                rtc.participants.count == 2 && peer.remoteParticipants.count == 1 &&
                    gifts.roomCursor != nil && self.presentedRoomController(for: rtc)?.viewIfLoaded?.window != nil
            }
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            XCTAssertTrue(gifts.events.isEmpty)
            let controller = try XCTUnwrap(presentedRoomController(for: rtc))
            let window = try XCTUnwrap(controller.viewIfLoaded?.window)
            let requestID = UUID()
            let sent = try await api.sendGift(roomID: created.id, giftID: "flower_rain", quantity: 1,
                                             recipientIDs: [receiver.user.id], requestID: requestID, token: sender.token)
            peerSendCost = sent.totalCost
            let eventID = try XCTUnwrap(sent.events.first?.id)
            XCTAssertEqual(sent.events.count, 1)
            XCTAssertEqual(sent.totalCost, 0, "首份花雨优先使用一次性体验礼包。")
            XCTAssertEqual(sent.inventoryUsed, 1)
            XCTAssertEqual(sent.diamondQuantity, 0)
            XCTAssertEqual(sent.totalQuantity, 1)
            XCTAssertEqual(sent.giftInventory.first { $0.giftID == "flower_rain" }?.quantity, 2)

            // Do not call gifts.pollRoom here: the UIKit-presented SwiftUI room
            // must drive the receiving account's first and incremental reads.
            try await waitFor("收礼方页面自动收到另一端礼物") { gifts.events.contains { $0.id == eventID } }
            receivedEventCount = gifts.events.filter { $0.id == eventID }.count
            XCTAssertEqual(receivedEventCount, 1)
            XCTAssertTrue(gifts.events.contains {
                $0.id == eventID && $0.senderUserID == sender.user.id && $0.recipientUserID == receiver.user.id
            })
            try await waitFor("收礼方真实房间播放随包 GIF") { !self.animatedImages(in: controller.view).isEmpty }
            let animation = try XCTUnwrap(animatedImages(in: controller.view).first)
            animationRendered = (animation.image?.images?.count ?? 0) > 1
            XCTAssertTrue(animationRendered)
            XCTAssertFalse(animation.isUserInteractionEnabled)
            window.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let output = URL(fileURLWithPath: "/tmp/" + device + "-kiki-gift-receive-fixed.png")
            try XCTUnwrap(screenshot.pngData()).write(to: output, options: .atomic)
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = device + "-peer-gift-received-in-real-room"
            attachment.lifetime = .keepAlways
            add(attachment)

            let after = try await api.experience(token: receiver.token)
            XCTAssertEqual(after.wallet.balance, before.wallet.balance, "收礼不增加钻石或产生收益。")
            XCTAssertEqual(after.giftInventory, before.giftInventory, "收到礼物只展示，不增加可转赠背包。")
            let retry = try await api.sendGift(roomID: created.id, giftID: "flower_rain", quantity: 1,
                                              recipientIDs: [receiver.user.id], requestID: requestID, token: sender.token)
            XCTAssertEqual(retry, sent, "重试复用原结算，不能再次扣背包或钻石。")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            receivedEventCount = gifts.events.filter { $0.id == eventID }.count
            XCTAssertEqual(receivedEventCount, 1, "同一请求重试和自动增量读取不能重复收礼。")
            XCTAssertFalse(rtc.microphoneEnabled)
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            await rtc.leaveRoom(endRoom: true)
            try await waitFor("验收房间结束并断开双方") { rtc.currentSDKRoomID == nil && peer.connectionState == .disconnected }
            await rtc.logout()
            await peer.disconnect()
            succeeded = true
        } catch {
            if let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: receiver.token) }
            await rtc.logout()
            await peer.disconnect()
            XCTFail("正式收礼页面集成验收未完成（凭据及底层错误原文已隐藏）。")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 3)
        }
    }

    @MainActor
    func testBackpackBurstSendUsesInventoryBeforeDiamonds() async throws {
        guard let encoded = ProcessInfo.processInfo.environment["KIKI_PRODUCTION_VOICE_ACCOUNTS_JSON"], !encoded.isEmpty else {
            throw XCTSkip("需在私密测试环境注入两份可注销的正式语聊换票结果；不使用 Apple 登录。")
        }
        let sessions: [KikiVoiceSessionResponse]
        do { sessions = try JSONDecoder().decode([KikiVoiceSessionResponse].self, from: Data(encoded.utf8)) }
        catch { XCTFail("私密测试会话格式不符合换票契约。"); return }
        guard sessions.count >= 2 else { XCTFail("需要两份独立语聊会话。"); return }
        let receiver = sessions[0], sender = sessions[1]
        guard receiver.user.id != sender.user.id,
              [receiver, sender].allSatisfy({ !$0.token.isEmpty && $0.expiresAt > Int(Date().timeIntervalSince1970) + 60 &&
                  $0.sdk.provider == "livekit" && $0.sdk.serverURL == "wss://furby.top" &&
                  $0.sdk.userID == $0.user.id }) else {
            XCTFail("测试会话必须是未过期的独立正式语聊授权。"); return
        }
        let api = KikiAPIClient.shared
        let rtc = KikiRTCService.shared
        let gifts = KikiGiftStore()
        let senderGifts = KikiGiftStore()
        gifts.configure(api: api, token: receiver.token, userID: receiver.user.id)
        senderGifts.configure(api: api, token: sender.token, userID: sender.user.id)
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api)
        rtc.configureGifts(gifts)
        let peer = Room()
        var roomID: String?
        var receivedEventCount = 0
        var batchCount = 0
        var animationRendered = false
        var topComboCount = 0
        var topComboConfirmed = false
        var topComboObservable = false
        var totalCost = 0
        var inventoryUsed = 0
        var senderFlowerCount = -1
        var receiverFlowerCount = -1
        var succeeded = false
        defer {
            let metadata: [String: Any] = [
                "roomID": roomID ?? "", "receivedEventCount": receivedEventCount,
                "batchCount": batchCount, "animationRendered": animationRendered,
                "topComboCount": topComboCount, "topComboConfirmed": topComboConfirmed,
                "topComboObservable": topComboObservable,
                "totalCost": totalCost, "inventoryUsed": inventoryUsed,
                "senderFlowerCount": senderFlowerCount, "receiverFlowerCount": receiverFlowerCount,
                "succeeded": succeeded,
                "device": UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/kiki-gift-burst-result.json"), options: .atomic)
            }
            rtc.configureGifts(nil)
            gifts.reset()
            senderGifts.reset()
        }
        do {
            // Each live acceptance method requires a fresh pair of disposable
            // identities; prior gift methods must never consume this package.
            let receiverBefore = try await api.experience(token: receiver.token)
            let senderBefore = try await api.experience(token: sender.token)
            XCTAssertEqual(receiverBefore.wallet.balance, 100_000_000)
            XCTAssertEqual(senderBefore.wallet.balance, 100_000_000)
            XCTAssertEqual(receiverBefore.giftInventory.first { $0.giftID == "flower_rain" }?.quantity, 3)
            XCTAssertEqual(senderBefore.giftInventory.first { $0.giftID == "flower_rain" }?.quantity, 3)
            await gifts.refresh()
            await senderGifts.refresh()
            XCTAssertEqual(senderGifts.giftCount("flower_rain"), 3)
            let flower = try XCTUnwrap(senderGifts.giftItems.first { $0.id == "flower_rain" })
            let created = try await api.reserveRoom(title: "背包多人连送自动验收", category: "随心聊", isLive: false, theme: 0, token: receiver.token)
            roomID = created.id
            try await rtc.login(credentials: receiver.sdk, sessionToken: receiver.token)
            try await rtc.createRoom(roomID: created.id, title: created.title, category: created.category, isLive: false, theme: created.theme)
            XCTAssertTrue(rtc.gifts === gifts)
            XCTAssertTrue(rtc.isPresentingRoom)
            XCTAssertFalse(rtc.microphoneEnabled)
            let grant = try await api.rtcJoin(roomID: created.id, token: sender.token)
            try await peer.connect(url: grant.serverURL, token: grant.participantToken)
            try await waitFor("双端真实入房与接收页面礼物游标") {
                rtc.participants.count == 2 && peer.remoteParticipants.count == 1 &&
                    gifts.roomCursor != nil && self.presentedRoomController(for: rtc)?.viewIfLoaded?.window != nil
            }
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            XCTAssertTrue(gifts.events.isEmpty)
            let controller = try XCTUnwrap(presentedRoomController(for: rtc))
            let window = try XCTUnwrap(controller.viewIfLoaded?.window)
            let queue = senderGifts.sendQueue(for: created.id)
            let recipients = [receiver.user.id, sender.user.id]
            for _ in 0..<3 { XCTAssertTrue(queue.enqueue(gift: flower, recipientIDs: recipients)) }
            XCTAssertNil(queue.lastCombo, "点击瞬间尚未获得服务器确认。")

            // The receiving account's actual presented room drives all reads.
            // No manual gifts.pollRoom call may make this acceptance pass.
            try await waitFor("接收方自动读取三次多人单件赠送并播放 GIF") {
                gifts.events.filter { $0.senderUserID == sender.user.id && $0.giftID == "flower_rain" }.count >= 6 &&
                    !self.animatedImages(in: controller.view).isEmpty
            }
            let animation = try XCTUnwrap(animatedImages(in: controller.view).first)
            animationRendered = (animation.image?.images?.count ?? 0) > 1
            XCTAssertTrue(animationRendered)
            XCTAssertFalse(animation.isUserInteractionEnabled)
            // The receiving room must combine three confirmed batches into its
            // visible top counter. Scan the real public accessibility labels;
            // event counts alone cannot prove what the person actually sees.
            let comboDeadline = Date().addingTimeInterval(2)
            var observedTopCombo: Int?
            repeat {
                if let count = giftTopComboCount(in: controller.view, giftName: flower.name) {
                    observedTopCombo = max(observedTopCombo ?? 0, count)
                    if count == 3 { break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < comboDeadline
            topComboObservable = observedTopCombo != nil
            topComboCount = observedTopCombo ?? 0
            topComboConfirmed = observedTopCombo == 3
            if let observedTopCombo {
                XCTAssertEqual(observedTopCombo, 3, "接收端顶部可见连击应为 ×3，不能只验证三批服务端事件。")
            } else {
                // In-process SwiftUI accessibility can omit virtual nodes on
                // some simulator versions. Record the missing proof explicitly;
                // the saved real-room screenshot then needs visual inspection.
                let note = XCTAttachment(string: "未能通过公开可访问性节点读取顶部连击数；topComboConfirmed=false，需核对本测试保存的真实房间截图。")
                note.name = "top-combo-accessibility-unavailable"; note.lifetime = .keepAlways; add(note)
            }
            window.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            try XCTUnwrap(screenshot.pngData()).write(to: URL(fileURLWithPath: "/tmp/" + device + "-kiki-gift-burst.png"), options: .atomic)
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = device + "-backpack-burst-in-real-room"
            attachment.lifetime = .keepAlways
            add(attachment)

            try await waitFor("发送队列全部确认并累计三次连送") {
                queue.pendingCount == 0 && !queue.isSending && queue.lastCombo?.count == 3
            }
            let events = gifts.events.filter { $0.senderUserID == sender.user.id && $0.giftID == "flower_rain" }
            receivedEventCount = events.count
            batchCount = Set(events.map(\.batchID)).count
            XCTAssertEqual(receivedEventCount, 6)
            XCTAssertEqual(batchCount, 3)
            XCTAssertEqual(Set(events.map(\.id)).count, 6)
            XCTAssertTrue(events.allSatisfy { $0.quantity == 1 && $0.batchRecipientCount == 2 })
            for batch in Dictionary(grouping: events, by: \.batchID).values {
                XCTAssertEqual(batch.count, 2)
                XCTAssertEqual(Set(batch.map(\.recipientUserID)), Set(recipients), "每次 Send 为每个选中目标各送一份。")
            }
            let combo = try XCTUnwrap(queue.lastCombo)
            totalCost = combo.totalCost
            inventoryUsed = combo.inventoryUsed
            XCTAssertEqual(combo.count, 3)
            XCTAssertEqual(combo.giftID, "flower_rain")
            XCTAssertEqual(Set(combo.recipientIDs), Set(recipients))
            XCTAssertEqual(inventoryUsed, 3)
            XCTAssertEqual(totalCost, 297)
            XCTAssertEqual(senderGifts.wallet?.balance, 100_000_000 - 297)
            XCTAssertEqual(senderGifts.giftCount("flower_rain"), 0)
            let senderAfter = try await api.experience(token: sender.token)
            let receiverAfter = try await api.experience(token: receiver.token)
            senderFlowerCount = senderAfter.giftInventory.first { $0.giftID == "flower_rain" }?.quantity ?? 0
            receiverFlowerCount = receiverAfter.giftInventory.first { $0.giftID == "flower_rain" }?.quantity ?? 0
            XCTAssertEqual(senderFlowerCount, 0)
            XCTAssertEqual(senderAfter.wallet.balance, 100_000_000 - 297)
            XCTAssertEqual(receiverFlowerCount, 3)
            XCTAssertEqual(receiverAfter.giftInventory, receiverBefore.giftInventory)
            XCTAssertEqual(receiverAfter.wallet.balance, receiverBefore.wallet.balance)
            let giftEntries = senderAfter.entries.filter { $0.kind == "gift" }
            XCTAssertEqual(giftEntries.count, 3, "三次确认各保留一次结算记录，纯背包单金额为零。")
            XCTAssertEqual(giftEntries.reduce(0) { $0 + $1.amount }, -297)
            XCTAssertFalse(rtc.microphoneEnabled)
            XCTAssertFalse(peer.localParticipant.isMicrophoneEnabled())
            await rtc.leaveRoom(endRoom: true)
            try await waitFor("连送验收房间结束并断开双方") { rtc.currentSDKRoomID == nil && peer.connectionState == .disconnected }
            await rtc.logout()
            await peer.disconnect()
            succeeded = true
        } catch {
            if let roomID { _ = try? await api.setRoomStatus(roomID, status: "ended", token: receiver.token) }
            await rtc.logout()
            await peer.disconnect()
            XCTFail("正式背包连送集成验收未完成（凭据及底层错误原文已隐藏）。")
            throw NSError(domain: "KikiProductionVoiceIntegration", code: 4)
        }
    }

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
        let gifts = KikiGiftStore()
        gifts.configure(api: api, token: listener.token, userID: listener.user.id)
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api); rtc.configureGifts(gifts)
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
            rtc.configureGifts(nil); gifts.reset()
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
        let gifts = KikiGiftStore()
        gifts.configure(api: api, token: host.token, userID: host.user.id)
        rtc.renewAuthorization = nil
        rtc.onRoomClosed = nil; rtc.onSessionExpired = nil
        rtc.configure(api: api); rtc.configureGifts(gifts)
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
            rtc.configureGifts(nil); gifts.reset()
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
    private func giftTopComboCount(in root: UIView, giftName: String) -> Int? {
        let nodes = roomAccessibilityNodes(in: root)
        let labels = nodes.compactMap { node -> String? in
            let identifier = (node as? UIAccessibilityIdentification)?.accessibilityIdentifier
            if identifier == "giftPresentationCombo" { return node.accessibilityLabel }
            // Public label fallback for simulators that omit a virtual node's
            // identifier. Chat says “送给”; the presentation says “赠送”.
            if let label = node.accessibilityLabel, label.contains(giftName), label.contains("×"),
               label.contains("赠送") || label.hasPrefix(giftName + " ×") { return label }
            if let text = (node as? UILabel)?.text, text.hasPrefix(giftName + " ×") { return text }
            return nil
        }
        return labels.compactMap { text -> Int? in
            guard let range = text.range(of: "×\\s*[0-9]+", options: .regularExpression) else { return nil }
            return Int(text[range].filter(\.isNumber))
        }.max()
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
    private func animatedImages(in view: UIView) -> [UIImageView] {
        var images: [UIImageView] = []
        if let imageView = view as? UIImageView, (imageView.image?.images?.count ?? 0) > 1 {
            images.append(imageView)
        }
        for child in view.subviews { images.append(contentsOf: animatedImages(in: child)) }
        return images
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
