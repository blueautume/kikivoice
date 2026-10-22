import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiSeatRequestSheetTests: XCTestCase {
    func testSeatRequestHalfSheetEmptyAndPopulatedFixtureScreenshots() async throws {
        let gifts = KikiGiftStore()
        defer { gifts.reset() }
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
        let sizes: [(String, CGSize, DynamicTypeSize)] = [
            ("375x812", CGSize(width: 375, height: 812), .large),
            ("1133x744", CGSize(width: 1133, height: 744), .large),
            ("large-text-375x812", CGSize(width: 375, height: 812), .accessibility1)
        ]
        var approvalCalls = 0, rejectionCalls = 0, profileCalls = 0, dismissalCalls = 0
        for (phase, state) in [("empty", empty), ("populated", populated)] {
            for (label, size, typeSize) in sizes {
                window.rootViewController?.dismiss(animated: false)
                try await Task.sleep(nanoseconds: 100_000_000)
                let sheet = KikiSeatRequestSheet(roomState: state, gifts: gifts, isWorking: false, isAvailable: true,
                    errorMessage: nil, onApprove: { _ in approvalCalls += 1 }, onReject: { _ in rejectionCalls += 1 },
                    onOpenPerson: { _ in profileCalls += 1 }, onDismiss: { dismissalCalls += 1 })
                    .dynamicTypeSize(typeSize)
                let launcher = KikiSeatRequestSheetFixtureLauncher(sheet: AnyView(sheet))
                    .preferredColorScheme(.dark)
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
                if let controller = presented.sheetPresentationController {
                    let identifiers = Set(controller.detents.map(\.identifier))
                    XCTAssertTrue(identifiers.contains(.medium), "The approval sheet must support the medium height")
                    XCTAssertTrue(identifiers.contains(.large), "The approval sheet must be expandable for long lists and large text")
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
        XCTAssertFalse(gifts.isAvailable, "The sheet renders local fixture state without an API session or RTC")
        XCTAssertNil(gifts.wallet)
        XCTAssertNil(gifts.catalog)
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
        Color(hex: 0x100C1A).ignoresSafeArea()
            .sheet(isPresented: $isPresented) { sheet }
    }
}
