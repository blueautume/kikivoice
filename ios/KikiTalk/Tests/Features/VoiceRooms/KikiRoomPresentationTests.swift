import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiRoomPresentationTests: XCTestCase {
    func testRoomHeaderUsesRemainingWidthWithoutCompressingAvatarOrFourControls() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let longTitle = "忙碌了一天，在这里慢慢聊聊生活里那些微小又值得开心的事"
        let cases: [(name: String, size: CGSize, scheme: ColorScheme, textSize: DynamicTypeSize,
                     owner: Bool, enabled: Bool, title: String)] = [
            ("320-light", CGSize(width: 320, height: 812), .light, .large, true, true, longTitle),
            ("375-dark", CGSize(width: 375, height: 812), .dark, .large, true, true, longTitle),
            ("402-member-light", CGSize(width: 402, height: 874), .light, .large, false, true, longTitle),
            ("ipad-744-dark", CGSize(width: 744, height: 1133), .dark, .large, true, true, longTitle),
            ("ipad-1133-light", CGSize(width: 1133, height: 744), .light, .large, true, true, longTitle),
            ("320-accessibility-dark", CGSize(width: 320, height: 812), .dark, .accessibility3, true, true, longTitle),
            ("375-member-accessibility-light", CGSize(width: 375, height: 812), .light, .accessibility3, false, true, longTitle),
            ("402-accessibility-dark", CGSize(width: 402, height: 874), .dark, .accessibility3, true, true, longTitle),
            ("ipad-744-accessibility-light", CGSize(width: 744, height: 1133), .light, .accessibility3, true, true, longTitle),
            ("402-disabled-dark", CGSize(width: 402, height: 874), .dark, .large, true, false, "晚风")
        ]
        var standardHeights: [CGFloat: CGFloat] = [:]
        for item in cases {
            let fixture = KikiRoomHeaderFixtureState()
            let onEdit: (() -> Void)? = item.owner ? { fixture.editCalls += 1 } : nil
            let header = KikiRoomHeader(title: item.title, host: "一个昵称很长也需要清楚区分的房主",
                                       onEditTitle: onEdit, isTitleEditingEnabled: item.enabled) {
                Button {} label: { KikiAvatar(index: 4, size: 36) }
                    .buttonStyle(.plain)
                    .background(KikiRoomHeaderFixtureProbe(key: "avatar", state: fixture))
            } controls: {
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { index in
                        Button { fixture.controlCalls += 1 } label: {
                            Image(systemName: ["ellipsis", "person.2", "arrow.down.right.and.arrow.up.left", "xmark"][index])
                                .font(.system(size: 15)).frame(width: 36, height: 36)
                                .background(KikiPalette.elevated, in: Circle())
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("roomHeader.fixture.control.\(index)")
                        .background(KikiRoomHeaderFixtureProbe(key: "control.\(index)", state: fixture))
                    }
                }.background(KikiRoomHeaderFixtureProbe(key: "controls", state: fixture))
            }
            .background(KikiRoomHeaderFixtureProbe(key: "header", state: fixture))
            let host = UIHostingController(rootView: header
                .padding(.horizontal, 18).padding(.top, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(KikiPalette.background.ignoresSafeArea())
                .preferredColorScheme(item.scheme).dynamicTypeSize(item.textSize))
            // This is a synthetic viewport fixture; real keyboard avoidance is
            // exercised separately by KikiRoomMessageInputTests on native scenes.
            host.safeAreaRegions = .container
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: item.size)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded()
            func frame(_ key: String) throws -> CGRect {
                let probe = try XCTUnwrap(fixture.probes[key], "Missing \(key) in \(item.name)")
                XCTAssertTrue(probe.window === window)
                return probe.convert(probe.bounds, to: window)
            }
            let row = try frame("header"), avatar = try frame("avatar"), controls = try frame("controls")
            XCTAssertEqual(row.width, item.size.width - 36, accuracy: 1, item.name)
            XCTAssertEqual(avatar.width, 36, accuracy: 0.5, item.name)
            XCTAssertEqual(avatar.height, 36, accuracy: 0.5, item.name)
            XCTAssertEqual(avatar.minX, row.minX, accuracy: 0.5, item.name)
            XCTAssertEqual(avatar.midY, row.midY, accuracy: 0.5, item.name)
            XCTAssertEqual(controls.width, 188, accuracy: 0.5, item.name)
            XCTAssertEqual(controls.maxX, row.maxX, accuracy: 0.5, item.name)
            XCTAssertGreaterThanOrEqual(row.height, 44, item.name)
            XCTAssertTrue(host.view.bounds.contains(row), item.name)
            var previousControl: CGRect?
            for index in 0..<4 {
                let control = try frame("control.\(index)")
                XCTAssertEqual(control.width, 44, accuracy: 0.5, item.name)
                XCTAssertEqual(control.height, 44, accuracy: 0.5, item.name)
                XCTAssertEqual(control.midY, row.midY, accuracy: 0.5, item.name)
                if let previousControl { XCTAssertEqual(control.minX - previousControl.maxX, 4, accuracy: 0.5, item.name) }
                previousControl = control
            }
            if item.textSize == .large, item.title == longTitle { standardHeights[item.size.width] = row.height }
            if item.textSize.isAccessibilitySize, let standard = standardHeights[item.size.width] {
                XCTAssertGreaterThan(row.height, standard + 20, "Large text must gain height instead of shrinking the fixed controls: \(item.name)")
            }
            XCTAssertEqual(fixture.editCalls, 0)
            XCTAssertEqual(fixture.controlCalls, 0)

            // Public accessibility containers expose the real identity region
            // on supporting runtimes. Native probes above remain unconditional.
            let nodes = headerAccessibilityNodes(in: host.view)
            let edit = nodes.first {
                ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == "livekit.room.editTitle"
            }
            if !item.owner {
                XCTAssertNil(edit, "A member's room identity must not become an edit button")
                if let title = nodes.first(where: { $0.accessibilityLabel == item.title }),
                   let owner = nodes.first(where: { $0.accessibilityLabel == "房主 一个昵称很长也需要清楚区分的房主" }) {
                    XCTAssertLessThanOrEqual(title.accessibilityFrame.maxY, owner.accessibilityFrame.minY + 1,
                                             "The title must stay above the host nickname")
                }
            } else if let edit {
                let identity = window.convert(edit.accessibilityFrame, from: window.screen.coordinateSpace)
                XCTAssertEqual(identity.minX, avatar.maxX + 8, accuracy: 1, item.name)
                XCTAssertEqual(identity.maxX, controls.minX - 8, accuracy: 1,
                               "The actual identity button must use the entire gap: \(item.name)")
                XCTAssertGreaterThanOrEqual(identity.height, 44, item.name)
                XCTAssertEqual(edit.accessibilityValue, item.title, "The complete title must remain readable by VoiceOver")
                XCTAssertEqual(edit.accessibilityTraits.contains(.notEnabled), !item.enabled)
                let activated = edit.accessibilityActivate()
                if !item.enabled { XCTAssertEqual(fixture.editCalls, 0) }
                else if activated { XCTAssertEqual(fixture.editCalls, 1) }
            }
            try capture(name: "room-header-" + item.name, windows: [window], bounds: window.bounds)
        }
    }

    func testCreateRoomIconKeepsACompactNativeTouchTargetAtAnyTextSize() {
        for textSize in [DynamicTypeSize.large, .accessibility3] {
            let host = UIHostingController(rootView: KikiCreateRoomButton(isVisible: false, action: {})
                .dynamicTypeSize(textSize))
            let size = host.sizeThatFits(in: CGSize(width: 375, height: 812))
            XCTAssertGreaterThanOrEqual(size.height, 44)
            XCTAssertEqual(size.height, KikiCreateRoomButton.touchHeight, accuracy: 0.01)
            XCTAssertEqual(size.width, KikiCreateRoomButton.capsuleHeight * 1.6, accuracy: 0.5,
                           "Hosting may round the capsule to a logical pixel")
            XCTAssertLessThan(KikiCreateRoomButton.capsuleHeight, size.height,
                              "A smaller capsule keeps the toolbar light without shrinking its native touch target")
            XCTAssertLessThan(size.width, 90, "The microphone action must leave space for the title and other toolbar controls")
        }
    }

    func testCreateRoomFormPrefillsDefaultNameWithoutOpeningNetworkOrRTC() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let store = presentationStore()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for (name, size, textSize) in [
            ("phone", CGSize(width: 375, height: 812), DynamicTypeSize.large),
            ("ipad", CGSize(width: 1133, height: 744), .large)
        ] {
            let host = UIHostingController(rootView: KikiCreateRoomView(isLive: false) { _ in
                XCTFail("Rendering the creation form must never create a room")
            }.environmentObject(store).dynamicTypeSize(textSize))
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 200_000_000)
            window.layoutIfNeeded()
            let field = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UITextField }.first)
            XCTAssertEqual(field.text, store.defaultRoomTitle)
            XCTAssertFalse(field.isFirstResponder)
            XCTAssertTrue(host.view.bounds.contains(field.convert(field.bounds, to: host.view)),
                          "The room name remains inside the compact form on phone and iPad")
            try capture(name: "create-room-" + name, windows: [window], bounds: window.bounds)
        }
    }

    func testDiscoverSearchKeepsTabsOutOfKeyboardAndDismissesWithoutLosingQuery() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let model = KikiSearchPresentationModel()
        let store = presentationStore()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: KikiDiscoverSearchFixture(model: model).environmentObject(store))
        // Native scene geometry is required for keyboard avoidance; never disable
        // the keyboard safe-area region to make this assertion pass.
        host.safeAreaRegions = .all
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        let field = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? UITextField }.first)
        let initialBar = try XCTUnwrap(model.barProbe)
        let initialBarFrame = initialBar.convert(initialBar.bounds, to: window)
        XCTAssertEqual(initialBar.window, window)
        XCTAssertGreaterThan(initialBarFrame.width, 100)
        XCTAssertGreaterThanOrEqual(initialBarFrame.height, 44)

        XCTAssertTrue(field.becomeFirstResponder())
        try await waitForSearch { field.isFirstResponder && model.searchFocused && model.barProbe?.window == nil }
        field.text = "音乐和晚风"
        field.sendActions(for: .editingChanged)
        try await Task.sleep(nanoseconds: 150_000_000)
        window.layoutIfNeeded()
        let fieldFrame = field.convert(field.bounds, to: host.view)
        XCTAssertTrue(host.view.bounds.contains(fieldFrame), "Search must retain normal keyboard-safe layout")
        XCTAssertNil(model.barProbe?.window, "The main tabs must not float above a focused search keyboard")
        let inputIdentity = ObjectIdentifier(field)
        let probe = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomKeyboardDismissal.Probe }.first)
        let dismissal = try XCTUnwrap(probe.coordinator)
        XCTAssertFalse(dismissal.acceptsTap(from: field), "Tapping within native search must keep editing")
        XCTAssertTrue(dismissal.acceptsTap(from: host.view), "Non-input blank space must end search editing")
        XCTAssertFalse(try XCTUnwrap(dismissal.recognizer).cancelsTouchesInView,
                       "The observer must preserve room/create/filter button delivery")
        let scrollViews = descendants(of: host.view).compactMap { $0 as? UIScrollView }
        let roomList = try XCTUnwrap(scrollViews.max { $0.bounds.height < $1.bounds.height })
        XCTAssertTrue(dismissal.acceptsTap(from: roomList),
                      "The real room-list blank area must reach the window dismissal observer")
        // SwiftUI may include the keyboard accessory in its native interactive
        // mode; both public UIKit modes track the drag rather than dismissing abruptly.
        XCTAssertTrue(scrollViews.contains {
            $0.keyboardDismissMode == .interactive || $0.keyboardDismissMode == .interactiveWithAccessory
        }, "Room-list scrolling must support interactive dismissal; native modes: \(scrollViews.map { $0.keyboardDismissMode.rawValue })")
        if ProcessInfo.processInfo.environment["KIKI_DISCOVER_SEARCH_SOFTWARE_KEYBOARD"] == "1" {
            let deadline = Date().addingTimeInterval(45)
            while host.view.keyboardLayoutGuide.layoutFrame.height <= 100, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
                window.layoutIfNeeded()
            }
            let keyboard = host.view.keyboardLayoutGuide.layoutFrame
            XCTAssertGreaterThan(keyboard.height, 100, "The opt-in requires a visible native software keyboard")
            XCTAssertLessThanOrEqual(field.convert(field.bounds, to: host.view).maxY, keyboard.minY + 1)
            XCTAssertNil(model.barProbe?.window)
        }
        try capture(name: "discover-search-focused", windows: [window], bounds: window.bounds)
        if ProcessInfo.processInfo.environment["KIKI_DISCOVER_SEARCH_SOFTWARE_KEYBOARD"] == "1" {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        // Deliver the same public callback used by the accepted window tap,
        // without creating synthetic touches or depending on SwiftUI AX nodes.
        dismissal.dismissAfterRecognizedTap()
        try await waitForSearch { !field.isFirstResponder && !model.searchFocused && model.barProbe?.window === window }
        XCTAssertEqual(field.text, "音乐和晚风")
        let restoredBar = try XCTUnwrap(model.barProbe)
        let restoredFrame = restoredBar.convert(restoredBar.bounds, to: window)
        XCTAssertEqual(restoredFrame.minX, initialBarFrame.minX, accuracy: 1)
        XCTAssertEqual(restoredFrame.maxY, initialBarFrame.maxY, accuracy: 1,
                       "Tabs return to the bottom after the keyboard has closed")
        XCTAssertEqual(restoredFrame.width, initialBarFrame.width, accuracy: 1)
        try capture(name: "discover-search-dismissed", windows: [window], bounds: window.bounds)

        XCTAssertTrue(field.becomeFirstResponder())
        try await waitForSearch { model.searchFocused && field.isFirstResponder }
        model.selectedTab = 1
        try await waitForSearch { !field.isFirstResponder && !model.searchFocused }
        model.selectedTab = 0
        try await waitForSearch { model.barProbe?.window === window }
        XCTAssertEqual(field.text, "音乐和晚风")
        XCTAssertEqual(ObjectIdentifier(field), inputIdentity, "Switching tabs must preserve the actual search field and query")
    }

    private func waitForSearch(file: StaticString = #filePath, line: UInt = #line,
                               _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
        XCTAssertTrue(predicate(), "Native search focus or tab layout did not settle", file: file, line: line)
    }

    func testOfflineSeatKeepsTheSameGridHeightAndDoesNotNeedAStatusCaption() {
        let gifts = KikiGiftStore()
        defer { gifts.reset() }
        let slot = KikiRoomSeat(index: 2, userID: "member", locked: false, audioLocked: false)
        let participant = KikiVoiceParticipant(id: "member", name: "海边的朋友", isLocal: false,
                                               isHost: false, isSpeaking: false, microphoneEnabled: false)
        for width in [CGFloat(72), 100, 150] {
            for textSize in [DynamicTypeSize.large, .accessibility3] {
                func measuredSeat(online: Bool) -> CGSize {
                    let member = KikiRoomMember(userID: "member", name: participant.name, avatarIndex: 4,
                                               avatarURL: nil, role: .member, seatIndex: 2,
                                               audioMuted: false, chatMuted: false, online: online,
                                               canPublishAudio: online, canPublishData: online)
                    let host = UIHostingController(rootView: KikiRoomSeatTile(slot: slot, member: member,
                        participant: participant, localUserID: "owner", avatarSize: 56, gifts: gifts)
                        .dynamicTypeSize(textSize).frame(width: width))
                    return host.sizeThatFits(in: CGSize(width: width, height: 1_000))
                }
                let online = measuredSeat(online: true)
                let offline = measuredSeat(online: false)
                XCTAssertEqual(online.width, offline.width, accuracy: 0.5)
                XCTAssertEqual(online.height, offline.height, accuracy: 0.5,
                               "An offline member must not move the next microphone row or the chat list")
            }
        }
    }

    func testLegacyRoomStillDecodesWithoutInventingMemberPreviews() throws {
        let legacy = Data(#"{"id":"voice_legacy","title":"旧版房间","host":"小岛","hostID":"host","category":"随心聊","audience":8,"isLive":false,"theme":0,"isCreatedByMe":false,"status":"live"}"#.utf8)
        let room = try JSONDecoder().decode(KikiRoom.self, from: legacy)
        XCTAssertTrue(room.memberPreview.isEmpty, "Only server-provided identities may appear in the overlapping avatar strip")
        XCTAssertEqual(room.audience, 8, "A missing preview must not replace the real participant count")
        let current = presentationRooms[0]
        let restored = try JSONDecoder().decode(KikiRoom.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.memberPreview, current.memberPreview)
        XCTAssertEqual(restored.memberPreview.map(\.userID), ["friend_a", "friend_b", "friend_c"])
    }

    func testRoomCardsGrowForAccessibilityTextWithinNarrowAndIPadColumns() throws {
        let store = presentationStore()
        let room = presentationRooms[1]
        for width in [CGFloat(335), 344, 520] {
            let standard = UIHostingController(rootView: KikiRoomCard(room: room)
                .environmentObject(store).dynamicTypeSize(.large).frame(width: width))
            let large = UIHostingController(rootView: KikiRoomCard(room: room)
                .environmentObject(store).dynamicTypeSize(.accessibility3).frame(width: width))
            let normalSize = standard.sizeThatFits(in: CGSize(width: width, height: 10_000))
            let accessibilitySize = large.sizeThatFits(in: CGSize(width: width, height: 10_000))
            XCTAssertEqual(normalSize.width, width, accuracy: 1)
            XCTAssertEqual(accessibilitySize.width, width, accuracy: 1)
            XCTAssertGreaterThan(normalSize.height, 120)
            XCTAssertGreaterThan(accessibilitySize.height, normalSize.height + 50,
                                 "Long titles and host names must get more height instead of a fixed card clipping them")
            XCTAssertLessThan(accessibilitySize.height, 1_500)
        }
        XCTAssertEqual(KikiRoomListLayout.columnCount(availableWidth: 375, accessibilitySize: false), 1)
        XCTAssertEqual(KikiRoomListLayout.columnCount(availableWidth: 744, accessibilitySize: false), 2)
        XCTAssertEqual(KikiRoomListLayout.columnCount(availableWidth: 1133, accessibilitySize: false), 2)
        XCTAssertEqual(KikiRoomListLayout.columnCount(availableWidth: 1133, accessibilitySize: true), 1)
    }

    func testRoomCardPhoneIPadAndLargeTextFixtureScreenshots() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let store = presentationStore()
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let cases: [(String, CGSize, DynamicTypeSize, ColorScheme)] = [
            ("phone", CGSize(width: 375, height: 812), .large, .light),
            ("ipad-portrait", CGSize(width: 744, height: 1133), .large, .light),
            ("ipad-landscape", CGSize(width: 1133, height: 744), .large, .light),
            ("large-text", CGSize(width: 375, height: 1000), .accessibility3, .light),
            ("dark", CGSize(width: 1133, height: 744), .large, .dark)
        ]
        for (name, size, typeSize, scheme) in cases {
            let host = UIHostingController(rootView: KikiRoomCardsFixture(rooms: presentationRooms)
                .environmentObject(store).dynamicTypeSize(typeSize).preferredColorScheme(scheme))
            window.rootViewController = host
            window.makeKeyAndVisible()
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 180_000_000)
            window.layoutIfNeeded()
            XCTAssertEqual(host.view.bounds.size, size)
            try capture(name: "room-cards-" + name, windows: [window], bounds: window.bounds)
        }
    }

    func testHostAvatarFloatingWindowKeepsFocusPassesTouchesAndAnnouncesAnySpeaker() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let base = UIWindow(windowScene: scene)
        base.rootViewController = UIHostingController(rootView: KikiRoomCardsFixture(rooms: presentationRooms)
            .environmentObject(presentationStore()).preferredColorScheme(.light))
        base.makeKeyAndVisible()
        var resumeCount = 0
        let overlay = KikiVoiceRoomFloatingOverlay(windowScene: scene, roomTitle: "周末一起聊聊", avatarURL: nil,
                                                   avatarIndex: 4, hostName: "小岛") { resumeCount += 1 }
        defer { overlay.hide(); base.isHidden = true; previous?.makeKeyAndVisible() }
        overlay.show()
        try await Task.sleep(nanoseconds: 180_000_000)
        let floating = try XCTUnwrap(scene.windows.first {
            !$0.isHidden && $0.accessibilityIdentifier == "voiceRoomFloatingWindow"
        })
        let bubble = try XCTUnwrap(descendants(of: floating).first {
            $0.accessibilityIdentifier == "voiceRoomFloatingBubble"
        } as? UIButton)
        XCTAssertTrue(base.isKeyWindow, "Showing the avatar window must not take focus from text fields")
        XCTAssertFalse(floating.canBecomeKey)
        XCTAssertEqual(bubble.bounds.width, bubble.bounds.height)
        XCTAssertGreaterThanOrEqual(bubble.bounds.width, 44)
        XCTAssertTrue(floating.bounds.inset(by: floating.safeAreaInsets).contains(bubble.convert(bubble.bounds, to: floating)))
        XCTAssertNil(floating.hitTest(CGPoint(x: 2, y: 2), with: nil), "Touches outside the avatar belong to the app underneath")
        XCTAssertNotNil(floating.hitTest(bubble.center, with: nil))
        XCTAssertEqual(bubble.accessibilityLabel, "返回小岛的语聊房")
        XCTAssertTrue(bubble.accessibilityValue?.contains("周末一起聊聊") == true)
        XCTAssertEqual(Set(bubble.accessibilityCustomActions?.map(\.name) ?? []), ["移到左侧", "移到右侧"])
        XCTAssertTrue(bubble.gestureRecognizers?.contains { $0 is UIPanGestureRecognizer } == true)
        let captions = descendants(of: bubble).compactMap { ($0 as? UILabel)?.text }
        XCTAssertEqual(captions, ["🧑🏻‍🎨"], "The visible control contains the real host preset avatar, without a text capsule")
        let rings = (bubble.layer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
        XCTAssertTrue(rings.allSatisfy { ($0.animationKeys() ?? []).isEmpty && $0.opacity == 0 })

        overlay.update(roomTitle: "周末一起聊聊", status: "语聊中", avatarURL: nil, avatarIndex: 4,
                       hostName: "小岛", isSpeaking: true)
        XCTAssertTrue(bubble.accessibilityValue?.contains("房内有人正在发言") == true,
                      "The ripple reflects anyone speaking in the room, including a listener's remote audio")
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertTrue(rings.contains { $0.opacity > 0 })
            XCTAssertTrue(rings.allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        } else {
            XCTAssertTrue(rings.contains { !($0.animationKeys() ?? []).isEmpty })
        }
        try capture(name: "floating-host-avatar-speaking", windows: [base, floating], bounds: base.bounds)
        bubble.sendActions(for: .touchUpInside)
        XCTAssertEqual(resumeCount, 1)

        let onlineFrame = bubble.frame
        overlay.update(roomTitle: "周末一起聊聊", status: "重连中", avatarURL: nil, avatarIndex: 4,
                       hostName: "小岛", isSpeaking: false, isOnline: false)
        XCTAssertTrue(bubble.accessibilityValue?.contains("连接中断") == true)
        XCTAssertEqual(bubble.frame, onlineFrame)
        let avatar = try XCTUnwrap(descendants(of: bubble).first {
            $0.accessibilityIdentifier == "voiceRoomFloatingAvatar"
        } as? UIImageView)
        XCTAssertNotNil(avatar.image, "The preset emoji is rasterized and desaturated while offline")
        XCTAssertLessThan(try XCTUnwrap(avatar.superview).alpha, 0.5)
        XCTAssertFalse(descendants(of: bubble).contains { ($0 as? UILabel)?.text?.contains("重连") == true },
                       "Connectivity is exposed to VoiceOver, without a visible caption or a new line")
        XCTAssertTrue(rings.allSatisfy { ($0.animationKeys() ?? []).isEmpty && $0.opacity == 0 })
        try capture(name: "floating-host-avatar-offline", windows: [base, floating], bounds: base.bounds)
        overlay.update(roomTitle: "周末一起聊聊", status: "语聊中", avatarURL: nil, avatarIndex: 4,
                       hostName: "小岛", isSpeaking: false, isOnline: true)
        XCTAssertNil(avatar.image)
        XCTAssertEqual(try XCTUnwrap(avatar.superview).alpha, 1)
        overlay.hide()
        XCTAssertFalse(overlay.isVisible)
        XCTAssertTrue(base.isKeyWindow)
    }

    func testFloatingAvatarAvoidsAnIntersectingKeyboardAndReturnsAfterItHides() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let base = UIWindow(windowScene: scene)
        base.rootViewController = UIViewController()
        base.makeKeyAndVisible()
        let overlay = KikiVoiceRoomFloatingOverlay(windowScene: scene, roomTitle: "边界验收", avatarURL: nil) { }
        defer { overlay.hide(); base.isHidden = true; previous?.makeKeyAndVisible() }
        overlay.show()
        try await Task.sleep(nanoseconds: 100_000_000)
        let floating = try XCTUnwrap(scene.windows.first {
            !$0.isHidden && $0.accessibilityIdentifier == "voiceRoomFloatingWindow"
        })
        let bubble = try XCTUnwrap(descendants(of: floating).first { $0.accessibilityIdentifier == "voiceRoomFloatingBubble" })
        let restingFrame = bubble.convert(bubble.bounds, to: floating)
        let keyboard = CGRect(x: floating.bounds.minX, y: restingFrame.midY - 15,
                              width: floating.bounds.width, height: floating.bounds.maxY - restingFrame.midY + 15)
        let screenKeyboard = floating.convert(keyboard, to: floating.screen.coordinateSpace)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: screenKeyboard),
                                                   UIResponder.keyboardAnimationDurationUserInfoKey: 0])
        let moved = bubble.convert(bubble.bounds, to: floating)
        XCTAssertFalse(moved.intersects(keyboard), "The avatar must remain reachable above an intersecting keyboard")
        XCTAssertTrue(floating.bounds.inset(by: floating.safeAreaInsets).contains(moved))
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil,
                                        userInfo: [UIResponder.keyboardAnimationDurationUserInfoKey: 0])
        let restored = bubble.convert(bubble.bounds, to: floating)
        XCTAssertEqual(restored.midX, restingFrame.midX, accuracy: 0.5)
        XCTAssertEqual(restored.midY, restingFrame.midY, accuracy: 0.5)
    }

    private func presentationStore() -> KikiAppStore {
        let identity = KikiPresentationIdentity()
        let defaults = UserDefaults(suiteName: "KikiRoomPresentationTests." + UUID().uuidString)!
        let consent = KikiConsentStore(defaults: defaults, identity: identity, requiresRemoteDocuments: false)
        return KikiAppStore(consent: consent, identity: identity,
            apiProvider: { XCTFail("Room-card fixtures must never create an account client"); return .shared },
            voiceAPIProvider: { XCTFail("Room-card fixtures must never create a voice client"); return .shared },
            rtcProvider: { XCTFail("Room-card fixtures must never connect RTC"); return KikiRTCService.shared })
    }

    private func foregroundScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func headerAccessibilityNodes(in root: UIView) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard result.count < 2_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let view = object as? UIView { view.subviews.forEach(visit) }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { visit(element) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 500 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
                }
            }
        }
        visit(root)
        return result
    }

    private func capture(name: String, windows: [UIWindow], bounds: CGRect) throws {
        windows.forEach { $0.layoutIfNeeded() }
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            for window in windows { XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let attachment = XCTAttachment(image: image)
        attachment.name = device + "-" + name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/kiki-room-presentation-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + ".png"), options: .atomic)
    }
}

@MainActor
private final class KikiRoomHeaderFixtureState {
    var probes: [String: UIView] = [:]
    var editCalls = 0
    var controlCalls = 0
}

private struct KikiRoomHeaderFixtureProbe: UIViewRepresentable {
    let key: String
    let state: KikiRoomHeaderFixtureState
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        state.probes[key] = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { state.probes[key] = view }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

@MainActor
private final class KikiSearchPresentationModel: ObservableObject {
    @Published var selectedTab = 0
    @Published var searchFocused = false
    var barProbe: UIView?
}

private struct KikiSearchBarProbe: UIViewRepresentable {
    let model: KikiSearchPresentationModel
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        model.barProbe = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { model.barProbe = view }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

private struct KikiDiscoverSearchFixture: View {
    @ObservedObject var model: KikiSearchPresentationModel
    var body: some View {
        KikiMainTabLayout(isRoomSearchFocused: model.selectedTab == 0 && model.searchFocused) {
            ZStack {
                KikiDiscoverView(isActive: model.selectedTab == 0, onSearchFocusChange: { model.searchFocused = $0 })
                    .opacity(model.selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(model.selectedTab == 0)
                if model.selectedTab != 0 { Text("动态") }
            }
        } tabBar: {
            HStack {
                ForEach(Array(["语聊", "动态", "消息", "我"].enumerated()), id: \.offset) { index, title in
                    Button(title) { model.selectedTab = index }.frame(maxWidth: .infinity, minHeight: 44)
                }
            }.padding(.vertical, 8).background(KikiSearchBarProbe(model: model))
        }
        .background(KikiPalette.background.ignoresSafeArea())
    }
}

private final class KikiPresentationIdentity: KikiIdentityStoring {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

private let presentationRooms: [KikiRoom] = [
    KikiRoom(id: "voice_music", title: "周末一起听听喜欢的歌 🎶", host: "小岛", hostID: "host_music", category: "音乐",
             audience: 16, isLive: false, theme: 0, isCreatedByMe: false, status: "live", hostAvatarIndex: 4,
             memberPreview: [KikiRoomMemberPreview(userID: "friend_a", name: "晚风", avatarIndex: 2, avatarURL: nil),
                             KikiRoomMemberPreview(userID: "friend_b", name: "山海", avatarIndex: 5, avatarURL: nil),
                             KikiRoomMemberPreview(userID: "friend_c", name: "豆包", avatarIndex: 8, avatarURL: nil)]),
    KikiRoom(id: "voice_long", title: "忙碌了一天，在这里慢慢聊聊生活里那些微小又值得开心的事", host: "一个昵称很长但也应该能完整阅读的朋友", hostID: "host_long", category: "随心聊",
             audience: 4, isLive: false, theme: 1, isCreatedByMe: false, status: "live", hostAvatarIndex: 7,
             memberPreview: [KikiRoomMemberPreview(userID: "host_long", name: "房主", avatarIndex: 7, avatarURL: nil),
                             KikiRoomMemberPreview(userID: "real_friend", name: "真实成员", avatarIndex: 1, avatarURL: nil),
                             KikiRoomMemberPreview(userID: "real_friend", name: "重复成员", avatarIndex: 1, avatarURL: nil)]),
    KikiRoom(id: "voice_legacy", title: "这一刻，分享今天的小收获", host: "南风", hostID: "host_legacy", category: "生活",
             audience: 8, isLive: false, theme: 2, isCreatedByMe: false, status: "live", hostAvatarIndex: 9),
    KikiRoom(id: "voice_draft", title: "晚点来聊天", host: "森林", hostID: "host_draft", category: "生活",
             audience: 0, isLive: false, theme: 3, isCreatedByMe: false, status: "draft", hostAvatarIndex: 10)
]

private struct KikiRoomCardsFixture: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let rooms: [KikiRoom]

    var body: some View {
        GeometryReader { geometry in
            let columns = KikiRoomListLayout.columnCount(availableWidth: geometry.size.width,
                                                       accessibilitySize: dynamicTypeSize.isAccessibilitySize)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("正在语聊").font(.title2.weight(.bold)).foregroundStyle(KikiPalette.text)
                        Spacer()
                        KikiCreateRoomButton(isVisible: false, action: {})
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), count: columns), spacing: 12) {
                        ForEach(rooms) { KikiRoomCard(room: $0) }
                    }
                }.padding(20).frame(maxWidth: 1120).frame(maxWidth: .infinity)
            }.background(KikiPalette.background)
        }
    }
}
