import SwiftUI
import UIKit

/// An occupant keeps their identity when the ordered-seat service changes their
/// number. Offline occupants remain here during the server's reconnect grace.
struct KikiRelationshipSeat: Equatable, Identifiable {
    let slot: KikiRoomSeat
    let member: KikiRoomMember
    var id: String { member.userID }

    static func occupants(in state: KikiRoomState?) -> [Self] {
        guard let state else { return [] }
        return state.seats.sorted { $0.index < $1.index }.compactMap { slot in
            guard let member = state.member(on: slot) else { return nil }
            return Self(slot: slot, member: member)
        }
    }
}

/// One clock drives both the avatar positions and every relationship endpoint.
/// Retargeting samples the current presentation, including an interrupted move.
struct KikiRelationshipMotion {
    struct Point: Equatable {
        var angle: Double
        var radius: Double = 1
        var opacity: Double
    }
    private struct Track {
        let from: Point
        let to: Point
    }
    private var tracks: [String: Track] = [:]
    private(set) var startedAt = Date.distantPast
    private(set) var duration: TimeInterval = 0

    func frame(at date: Date) -> [String: Point] {
        let fraction = duration > 0 ? min(1, max(0, date.timeIntervalSince(startedAt) / duration)) : 1
        let progress = fraction * fraction * (3 - 2 * fraction)
        return tracks.mapValues { track in
            Point(angle: track.from.angle + (track.to.angle - track.from.angle) * progress,
                  radius: track.from.radius + (track.to.radius - track.from.radius) * progress,
                  opacity: track.from.opacity + (track.to.opacity - track.from.opacity) * progress)
        }
    }

    mutating func retarget(orderedIDs: [String], at date: Date, animated: Bool) {
        let current = frame(at: date)
        var next: [String: Track] = [:]
        for (index, id) in orderedIDs.enumerated() {
            let target = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(1, orderedIDs.count))
            let radialTarget = orderedIDs.count == 1 ? 0.0 : 1.0
            let from = current[id] ?? Point(angle: target, radius: radialTarget, opacity: 0)
            var travel = (target - from.angle).truncatingRemainder(dividingBy: 2 * .pi)
            if travel > .pi { travel -= 2 * .pi }
            if travel < -.pi { travel += 2 * .pi }
            let to = Point(angle: from.angle + travel, radius: radialTarget, opacity: 1)
            next[id] = Track(from: animated ? from : to, to: to)
        }
        if animated {
            for (id, point) in current where !orderedIDs.contains(id) && point.opacity > 0 {
                next[id] = Track(from: point, to: Point(angle: point.angle, radius: point.radius, opacity: 0))
            }
        }
        tracks = next
        startedAt = date
        duration = animated ? 0.5 : 0
    }

    mutating func settle() {
        tracks = tracks.filter { $0.value.to.opacity > 0 }.mapValues { Track(from: $0.to, to: $0.to) }
        duration = 0
    }
}

struct KikiRelationshipStageGeometry {
    let width: CGFloat
    var avatarSize: CGFloat { width < 320 ? 46 : (width >= 400 ? 58 : 52) }
    var cellWidth: CGFloat { min(92, max(70, width / 4)) }
    var cellHeight: CGFloat { avatarSize + 43 }
    var height: CGFloat { width + 36 }
    var radius: CGFloat { max(0, (width - cellWidth) / 2 - 4) }
    var center: CGPoint { CGPoint(x: width / 2, y: width / 2) }
    func point(angle: Double, radius fraction: Double = 1) -> CGPoint {
        CGPoint(x: center.x + radius * fraction * cos(angle), y: center.y + radius * fraction * sin(angle))
    }
    func point(_ value: KikiRelationshipMotion.Point) -> CGPoint { point(angle: value.angle, radius: value.radius) }
    func cellCenter(angle: Double, radius fraction: Double = 1) -> CGPoint {
        let avatar = point(angle: angle, radius: fraction)
        return CGPoint(x: avatar.x, y: avatar.y + cellHeight / 2 - (avatarSize / 2 + 3))
    }
}

struct KikiRelationshipCategory: Identifiable {
    let code: String
    let label: String
    var id: String { code }

    static func categories(for mode: KikiRelationshipMode) -> [Self] {
        let names: [(String, String)]
        switch mode {
        case .bazi:
            names = [("HARMONY_ONLY", "相合"), ("CONFLICT_ONLY", "相冲"), ("MIXED", "合冲并见"),
                     ("NONE", "未命中直接合冲")]
        case .mbti:
            names = [("GOLDEN", "黄金配对"), ("SILVER", "白银配对"), ("PEDAGOGUE", "师生配对"),
                     ("SAME_TYPE", "同类型"), ("OTHER", "其他组合")]
        case .zodiac:
            names = [("SAME_SIGN", "同星座"), ("ADJACENT", "相邻星座"), ("SEXTILE", "六分"),
                     ("SQUARE", "刑"), ("TRINE", "拱"), ("QUINCUNX", "梅花"), ("OPPOSITION", "对宫")]
        }
        return (names + [("UNAVAILABLE", "暂无法展示关系")]).map { Self(code: $0.0, label: $0.1) }
    }
}

struct KikiStageRelationshipPair: Identifiable {
    let a: KikiRelationshipSeat
    let b: KikiRelationshipSeat
    let summary: KikiRelationshipSummary?
    var id: String { [a.id, b.id].sorted().joined(separator: "|") }
    var code: String { summary?.code ?? "UNAVAILABLE" }
    var label: String { code == "UNAVAILABLE" ? "暂无法展示关系" : (summary?.label ?? "暂无法展示关系") }
}

private struct KikiRelationshipFetchScope: Equatable {
    let roomID: String?
    let userID: String?
    let accountID: String?
    let privacyRevision: Int
    let roomRevision: Int
    let seats: String
    let active: Bool
    let refresh: UUID
}

/// The existing voice room owns membership, permissions and speaking state.
/// This view only presents its accepted snapshot and server-computed summaries.
struct KikiRelationshipStage: View {
    @ObservedObject var rtc: KikiRTCService
    let width: CGFloat
    let onOpenPerson: (String) -> Void
    let onRequestSeat: () -> Void
    let onEndComposing: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("kiki.room.relationship.mode") private var storedMode = KikiRelationshipMode.bazi.rawValue
    @State private var relationships: KikiRoomRelationships?
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var refreshID = UUID()
    @State private var showsRelationships = false
    @State private var motion = KikiRelationshipMotion()
    @State private var retainedSeats: [String: KikiRelationshipSeat] = [:]
    @State private var motionGeneration = UUID()
    @State private var isMoving = false
    @State private var edgeOpacity = 0.0
    @State private var edgeRevealID = UUID()

    private var mode: KikiRelationshipMode { KikiRelationshipMode(rawValue: storedMode) ?? .bazi }
    private var seats: [KikiRelationshipSeat] {
        guard rtc.roomState?.room.id == rtc.currentRoomID else { return [] }
        return KikiRelationshipSeat.occupants(in: rtc.roomState)
    }
    private var seatSignature: String { seats.map { "\($0.id):\($0.slot.index)" }.joined(separator: "|") }
    private var scope: KikiRelationshipFetchScope {
        .init(roomID: rtc.currentRoomID, userID: rtc.roomState?.me.userID,
              accountID: rtc.socialStore?.userID, privacyRevision: rtc.socialStore?.socialPrivacyRevision ?? 0,
              roomRevision: rtc.roomState?.revision ?? -1, seats: seatSignature,
              active: scenePhase == .active && !rtc.isVoiceRoomMinimized && rtc.canUseRoom
                  && rtc.roomState?.room.id == rtc.currentRoomID,
              refresh: refreshID)
    }
    private var pairs: [KikiStageRelationshipPair] {
        let returned = Dictionary((relationships?.pairs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return seats.enumerated().flatMap { index, a in
            seats.dropFirst(index + 1).map { b in
                let key = [a.id, b.id].sorted().joined(separator: "|")
                return KikiStageRelationshipPair(a: a, b: b, summary: returned[key]?.summary(for: mode))
            }
        }
    }
    private var currentSeatMap: [String: KikiRelationshipSeat] {
        Dictionary(seats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("关系模式", selection: $storedMode) {
                ForEach(KikiRelationshipMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            .accessibilityIdentifier("livekit.room.relationship.mode")

            circle
            KikiRelationshipLegend(mode: mode)
                .frame(maxWidth: 440)
            relationshipTools
        }
        .onChange(of: seatSignature, initial: true) { _, _ in updateMotion() }
        .onChange(of: rtc.currentRoomID) { _, _ in
            relationships = nil
            retainedSeats = [:]
            motion = KikiRelationshipMotion()
            showsRelationships = false
            updateMotion()
        }
        .onChange(of: storedMode) { _, _ in
            revealEdges()
        }
        .onChange(of: relationships?.revision) { _, _ in
            revealEdges()
        }
        .onChange(of: showsRelationships) { _, shown in if shown { onEndComposing() } }
        .onChange(of: reduceMotion) { _, reduced in if reduced { finishMotion() } }
        .task(id: motionGeneration) {
            guard isMoving else { return }
            do { try await Task.sleep(for: .milliseconds(510)) } catch { return }
            finishMotion()
        }
        .task(id: scope) { await pollRelationships(expected: scope) }
        .task(id: edgeRevealID) {
            guard relationships != nil else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.22)) { edgeOpacity = 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .kikiRelationshipProfileDidChange)) { _ in
            relationships = nil
            refreshID = UUID()
        }
        .onDisappear {
            relationships = nil
        }
        .sheet(isPresented: $showsRelationships) { relationshipsSheet }
    }

    private var circle: some View {
        let geometry = KikiRelationshipStageGeometry(width: min(440, max(240, width)))
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isMoving)) { timeline in
            KikiRelationshipCircle(geometry: geometry,
                seats: retainedSeats.keys.sorted().compactMap { currentSeatMap[$0] ?? retainedSeats[$0] },
                activeIDs: Set(seats.map(\.id)), frame: motion.frame(at: timeline.date), pairs: pairs,
                profiles: relationships?.profiles ?? [], participants: rtc.participants,
                localUserID: rtc.roomState?.me.userID, mode: mode,
                edgeOpacity: edgeOpacity, onOpenPerson: onOpenPerson)
        }
        .overlay {
            if rtc.roomState == nil {
                ProgressView("正在同步麦位").font(.caption)
            } else if seats.isEmpty && retainedSeats.isEmpty {
                Button(action: onRequestSeat) {
                    Label("申请上麦", systemImage: "mic.badge.plus")
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 12)
                }
                .buttonStyle(.bordered)
                .disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("livekit.room.relationship.circle")
    }

    private var relationshipTools: some View {
        HStack(spacing: 8) {
            if isLoading && relationships == nil && seats.count > 1 {
                ProgressView().controlSize(.mini)
                Text("正在连接关系").font(.caption).foregroundStyle(KikiPalette.secondary)
            } else if loadFailed && seats.count > 1 {
                Button("重新获取关系") { refreshID = UUID() }.font(.caption)
            }
            Spacer(minLength: 0)
            Button { showsRelationships = true } label: {
                Label("关系说明", systemImage: "info.circle")
                    .font(.caption).frame(minHeight: 44)
            }
            .accessibilityIdentifier("livekit.room.relationship.details")
        }
        .tint(KikiPalette.purple)
        .frame(maxWidth: 440)
    }

    private var relationshipsSheet: some View {
        KikiRelationshipDetails(mode: mode, pairs: pairs) { showsRelationships = false }
            .kikiRoomSheet()
    }

    private func updateMotion() {
        let current = currentSeatMap
        retainedSeats.merge(current) { _, new in new }
        motion.retarget(orderedIDs: seats.map(\.id), at: Date(), animated: !reduceMotion && !retainedSeats.isEmpty)
        isMoving = !reduceMotion
        motionGeneration = UUID()
        if reduceMotion { finishMotion() }
    }

    private func finishMotion() {
        motion.settle()
        retainedSeats = currentSeatMap
        isMoving = false
    }

    private func revealEdges() {
        edgeOpacity = 0
        edgeRevealID = UUID()
    }

    @MainActor private func pollRelationships(expected: KikiRelationshipFetchScope) async {
        // Room revisions do not distinguish membership from a privacy opt-out.
        // Keep departing avatars for their motion, but never retain relationship
        // evidence across scope invalidation merely to animate departing edges.
        relationships = nil
        isLoading = false
        loadFailed = false
        guard expected.active, let roomID = expected.roomID, let store = rtc.socialStore else { return }
        while !Task.isCancelled {
            isLoading = true
            do {
                let response = try await store.roomRelationships(roomID: roomID)
                try Task.checkCancellation()
                guard scope == expected, response.roomID == roomID else { return }
                // A server snapshot from before the accepted room revision may
                // include a just-revoked relationship. Never retain it.
                guard response.roomRevision >= expected.roomRevision else {
                    relationships = nil
                    throw KikiAPIError.invalidResponse
                }
                relationships = response
                loadFailed = false
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, scope == expected else { return }
                relationships = nil
                loadFailed = true
            }
            isLoading = false
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard scope == expected else { return }
        }
    }

}

/// A deterministic bow for each pair. It is evaluated from the same presentation
/// points as the avatars, so interrupted seat motion never detaches a curve.
struct KikiRelationshipCurve {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    var path: Path {
        var value = Path()
        value.move(to: start)
        value.addQuadCurve(to: end, control: control)
        return value
    }

    static func make(from a: CGPoint, to b: CGPoint, center: CGPoint, radius: CGFloat,
                     trim: CGFloat, pairID: String, lane: CGFloat = 0) -> Self? {
        let dx = b.x - a.x, dy = b.y - a.y
        let distance = hypot(dx, dy)
        guard radius > 0, distance > trim * 2 + 4 else { return nil }
        let normal = CGPoint(x: -dy / distance, y: dx / distance)
        let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let hash = pairID.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        // The side stays fixed for the pair, including when a moving chord
        // crosses the center. Choosing an inward side from each frame would
        // suddenly flip an arc halfway through a seat reflow.
        let sign: CGFloat = hash & 1 == 0 ? 1 : -1
        let visibleLength = distance - trim * 2
        let variation = CGFloat((hash >> 1) % 5) / 4
        // `lane` is the visible midpoint offset, not a small addition to an
        // already-large bow. Mixed relationships therefore occupy opposite
        // sides of the chord, with a 20pt gap on normal-length connections.
        let gentleBend = min(10, 5 + visibleLength * 0.018 + variation)
        let midpointOffset = lane == 0
            ? sign * min(gentleBend, visibleLength * 0.24)
            : sign * (lane < 0 ? -1 : 1) * min(abs(lane), visibleLength * 0.30)
        let control = CGPoint(x: midpoint.x + normal.x * midpointOffset * 2,
                              y: midpoint.y + normal.y * midpointOffset * 2)
        // Trim on the original chord. This keeps both colors attached at the
        // same avatar boundary and makes the visible sagitta predictable.
        return Self(start: CGPoint(x: a.x + dx / distance * trim,
                                   y: a.y + dy / distance * trim),
                    control: control,
                    end: CGPoint(x: b.x - dx / distance * trim,
                                 y: b.y - dy / distance * trim))
    }
}

struct KikiRelationshipStroke {
    let color: Color
    let dash: [CGFloat]
    var lane: CGFloat = 0
}

/// One visual vocabulary is shared by the actual curves, the visible legend and
/// the read-only explanations. Every known MBTI/zodiac category has a line.
enum KikiRelationshipVisuals {
    static let lineWidth: CGFloat = 2.6

    private static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }

    static func color(for code: String) -> Color {
        switch code {
        case "HARMONY_ONLY", "TRINE", "SAME_TYPE": return adaptive(0x21836C, 0x70D9B7)
        case "CONFLICT_ONLY", "SQUARE": return adaptive(0xCA6248, 0xFA9B7C)
        case "GOLDEN": return adaptive(0xAF7B13, 0xF0C76A)
        case "SILVER": return adaptive(0x477CC5, 0x98C3FF)
        case "PEDAGOGUE", "QUINCUNX": return adaptive(0xA05EB9, 0xD5A0EC)
        case "SAME_SIGN", "MIXED": return KikiPalette.purple
        case "SEXTILE": return adaptive(0x2C8B9D, 0x7FD9E7)
        case "ADJACENT": return adaptive(0x6D74BA, 0xB1B8FF)
        case "OPPOSITION": return adaptive(0xBE567E, 0xF49EC2)
        default: return adaptive(0x797F93, 0xB6BED0)
        }
    }

    static func strokes(for code: String) -> [KikiRelationshipStroke] {
        switch code {
        case "MIXED": return [.init(color: color(for: "HARMONY_ONLY"), dash: [], lane: -10),
                              .init(color: color(for: "CONFLICT_ONLY"), dash: [6, 4], lane: 10)]
        case "HARMONY_ONLY", "GOLDEN", "SAME_SIGN", "TRINE": return [.init(color: color(for: code), dash: [])]
        case "SILVER", "ADJACENT": return [.init(color: color(for: code), dash: [10, 4])]
        case "CONFLICT_ONLY", "PEDAGOGUE", "SQUARE", "SEXTILE": return [.init(color: color(for: code), dash: [6, 4])]
        case "SAME_TYPE", "QUINCUNX": return [.init(color: color(for: code), dash: [1.2, 4.5])]
        case "OTHER", "OPPOSITION": return [.init(color: color(for: code), dash: [9, 3, 1.5, 3])]
        case "NONE": return [.init(color: color(for: code), dash: [2, 6])]
        default: return []
        }
    }

    static func legendTitle(for category: KikiRelationshipCategory) -> String {
        category.code == "NONE" ? "无直接合冲" : category.label
    }

    static func explanation(for code: String) -> String {
        switch code {
        case "HARMONY_ONLY": return "默契合拍。聊天有种接得上话的感觉，共同兴趣很适合开场。偶尔分享一点不同想法，让熟悉的节奏也有新鲜感。"
        case "CONFLICT_ONLY": return "火花碰撞。各有主见，聊天容易冒出火花，也可能忍不住较劲。不同意见先说清楚，把争输赢换成一起找有趣的答案。"
        case "MIXED": return "欢喜冤家。聊得来，也容易斗嘴，互动里常有一点小较劲。享受彼此懂的部分，较劲时缓一拍，把真心话直接说出来。"
        case "NONE": return "慢热探索。默契适合慢慢培养，先别急着判断合不合拍。从共同话题或小游戏开始，多聊几次，再发现你们独有的节奏。"
        case "GOLDEN": return "互补来电。不同的思路能给聊天添些新鲜感，适合互相接住新点子。多问问对方为什么这样想，让差异成为有趣的话题。"
        case "SILVER": return "同频共鸣。关注的话题有些相近，接话亲切，又能听到不同角度。先聊共同兴趣，也给对方的小习惯和独特想法留点空间。"
        case "PEDAGOGUE": return "灵感搭子。适合交换思路，轮流当彼此的小老师。少一点说教，多一点好奇，问问对方的理由，让聊天多出有趣的新发现。"
        case "SAME_TYPE": return "同款默契。偏好相近，聊天像遇到熟悉的脑回路，接话很有亲切感。也多聊聊各自不同的经历，让相似的组合有新故事。"
        case "OTHER": return "自由搭配。你们没有固定的相处剧本，合不合拍可以边聊边发现。从共同兴趣开始，试试不同话题，找到自己的聊天节奏。"
        case "SAME_SIGN": return "同频搭子。熟悉感是这组的聊天关键词，共同喜好很适合开场。别急着以为已经懂了对方，也听听那些不一样的小故事。"
        case "ADJACENT": return "好奇搭子。既有一点亲近感，也有值得好奇的不同之处。交换喜欢的小事和日常习惯，节奏不同时慢一点，给新鲜感留些空间。"
        case "SEXTILE": return "轻松接球。适合一来一回地接话，轻松互动就是这组的亮点。主动递个新话题或小游戏，也给对方接球的时间，聊天更有趣。"
        case "SQUARE": return "火花搭子。聊天有来有往，也容易因为不同想法斗嘴较劲。把想法说清楚，少让对方猜，一起完成个小挑战，让火花变成乐趣。"
        case "TRINE": return "舒服合拍。相处的关键词是自在，聊天不妨跟着舒服的节奏走。偶尔主动关心，或一起尝试点新鲜事，让轻松的互动多点温度。"
        case "QUINCUNX": return "新奇磨合。想法和习惯可能不在同一频道，好奇心能打开新话题。把期待说具体，给彼此一点调整的时间，慢慢找到共同节奏。"
        case "OPPOSITION": return "反差来电。不同的表达和习惯让互动有张力，也有互补的想象空间。先听懂另一边的想法，再一起找平衡，别急着把对话变成辩论。"
        default: return "稍后揭晓。当前还不能展示这组关系的介绍，先把注意力留给聊天。稍后刷新再看看，你们的相处也可以从一个有趣的话题开始。"
        }
    }

    static func friendlyTitle(for code: String) -> String {
        String(explanation(for: code).prefix { $0 != "。" })
    }

    static func friendlyBody(for code: String) -> String {
        let text = explanation(for: code)
        guard let end = text.firstIndex(of: "。") else { return text }
        return String(text[text.index(after: end)...])
    }

}

struct KikiRelationshipLineSample: View {
    let code: String
    var body: some View {
        Canvas { context, size in
            for stroke in KikiRelationshipVisuals.strokes(for: code) {
                let baseline = size.height / 2
                let bend: CGFloat = stroke.lane == 0 ? -2 : (stroke.lane < 0 ? -2.6 : 2.6)
                var path = Path()
                path.move(to: CGPoint(x: 1, y: baseline))
                path.addQuadCurve(to: CGPoint(x: size.width - 1, y: baseline),
                                  control: CGPoint(x: size.width / 2, y: baseline + bend * 2))
                context.stroke(path, with: .color(stroke.color),
                               style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: stroke.dash))
            }
        }.accessibilityHidden(true)
    }
}

struct KikiRelationshipLegend: View {
    let mode: KikiRelationshipMode
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(KikiRelationshipCategory.categories(for: mode).filter { $0.code != "UNAVAILABLE" }) { category in
                HStack(spacing: 5) {
                    KikiRelationshipLineSample(code: category.code).frame(width: 24, height: 15)
                    Text(KikiRelationshipVisuals.legendTitle(for: category))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(KikiPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(KikiRelationshipVisuals.legendTitle(for: category))
            }
        }
        .padding(.horizontal, 4).padding(.top, 2)
        .accessibilityIdentifier("livekit.room.relationship.legend")
    }
}

/// Read-only, entertainment-oriented explanations. The same short copy is
/// returned by the server; the original relationship term remains a caption.
struct KikiRelationshipDetails: View {
    let mode: KikiRelationshipMode
    let pairs: [KikiStageRelationshipPair]
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !pairs.isEmpty {
                        Text("当前配对").font(.headline).padding(.top, 4)
                        ForEach(pairs) { pair in
                            VStack(alignment: .leading, spacing: 12) {
                                Text("\(pair.a.member.name) · \(pair.b.member.name)")
                                    .font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
                                explanation(code: pair.code, label: pair.code == "NONE" ? "无直接合冲" : pair.label)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                        }
                    }
                    Text("全部关系图示").font(.headline).padding(.top, pairs.isEmpty ? 4 : 8)
                    ForEach(KikiRelationshipCategory.categories(for: mode).filter { $0.code != "UNAVAILABLE" }) { category in
                        explanation(code: category.code, label: KikiRelationshipVisuals.legendTitle(for: category))
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                    Text("娱乐配对，开心参考")
                        .font(.caption).foregroundStyle(KikiPalette.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .padding(16)
            }
            .background(KikiPalette.background)
            .navigationTitle("\(mode.title)关系说明").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", action: onDismiss) }
            }
        }
    }

    private func explanation(code: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                KikiRelationshipLineSample(code: code).frame(width: 34, height: 18)
                Text(label).font(.caption.weight(.medium)).foregroundStyle(KikiPalette.secondary)
            }
            Text(KikiRelationshipVisuals.friendlyTitle(for: code))
                .font(.title3.weight(.semibold)).foregroundStyle(KikiPalette.text)
            Text(KikiRelationshipVisuals.friendlyBody(for: code))
                .font(.subheadline).foregroundStyle(KikiPalette.secondary)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The avatar keeps a fixed anchor while the optional public label unfolds
/// below its nickname. Bazi has no blank label or background placeholder.
enum KikiRelationshipSeatLabelLayout {
    static func tagHeight(mode: KikiRelationshipMode, value: String?) -> CGFloat {
        mode != .bazi && value?.isEmpty == false ? 17 : 0
    }
    static func plateHeight(mode: KikiRelationshipMode, value: String?) -> CGFloat {
        20 + tagHeight(mode: mode, value: value)
    }
}

/// Stateless production renderer, also used by presentation fixtures. Its only
/// relationship inputs are the public result projections returned by the server.
struct KikiRelationshipCircle: View {
    let geometry: KikiRelationshipStageGeometry
    let seats: [KikiRelationshipSeat]
    let activeIDs: Set<String>
    let frame: [String: KikiRelationshipMotion.Point]
    let pairs: [KikiStageRelationshipPair]
    let profiles: [KikiRelationshipPublicProfile]
    let participants: [KikiVoiceParticipant]
    let localUserID: String?
    let mode: KikiRelationshipMode
    let edgeOpacity: Double
    let onOpenPerson: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(RadialGradient(colors: [KikiPalette.purple.opacity(0.015), KikiPalette.purple.opacity(0.065)],
                                     center: .center, startRadius: 0, endRadius: geometry.radius))
                .overlay(Circle().stroke(KikiPalette.purple.opacity(0.36), lineWidth: 2))
                .frame(width: geometry.radius * 2, height: geometry.radius * 2)
                .position(geometry.center)
                .allowsHitTesting(false).accessibilityHidden(true)
            Canvas { context, _ in drawEdges(context: &context) }
                .opacity(edgeOpacity)
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(seats) { occupant in
                if let value = frame[occupant.id] {
                    avatar(occupant)
                        .opacity(value.opacity)
                        .position(geometry.point(value))
                        .allowsHitTesting(activeIDs.contains(occupant.id) && value.opacity > 0.9)
                        .accessibilityHidden(!activeIDs.contains(occupant.id))
                }
            }
        }
        .frame(width: geometry.width, height: geometry.height)
    }

    private func avatar(_ occupant: KikiRelationshipSeat) -> some View {
        let tag = publicTag(for: occupant.id)
        let tagHeight = KikiRelationshipSeatLabelLayout.tagHeight(mode: mode, value: tag)
        let labelAnimation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.24)
        return Button { onOpenPerson(occupant.id) } label: {
            VStack(spacing: 0) {
                KikiRoomSeatTile(slot: occupant.slot, member: occupant.member,
                    participant: participants.first { $0.id == occupant.id },
                    localUserID: localUserID, avatarSize: geometry.avatarSize)
                    .overlay(alignment: .topLeading) {
                        Text("\(occupant.slot.index)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(KikiPalette.secondary)
                            .frame(width: 17, height: 17)
                            .background(KikiPalette.surface.opacity(0.96), in: Circle())
                    }
                ZStack(alignment: .top) {
                    if tagHeight > 0, let tag {
                        Text(tag)
                            .id("\(mode.rawValue):\(tag)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(KikiPalette.lavender).lineLimit(1)
                            .padding(.top, 3)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: tagHeight, alignment: .top)
                .clipped()
            }
            .frame(width: geometry.cellWidth)
            .background(alignment: .top) {
                Circle().fill(KikiPalette.background)
                    .frame(width: geometry.avatarSize + 6, height: geometry.avatarSize + 6)
            }
            .background(alignment: .bottom) {
                Capsule().fill(KikiPalette.background.opacity(0.97))
                    .frame(height: KikiRelationshipSeatLabelLayout.plateHeight(mode: mode, value: tag))
                    .padding(.horizontal, -3).offset(y: 3)
            }
            .animation(labelAnimation, value: mode)
            .animation(labelAnimation, value: tag)
            .contentShape(Rectangle())
        }
        // Position only this stable avatar-sized anchor. The label may change
        // height, but cannot move the avatar or any relationship endpoint.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: geometry.cellWidth, height: geometry.avatarSize + 6, alignment: .top)
        .buttonStyle(.plain)
        .accessibilityLabel("\(occupant.slot.index)号麦，查看\(occupant.member.name)的个人主页")
        .accessibilityIdentifier("livekit.room.relationship.seat.\(occupant.id)")
    }

    private func publicTag(for userID: String) -> String? {
        guard let profile = profiles.first(where: { $0.userID == userID }) else { return nil }
        switch mode { case .bazi: return nil; case .mbti: return profile.mbtiType; case .zodiac: return profile.zodiacSign }
    }

    private func drawEdges(context: inout GraphicsContext) {
        for pair in pairs {
            guard let a = frame[pair.a.id], let b = frame[pair.b.id] else { continue }
            let first = pair.a.id < pair.b.id ? a : b
            let last = pair.a.id < pair.b.id ? b : a
            let start = geometry.point(first), end = geometry.point(last)
            let offline = !pair.a.member.online || !pair.b.member.online
            let opacity = min(a.opacity, b.opacity) * (offline ? 0.68 : 0.94)
            for stroke in KikiRelationshipVisuals.strokes(for: pair.code) {
                guard let curve = KikiRelationshipCurve.make(from: start, to: end, center: geometry.center,
                    radius: geometry.radius, trim: geometry.avatarSize / 2 + 7, pairID: pair.id, lane: stroke.lane) else { continue }
                context.stroke(curve.path, with: .color(stroke.color.opacity(opacity * 0.13)),
                               style: StrokeStyle(lineWidth: 6.5, lineCap: .round, dash: stroke.dash))
                context.stroke(curve.path, with: .color(stroke.color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: KikiRelationshipVisuals.lineWidth,
                                                  lineCap: .round, lineJoin: .round, dash: stroke.dash))
            }
        }
    }
}
