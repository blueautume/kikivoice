import XCTest
import SwiftUI
import UIKit
@testable import KikiTalk

final class KikiForegroundNotificationTests: XCTestCase {
    private let account = KikiForegroundNotificationScope(sessionKey: "1:account", privacyRevision: 0)
    private let foreground = KikiForegroundNotificationContext(isActive: true)

    private func direct(_ id: String, peer: String = "friend") -> KikiForegroundNotificationCandidate {
        .init(id: id, kind: .direct(personID: peer))
    }

    private func room(_ id: String, roomID: String = "lk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") -> KikiForegroundNotificationCandidate {
        .init(id: id, kind: .room(roomID: roomID))
    }

    func testFirstSnapshotSeedsWithoutAlertingAndAcceptedMessagesAlertOnlyOnce() {
        var gate = KikiForegroundNotificationGate()
        let old = direct("old")
        XCTAssertFalse(gate.accepts(old, scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: true))
        XCTAssertFalse(gate.accepts(old, scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: false))
        XCTAssertTrue(gate.accepts(direct("new"), scope: account, currentScope: account, context: foreground,
                                   notificationsEnabled: true, baseline: false))
        XCTAssertFalse(gate.accepts(direct("new"), scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: false),
                       "APNs invalidation and the periodic HTTP poll must not produce two alerts")
    }

    func testVisibleCurrentConversationSuppressesButProfileAndReportOverlaysPermitNewAlerts() {
        var gate = KikiForegroundNotificationGate()
        let reading = KikiForegroundNotificationContext(isActive: true, conversationPersonID: "friend")
        XCTAssertFalse(gate.accepts(direct("read"), scope: account, currentScope: account, context: reading,
                                    notificationsEnabled: true, baseline: false))
        let covered = KikiForegroundNotificationContext(isActive: true, conversationPersonID: "friend", hasConversationOverlay: true)
        for id in ["while-profile-is-open", "while-report-is-open"] {
            XCTAssertTrue(gate.accepts(direct(id), scope: account, currentScope: account, context: covered,
                                       notificationsEnabled: true, baseline: false))
        }
        XCTAssertFalse(gate.accepts(direct("read"), scope: account, currentScope: account, context: covered,
                                    notificationsEnabled: true, baseline: false),
                       "Covering the conversation cannot replay a message already consumed while reading")
        XCTAssertTrue(gate.accepts(direct("other", peer: "someone-else"), scope: account, currentScope: account,
                                   context: reading, notificationsEnabled: true, baseline: false))
    }

    func testCurrentRoomSuppressesItsAlertAndLeavingDoesNotReplayTheConsumedEvent() {
        var gate = KikiForegroundNotificationGate()
        let roomID = "lk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let inRoom = KikiForegroundNotificationContext(isActive: true, hasConversationOverlay: true, currentRoomID: roomID)
        XCTAssertFalse(gate.accepts(room("already-in-room"), scope: account, currentScope: account, context: inRoom,
                                    notificationsEnabled: true, baseline: false),
                       "A room/profile overlay does not make an alert for the current RTC room useful")
        XCTAssertFalse(gate.accepts(room("already-in-room"), scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: false),
                       "Leaving the room cannot replay an event consumed while inside")
        XCTAssertTrue(gate.accepts(room("another-room", roomID: "lk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
                                   scope: account, currentScope: account, context: inRoom,
                                   notificationsEnabled: true, baseline: false))
        XCTAssertTrue(gate.accepts(.init(id: "ordinary-interaction", kind: .notifications),
                                   scope: account, currentScope: account, context: inRoom,
                                   notificationsEnabled: true, baseline: false),
                      "A current room only suppresses notifications targeting that room")
        XCTAssertTrue(gate.accepts(room("after-leaving"), scope: account, currentScope: account, context: foreground,
                                   notificationsEnabled: true, baseline: false))
    }

    func testRoomCandidatesRetainBaselineBackgroundOptOutAndScopeGates() {
        var gate = KikiForegroundNotificationGate()
        for (id, context, enabled, baseline) in [
            ("room-baseline", foreground, true, true),
            ("room-background", KikiForegroundNotificationContext(isActive: false), true, false),
            ("room-disabled", foreground, false, false)
        ] {
            XCTAssertFalse(gate.accepts(room(id), scope: account, currentScope: account, context: context,
                                        notificationsEnabled: enabled, baseline: baseline))
            XCTAssertFalse(gate.accepts(room(id), scope: account, currentScope: account, context: foreground,
                                        notificationsEnabled: true, baseline: false),
                           "Returning to the foreground or enabling alerts cannot replay a consumed room event")
        }
        for current in [KikiForegroundNotificationScope(sessionKey: "2:other-account", privacyRevision: 0),
                        KikiForegroundNotificationScope(sessionKey: account.sessionKey, privacyRevision: 1)] {
            var scopedGate = KikiForegroundNotificationGate()
            XCTAssertFalse(scopedGate.accepts(room("late-room"), scope: account, currentScope: current,
                                              context: foreground, notificationsEnabled: true, baseline: false))
            XCTAssertTrue(scopedGate.accepts(room("late-room"), scope: current, currentScope: current,
                                             context: foreground, notificationsEnabled: true, baseline: false),
                          "A rejected old-scope room response must not consume the current scope's event")
        }
    }

    func testBackgroundEventsDoNotAlertOrReplayWhenTheAppBecomesActive() {
        var gate = KikiForegroundNotificationGate()
        let background = KikiForegroundNotificationContext(isActive: false)
        XCTAssertFalse(gate.accepts(direct("background"), scope: account, currentScope: account, context: background,
                                    notificationsEnabled: true, baseline: false))
        XCTAssertFalse(gate.accepts(direct("background"), scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: false))
        XCTAssertTrue(gate.accepts(direct("foreground"), scope: account, currentScope: account, context: foreground,
                                   notificationsEnabled: true, baseline: false))
    }

    func testLateAccountAndPrivacyResponsesCannotAlertOrPoisonTheCurrentScope() {
        for current in [KikiForegroundNotificationScope(sessionKey: "2:other-account", privacyRevision: 0),
                        KikiForegroundNotificationScope(sessionKey: account.sessionKey, privacyRevision: 1)] {
            var gate = KikiForegroundNotificationGate()
            XCTAssertFalse(gate.accepts(direct("late"), scope: account, currentScope: current, context: foreground,
                                        notificationsEnabled: true, baseline: false))
            XCTAssertTrue(gate.accepts(direct("late"), scope: current, currentScope: current, context: foreground,
                                       notificationsEnabled: true, baseline: false),
                          "A rejected old response must not consume a new session's event")
            XCTAssertFalse(gate.accepts(direct("signed-out"), scope: current, currentScope: nil, context: foreground,
                                        notificationsEnabled: true, baseline: false))
        }
    }

    func testExplicitAccountOptOutSuppressesWithoutReplayingWhenEnabled() {
        var gate = KikiForegroundNotificationGate()
        XCTAssertFalse(gate.accepts(direct("disabled"), scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: false, baseline: false))
        XCTAssertFalse(gate.accepts(direct("disabled"), scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: false))
        // System APNs permission is deliberately not an input to this in-app policy.
        XCTAssertTrue(gate.accepts(direct("enabled"), scope: account, currentScope: account, context: foreground,
                                   notificationsEnabled: true, baseline: false))
    }

    func testMessageAndCommunityStreamsAndDifferentPeersHaveIndependentEventIdentity() {
        var gate = KikiForegroundNotificationGate()
        let candidates = [direct("same", peer: "first"), direct("same", peer: "second"),
                          KikiForegroundNotificationCandidate(id: "same", kind: .notifications)]
        for candidate in candidates {
            XCTAssertTrue(gate.accepts(candidate, scope: account, currentScope: account, context: foreground,
                                       notificationsEnabled: true, baseline: false))
            XCTAssertFalse(gate.accepts(candidate, scope: account, currentScope: account, context: foreground,
                                        notificationsEnabled: true, baseline: false))
        }
    }

    func testUnchangedUnreadConversationHeadsStaySilentDuringALongForegroundSession() {
        var gate = KikiForegroundNotificationGate()
        let unread = direct("older-unread", peer: "quiet-conversation")
        XCTAssertFalse(gate.accepts(unread, scope: account, currentScope: account, context: foreground,
                                    notificationsEnabled: true, baseline: true))
        for index in 0..<520 {
            XCTAssertTrue(gate.accepts(direct("busy-\(index)"), scope: account, currentScope: account, context: foreground,
                                       notificationsEnabled: true, baseline: false))
            XCTAssertFalse(gate.accepts(unread, scope: account, currentScope: account, context: foreground,
                                        notificationsEnabled: true, baseline: false),
                           "Repeated inbox polling must not re-alert an unchanged unread head when the bounded cache fills")
        }
    }

    func testMalformedCandidatesAndMissingPushIdentityCannotProducePreviewContent() throws {
        var gate = KikiForegroundNotificationGate()
        for candidate in [direct(""), direct("message", peer: ""), direct(String(repeating: "x", count: 257))] {
            XCTAssertFalse(gate.accepts(candidate, scope: account, currentScope: account, context: foreground,
                                        notificationsEnabled: true, baseline: false))
        }
        XCTAssertNil(KikiPushTap(payload: ["title": "untrusted sender", "body": "private message", "personID": "claimed-peer"]))
        let delivery = UUID().uuidString
        let tap = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": delivery, "accountTag": "verified-tag",
                                                    "personID": "claimed-peer", "body": "private message"]))
        XCTAssertEqual(tap, KikiPushTap(payload: ["deliveryID": delivery, "accountTag": "verified-tag"]))
        let notice = KikiForegroundNotice(scope: account, candidate: direct("private-event-id", peer: "private-peer-id"))
        XCTAssertEqual(notice.title, "收到新消息")
        XCTAssertEqual(notice.message, "收到一条新私信，可在消息页查看。")
        XCTAssertFalse((notice.title + notice.message).contains("private"))
    }

    func testAuthenticatedPreviewIsVisibleByDefaultAndHiddenPreferenceUsesGenericContent() throws {
        let candidate = KikiForegroundNotificationCandidate(id: "verified-event", kind: .direct(personID: "friend"),
            preview: .init(title: "消息好友 👨‍👩‍👧‍👦", message: "今晚一起听歌吗？🎵"))
        let visible = KikiForegroundNotice(scope: account, candidate: candidate)
        XCTAssertEqual(visible.title, "消息好友 👨‍👩‍👧‍👦")
        XCTAssertEqual(visible.message, "今晚一起听歌吗？🎵")
        let hidden = KikiForegroundNotice(scope: account, candidate: candidate, hideContent: true)
        XCTAssertEqual(hidden.title, "收到新消息")
        XCTAssertEqual(hidden.message, "收到一条新私信，可在消息页查看。")
        XCTAssertFalse((hidden.title + hidden.message).contains("消息好友"))
        XCTAssertFalse((hidden.title + hidden.message).contains("听歌"))
        XCTAssertNil(KikiForegroundNotificationPreview(title: "  ", message: "body"))
        XCTAssertNil(KikiForegroundNotificationPreview(title: "name", message: "\n\t"))
        let emoji = "👨‍👩‍👧‍👦"
        let bounded = try XCTUnwrap(KikiForegroundNotificationPreview(title: "好友\n昵称", message: String(repeating: emoji, count: 300)))
        XCTAssertEqual(bounded.title, "好友 昵称")
        XCTAssertEqual(bounded.message, String(repeating: emoji, count: 240), "Preview bounds must preserve whole extended grapheme clusters")
    }

    func testRoomPreviewUsesAuthenticatedActorAndTextAndHidesBothWithTheExistingPreference() {
        let candidate = KikiForegroundNotificationCandidate(id: "verified-room-start", kind: .room(roomID: "lk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            preview: .init(title: "开房好友", message: "开始语聊了，点击进入房间"))
        let visible = KikiForegroundNotice(scope: account, candidate: candidate)
        XCTAssertEqual(visible.title, "开房好友")
        XCTAssertEqual(visible.message, "开始语聊了，点击进入房间")
        let hidden = KikiForegroundNotice(scope: account, candidate: candidate, hideContent: true)
        XCTAssertEqual(hidden.title, "收到新消息")
        XCTAssertEqual(hidden.message, "有新的互动消息，可在消息页查看。")
        XCTAssertFalse((hidden.title + hidden.message).contains("开房好友"))
        XCTAssertFalse((hidden.title + hidden.message).contains("开始语聊"))
        XCTAssertFalse((hidden.title + hidden.message).contains("lk_"))
    }

    @MainActor
    func testUnattachedControllerRejectsForegroundEventsAndCannotNavigate() async {
        let push = KikiPushController()
        push.foregroundContext = { .init(isActive: true) }
        XCTAssertNil(push.currentForegroundScope)
        push.receiveForegroundCandidates([direct("unattached")], scope: account)
        push.receiveForeground(nil)
        XCTAssertNil(push.foregroundNotice)
        XCTAssertNil(push.navigation)
        XCTAssertNil(push.pendingInboxRequest)
    }

    @MainActor
    func testNativeNoticeAppearsAboveSheetWithoutTakingFocusAndPassesOutsideTouches() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let fixtureWindow = UIWindow(windowScene: scene)
        fixtureWindow.frame = scene.coordinateSpace.bounds
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        fixtureWindow.rootViewController = root
        fixtureWindow.makeKeyAndVisible()
        let sheet = UIViewController()
        sheet.view.backgroundColor = .secondarySystemBackground
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.medium(), .large()]
        let textField = UITextField(frame: CGRect(x: 24, y: 60, width: 240, height: 44))
        textField.placeholder = "通知展示测试"
        textField.borderStyle = .roundedRect
        sheet.view.addSubview(textField)
        root.present(sheet, animated: false)
        let presentation = KikiForegroundNoticePresentation()
        defer {
            presentation.hide()
            textField.resignFirstResponder()
            root.dismiss(animated: false)
            fixtureWindow.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(textField.becomeFirstResponder())
        XCTAssertTrue(sheet.view.window === fixtureWindow)
        let notice = KikiForegroundNotice(scope: account, candidate: .init(id: "fixture-event", kind: .direct(personID: "friend"),
            preview: .init(title: "消息好友的较长昵称 👨‍👩‍👧‍👦 Long display name", message: String(repeating: "今晚一起听歌吗？ Let's listen together 🎵👨‍👩‍👧‍👦 ", count: 30))))

        @MainActor func verifyNotice(_ scheme: ColorScheme) async throws {
            fixtureWindow.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            presentation.show(notice, in: scene, colorScheme: scheme,
                              onDismiss: { [weak presentation] in presentation?.hide() })
            let overlay = try XCTUnwrap(presentation.window)
            let deadline = Date().addingTimeInterval(2)
            while overlay.bannerFrame.isEmpty, Date() < deadline {
                overlay.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 30_000_000)
            }
            XCTAssertFalse(overlay.isHidden)
            XCTAssertTrue(overlay.windowScene === scene)
            XCTAssertGreaterThan(overlay.windowLevel, fixtureWindow.windowLevel)
            XCTAssertLessThan(overlay.windowLevel, UIWindow.Level.alert)
            XCTAssertFalse(overlay.isKeyWindow)
            XCTAssertTrue(fixtureWindow.isKeyWindow)
            XCTAssertTrue(textField.isFirstResponder, "A notice must preserve the sheet's active input")
            XCTAssertTrue(root.presentedViewController === sheet, "Showing a notice must not dismiss a settings/profile sheet")
            XCTAssertEqual(overlay.traitCollection.userInterfaceStyle, scheme == .dark ? .dark : .light)
            let banner = overlay.bannerFrame
            XCTAssertGreaterThan(banner.width, 0)
            XCTAssertGreaterThan(banner.height, 0)
            XCTAssertLessThan(banner.height, 200, "A long bilingual/emoji preview must remain a compact banner")
            XCTAssertNotNil(overlay.hitTest(CGPoint(x: banner.midX, y: banner.midY), with: nil))
            let outside = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.maxY - 4)
            XCTAssertNil(overlay.hitTest(outside, with: nil), "Touches outside the banner must reach the sheet below")
            XCTAssertNotNil(fixtureWindow.hitTest(outside, with: nil))
            try captureNotice(fixtureWindow: fixtureWindow, overlay: overlay, scheme: scheme)
        }
        for scheme in [ColorScheme.light, .dark] { try await verifyNotice(scheme) }
        weak var releasedWindow = presentation.window
        presentation.hide()
        XCTAssertNil(presentation.window)
        XCTAssertNil(releasedWindow?.windowScene, "A removed notice must immediately detach from its scene")
        XCTAssertNil(releasedWindow?.rootViewController)
        let releaseDeadline = Date().addingTimeInterval(1)
        while releasedWindow != nil, Date() < releaseDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(releasedWindow, "Removing the notice must release its scene window and hosted content")
        XCTAssertTrue(fixtureWindow.isKeyWindow)
        XCTAssertTrue(textField.isFirstResponder)
    }

    @MainActor
    private func captureNotice(fixtureWindow: UIWindow, overlay: UIWindow, scheme: ColorScheme) throws {
        let image = UIGraphicsImageRenderer(bounds: fixtureWindow.bounds).image { _ in
            XCTAssertTrue(fixtureWindow.drawHierarchy(in: fixtureWindow.bounds, afterScreenUpdates: true))
            XCTAssertTrue(overlay.drawHierarchy(in: overlay.bounds, afterScreenUpdates: true))
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let name = device + "-foreground-notice-" + (scheme == .dark ? "dark" : "light")
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/kiki-foreground-notice-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
    }
}
