import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

final class KikiRelationshipStageTests: XCTestCase {
    func testLegendsAlwaysExposeEveryModeCategoryAndEveryKnownCategoryHasACurve() {
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .bazi).map(\.code),
                       ["HARMONY_ONLY", "CONFLICT_ONLY", "MIXED", "UNAVAILABLE"])
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .mbti).map(\.code),
                       ["GOLDEN", "SILVER", "PEDAGOGUE", "SAME_TYPE", "UNAVAILABLE"])
        XCTAssertEqual(KikiRelationshipCategory.categories(for: .zodiac).map(\.code),
                       ["SAME_SIGN", "ADJACENT", "SEXTILE", "SQUARE", "TRINE", "QUINCUNX", "OPPOSITION", "UNAVAILABLE"])
        for mode in KikiRelationshipMode.allCases {
            for category in KikiRelationshipCategory.categories(for: mode) where category.code != "UNAVAILABLE" {
                XCTAssertFalse(KikiRelationshipVisuals.strokes(for: category.code).isEmpty, category.code)
            }
        }
        XCTAssertTrue(KikiRelationshipVisuals.strokes(for: "UNAVAILABLE").isEmpty)
        XCTAssertTrue(KikiRelationshipVisuals.strokes(for: "NONE").isEmpty)
        XCTAssertTrue(KikiRelationshipVisuals.strokes(for: "OTHER").isEmpty)
        XCTAssertEqual(KikiRelationshipMode.allCases, [.bazi, .zodiac, .mbti])
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

    func testFixedStageBudgetFitsAllSeatsAndKeepsEveryAdjacentCurve() throws {
        for (width, budget): (CGFloat, CGFloat) in [(284, 244), (284, 250), (354, 350), (394, 430), (440, 600)] {
            let layout = KikiRelationshipStageLayout(width: width, maxHeight: budget)
            let geometry = layout.geometry
            XCTAssertLessThanOrEqual(layout.height, budget)
            XCTAssertEqual(layout.footerHeight, max(44, CGFloat(ceil(7.0 / Double(layout.legendColumns))) * 18 - 4))
            XCTAssertEqual(layout.legendWidth + 10 + KikiRelationshipStageLayout.selectorWidth, width)
            for count in 1...8 {
                let points = (0..<count).map { index in
                    geometry.point(angle: -.pi / 2 + Double(index) * 2 * .pi / Double(count), radius: count == 1 ? 0 : 1)
                }
                for point in points {
                    let bounds = CGRect(x: point.x - geometry.cellWidth / 2,
                                        y: point.y - geometry.avatarSize / 2 - 3,
                                        width: geometry.cellWidth, height: geometry.cellHeight)
                    XCTAssertGreaterThanOrEqual(bounds.minX, 0)
                    XCTAssertGreaterThanOrEqual(bounds.minY, 0)
                    XCTAssertLessThanOrEqual(bounds.maxX, geometry.width)
                    XCTAssertLessThanOrEqual(bounds.maxY, geometry.height)
                    // Footer starts after the complete bottom nickname/tag.
                    XCTAssertLessThan(bounds.maxY, geometry.height + KikiRelationshipStageLayout.footerSpacing)
                }
                guard count > 1 else { continue }
                for index in points.indices {
                    let next = points[(index + 1) % count]
                    for stroke in KikiRelationshipVisuals.strokes(for: "MIXED") {
                        XCTAssertNotNil(KikiRelationshipCurve.make(from: points[index], to: next,
                            center: geometry.center, radius: geometry.radius, trim: geometry.edgeTrim,
                            pairID: "adjacent-\(index)", lane: stroke.lane), "\(width)x\(budget), \(count)人")
                    }
                }
            }
        }
    }

    func testEveryModeAndOccupantCountKeepsCaptionRectanglesClearOfAvatarsAndEachOther() {
        for (width, budget): (CGFloat, CGFloat) in [(284, 244), (284, 250), (339, 300), (354, 350), (394, 430), (440, 600)] {
            let geometry = KikiRelationshipStageLayout(width: width, maxHeight: budget).geometry
            for mode in KikiRelationshipMode.allCases {
                for count in 1...8 {
                    let ids = (0..<count).map { "seat-\($0)" }
                    var motion = KikiRelationshipMotion()
                    motion.retarget(orderedIDs: ids, at: .now, animated: false)
                    let frame = motion.frame(at: .now)
                    let tags = Dictionary(uniqueKeysWithValues: ids.map { ($0, mode == .mbti ? "INFJ" : "处女座") })
                    let result = KikiRelationshipLabelPlacement.resolve(geometry: geometry, frame: frame, mode: mode, tags: tags)
                    XCTAssertTrue(result.unresolvedIDs.isEmpty, "\(width)x\(budget), \(mode), \(count)人")
                    assertClearCaptions(result, geometry: geometry, frame: frame)
                    if width == 394, count == 8 {
                        XCTAssertTrue(result.offsets.values.allSatisfy { $0 == .zero }, "430pt保留原有宽裕布局")
                    }
                    for id in ids {
                        guard let offset = result.offsets[id] else { return XCTFail("Missing caption offset") }
                        let tag = mode == .bazi ? nil : tags[id]
                        let shape = KikiRelationshipSeatHitShape(avatarHeight: geometry.avatarSize + 6,
                            nicknameGap: geometry.isCompact ? 3 : 6,
                            labelHeight: KikiRelationshipSeatLabelLayout.plateHeight(mode: mode, value: tag, compact: geometry.isCompact),
                            labelOffset: offset)
                        let path = shape.path(in: CGRect(x: 0, y: 0, width: geometry.cellWidth, height: geometry.avatarSize + 6))
                        let captionCenter = CGPoint(x: geometry.cellWidth / 2 + offset.width,
                            y: geometry.avatarSize + 6 + (geometry.isCompact ? 3 : 6)
                                + KikiRelationshipSeatLabelLayout.plateHeight(mode: mode, value: tag, compact: geometry.isCompact) / 2 + offset.height)
                        XCTAssertTrue(path.contains(captionCenter), "移开的昵称和标签仍能点开对应用户")
                    }
                }
            }
        }
    }

    func testCaptionTargetsRemainClearThroughoutInterruptedSeatReflow() {
        let geometry = KikiRelationshipStageLayout(width: 339, maxHeight: 300).geometry
        let start = Date(timeIntervalSince1970: 8_000)
        var motion = KikiRelationshipMotion()
        motion.retarget(orderedIDs: (0..<5).map { "seat-\($0)" }, at: start, animated: false)
        motion.retarget(orderedIDs: (0..<8).map { "seat-\($0)" }, at: start, animated: true)
        var previous: [String: CGSize] = [:]
        for step in 0...10 {
            let date = start.addingTimeInterval(Double(step) * 0.05)
            if step == 4 { motion.retarget(orderedIDs: ["seat-0", "seat-2", "seat-5"], at: date, animated: true) }
            let frame = motion.frame(at: date)
            let tags = Dictionary(uniqueKeysWithValues: frame.keys.map { ($0, "INFJ") })
            let result = KikiRelationshipLabelPlacement.resolve(geometry: geometry, frame: frame, mode: .mbti, tags: tags, previous: previous)
            XCTAssertTrue(result.unresolvedIDs.isEmpty)
            assertClearCaptions(result, geometry: geometry, frame: frame)
            previous = result.offsets
        }
    }

    private func assertClearCaptions(_ result: KikiRelationshipLabelPlacement.Result,
                                     geometry: KikiRelationshipStageGeometry,
                                     frame: [String: KikiRelationshipMotion.Point], file: StaticString = #filePath, line: UInt = #line) {
        let bounds = CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        for (id, rect) in result.rectangles {
            XCTAssertTrue(bounds.contains(rect), id, file: file, line: line)
            for (otherID, point) in frame where point.opacity > 0.01 {
                XCTAssertFalse(rect.intersects(geometry.avatarRect(at: geometry.point(point))),
                               "\(id) caption covers \(otherID) avatar", file: file, line: line)
            }
            for (otherID, other) in result.rectangles where otherID != id {
                XCTAssertFalse(rect.intersects(other), "\(id) caption covers \(otherID) caption", file: file, line: line)
            }
        }
    }

    func testHiddenCategoriesNeverProduceLinesLegendOrCurrentPairCards() {
        let a = KikiRelationshipSeat(slot: .init(index: 1, userID: "a", locked: false, audioLocked: false),
                                     member: member("a", seat: 1, online: true))
        let b = KikiRelationshipSeat(slot: .init(index: 2, userID: "b", locked: false, audioLocked: false),
                                     member: member("b", seat: 2, online: true))
        for (mode, hidden, shown): (KikiRelationshipMode, String, String) in [(.bazi, "NONE", "MIXED"), (.mbti, "OTHER", "GOLDEN")] {
            let hiddenPair = KikiStageRelationshipPair(a: a, b: b, summary: .init(code: hidden, label: hidden, description: hidden))
            let shownPair = KikiStageRelationshipPair(a: a, b: b, summary: .init(code: shown, label: shown, description: shown))
            XCTAssertFalse(KikiRelationshipCategory.isDisplayed(hidden, in: mode))
            XCTAssertFalse(KikiRelationshipCategory.categories(for: mode).contains { $0.code == hidden })
            XCTAssertTrue(KikiRelationshipVisuals.strokes(for: hidden).isEmpty)
            XCTAssertTrue(KikiRelationshipDetails.displayedPairs([hiddenPair], in: mode).isEmpty)
            XCTAssertEqual(KikiRelationshipDetails.displayedPairs([shownPair], in: mode).map(\.code), [shown])
            XCTAssertFalse(KikiRelationshipCategory.isDisplayed("UNAVAILABLE", in: mode))
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
        XCTAssertEqual(KikiRelationshipSeatLabelLayout.plateHeight(mode: .bazi, value: nil), 14)
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
        let scenarios: [(String, CGFloat, CGFloat, CGFloat, Int, KikiRelationshipMode, ColorScheme)] = [
            ("small-eight-bazi-light", 320, 568, 250, 8, .bazi, .light),
            ("small-eight-zodiac-dark", 320, 568, 250, 8, .zodiac, .dark),
            ("small-eight-mbti-dark", 320, 568, 250, 8, .mbti, .dark),
            ("small-eight-long-zodiac-dark", 320, 568, 250, 8, .zodiac, .dark),
            ("small-eight-long-mbti-dark", 320, 568, 250, 8, .mbti, .dark),
            ("supported-small-eight-long-zodiac-dark", 375, 667, 300, 8, .zodiac, .dark),
            ("supported-small-eight-long-mbti-dark", 375, 667, 300, 8, .mbti, .dark),
            ("small-one-bazi-light", 320, 568, 250, 1, .bazi, .light),
            ("small-empty-zodiac-dark", 320, 568, 250, 0, .zodiac, .dark),
            ("phone-eight-mbti-dark", 390, 844, 350, 8, .mbti, .dark),
            ("phone-eight-zodiac-light", 390, 844, 350, 8, .zodiac, .light),
            ("phone-eight-long-zodiac-dark", 390, 844, 350, 8, .zodiac, .dark),
            ("phone-eight-long-mbti-dark", 390, 844, 350, 8, .mbti, .dark),
            ("phone-one-bazi-dark", 390, 844, 350, 1, .bazi, .dark),
            ("phone-one-mbti-dark", 390, 844, 350, 1, .mbti, .dark),
            ("phone-one-zodiac-dark", 390, 844, 350, 1, .zodiac, .dark),
            ("phone-two-mixed-bazi-light", 390, 844, 350, 2, .bazi, .light),
            ("phone-two-mixed-bazi-dark", 390, 844, 350, 2, .bazi, .dark),
            ("phone-empty-bazi-light", 390, 844, 350, 0, .bazi, .light),
            ("large-eight-bazi-dark", 430, 932, 430, 8, .bazi, .dark),
            ("large-eight-zodiac-dark", 430, 932, 430, 8, .zodiac, .dark),
            ("large-eight-long-zodiac-dark", 430, 932, 430, 8, .zodiac, .dark),
            ("large-eight-long-mbti-dark", 430, 932, 430, 8, .mbti, .dark),
            ("ipad-eight-bazi-dark", 744, 1133, 600, 8, .bazi, .dark)
        ]
        let names = ["青禾", "知夏", "晚晴", "南风", "星野", "听雨", "望舒", "阿岚"]
        let longNames = ["今天也想好好听你说话", "北方有个爱看星星的人", "夜里的小岛总有温柔晚风", "周末一起去很远的地方散步",
                         "夏日限定的橘子汽水", "清晨第一缕阳光和你", "云端收藏了很多有趣故事", "山海之间慢慢寻找新朋友"]
        let mbti = ["INFJ", "ENFP", "ISFJ", "ENTP", "ISTP", "INTJ", "ENFJ", "ESTP"]
        let zodiac = ["处女座", "狮子座", "双鱼座", "双子座", "金牛座", "射手座", "白羊座", "双鱼座"]
        let output = URL(fileURLWithPath: "/tmp/kiki-relationship-stage-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, viewport, viewportHeight, stageBudget, count, mode, scheme) in scenarios {
            let displayNames = name.contains("long") ? longNames : names
            let occupants = (0..<count).map { index in
                let id = "fixture-\(index)"
                let person = KikiRoomMember(userID: id, name: displayNames[index], avatarIndex: index, avatarURL: nil,
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
            let layout = KikiRelationshipStageLayout(width: min(440, viewport - 36), maxHeight: stageBudget)
            let geometry = layout.geometry
            let circle = KikiRelationshipCircle(geometry: geometry, seats: occupants, activeIDs: Set(occupants.map(\.id)),
                frame: motion.frame(at: .now), pairs: pairs, profiles: profiles,
                participants: [], localUserID: occupants.first?.id, mode: mode,
                edgeOpacity: 1, onOpenPerson: { _ in })
            let content = VStack(spacing: 12) {
                Text("圆形麦位").font(.headline).padding(.top, 18)
                VStack(spacing: KikiRelationshipStageLayout.footerSpacing) {
                    circle
                    KikiRelationshipStageFooter(layout: layout, selection: .constant(mode))
                }
                .frame(width: layout.width, height: layout.height, alignment: .top)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KikiPalette.background)
            .preferredColorScheme(scheme)
            let host = UIHostingController(rootView: content)
            host.safeAreaRegions = SafeAreaRegions.container
            window.rootViewController = host
            window.frame = CGRect(x: 0, y: 0, width: viewport, height: viewportHeight)
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
        let layout = KikiRelationshipStageLayout(width: 354, maxHeight: 350)
        VStack(spacing: KikiRelationshipStageLayout.footerSpacing) {
            KikiRelationshipCircle(geometry: layout.geometry, seats: [seat], activeIDs: [seat.id],
                frame: [seat.id: .init(angle: -.pi / 2, radius: 0, opacity: 1)], pairs: [],
                profiles: [.init(userID: seat.id, mbtiType: "INFJ", zodiacSign: "处女座")],
                participants: [], localUserID: seat.id, mode: state.mode, edgeOpacity: 1, onOpenPerson: { _ in })
            KikiRelationshipStageFooter(layout: layout, selection: $state.mode)
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .background(KikiPalette.background)
    }
}
