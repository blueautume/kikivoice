import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiInboxConversationRowTests: XCTestCase {
    /// Renders the production row in a genuine system List. The optional
    /// observation mode accepts actual Simulator gestures; it never fabricates
    /// touches, searches private UIKit views or invokes the row callbacks itself.
    func testInboxConversationRowFixtureScreenshotsAndOptionalNativeSwipeObservation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer {
            window.frame = originalFrame
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let folder = URL(fileURLWithPath: "/tmp/kiki-inbox-row-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let cases: [(String, CGSize, ColorScheme, DynamicTypeSize)] = [
            ("phone", CGSize(width: 375, height: 812), .light, .large),
            ("ipad-portrait", CGSize(width: 744, height: 1133), .light, .large),
            ("ipad-landscape-dark", CGSize(width: 1133, height: 744), .dark, .large),
            ("phone-large-text", CGSize(width: 375, height: 812), .light, .accessibility1)
        ]
        for (label, size, scheme, typeSize) in cases {
            let fixture = try KikiInboxRowFixtureState()
            let view = KikiInboxRowFixtureList(fixture: fixture)
                .preferredColorScheme(scheme).dynamicTypeSize(typeSize)
            window.rootViewController = UIHostingController(rootView: view)
            window.frame = CGRect(origin: originalFrame.origin, size: size)
            window.rootViewController?.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 450_000_000)
            window.layoutIfNeeded()
            XCTAssertEqual(window.bounds.size, size)
            XCTAssertEqual(window.rootViewController?.view.bounds.size, size)
            capture(window: window, name: device + "-inbox-" + label, folder: folder)
            XCTAssertEqual(fixture.pinCalls, 0)
            XCTAssertEqual(fixture.deleteCalls, 0)
            XCTAssertEqual(fixture.openCalls, 0)
            XCTAssertEqual(fixture.entries.first?.unreadLabel, "99+")
            XCTAssertTrue(fixture.entries.contains { $0.isPinned })
            XCTAssertTrue(fixture.entries.contains { $0.id == "notification:fixture-notice" })
            XCTAssertTrue(fixture.entries.contains { $0.id == "notification:fixture-mutual-follow" && !$0.isPinned })
        }

        guard ProcessInfo.processInfo.environment["KIKI_INBOX_SWIPE_OBSERVATION"] == "1" else { return }
        let fixture = try KikiInboxRowFixtureState()
        let view = KikiInboxRowFixtureList(fixture: fixture).preferredColorScheme(.light)
        window.rootViewController = UIHostingController(rootView: view)
        window.frame = originalFrame
        window.rootViewController?.view.frame = window.bounds
        window.makeKeyAndVisible()
        try await Task.sleep(nanoseconds: 500_000_000)
        window.layoutIfNeeded()
        capture(window: window, name: device + "-inbox-observation-ready", folder: folder)
        print("InboxSwipeFixture ready device=\(device) target=滑动验证 width=\(Int(window.bounds.width)) height=\(Int(window.bounds.height)); swipe first row, tap 置顶, swipe again, tap 删除; local callbacks only")
        let deadline = Date().addingTimeInterval(60)
        var capturedPinnedState = false
        while (fixture.pinCalls == 0 || fixture.deleteCalls == 0), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            if fixture.pinCalls > 0, !capturedPinnedState {
                capturedPinnedState = true
                capture(window: window, name: device + "-inbox-observation-pinned", folder: folder)
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        capture(window: window, name: device + "-inbox-observation-result", folder: folder)
        XCTAssertEqual(fixture.pinCalls, 1, "A real native left-swipe pin button must invoke the production row's callback exactly once")
        XCTAssertEqual(fixture.deleteCalls, 1, "A real native left-swipe delete button must invoke the production row's callback exactly once")
        XCTAssertEqual(fixture.events, ["pin", "delete"], "The fixture requires pin first and delete second")
        XCTAssertFalse(fixture.entries.contains { $0.id == fixture.targetID })
        XCTAssertEqual(fixture.openCalls, 0, "Swipe action taps must not open the conversation")
        print("InboxSwipeFixture completed pin=\(fixture.pinCalls) delete=\(fixture.deleteCalls) open=\(fixture.openCalls) events=\(fixture.events.joined(separator: ","))")
    }

    private func capture(window: UIWindow, name: String, folder: URL) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        do { try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png")) }
        catch { XCTFail("Could not save \(name): \(error)") }
    }
}

@MainActor
private final class KikiInboxRowFixtureState: ObservableObject {
    @Published var entries: [KikiInboxEntry]
    @Published private(set) var pinCalls = 0
    @Published private(set) var deleteCalls = 0
    @Published private(set) var openCalls = 0
    private(set) var events: [String] = []
    let targetID = "direct:swipe-fixture"

    init() throws {
        let now = Date().timeIntervalSince1970
        let target = try Self.conversation(id: "swipe-fixture", name: "滑动验证", avatar: 4, unread: 155, time: now - 60)
        let pinned = try Self.conversation(id: "pinned-fixture", name: "置顶的聊天", avatar: 2, unread: 0, time: now - 300)
        let long = try Self.conversation(id: "long-fixture", name: "这是一个很长很长的会话名字用来检查截断", avatar: 6, unread: 8, time: now - 600)
        entries = [
            KikiInboxEntry(content: .direct(target), activityAt: now - 60,
                           preview: "左滑后可置顶或删除此会话", unreadCount: 155, isPinned: false),
            KikiInboxEntry(content: .direct(pinned), activityAt: now - 300,
                           preview: "已置顶的会话保留时间与未读布局", unreadCount: 0, isPinned: true),
            KikiInboxEntry(notification: KikiSocialNotification(id: "fixture-notice", kind: "follow", actor: target.person,
                text: "关注了你", createdAt: now - 450, readAt: nil, roomID: nil)),
            KikiInboxEntry(notification: KikiSocialNotification(id: "fixture-mutual-follow", kind: "mutual_follow", actor: target.person,
                text: "你们互相关注了，现在可以开始聊天", createdAt: now - 500, readAt: nil, roomID: nil)),
            KikiInboxEntry(content: .direct(long), activityAt: now - 600,
                           preview: "长名称与消息预览仍然保持单行，避免挤压未读标记", unreadCount: 8, isPinned: false)
        ]
    }

    func open(_ entry: KikiInboxEntry) {
        openCalls += 1
        print("InboxSwipeFixture open id=\(entry.id)")
    }

    func togglePin(_ entry: KikiInboxEntry) {
        pinCalls += 1; events.append("pin")
        entries = entries.map { value in
            guard value.id == entry.id else { return value }
            return KikiInboxEntry(content: value.content, activityAt: value.activityAt,
                                  preview: value.preview, unreadCount: value.unreadCount, isPinned: !value.isPinned)
        }
        print("InboxSwipeFixture pin count=\(pinCalls) id=\(entry.id) pinned=\(!entry.isPinned)")
    }

    func delete(_ entry: KikiInboxEntry) {
        deleteCalls += 1; events.append("delete")
        entries.removeAll { $0.id == entry.id }
        print("InboxSwipeFixture delete count=\(deleteCalls) id=\(entry.id)")
    }

    private static func conversation(id: String, name: String, avatar: Int, unread: Int, time: Double) throws -> KikiConversation {
        let value: [String: Any] = [
            "id": id,
            "person": ["id": "person-" + id, "name": name, "bio": "", "avatarIndex": avatar,
                       "following": true, "followsYou": true, "mutual": true, "followingCount": 1, "followerCount": 1],
            "lastMessage": ["id": "message-" + id, "seq": 1, "senderID": "person-" + id,
                            "text": "本地截图数据", "createdAt": time],
            "unreadCount": unread, "canSend": true
        ]
        return try JSONDecoder().decode(KikiConversation.self, from: JSONSerialization.data(withJSONObject: value))
    }
}

private struct KikiInboxRowFixtureList: View {
    @ObservedObject var fixture: KikiInboxRowFixtureState

    private func isDirect(_ entry: KikiInboxEntry) -> Bool { if case .direct = entry.content { return true }; return false }

    var body: some View {
        NavigationStack {
            List {
                ForEach(fixture.entries) { entry in
                    KikiInboxConversationRow(entry: entry, isWorking: false, canDelete: true, canPin: isDirect(entry),
                        onOpen: { fixture.open(entry) }, onTogglePin: { fixture.togglePin(entry) }, onDelete: { fixture.delete(entry) })
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(entry.isPinned ? KikiPalette.purple.opacity(0.06) : KikiPalette.surface)
                        .listRowSeparatorTint(KikiPalette.elevated)
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden)
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("全部已读", systemImage: "checkmark.bubble") { }
                        Button("全部删除", systemImage: "trash", role: .destructive) { }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .accessibilityLabel("消息操作")
                }
            }
        }
        .tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
}
