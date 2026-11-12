import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

final class KikiRelationshipStageTests: XCTestCase {
    func testLegendsAlwaysExposeEveryModeCategoryAndEveryKnownCategoryHasACurve() {
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .bazi).map(\.code),
                       ["HARMONY_ONLY", "CONFLICT_ONLY", "MIXED", "NONE", "UNAVAILABLE"])
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .mbti).map(\.code),
                       ["GOLDEN", "SILVER", "PEDAGOGUE", "SAME_TYPE", "OTHER", "UNAVAILABLE"])
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .zodiac).map(\.code),
                       ["SAME_SIGN", "ADJACENT", "SEXTILE", "SQUARE", "TRINE", "QUINCUNX", "OPPOSITION", "UNAVAILABLE"])
        for mode in KikiRelationshipMode.allCases {
            for category in KikiRelationshipCategory.categories(for: mode) where category.code != "UNAVAILABLE" {
                XCTAssertFalse(KikiRelationshipVisuals.strokes(for: category.code).isEmpty, category.code)
            }
        }
        XCTAssertTrue(KikiRelationshipVisuals.strokes(for: "UNAVAILABLE").isEmpty)
        XCTAssertGreaterThanOrEqual(KikiRelationshipVisuals.lineWidth, 2.5)
    }

    func testInterruptedReflowStartsAtPresentedPositionInsteadOfOldDestination() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var motion = KikiRelationshipMotion()
        motion.retarget(orderedIDs: ["host", "a", "b"], at: start, animated: false)
        motion.retarget(orderedIDs: ["host", "a", "b", "c"], at: start, animated: true)
        let interrupt = start.addingTimeInterval(0.19)
        let before = motion.frame(at: interrupt)
        motion.retarget(orderedIDs: ["host", "b", "c"], at: interrupt, animated: true)
        let after = motion.frame(at: interrupt)
        for id in ["host", "a", "b", "c"] {
            let old = try XCTUnwrap(before[id]), new = try XCTUnwrap(after[id])
            XCTAssertEqual(old.angle, new.angle, accuracy: 0.000_001)
            XCTAssertEqual(old.radius, new.radius, accuracy: 0.000_001)
            XCTAssertEqual(old.opacity, new.opacity, accuracy: 0.000_001)
        }
        XCTAssertEqual(try XCTUnwrap(after["host"]).angle, -.pi / 2, accuracy: 0.000_001)
    }

    func testDepartureFadesWithoutMovingTheDepartingAvatarAndSettlesToRealOccupants() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var motion = KikiRelationshipMotion()
        motion.retarget(orderedIDs: ["host", "a", "b"], at: start, animated: false)
        let original = try XCTUnwrap(motion.frame(at: start)["a"])
        motion.retarget(orderedIDs: ["host", "b"], at: start, animated: true)
        let middle = try XCTUnwrap(motion.frame(at: start.addingTimeInterval(0.25))["a"])
        XCTAssertEqual(middle.angle, original.angle, accuracy: 0.000_001)
        XCTAssertEqual(middle.opacity, 0.5, accuracy: 0.000_001)
        motion.settle()
        XCTAssertEqual(Set(motion.frame(at: start).keys), ["host", "b"])
    }

    func testReducedMotionHasNoGhostSeatsAndNoIntermediatePositions() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var motion = KikiRelationshipMotion()
        motion.retarget(orderedIDs: ["host", "a", "b"], at: start, animated: false)
        motion.retarget(orderedIDs: ["host", "b"], at: start, animated: false)
        let result = motion.frame(at: start)
        XCTAssertNil(result["a"])
        XCTAssertEqual(try XCTUnwrap(result["b"]).angle, .pi / 2, accuracy: 0.000_001)
        XCTAssertTrue(result.values.allSatisfy { $0.opacity == 1 })
    }

    func testAllEightAvatarCentersAndLabelsFitSmallAndLargeStages() {
        for width: CGFloat in [284, 339, 366, 440] {
            let geometry = KikiRelationshipStageGeometry(width: width)
            for count in 1...8 {
                var motion = KikiRelationshipMotion()
                let ids = (0..<count).map { "seat-\($0)" }
                motion.retarget(orderedIDs: ids, at: .now, animated: false)
                let values = ids.compactMap { motion.frame(at: .now)[$0] }
                let avatarPoints = values.map { geometry.point($0) }
                for value in values {
                    let center = geometry.cellCenter(angle: value.angle, radius: value.radius)
                    let cell = CGRect(x: center.x - geometry.cellWidth / 2,
                                      y: center.y - geometry.cellHeight / 2,
                                      width: geometry.cellWidth, height: geometry.cellHeight)
                    XCTAssertGreaterThanOrEqual(cell.minX, 0)
                    XCTAssertLessThanOrEqual(cell.maxX, width)
                    XCTAssertGreaterThanOrEqual(cell.minY, 0)
                    XCTAssertLessThanOrEqual(cell.maxY, geometry.height)
                    let actualAvatarCenter = CGPoint(x: cell.midX, y: cell.minY + geometry.avatarSize / 2 + 3)
                    let edgeEndpoint = geometry.point(value)
                    XCTAssertEqual(actualAvatarCenter.x, edgeEndpoint.x, accuracy: 0.000_001)
                    XCTAssertEqual(actualAvatarCenter.y, edgeEndpoint.y, accuracy: 0.000_001)
                }
                if count > 1 {
                    for (i, point) in avatarPoints.enumerated() {
                        let next = avatarPoints[(i + 1) % count]
                        XCTAssertGreaterThan(hypot(next.x - point.x, next.y - point.y), geometry.avatarSize + 6)
                    }
                }
            }
        }
    }

    func testOnlyOccupiedRealSeatsAreDrawnAndOfflineGraceKeepsIdentityAndActualNumber() {
        let host = member("host", seat: 1, online: true)
        let guest = member("guest", seat: 5, online: false)
        let listener = member("listener", seat: nil, online: true)
        let slots = (1...8).map { KikiRoomSeat(index: $0, userID: $0 == 1 ? "host" : ($0 == 5 ? "guest" : nil),
                                            locked: $0 == 2, audioLocked: false) }
        let room = KikiRoom(id: "lk_fixture", title: "房间", host: "房主", hostID: "host", category: "聊天",
                            audience: 3, isLive: true, theme: 0, isCreatedByMe: true, status: "active")
        let state = KikiRoomState(room: room, revision: 1, me: host, seats: slots,
                                  members: [listener, guest, host], queue: [], invitations: [], bans: [])
        let occupants = KikiRelationshipSeat.occupants(in: state)
        XCTAssertEqual(occupants.map(\.id), ["host", "guest"])
        XCTAssertEqual(occupants.map { $0.slot.index }, [1, 5])
        XCTAssertFalse(occupants[1].member.online)
        XCTAssertTrue(KikiRelationshipSeat.occupants(in: nil).isEmpty)
    }


    func testSingleOccupantStartsAtCenterAndGlidesToTheRingWhenSecondJoins() throws {
        let start = Date(timeIntervalSince1970: 4_000)
        let geometry = KikiRelationshipStageGeometry(width: 340)
        var motion = KikiRelationshipMotion()
        motion.retarget(orderedIDs: ["host"], at: start, animated: false)
        let single = try XCTUnwrap(motion.frame(at: start)["host"])
        XCTAssertEqual(single.radius, 0)
        XCTAssertEqual(geometry.point(single), geometry.center)
        motion.retarget(orderedIDs: ["host", "guest"], at: start, animated: true)
        XCTAssertEqual(geometry.point(try XCTUnwrap(motion.frame(at: start)["host"])), geometry.center)
        let halfway = try XCTUnwrap(motion.frame(at: start.addingTimeInterval(0.25))["host"])
        XCTAssertEqual(halfway.radius, 0.5, accuracy: 0.000_001)
        let point = geometry.point(halfway)
        XCTAssertEqual(hypot(point.x - geometry.center.x, point.y - geometry.center.y), geometry.radius / 2, accuracy: 0.000_001)
        motion.settle()
        XCTAssertEqual(try XCTUnwrap(motion.frame(at: start)["host"]).radius, 1)
        motion.retarget(orderedIDs: ["host"], at: start, animated: true)
        XCTAssertEqual(try XCTUnwrap(motion.frame(at: start.addingTimeInterval(0.25))["host"]).radius, 0.5, accuracy: 0.000_001)
        motion.settle()
        XCTAssertEqual(geometry.point(try XCTUnwrap(motion.frame(at: start)["host"])), geometry.center)
    }

    func testOppositeAvatarCurveUsesAShallowBowAndPresentedEndpoints() throws {
        let geometry = KikiRelationshipStageGeometry(width: 340)
        let a = geometry.point(angle: -.pi / 2), b = geometry.point(angle: .pi / 2)
        let trim = geometry.avatarSize / 2 + 7
        let curve = try XCTUnwrap(KikiRelationshipCurve.make(from: a, to: b, center: geometry.center,
            radius: geometry.radius, trim: trim, pairID: "a|b"))
        let midpoint = quadraticMidpoint(curve)
        XCTAssertGreaterThanOrEqual(abs(midpoint.x - geometry.center.x), 5)
        XCTAssertLessThanOrEqual(abs(midpoint.x - geometry.center.x), 10)
        XCTAssertEqual(midpoint.y, geometry.center.y, accuracy: 0.000_001)
        XCTAssertEqual(hypot(curve.start.x - a.x, curve.start.y - a.y), trim, accuracy: 0.000_001)
        XCTAssertEqual(hypot(curve.end.x - b.x, curve.end.y - b.y), trim, accuracy: 0.000_001)
        var quadraticSegments = 0
        curve.path.forEach { if case .quadCurve = $0 { quadraticSegments += 1 } }
        XCTAssertEqual(quadraticSegments, 1)
        let movedA = geometry.point(angle: -.pi / 3, radius: 0.6)
        let moved = try XCTUnwrap(KikiRelationshipCurve.make(from: movedA, to: b, center: geometry.center,
            radius: geometry.radius, trim: trim, pairID: "a|b"))
        XCTAssertEqual(hypot(moved.start.x - movedA.x, moved.start.y - movedA.y), trim, accuracy: 0.000_001)
        XCTAssertNotEqual(moved.start, curve.start)
        let duplicate = try XCTUnwrap(KikiRelationshipCurve.make(from: movedA, to: b, center: geometry.center,
            radius: geometry.radius, trim: trim, pairID: "a|b"))
        XCTAssertEqual(moved.control, duplicate.control)
    }

    func testMixedCurvesStayOnOppositeSidesWithAClearMidpointGap() throws {
        for width: CGFloat in [284, 354, 440] {
            let geometry = KikiRelationshipStageGeometry(width: width)
            let a = geometry.point(angle: -.pi / 2), b = geometry.point(angle: .pi / 2)
            let curves = try KikiRelationshipVisuals.strokes(for: "MIXED").map { stroke in
                try XCTUnwrap(KikiRelationshipCurve.make(from: a, to: b, center: geometry.center,
                    radius: geometry.radius, trim: geometry.avatarSize / 2 + 7,
                    pairID: "same|stable-pair", lane: stroke.lane))
            }
            XCTAssertEqual(curves.count, 2)
            let offsets = curves.map { quadraticMidpoint($0).x - geometry.center.x }
            XCTAssertLessThan(offsets[0] * offsets[1], 0, "合与冲必须分居弦两侧")
            XCTAssertEqual(abs(offsets[0] - offsets[1]), 20, accuracy: 0.000_001)
            XCTAssertEqual(curves[0].start, curves[1].start)
            XCTAssertEqual(curves[0].end, curves[1].end)
        }
    }

    func testBaziHasNoPublicTagPlaceholderOrLargeNicknamePlate() {
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.tagHeight(mode: .bazi, value: "INFJ"), 0)
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.plateHeight(mode: .bazi, value: nil), 20)
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.tagHeight(mode: .mbti, value: "INFJ"), 17)
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.tagHeight(mode: .zodiac, value: "处女座"), 17)
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.tagHeight(mode: .mbti, value: nil), 0)
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.tagHeight(mode: .zodiac, value: ""), 0)
    }

    func testFriendlyCopyKeepsOriginalCategoriesAndDoesNotRepeatTheTitleInBody() {
        XCTAssertEqual(KikiRelationshipVisuals.friendlyTitle(for: "MIXED"), "欢喜冤家")
        XCTAssertEqual(KikiRelationshipVisuals.friendlyTitle(for: "NONE"), "慢热探索")
        for mode in KikiRelationshipMode.allCases {
            for category in KikiRelationshipCategory.categories(for: mode) {
                let title = KikiRelationshipVisuals.friendlyTitle(for: category.code)
                let body = KikiRelationshipVisuals.friendlyBody(for: category.code)
                XCTAssertFalse(title.isEmpty)
                XCTAssertFalse(body.isEmpty)
                XCTAssertFalse(body.hasPrefix(title + "。"))
            }
        }
    }

    @MainActor
    func testProductionCirclePresentationInThreeModesAndEmptySingleEightOccupantStates() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive
        }) else { throw XCTSkip("A foreground native scene is required for the circle presentation fixture") }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let scenarios: [(String, CGFloat, Int, KikiRelationshipMode, ColorScheme)] = [
            ("small-eight-bazi-light", 320, 8, .bazi, .light),
            ("phone-eight-mbti-dark", 390, 8, .mbti, .dark),
            ("phone-eight-zodiac-light", 390, 8, .zodiac, .light),
            ("phone-one-bazi-dark", 390, 1, .bazi, .dark),
            ("phone-one-mbti-dark", 390, 1, .mbti, .dark),
            ("phone-one-zodiac-dark", 390, 1, .zodiac, .dark),
            ("phone-two-mixed-bazi-light", 390, 2, .bazi, .light),
            ("phone-two-mixed-bazi-dark", 390, 2, .bazi, .dark),
            ("phone-empty-bazi-light", 390, 0, .bazi, .light),
            ("ipad-eight-bazi-dark", 744, 8, .bazi, .dark)
        ]
        let names = ["青禾", "知夏", "晚晴", "南风", "星野", "听雨", "望舒", "阿岚"]
        let mbti = ["INFJ", "ENFP", "ISFJ", "ENTP", "ISTP", "INTJ", "ENFJ", "ESTP"]
        let zodiac = ["处女座", "狮子座", "双鱼座", "双子座", "金牛座", "射手座", "白羊座", "双鱼座"]
        let output = URL(fileURLWithPath: "/tmp/kiki-relationship-stage-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, viewport, count, mode, scheme) in scenarios {
            let occupants = (0..<count).map { index in
                let id = "fixture-\(index)"
                let person = KikiRoomMember(userID: id, name: names[index], avatarIndex: index, avatarURL: nil,
                    role: index == 0 ? .owner : .member, seatIndex: index + 1,
                    audioMuted: false, chatMuted: false, online: index != 6,
                    canPublishAudio: true, canPublishData: true)
                return KikiRelationshipSeat(slot: .init(index: index + 1, userID: id, locked: false, audioLocked: false),
                                            member: person)
            }
            let profiles = occupants.enumerated().map { index, seat in
                KikiRelationshipPublicProfile(userID: seat.id, mbtiType: mbti[index], zodiacSign: zodiac[index])
            }
            let codes: [String] = mode == .bazi ? ["HARMONY_ONLY", "CONFLICT_ONLY", "MIXED", "NONE"]
                : (mode == .mbti ? ["GOLDEN", "SILVER", "PEDAGOGUE", "SAME_TYPE", "OTHER"]
                                : ["SAME_SIGN", "ADJACENT", "SEXTILE", "SQUARE", "TRINE", "QUINCUNX", "OPPOSITION"])
            var pairs: [KikiStageRelationshipPair] = []
            for index in occupants.indices {
                for other in (index + 1)..<occupants.count {
                    pairs.append(KikiStageRelationshipPair(a: occupants[index], b: occupants[other],
                        summary: .init(code: count == 2 && mode == .bazi ? "MIXED" : codes[(index + other) % codes.count], label: "关系结果", description: "关系结果示例")))
                }
            }
            var motion = KikiRelationshipMotion()
            motion.retarget(orderedIDs: occupants.map(\.id), at: .now, animated: false)
            let geometry = KikiRelationshipStageGeometry(width: min(440, viewport - 36))
            let circle = KikiRelationshipCircle(geometry: geometry, seats: occupants, activeIDs: Set(occupants.map(\.id)),
                frame: motion.frame(at: .now), pairs: pairs, profiles: profiles,
                participants: [], localUserID: occupants.first?.id, mode: mode,
                edgeOpacity: 1, onOpenPerson: { _ in })
            let content = VStack(spacing: 12) {
                Text("圆形麦位").font(.headline).padding(.top, 18)
                Picker("关系模式", selection: .constant(mode)) {
                    ForEach(KikiRelationshipMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420).padding(.horizontal, 18)
                circle
                KikiRelationshipLegend(mode: mode).padding(.horizontal, 18)
                Text("\(mode.title) · 关系说明").font(.caption).foregroundStyle(KikiPalette.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KikiPalette.background)
            .preferredColorScheme(scheme)
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = SafeAreaRegions.container
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: viewport, height: viewport > 500 ? 1133 : 844)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(180))
            window.layoutIfNeeded()
            try saveScreenshot(window: window, name: name, directory: output)
        }
    }

    @MainActor
    func testProductionModeTransitionsAndFriendlyExplanationCards() async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive
        }) else { throw XCTSkip("A foreground native scene is required for the mode transition fixture") }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let seat = KikiRelationshipSeat(slot: .init(index: 1, userID: "host", locked: false, audioLocked: false),
                                       member: member("host", seat: 1, online: true))
        let state = KikiRelationshipFixtureMode()
        let fixture = KikiRelationshipModeTransitionFixture(state: state, seat: seat)
        let host = UIHostingController(rootView: fixture.preferredColorScheme(.dark))
        window.rootViewController = host
        host.view.frame = window.bounds
        window.makeKeyAndVisible()
        let output = URL(fileURLWithPath: "/tmp/kiki-relationship-stage-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(180))
        for (name, mode, wait): (String, KikiRelationshipMode, Int) in [
            ("mode-bazi-before", .bazi, 20),
            ("mode-mbti-fade-in", .mbti, 100),
            ("mode-mbti-settled", .mbti, 200),
            ("mode-zodiac-crossfade", .zodiac, 100),
            ("mode-zodiac-settled", .zodiac, 200),
            ("mode-bazi-collapse", .bazi, 100),
            ("mode-bazi-after", .bazi, 200)
        ] {
            state.mode = mode
            try await Task.sleep(for: .milliseconds(wait))
            window.layoutIfNeeded()
            try saveScreenshot(window: window, name: name, directory: output)
        }
        let second = KikiRelationshipSeat(slot: .init(index: 2, userID: "guest", locked: false, audioLocked: false),
                                         member: member("guest", seat: 2, online: true))
        for mode in KikiRelationshipMode.allCases {
            let code = mode == .bazi ? "MIXED" : (mode == .mbti ? "GOLDEN" : "SEXTILE")
            let label = try XCTUnwrap(KikiRelationshipCategory.categories(for: mode).first { $0.code == code }?.label)
            let pair = KikiStageRelationshipPair(a: seat, b: second,
                summary: .init(code: code, label: label, description: KikiRelationshipVisuals.explanation(for: code)))
            let details = UIHostingController(rootView:
                KikiRelationshipDetails(mode: mode, pairs: [pair], onDismiss: {}).preferredColorScheme(.dark))
            window.rootViewController = details
            details.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(180))
            window.layoutIfNeeded()
            try saveScreenshot(window: window, name: "details-\(mode.rawValue)", directory: output)
        }
    }

    @MainActor
    private func saveScreenshot(window: UIWindow, name: String, directory: URL) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 5_000)
        let attachment = XCTAttachment(image: image)
        attachment.name = "relationship-circle-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func quadraticMidpoint(_ curve: KikiRelationshipCurve) -> CGPoint {
        CGPoint(x: curve.start.x * 0.25 + curve.control.x * 0.5 + curve.end.x * 0.25,
                y: curve.start.y * 0.25 + curve.control.y * 0.5 + curve.end.y * 0.25)
    }

    private func member(_ id: String, seat: Int?, online: Bool) -> KikiRoomMember {
        .init(userID: id, name: id, avatarIndex: 0, avatarURL: nil,
              role: id == "host" ? .owner : .member, seatIndex: seat,
              audioMuted: false, chatMuted: false, online: online,
              canPublishAudio: seat != nil && online, canPublishData: online)
    }
}

@MainActor
private final class KikiRelationshipFixtureMode: ObservableObject {
    @Published var mode: KikiRelationshipMode = .bazi
}

private struct KikiRelationshipModeTransitionFixture: View {
    @ObservedObject var state: KikiRelationshipFixtureMode
    let seat: KikiRelationshipSeat

    var body: some View {
        let geometry = KikiRelationshipStageGeometry(width: 354)
        VStack(spacing: 12) {
            Picker("关系模式", selection: $state.mode) {
                ForEach(KikiRelationshipMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).padding(.top, 30).padding(.horizontal, 18)
            KikiRelationshipCircle(geometry: geometry, seats: [seat], activeIDs: [seat.id],
                frame: [seat.id: .init(angle: -.pi / 2, radius: 0, opacity: 1)], pairs: [],
                profiles: [.init(userID: seat.id, mbtiType: "INFJ", zodiacSign: "处女座")],
                participants: [], localUserID: seat.id, mode: state.mode, edgeOpacity: 1, onOpenPerson: { _ in })
            KikiRelationshipLegend(mode: state.mode).padding(.horizontal, 18)
            Spacer()
        }
        .background(KikiPalette.background)
    }
}
