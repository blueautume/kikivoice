import CryptoKit
import AtomicXCore
import Foundation
import Security
import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

/// Test target only. No bypass, QA token or relaxed TLS policy is linked into
/// the app. The temporary service is reachable only through an SSH tunnel.
@MainActor
final class KikiGiftRealtimeTests: XCTestCase {
    func testIsolatedQAGiftSenderAndReceiver() async throws {
        let env = ProcessInfo.processInfo.environment
        let testStartedAt = Int(Date().timeIntervalSince1970) - 3
        guard env["KIKI_GIFT_QA_ENABLED"] == "1" else { throw XCTSkip("按礼物测试文档启动隔离 QA 后端后启用。") }
        let baseURL = try XCTUnwrap(URL(string: try XCTUnwrap(env["KIKI_GIFT_QA_BASE_URL"])))
        guard baseURL.scheme == "https", baseURL.host == "127.0.0.1", baseURL.port == 19443 else {
            throw KikiAPIError.security("隔离测试仅允许指定的本机 HTTPS 隧道。")
        }
        let key = try XCTUnwrap(env["KIKI_GIFT_QA_TOKEN"])
        let fingerprint = try XCTUnwrap(env["KIKI_GIFT_QA_TLS_SHA256"])
        let delegate = GiftQATLSDelegate(fingerprint: fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let api = KikiAPIClient(baseURL: baseURL, session: session)
        let role = env["KIKI_GIFT_QA_ROLE"] ?? "sender"
        let runID = env["KIKI_GIFT_QA_RUN_ID"] ?? "gift_validation"
        let userID = "qa_\(runID)_\(role)"
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let legal: [String: Any] = ["privacyVersion": docs.versions.privacyVersion, "termsVersion": docs.versions.termsVersion,
                                  "documentHash": docs.versions.documentHash, "accepted": true, "adultConfirmed": true]
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/internal/qa/login"))
        request.httpMethod = "POST"; request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["userID": userID, "name": role == "receiver" ? "礼物接收验收" : "礼物发送验收", "legalConsent": legal])
        let (loginData, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let login = try JSONDecoder().decode(KikiLoginResponse.self, from: loginData)
        let identity = GiftQAIdentity(token: login.token)
        let suite = "KikiGiftQA." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let consent = KikiConsentStore(defaults: defaults, identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { api },
                                  rtcProvider: { KikiRTCService.shared }, appleProvider: { GiftQAApple() })
        addTeardownBlock { await store.logout() }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow))
        let originalRoot = window.rootViewController
        let qaRoot = UIHostingController(rootView: KikiProfileView().environmentObject(store).environmentObject(consent).preferredColorScheme(.dark))
        window.rootViewController = qaRoot; window.makeKeyAndVisible()
        defer { window.rootViewController = originalRoot }
        await store.start()
        XCTAssertTrue(store.isAuthenticated, store.loadingError ?? "QA SDK 登录失败")
        let gifts = store.gifts
        await gifts.load()
        XCTAssertEqual(gifts.catalog?.gifts.count, 5)
        XCTAssertNotNil(gifts.wallet)
        let multipleRecipients = env["KIKI_GIFT_QA_MULTI"] == "1"

        if role == "receiver" {
            // The second simulator records a cursor before the sender starts;
            // root coordinates the run through this QA-only room registry.
            var target: DemoRoom?
            for _ in 0..<80 {
                let records = try await api.roomMetadata(ids: [env["KIKI_GIFT_QA_ROOM_ID"] ?? ""], token: login.token)
                target = records.first
                if target?.status == "live" { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let room = try XCTUnwrap(target)
            var joined = false
            for _ in 0..<10 {
                do { try await store.openRoom(room); joined = true; break }
                catch { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            XCTAssertTrue(joined, "等待发送端创建或恢复 SDK 房间")
            XCTAssertTrue(KikiRTCService.shared.isCurrentRoom(room.id))
            takeScreenshot("gift-receiver-room")
            NotificationCenter.default.post(name: Notification.Name("KikiGiftPanelRequested"), object: nil, userInfo: ["roomID": room.id])
            try await Task.sleep(nanoseconds: 700_000_000)
            takeScreenshot("gift-receiver-panel-small-screen")
            qaRoot.presentedViewController?.presentedViewController?.dismiss(animated: false)
            var cursor = try await gifts.events(roomID: room.id, after: nil).nextCursor
            await gifts.send(roomID: room.id, giftID: "heart", quantity: 1)
            XCTAssertNil(gifts.errorMessage)
            var received: Set<String> = []
            var batchEvents: [KikiGiftEvent] = []
            for _ in 0..<(env["KIKI_GIFT_QA_UI"] == "1" ? 240 : 120) {
                let page = try await gifts.events(roomID: room.id, after: cursor)
                cursor = page.nextCursor
                received.formUnion(page.events.filter { $0.senderID == room.hostID }.map(\.giftID))
                batchEvents.append(contentsOf: page.events.filter { $0.senderID == room.hostID && $0.batchID != nil })
                if !page.events.isEmpty {
                    try await Task.sleep(nanoseconds: 450_000_000)
                    takeScreenshot("gift-receiver-\(page.events.last!.giftID)")
                }
                if multipleRecipients ? batchEvents.count >= 2 : received.count == 5 { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            if multipleRecipients {
                XCTAssertEqual(Set(batchEvents.map(\.recipientID)), [room.hostID, login.user.sdkUserID])
                XCTAssertEqual(Set(batchEvents.map(\.quantity)), [99])
                XCTAssertEqual(Set(batchEvents.compactMap(\.batchID)).count, 1)
                XCTAssertEqual(Set(batchEvents.compactMap(\.batchRecipientCount)), [2])
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let messages = BarrageStore.create(liveID: room.id).state.value.messageList.filter {
                    $0.extensionInfo?["TYPE"] == "KIKI_FREE_GIFT"
                }
                let eventIDs = Set(batchEvents.map(\.id))
                let matching = messages.filter { eventIDs.contains($0.extensionInfo?["gift_event_id"] ?? "") }
                XCTAssertEqual(matching.count, 2)
                XCTAssertTrue(matching.allSatisfy { $0.textContent.contains("×99") })
                XCTAssertEqual(Set(matching.map(\.textContent)), ["送给 礼物发送验收 初见心动 ×99", "送给 礼物接收验收 初见心动 ×99"])
                takeScreenshot("gift-multi-receiver-chat")
            } else { XCTAssertEqual(received, KikiGift.knownIDs) }
        } else {
            let room: DemoRoom
            if let roomID = env["KIKI_GIFT_QA_ROOM_ID"], !roomID.isEmpty {
                let records = try await api.roomMetadata(ids: [roomID], token: login.token)
                room = try XCTUnwrap(records.first)
            } else {
                let reserved = try await api.reserveRoom(title: "礼物隔离验收", category: "随心聊", isLive: false, theme: 1, token: login.token)
                room = reserved
            }
            if room.status == "live" {
                do { try await store.openRoom(room) }
                catch { try await store.startRoom(room) }
            } else { try await store.startRoom(room) }
            XCTAssertTrue(KikiRTCService.shared.isCurrentRoom(room.id))
            let before = try XCTUnwrap(gifts.wallet?.balance)
            var readyCursor: Int64 = 0
            var receiverReady = false
            for _ in 0..<120 {
                let page = try await gifts.events(roomID: room.id, after: readyCursor)
                readyCursor = page.nextCursor
                receiverReady = page.events.contains { $0.senderID != login.user.sdkUserID && $0.createdAt >= testStartedAt }
                if receiverReady { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            XCTAssertTrue(receiverReady, "接收端需先进入真实房间并发出就绪礼物")
            NotificationCenter.default.post(name: Notification.Name("KikiGiftPanelRequested"), object: nil, userInfo: ["roomID": room.id])
            try await Task.sleep(nanoseconds: 700_000_000)
            takeScreenshot("gift-panel-five-gifts")
            if multipleRecipients, env["KIKI_GIFT_QA_UI"] == "1" {
                print("KIKI_MULTI_GIFT_PANEL_READY")
                try await Task.sleep(nanoseconds: 40_000_000_000)
                takeScreenshot("gift-multi-two-selected")
            }
            qaRoot.presentedViewController?.presentedViewController?.dismiss(animated: false)
            if multipleRecipients {
                let candidates = KikiSDKGiftRecipients(roomID: room.id)
                candidates.source.refresh?()
                for _ in 0..<60 {
                    if candidates.source.members.count >= 2 { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                let targets = candidates.source.members.map(\.id).sorted()
                XCTAssertEqual(targets.count, 2, "SDK名单应包含房主和真实听众各一人")
                await gifts.sendBatch(roomID: room.id, giftID: "heart", quantity: 99, recipientIDs: targets)
                XCTAssertNil(gifts.errorMessage)
                XCTAssertEqual(gifts.wallet?.balance, before - 198)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let messages = BarrageStore.create(liveID: room.id).state.value.messageList.filter {
                    $0.sender.userID == login.user.sdkUserID && $0.extensionInfo?["gift_count"] == "99"
                }
                XCTAssertEqual(messages.count, 2, "每个收礼人一条消息，ack/poll不得重复")
                XCTAssertEqual(Set(messages.map(\.textContent)), ["送给 礼物发送验收 初见心动 ×99", "送给 礼物接收验收 初见心动 ×99"])
                takeScreenshot("gift-multi-sender-chat")
                for _ in 0..<75 {
                    if candidates.source.members.count == 1 { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                XCTAssertEqual(candidates.source.members.map(\.id), [login.user.sdkUserID], "听众离房后从收礼名单移除")
                NotificationCenter.default.post(name: Notification.Name("KikiGiftPanelRequested"), object: nil, userInfo: ["roomID": room.id])
                try await Task.sleep(nanoseconds: 500_000_000)
                takeScreenshot("gift-multi-after-listener-left")
                qaRoot.presentedViewController?.presentedViewController?.dismiss(animated: false)
                // UIKit finishes a sheet dismissal on the next run-loop turn,
                // even with animations disabled. Minimize only after it closes.
                for _ in 0..<40 {
                    if qaRoot.presentedViewController?.presentedViewController == nil { break }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
            } else {
              for gift in try XCTUnwrap(gifts.catalog?.gifts) {
                await gifts.send(roomID: room.id, giftID: gift.id, quantity: 1)
                XCTAssertNil(gifts.errorMessage)
                XCTAssertEqual(gifts.lastSent?.giftID, gift.id)
                try await Task.sleep(nanoseconds: 500_000_000)
                takeScreenshot("gift-sender-\(gift.id)")
                try await Task.sleep(nanoseconds: UInt64(gift.durationMilliseconds + 500) * 1_000_000)
              }
              XCTAssertEqual(gifts.wallet?.balance, before - 16_098)
            }
            let sdkRoomID = KikiRTCService.shared.currentSDKRoomID
            XCTAssertTrue(KikiRTCService.shared.minimizeVoiceRoom())
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(KikiRTCService.shared.currentSDKRoomID, sdkRoomID)
            takeScreenshot("gift-minimized-wallet")
            try await KikiRTCService.shared.resumeMinimizedVoiceRoom()
            XCTAssertEqual(KikiRTCService.shared.currentSDKRoomID, sdkRoomID)
            takeScreenshot("gift-restored-room")
        }
        await store.logout()
    }

    private func takeScreenshot(_ name: String) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
private final class GiftQAIdentity: KikiIdentityStoring {
    private var values: [String: String]
    init(token: String) { values = ["sessionToken": token, "appleSubject": "isolated-qa-only", "appleSessionVersion": "1"] }
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}
@MainActor
private final class GiftQAApple: KikiAppleAuthorizing {
    func authorize(nonce: String, state: String) async throws -> KikiAppleCredential { throw CancellationError() }
    func credentialState(subject: String) async throws -> KikiAppleCredentialState { .authorized }
    func cancel() { }
}

private final class GiftQATLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.port == 19443,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = certificates.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        guard digest == fingerprint,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "kiki.group" as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
