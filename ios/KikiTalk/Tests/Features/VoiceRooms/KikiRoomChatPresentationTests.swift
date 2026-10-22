import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiRoomChatPresentationTests: XCTestCase {
    func testBottomFollowingSurvivesKeyboardResizeFramesUntilTheBottomIsRestored() throws {
        var tracking = KikiRoomChatTracking()
        XCTAssertNil(tracking.update(.init(bottom: 604, height: 600), hasPositionedChat: true, isDragging: false))
        let request = try XCTUnwrap(tracking.update(.init(bottom: 604, height: 500),
                                                    hasPositionedChat: true, isDragging: false))
        XCTAssertEqual(tracking.update(.init(bottom: 550, height: 450), hasPositionedChat: true, isDragging: false), request)
        XCTAssertEqual(tracking.update(.init(bottom: 470, height: 450), hasPositionedChat: true, isDragging: false), request,
                       "Being within the 50-point following threshold must not finish a partially restored keyboard resize")
        XCTAssertTrue(tracking.isNearBottom)
        XCTAssertTrue(tracking.mayRestore(request, isDragging: false))
        XCTAssertNil(tracking.update(.init(bottom: 454, height: 450), hasPositionedChat: true, isDragging: false))
        XCTAssertTrue(tracking.isNearBottom)
        XCTAssertFalse(tracking.mayRestore(request, isDragging: false), "The completed restore must invalidate queued work")
    }

    func testViewportResizeDoesNotPullAnOlderMessageReaderToTheBottom() {
        var tracking = KikiRoomChatTracking()
        XCTAssertNil(tracking.update(.init(bottom: 900, height: 500), hasPositionedChat: true, isDragging: false))
        XCTAssertFalse(tracking.isNearBottom)
        for height in [CGFloat(400), 320, 450, 500] {
            XCTAssertNil(tracking.update(.init(bottom: 900, height: height), hasPositionedChat: true, isDragging: false))
            XCTAssertFalse(tracking.isNearBottom)
        }
    }

    func testEqualHeightWidthReductionRestoresTheBottomAfterMessageWrapping() throws {
        var tracking = KikiRoomChatTracking()
        XCTAssertNil(tracking.update(.init(bottom: 504, height: 500, width: 700),
                                     hasPositionedChat: true, isDragging: false))
        let request = try XCTUnwrap(tracking.update(.init(bottom: 680, height: 500, width: 400),
                                                    hasPositionedChat: true, isDragging: false))
        XCTAssertTrue(tracking.mayRestore(request, isDragging: false))
        XCTAssertNil(tracking.update(.init(bottom: 504, height: 500, width: 400),
                                     hasPositionedChat: true, isDragging: false))
        XCTAssertFalse(tracking.mayRestore(request, isDragging: false))
        XCTAssertTrue(tracking.isNearBottom)
    }

    func testDraggingCancelsAQueuedRestoreEvenAfterANewerResizeBegins() throws {
        var tracking = KikiRoomChatTracking()
        _ = tracking.update(.init(bottom: 504, height: 500), hasPositionedChat: true, isDragging: false)
        let cancelled = try XCTUnwrap(tracking.update(.init(bottom: 504, height: 300),
                                                      hasPositionedChat: true, isDragging: false))
        tracking.beganDragging()
        XCTAssertFalse(tracking.mayRestore(cancelled, isDragging: false), "A queued closure must stay cancelled after the drag ends")
        XCTAssertNil(tracking.update(.init(bottom: 700, height: 280), hasPositionedChat: true, isDragging: true))
        XCTAssertNil(tracking.update(.init(bottom: 700, height: 280), hasPositionedChat: true, isDragging: false))
        XCTAssertFalse(tracking.isNearBottom)
        _ = tracking.update(.init(bottom: 284, height: 280), hasPositionedChat: true, isDragging: false)
        let replacement = try XCTUnwrap(tracking.update(.init(bottom: 284, height: 200),
                                                        hasPositionedChat: true, isDragging: false))
        XCTAssertNotEqual(replacement, cancelled)
        XCTAssertFalse(tracking.mayRestore(cancelled, isDragging: false))
        XCTAssertFalse(tracking.mayRestore(replacement, isDragging: true))
        XCTAssertTrue(tracking.mayRestore(replacement, isDragging: false))
    }

    func testNewMessagesAtTheSameViewportSizeDoNotRequestAResizeRestore() {
        var tracking = KikiRoomChatTracking()
        _ = tracking.update(.init(bottom: 504, height: 500), hasPositionedChat: true, isDragging: false)
        XCTAssertNil(tracking.update(.init(bottom: 620, height: 500), hasPositionedChat: true, isDragging: false),
                     "Ordinary message following belongs to the timeline/local-send handler")
        XCTAssertFalse(tracking.isNearBottom)
        XCTAssertNil(tracking.update(.init(bottom: 680, height: 500), hasPositionedChat: true, isDragging: false))
    }

    func testAnnouncementPollingKeepsOneStableRowAndAnUpdateReplacesIt() {
        let original = KikiRoomAnnouncement(text: "欢迎来到房间", revision: 4, updatedAt: 110, updatedByUserID: "host")
        let first = timeline(announcement: original)
        for _ in 0..<10 {
            XCTAssertEqual(timeline(announcement: original), first,
                           "Polling the current announcement must not append another notice")
        }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].id, "announcement-4")
        let updated = KikiRoomAnnouncement(text: "今晚一起练习口语", revision: 5, updatedAt: 125, updatedByUserID: "host")
        let replacement = timeline(announcement: updated)
        XCTAssertEqual(replacement, [.announcement(updated)])
        XCTAssertFalse(replacement.contains { $0.id == first[0].id })
    }

    func testClearingOrMissingAnnouncementDoesNotInventDefaultChatContent() {
        XCTAssertTrue(timeline(announcement: .empty).isEmpty)
        XCTAssertTrue(timeline(announcement: .init(text: " \n\t ", revision: 8, updatedAt: 150,
                                                   updatedByUserID: "host")).isEmpty)
        let message = voice("real-message", createdAt: 100, sequence: 1)
        XCTAssertEqual(timeline(messages: [message], announcement: .empty), [.message(message)],
                       "The welcome placeholder must not become an invented announcement")
    }

    func testAnnouncementUpdatesTakeTheirServerTimestampPlaceAmongMessages() {
        let old = voice("old", createdAt: 100, sequence: 1)
        let newer = voice("newer", createdAt: 130, sequence: 2)
        let initial = KikiRoomAnnouncement(text: "旧公告", revision: 1, updatedAt: 110, updatedByUserID: "host")
        XCTAssertEqual(timeline(messages: [newer, old], announcement: initial).map(\.id),
                       ["old", "announcement-1", "newer"])
        let updated = KikiRoomAnnouncement(text: "已更新", revision: 2, updatedAt: 140, updatedByUserID: "host")
        XCTAssertEqual(timeline(messages: [newer, old], announcement: updated).map(\.id),
                       ["old", "newer", "announcement-2"])
    }

    func testBlockedPeopleDoNotLeakThroughEitherGiftSideOrMessageHistory() {
        let blockedMessage = voice("hidden-message", sender: "blocked", createdAt: 100, sequence: 1)
        let visible = voice("visible-message", sender: "friend", createdAt: 100, sequence: 2)
        let hiddenSender = gift("hidden-sender", sender: "blocked", recipient: "friend", createdAt: 101)
        let hiddenRecipient = gift("hidden-recipient", sender: "friend", recipient: "blocked", createdAt: 102)
        let publicGift = gift("visible-gift", sender: "friend", recipient: "host", createdAt: 103)
        let result = timeline(messages: [blockedMessage, visible], gifts: [hiddenSender, hiddenRecipient, publicGift],
                              blockedIDs: ["blocked"])
        XCTAssertEqual(result, [.message(visible), .gift(publicGift)])
    }

    func testBlockedAnnouncementAuthorIsFilteredConsistentlyWithRoomChat() {
        let notice = KikiRoomAnnouncement(text: "已屏蔽成员发布的公告", revision: 4, updatedAt: 110,
                                           updatedByUserID: "blocked")
        XCTAssertTrue(timeline(announcement: notice, blockedIDs: ["blocked"]).isEmpty)
        let unknownAuthor = KikiRoomAnnouncement(text: "服务器公告", revision: 5, updatedAt: 120, updatedByUserID: nil)
        XCTAssertEqual(timeline(announcement: unknownAuthor, blockedIDs: ["blocked"]), [.announcement(unknownAuthor)],
                       "A missing author is not proof that the notice belongs to a blocked person")
    }

    func testTimelineRemainsChronologicalAndDeterministicForEqualTimestamps() {
        let earlyGift = gift("early", createdAt: 99, sequence: 8)
        let laterGift = gift("gift-a", createdAt: 100, sequence: 1)
        let high = voice("msg-z", createdAt: 100, sequence: 9)
        let low = voice("msg-a", createdAt: 100, sequence: 2)
        let tie = voice("msg-b", createdAt: 100, sequence: 2)
        let announcement = KikiRoomAnnouncement(text: "公告", revision: 1, updatedAt: 100, updatedByUserID: "host")
        let entries = timeline(messages: [high, tie, low], gifts: [laterGift, earlyGift], announcement: announcement)
        XCTAssertEqual(entries.map(\.id), ["gift-early", "msg-a", "msg-b", "msg-z", "gift-gift-a", "announcement-1"])
        XCTAssertEqual(entries.map(\.createdAt), [99, 100, 100, 100, 100, 100])
        XCTAssertEqual(entries, timeline(messages: [low, high, tie], gifts: [earlyGift, laterGift], announcement: announcement),
                       "Unchanged server content must not jump when feed arrays arrive in another order")
    }

    func testChatBubbleWrapsLongMessagesAndAccessibilityTextWithinItsColumn() {
        let text = String(repeating: "今天有什么开心的事？一起慢慢聊聊生活里的小收获 😀 ", count: 8)
        for width in [CGFloat(280), 335, 520] {
            let standard = UIHostingController(rootView: bubble(text: text).dynamicTypeSize(.large).frame(width: width))
            let accessibility = UIHostingController(rootView: bubble(text: text).dynamicTypeSize(.accessibility3).frame(width: width))
            let normalSize = standard.sizeThatFits(in: CGSize(width: width, height: 10_000))
            let largeSize = accessibility.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertEqual(normalSize.width, width, accuracy: 1)
            XCTAssertEqual(largeSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(normalSize.height, 80)
            XCTAssertGreaterThan(largeSize.height, normalSize.height + 40,
                                 "A long message must wrap vertically instead of compressing or clipping text")
            XCTAssertLessThan(largeSize.height, 6_000)
        }
    }

    func testAudienceUsesOneFullWidthHorizontalRowWithNamesBelowAvatars() async throws {
        try await withWindow { window in
            let listeners = Self.listeners(count: 20) + [Self.member("offline", online: false), Self.member("speaker", seat: 2)]
            let host = UIHostingController(rootView: KikiRoomAudienceStrip(listeners: listeners, onOpenPerson: { _ in }) { member in
                KikiAvatar(index: member.avatarIndex, size: 36)
            }.padding(16).background(KikiPalette.background).ignoresSafeArea())
            await mount(host, in: window, size: CGSize(width: 375, height: 100))
            let horizontal = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UIScrollView }.first {
                $0.contentSize.width > $0.bounds.width + 1
            })
            XCTAssertGreaterThan(horizontal.bounds.width, 320,
                                 "The entire listener width belongs to the horizontal avatar-and-name row")
            XCTAssertLessThanOrEqual(horizontal.contentSize.height, horizontal.bounds.height + 1,
                                     "Listeners stay in one horizontal row")
            let viewport = horizontal.convert(horizontal.bounds, to: window)
            XCTAssertGreaterThanOrEqual(viewport.minX, 0)
            XCTAssertGreaterThan(viewport.width, 100)
            XCTAssertLessThanOrEqual(viewport.maxX, window.bounds.width,
                                     "There is no separate count control to reserve space for")
            XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(viewport))
            // The runtime does not consistently expose SwiftUI virtual accessibility nodes in process.
            // This test checks the real UIKit viewport; visible names and filtered identities are reviewed in screenshots.
            try capture(window: window, name: "audience-20-online-with-offline-and-speaker-excluded")
        }
    }

    func testProductionChatComponentsPhoneIPadLargeTextAndEmptyAudienceScreenshots() async throws {
        try await withWindow { window in
            let cases: [(String, CGSize, DynamicTypeSize, ColorScheme, Int)] = [
                ("phone", CGSize(width: 375, height: 812), .large, .light, 12),
                ("phone-dark", CGSize(width: 375, height: 812), .large, .dark, 12),
                ("ipad-landscape", CGSize(width: 1133, height: 744), .large, .light, 20),
                ("large-text", CGSize(width: 375, height: 1000), .accessibility3, .dark, 12),
                ("empty-audience", CGSize(width: 375, height: 812), .large, .dark, 0)
            ]
            for (name, size, typeSize, scheme, count) in cases {
                let fixtureMembers = Self.listeners(count: count)
                    + [Self.member("offline", online: false), Self.member("speaker", seat: 2)]
                let host = UIHostingController(rootView: KikiRoomChatScreenshotFixture(listeners: fixtureMembers)
                    .dynamicTypeSize(typeSize).preferredColorScheme(scheme))
                await mount(host, in: window, size: size)
                XCTAssertEqual(host.view.bounds.size, size)
                let viewports = descendants(of: host.view).compactMap { $0 as? UIScrollView }
                XCTAssertGreaterThanOrEqual(viewports.count, count > 0 ? 2 : 1, "The listener strip and message list use real scroll viewports")
                for scroll in viewports {
                    if count == 0 && scroll.bounds.height == 0 { continue }
                    let viewport = scroll.convert(scroll.bounds, to: window)
                    XCTAssertGreaterThan(viewport.width, 0)
                    XCTAssertGreaterThan(viewport.height, 0)
                    XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(viewport),
                                  "Chat and listener viewports must fit the rendered phone or iPad window")
                }
                try capture(window: window, name: name)
            }
        }
    }

    private func timeline(messages: [KikiVoiceMessage] = [], gifts: [KikiGiftEvent] = [],
                          announcement: KikiRoomAnnouncement = .empty, blockedIDs: Set<String> = []) -> [KikiRoomChatEntry] {
        KikiRoomChatEntry.timeline(messages: messages, gifts: gifts, announcement: announcement, blockedIDs: blockedIDs)
    }

    private func voice(_ id: String, sender: String = "friend", createdAt: Int, sequence: Int) -> KikiVoiceMessage {
        .init(id: id, senderID: sender, senderName: "朋友", text: "你好", isLocal: false,
              createdAt: createdAt, sequence: sequence, senderAvatarIndex: 3)
    }

    private func gift(_ id: String, sender: String = "friend", recipient: String = "host",
                      createdAt: Int, sequence: Int = 1) -> KikiGiftEvent {
        .init(id: id, roomID: "fixture-room", batchID: "batch-" + id, senderUserID: sender, senderName: "朋友",
              recipientUserID: recipient, recipientName: "房主", giftID: "flower", giftName: "鲜花", seq: sequence,
              quantity: 1, unitPrice: 30, batchRecipientCount: 1, createdAt: createdAt)
    }

    private func bubble(text: String) -> some View {
        KikiRoomChatBubbleRow(id: "long", senderName: "一个很长的昵称也需要换行的朋友", text: text,
                              isLocal: false, onOpenSender: {}) {
            KikiAvatar(index: 3, size: 32)
        } bubbleBackground: {
            RoundedRectangle(cornerRadius: 15).fill(KikiPalette.surface)
        }
    }

    fileprivate static func member(_ id: String, index: Int = 0, online: Bool = true, seat: Int? = nil) -> KikiRoomMember {
        .init(userID: id, name: "听众 \(index + 1)", avatarIndex: index, avatarURL: nil, role: .member, seatIndex: seat,
              audioMuted: false, chatMuted: false, online: online, canPublishAudio: seat != nil, canPublishData: true)
    }

    fileprivate static func listeners(count: Int) -> [KikiRoomMember] {
        (0..<count).map { member("listener-\($0)", index: $0) }
    }

    private func withWindow(_ operation: (UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await operation(window)
    }

    private func mount<Content: View>(_ host: UIHostingController<Content>, in window: UIWindow, size: CGSize) async {
        window.rootViewController = host
        window.frame = CGRect(origin: window.frame.origin, size: size)
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        try? await Task.sleep(nanoseconds: 250_000_000)
        window.layoutIfNeeded()
    }

    private func capture(window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let prefix = device + "-room-chat-" + name
        let attachment = XCTAttachment(image: image)
        attachment.name = prefix; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/kiki-room-chat-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(prefix + ".png"), options: .atomic)
    }

    private func descendants(of view: UIView) -> [UIView] { [view] + view.subviews.flatMap { descendants(of: $0) } }

}

private struct KikiRoomChatScreenshotFixture: View {
    let listeners: [KikiRoomMember]
    private let longText = "今天过得怎么样？我想分享一下今天的小收获：终于学会了用中文点咖啡，也交到了新朋友 😀☕️ 我们可以一起练习，让每天进步一点点。"

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("一起练习，慢慢聊").font(.headline).foregroundStyle(KikiPalette.text)
                Spacer()
                Image(systemName: "ellipsis").foregroundStyle(KikiPalette.purple).frame(width: 44, height: 44)
                    .background(KikiPalette.surface, in: Circle())
            }
            KikiRoomAudienceStrip(listeners: listeners, onOpenPerson: { _ in }) { member in
                KikiAvatar(index: member.avatarIndex, size: 36)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    KikiRoomChatBubbleRow(id: "friend", senderName: "南风", text: "大家好，今天在聊什么？", isLocal: false,
                                          onOpenSender: {}) {
                        KikiAvatar(index: 5, size: 32)
                    } bubbleBackground: { RoundedRectangle(cornerRadius: 15).fill(KikiPalette.surface) }
                    KikiRoomChatBubbleRow(id: "me", senderName: "我", text: "你好 👋 很高兴认识你！", isLocal: true,
                                          onOpenSender: {}) {
                        KikiAvatar(index: 2, size: 32)
                    } bubbleBackground: { RoundedRectangle(cornerRadius: 15).fill(KikiPalette.surface) }
                    KikiRoomAnnouncementChatRow(text: "欢迎来到 KikiTalk。请友好交流，尊重每位朋友，让我们一起享受聊天的时光。", onOpen: {})
                    KikiRoomChatBubbleRow(id: "gift", senderName: "小岛", text: "送给南风 鲜花 ×1", isLocal: false,
                                          isGift: true, onOpenSender: {}) {
                        KikiAvatar(index: 4, size: 32)
                    } bubbleBackground: { RoundedRectangle(cornerRadius: 15).fill(KikiPalette.purple.opacity(0.12)) }
                    KikiRoomChatBubbleRow(id: "long", senderName: "昵称比较长的一位朋友", text: longText, isLocal: false,
                                          onOpenSender: {}) {
                        KikiAvatar(index: 8, size: 32)
                    } bubbleBackground: { RoundedRectangle(cornerRadius: 15).fill(KikiPalette.surface) }
                }
            }
            HStack {
                Text("说点什么…").foregroundStyle(KikiPalette.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(KikiPalette.surface, in: Capsule())
                Image(systemName: "mic.fill").foregroundStyle(KikiPalette.purple).frame(width: 44, height: 44)
                    .background(KikiPalette.surface, in: Circle())
                Image(systemName: "gift.fill").foregroundStyle(KikiPalette.purple).frame(width: 44, height: 44)
                    .background(KikiPalette.surface, in: Circle())
            }
        }
        .padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KikiRoomDecorationBackground(decorationID: "background_aurora"))
    }
}
