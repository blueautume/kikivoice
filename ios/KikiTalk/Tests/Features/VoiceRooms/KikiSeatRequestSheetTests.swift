import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiSeatRequestSheetTests: XCTestCase {
    func testSeatRequestHalfSheetEmptyAndPopulatedFixtureScreenshots() async throws {
        let populated = fixtureState(populated: true)
        let empty = fixtureState(populated: false)
        XCTAssertEqual(populated.queue.filter { $0.status == "pending" }.count, 3)
        XCTAssertEqual(populated.queue.filter { $0.status == "approved" }.count, 1)
        XCTAssertTrue(populated.members.contains { !$0.online })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.frame = originalFrame
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let folder = URL(fileURLWithPath: "/tmp/kiki-seat-request-sheet-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let sizes: [(String, CGSize, DynamicTypeSize, ColorScheme)] = [
            ("light-375x812", CGSize(width: 375, height: 812), .large, .light),
            ("dark-375x812", CGSize(width: 375, height: 812), .large, .dark),
            ("light-1133x744", CGSize(width: 1133, height: 744), .large, .light),
            ("dark-1133x744", CGSize(width: 1133, height: 744), .large, .dark),
            ("light-large-text-375x812", CGSize(width: 375, height: 812), .accessibility1, .light),
            ("dark-large-text-375x812", CGSize(width: 375, height: 812), .accessibility1, .dark)
        ]
        var approvalCalls = 0, rejectionCalls = 0, profileCalls = 0, dismissalCalls = 0
        for (phase, state) in [("empty", empty), ("populated", populated)] {
            for (label, size, typeSize, scheme) in sizes {
                window.rootViewController?.dismiss(animated: false)
                try await Task.sleep(nanoseconds: 100_000_000)
                let sheet = KikiSeatRequestSheet(roomState: state, isWorking: false, isAvailable: true,
                    errorMessage: nil, onApprove: { _ in approvalCalls += 1 }, onReject: { _ in rejectionCalls += 1 },
                    onOpenPerson: { _ in profileCalls += 1 }, onDismiss: { dismissalCalls += 1 })
                    .dynamicTypeSize(typeSize)
                let launcher = KikiSeatRequestSheetFixtureLauncher(sheet: AnyView(sheet))
                    .preferredColorScheme(scheme)
                let host = UIHostingController(rootView: launcher)
                window.rootViewController = host
                window.frame = CGRect(origin: originalFrame.origin, size: size)
                host.view.frame = window.bounds
                window.makeKeyAndVisible()
                let deadline = Date().addingTimeInterval(3)
                while host.presentedViewController?.viewIfLoaded?.window == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let presented = try XCTUnwrap(host.presentedViewController, "The fixture must render an actual native sheet")
                try await Task.sleep(nanoseconds: 450_000_000)
                window.layoutIfNeeded()
                XCTAssertEqual(window.bounds.size, size)
                XCTAssertEqual(host.view.bounds.size, size)
                XCTAssertNotNil(presented.viewIfLoaded?.window)
                XCTAssertEqual(presented.traitCollection.userInterfaceStyle, scheme == .dark ? .dark : .light,
                               "The request sheet must inherit the presenting system appearance")
                if let controller = presented.sheetPresentationController {
                    let identifiers = Set(controller.detents.map(\.identifier))
                    XCTAssertTrue(identifiers.contains(.medium), "The approval sheet must support the medium height")
                    XCTAssertTrue(identifiers.contains(.large), "The approval sheet must be expandable for long lists and large text")
                    XCTAssertTrue(controller.prefersGrabberVisible)
                    XCTAssertFalse(controller.prefersScrollingExpandsWhenScrolledToEdge)
                    if presented.traitCollection.verticalSizeClass != .compact {
                        XCTAssertEqual(controller.selectedDetentIdentifier, .medium)
                    }
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let name = device + "-seat-requests-" + phase + "-" + label
                let attachment = XCTAttachment(image: image)
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
                try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
            }
        }
        XCTAssertEqual(approvalCalls, 0, "Presentation must not approve automatically")
        XCTAssertEqual(rejectionCalls, 0, "Presentation must not reject automatically")
        XCTAssertEqual(profileCalls, 0)
        XCTAssertEqual(dismissalCalls, 0)
    }

    func testSharedRoomSheetsStartMediumExpandLargeAndInheritBothAppearances() async throws {
        var saveCalls = 0
        let announcement = "欢迎来到房间。请友好交流，尊重每位朋友。"
        let contents: [(String, AnyView)] = [
            ("announcement-reader", AnyView(KikiRoomAnnouncementContent(text: .constant(announcement), canManageRoom: false,
                canUseRoom: true, isSaving: false, announcement: announcement, onSave: { saveCalls += 1 }, onClose: {}))),
            ("announcement-save", AnyView(KikiRoomAnnouncementContent(text: .constant(announcement), canManageRoom: true,
                canUseRoom: true, isSaving: false, announcement: announcement, onSave: { saveCalls += 1 }, onClose: {}))),
            ("announcement-saving", AnyView(KikiRoomAnnouncementContent(text: .constant(announcement), canManageRoom: true,
                canUseRoom: true, isSaving: true, announcement: announcement, onSave: { saveCalls += 1 }, onClose: {}))),
            ("announcement-disabled", AnyView(KikiRoomAnnouncementContent(text: .constant(announcement), canManageRoom: true,
                canUseRoom: false, isSaving: false, announcement: announcement, onSave: { saveCalls += 1 }, onClose: {}))),
            ("scrollable-content", AnyView(NavigationStack {
                ScrollView {
                    LazyVStack { ForEach(1...40, id: \.self) { Text("房内内容 \($0)").frame(maxWidth: .infinity).padding(20) } }
                }.navigationTitle("房内列表").navigationBarTitleDisplayMode(.inline)
            }))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        for scheme in [ColorScheme.light, .dark] {
            for (name, content) in contents {
                window.rootViewController?.dismiss(animated: false)
                let host = UIHostingController(rootView: KikiSeatRequestSheetFixtureLauncher(sheet: content)
                    .preferredColorScheme(scheme))
                window.rootViewController = host
                window.makeKeyAndVisible()
                let deadline = Date().addingTimeInterval(3)
                while host.presentedViewController?.viewIfLoaded?.window == nil, Date() < deadline {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                let presented = try XCTUnwrap(host.presentedViewController)
                let sheet = try XCTUnwrap(presented.sheetPresentationController)
                try await Task.sleep(nanoseconds: 450_000_000)
                window.layoutIfNeeded()
                XCTAssertEqual(presented.traitCollection.userInterfaceStyle, scheme == .dark ? .dark : .light)
                XCTAssertEqual(Set(sheet.detents.map(\.identifier)), Set([.medium, .large]))
                XCTAssertTrue(sheet.prefersGrabberVisible)
                XCTAssertFalse(sheet.prefersScrollingExpandsWhenScrolledToEdge,
                               "Room content must scroll at medium height instead of expanding the sheet")
                XCTAssertEqual(sheet.selectedDetentIdentifier, .medium, "Each newly presented room sheet must start half-screen")
                let mediumHeight = presented.view.bounds.height
                if name == "scrollable-content" {
                    func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                    let scroll = try XCTUnwrap(descendants(presented.view).compactMap { $0 as? UIScrollView }
                        .first { $0.contentSize.height > $0.bounds.height + 200 })
                    let before = scroll.contentOffset.y
                    scroll.setContentOffset(CGPoint(x: 0, y: before + 200), animated: false)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    window.layoutIfNeeded()
                    XCTAssertGreaterThan(scroll.contentOffset.y, before + 100)
                    XCTAssertEqual(sheet.selectedDetentIdentifier, .medium)
                    XCTAssertEqual(presented.view.bounds.height, mediumHeight, accuracy: 1)
                }
                try capture(window: window, name: name + (scheme == .dark ? "-dark-medium" : "-light-medium"))
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
                try await Task.sleep(nanoseconds: 450_000_000)
                window.layoutIfNeeded()
                XCTAssertEqual(sheet.selectedDetentIdentifier, .large)
                XCTAssertGreaterThan(presented.view.bounds.height, mediumHeight + 10,
                                     "The native controller must expand the actual content viewport")
            }
        }
        XCTAssertEqual(saveCalls, 0, "Rendering an enabled or loading save button must never submit an announcement")
    }

    func testSeatInvitationControlsFitSmallScreensAndRequireExplicitActions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer {
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let scenarios: [(String, Bool, Bool, Bool, DynamicTypeSize)] = [
            ("ready", false, true, false, .large),
            ("full-room", false, true, true, .large),
            ("busy", true, true, false, .large),
            ("unavailable", false, false, false, .large),
            ("full-room-large-text", false, true, true, .accessibility3)
        ]
        var observations: [[String: Any]] = []
        for scheme in [ColorScheme.light, .dark] {
            for (name, busy, enabled, full, textSize) in scenarios {
                let model = KikiSeatInvitationFixtureModel()
                let fixture = KikiSeatInvitationControlsFixture(model: model, isBusy: busy,
                    isEnabled: enabled, isRoomFull: full)
                    .dynamicTypeSize(textSize).preferredColorScheme(scheme)
                let host = UIHostingController(rootView: fixture)
                window.rootViewController = host
                window.frame = CGRect(origin: originalFrame.origin, size: CGSize(width: 375, height: 812))
                host.view.frame = window.bounds
                window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 350_000_000)
                window.layoutIfNeeded()

                func frame(_ key: String) throws -> CGRect {
                    let probe = try XCTUnwrap(model.probes[key]?.last {
                        $0.window === window && $0.bounds.width > 1 && $0.bounds.height > 1
                    }, "The fixture must measure visible production content: \(key)")
                    return probe.convert(probe.bounds, to: window)
                }
                let invite = try frame("invite")
                let card = try frame("card")
                XCTAssertGreaterThanOrEqual(invite.height, 44, "A compact visual button must keep a 44-point touch target")
                XCTAssertGreaterThan(invite.width, 64)
                XCTAssertGreaterThanOrEqual(invite.minX, 0)
                XCTAssertLessThanOrEqual(invite.maxX, 375)
                XCTAssertEqual(card.width, 343, accuracy: 1)
                XCTAssertEqual(card.minX, 16, accuracy: 1)
                XCTAssertGreaterThan(card.height, 110)
                XCTAssertLessThan(card.height, 650, "Large text must fit in the phone viewport without clipping the actions")
                XCTAssertGreaterThan(card.minY, invite.maxY)
                XCTAssertEqual(model.invites, 0)
                XCTAssertEqual(model.acceptances, 0, "Showing an invitation must never accept it or open the microphone")
                XCTAssertEqual(model.declines, 0)

                try capture(window: window, name: "invitation-controls-" + name + (scheme == .dark ? "-dark" : "-light"))
                var activationResults: [String: Bool] = [:]
                for identifier in ["social.profile.inviteSeat", "livekit.room.acceptSeatInvitation", "livekit.room.declineSeatInvitation"] {
                    let node = invitationAccessibilityNodes(in: host.view).first {
                        ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
                    }
                    if let node {
                        activationResults[identifier] = activateInvitationControl(node)
                    } else {
                        activationResults[identifier] = false
                    }
                }
                await Task.yield()
                if busy || !enabled {
                    XCTAssertEqual(model.invites, 0, "Busy and disabled invitation controls must not submit")
                    XCTAssertEqual(model.acceptances, 0)
                    XCTAssertEqual(model.declines, 0)
                } else {
                    XCTAssertEqual(model.invites, activationResults["social.profile.inviteSeat"] == true ? 1 : 0)
                    XCTAssertEqual(model.acceptances, activationResults["livekit.room.acceptSeatInvitation"] == true ? 1 : 0)
                    XCTAssertEqual(model.declines, activationResults["livekit.room.declineSeatInvitation"] == true ? 1 : 0)
                }
                observations.append([
                    "scenario": name, "appearance": scheme == .dark ? "dark" : "light",
                    "inviteFrame": NSCoder.string(for: invite), "cardFrame": NSCoder.string(for: card),
                    "accessibilityActivation": activationResults,
                    "callbackCounts": ["invite": model.invites, "accept": model.acceptances, "decline": model.declines]
                ])
            }
        }
        // Some test-host runtimes omit SwiftUI's virtual accessibility nodes.
        // Keep the layout evidence and report activation availability explicitly.
        let report = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        attachment.name = "seat-invitation-layout-and-activation"; attachment.lifetime = .keepAlways; add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/kiki-seat-request-sheet-screenshots", isDirectory: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try report.write(to: folder.appendingPathComponent(device + "-seat-invitation-validation.json"))
    }

    private func invitationAccessibilityNodes(in root: UIView) -> [NSObject] {
        var nodes: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard nodes.count < 2_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            nodes.append(object)
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
        return nodes
    }

    private func activateInvitationControl(_ object: NSObject) -> Bool {
        if object.accessibilityActivate() { return true }
        guard let control = object as? UIControl, control.isEnabled else { return false }
        if control.allControlEvents.contains(.primaryActionTriggered) {
            control.sendActions(for: .primaryActionTriggered)
        } else if control.allControlEvents.contains(.touchUpInside) {
            control.sendActions(for: .touchUpInside)
        } else {
            return false
        }
        return true
    }

    private func capture(window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let filename = device + "-room-sheet-" + name
        let attachment = XCTAttachment(image: image)
        attachment.name = filename
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = URL(fileURLWithPath: "/tmp/kiki-seat-request-sheet-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(filename + ".png"))
    }

    private func fixtureState(populated: Bool) -> KikiRoomState {
        let owner = KikiRoomMember(userID: "kiki_sheet_owner", name: "房主", avatarIndex: 0, avatarURL: nil,
                                  role: .owner, seatIndex: 1, audioMuted: false, chatMuted: false,
                                  online: true, canPublishAudio: true, canPublishData: true, seatRequestStatus: "seated")
        let specifications: [(String, String, Bool, String)] = [
            ("kiki_sheet_one", "小岛", true, "pending"),
            ("kiki_sheet_two", "想聊聊今天的小确幸", true, "pending"),
            ("kiki_sheet_three", "夏日海风", false, "pending"),
            ("kiki_sheet_four", "云朵", true, "approved")
        ]
        let applicants = populated ? specifications.enumerated().map { index, spec in
            KikiRoomMember(userID: spec.0, name: spec.1, avatarIndex: index + 2, avatarURL: nil,
                           role: .member, seatIndex: nil, audioMuted: false, chatMuted: false,
                           online: spec.2, canPublishAudio: false, canPublishData: true,
                           offlineSince: spec.2 ? nil : 1_792_440_000,
                           reconnectDeadline: spec.2 ? nil : 1_792_440_060, seatRequestStatus: spec.3)
        } : []
        let requests = populated ? specifications.enumerated().map { index, spec in
            KikiSeatRequest(userID: spec.0, name: spec.1, requestedAt: 1_792_439_900 + index,
                            position: index + 1, status: spec.3, online: spec.2)
        } : []
        let room = KikiRoom(id: "lk_" + String(repeating: "c", count: 32), title: "今晚聊点轻松的", host: owner.name,
                            hostID: owner.userID, category: "随心聊", audience: applicants.count + 1,
                            isLive: false, theme: 0, isCreatedByMe: true, status: "live")
        let seats = (1...8).map { KikiRoomSeat(index: $0, userID: $0 == 1 ? owner.userID : nil, locked: false, audioLocked: false) }
        return KikiRoomState(room: room, revision: 4, me: owner, seats: seats, members: [owner] + applicants,
                             queue: requests, invitations: [], bans: [])
    }
}

/// Real SwiftUI presentation keeps native detents, dismissal and iPad adaptation
/// in the screenshot; no production singleton or network operation is involved.
private struct KikiSeatRequestSheetFixtureLauncher: View {
    let sheet: AnyView
    @State private var isPresented = true
    var body: some View {
        KikiPalette.background.ignoresSafeArea()
            .sheet(isPresented: $isPresented) { sheet.kikiRoomSheet() }
    }
}

@MainActor
private final class KikiSeatInvitationFixtureModel: ObservableObject {
    var invites = 0
    var acceptances = 0
    var declines = 0
    var probes: [String: [UIView]] = [:]
}

private struct KikiSeatInvitationControlsFixture: View {
    let model: KikiSeatInvitationFixtureModel
    let isBusy: Bool
    let isEnabled: Bool
    let isRoomFull: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                KikiIncomingSeatInvitationCard(isBusy: isBusy, isEnabled: isEnabled, isRoomFull: isRoomFull,
                    onAccept: { model.acceptances += 1 }, onDecline: { model.declines += 1 })
                    .background(KikiSeatInvitationLayoutProbe(key: "card", model: model))
                    .padding(16)
            }
            .background(KikiPalette.background.ignoresSafeArea())
            .navigationTitle("个人主页").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26.0, *) {
                    ToolbarItem(placement: .topBarLeading) { inviteButton }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) { inviteButton }
                }
                ToolbarItem(placement: .confirmationAction) { Button("完成") {} }
            }
        }
    }

    private var inviteButton: some View {
        KikiProfileSeatInviteButton(title: "邀请", isBusy: isBusy, isEnabled: isEnabled) { model.invites += 1 }
            .background(KikiSeatInvitationLayoutProbe(key: "invite", model: model))
    }
}

private struct KikiSeatInvitationLayoutProbe: UIViewRepresentable {
    let key: String
    let model: KikiSeatInvitationFixtureModel
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        model.probes[key, default: []].append(view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
