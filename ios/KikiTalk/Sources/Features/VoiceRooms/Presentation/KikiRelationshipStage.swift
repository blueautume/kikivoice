import SwiftUI

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
                  opacity: track.from.opacity + (track.to.opacity - track.from.opacity) * progress)
        }
    }

    mutating func retarget(orderedIDs: [String], at date: Date, animated: Bool) {
        let current = frame(at: date)
        var next: [String: Track] = [:]
        for (index, id) in orderedIDs.enumerated() {
            let target = -Double.pi / 2 + Double(index) * 2 * .pi / Double(max(1, orderedIDs.count))
            let from = current[id] ?? Point(angle: target, opacity: 0)
            var travel = (target - from.angle).truncatingRemainder(dividingBy: 2 * .pi)
            if travel > .pi { travel -= 2 * .pi }
            if travel < -.pi { travel += 2 * .pi }
            let to = Point(angle: from.angle + travel, opacity: 1)
            next[id] = Track(from: animated ? from : to, to: to)
        }
        if animated {
            for (id, point) in current where !orderedIDs.contains(id) && point.opacity > 0 {
                next[id] = Track(from: point, to: Point(angle: point.angle, opacity: 0))
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
    func point(angle: Double) -> CGPoint {
        CGPoint(x: width / 2 + radius * cos(angle), y: width / 2 + radius * sin(angle))
    }
    func cellCenter(angle: Double) -> CGPoint {
        let avatar = point(angle: angle)
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
    var explanation: String {
        code == "UNAVAILABLE" ? "当前暂无法展示这组关系，可稍后再查看。" : (summary?.description ?? "")
    }
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
    @State private var selectedPairID: String?
    @State private var showsRelationships = false
    @State private var showsProfile = false
    @State private var selectedFilter = "ALL"
    @State private var onlyMe = false
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
    private var selectedPair: KikiStageRelationshipPair? { pairs.first { $0.id == selectedPairID } }
    private var visibleListPairs: [KikiStageRelationshipPair] {
        pairs.filter { pair in
            (selectedFilter == "ALL" || pair.code == selectedFilter)
                && (!onlyMe || pair.a.id == rtc.roomState?.me.userID || pair.b.id == rtc.roomState?.me.userID)
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

            if rtc.roomState == nil {
                ProgressView("正在同步麦位")
                    .frame(height: 160).frame(maxWidth: .infinity)
            } else if seats.isEmpty && retainedSeats.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mic.circle").font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(KikiPalette.secondary)
                    Button("申请上麦", action: onRequestSeat)
                        .buttonStyle(.bordered).disabled(!rtc.canUseRoom || rtc.isPerformingRoomAction)
                }.frame(height: 170).frame(maxWidth: .infinity)
            } else {
                circle
            }
            relationshipTools
            if let selectedPair {
                HStack(spacing: 6) {
                    Button { showsRelationships = true } label: {
                        Text("\(selectedPair.a.member.name) · \(selectedPair.b.member.name) · \(selectedPair.label)")
                            .font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                    Spacer(minLength: 0)
                    Button { selectedPairID = nil } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }.accessibilityLabel("取消关系高亮")
                }
                .foregroundStyle(KikiPalette.secondary)
                .accessibilityIdentifier("livekit.room.relationship.selection")
            }
        }
        .onChange(of: seatSignature, initial: true) { _, _ in updateMotion() }
        .onChange(of: rtc.currentRoomID) { _, _ in
            relationships = nil
            selectedPairID = nil
            retainedSeats = [:]
            motion = KikiRelationshipMotion()
            showsRelationships = false
            showsProfile = false
            updateMotion()
        }
        .onChange(of: storedMode) { _, _ in
            selectedFilter = "ALL"
            revealEdges()
        }
        .onChange(of: relationships?.revision) { _, _ in
            revealEdges()
        }
        .onChange(of: showsRelationships) { _, shown in if shown { onEndComposing() } }
        .onChange(of: showsProfile) { _, shown in if shown { onEndComposing() } }
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
            selectedPairID = nil
        }
        .sheet(isPresented: $showsRelationships) { relationshipsSheet }
        .sheet(isPresented: $showsProfile) {
            if let store = rtc.socialStore {
                NavigationStack { KikiRelationshipProfileView(store: store) }
                    .kikiRoomSheet()
            }
        }
    }

    private var circle: some View {
        let geometry = KikiRelationshipStageGeometry(width: min(440, max(240, width)))
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isMoving)) { timeline in
            KikiRelationshipCircle(geometry: geometry,
                seats: retainedSeats.keys.sorted().compactMap { currentSeatMap[$0] ?? retainedSeats[$0] },
                activeIDs: Set(seats.map(\.id)), frame: motion.frame(at: timeline.date), pairs: pairs,
                profiles: relationships?.profiles ?? [], participants: rtc.participants,
                localUserID: rtc.roomState?.me.userID, mode: mode, selectedPairID: selectedPairID,
                edgeOpacity: edgeOpacity, onOpenPerson: onOpenPerson)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("livekit.room.relationship.circle")
    }

    private var relationshipTools: some View {
        HStack(spacing: 8) {
            Group {
                if isLoading && relationships == nil {
                    ProgressView().controlSize(.mini)
                    Text("正在计算关系")
                } else if loadFailed {
                    Button("重新获取") { refreshID = UUID() }
                } else {
                    Text(mode == .bazi ? "实线相合 · 虚线相冲" : "选择配对可高亮关系")
                }
            }
            .font(.caption2).foregroundStyle(KikiPalette.secondary)
            Spacer(minLength: 0)
            if rtc.socialStore != nil {
                Button { showsProfile = true } label: {
                    Image(systemName: "person.crop.circle.badge.plus").frame(width: 44, height: 44)
                }.accessibilityLabel("编辑自己的关系资料")
            }
            Button { showsRelationships = true } label: {
                Text("查看关系").font(.caption.weight(.medium)).frame(minHeight: 44)
            }
            .disabled(seats.count < 2)
            .accessibilityIdentifier("livekit.room.relationship.details")
        }
        .tint(KikiPalette.purple)
        .frame(maxWidth: 440)
    }

    private var relationshipsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Picker("关系类别", selection: $selectedFilter) {
                        Text("全部关系").tag("ALL")
                        ForEach(filterCategories, id: \.code) { item in Text(item.label).tag(item.code) }
                    }
                    Toggle("只看与我相关", isOn: $onlyMe)
                        .disabled(!seats.contains { $0.id == rtc.roomState?.me.userID })
                } footer: {
                    Text(mode == .bazi ? "只展示计算结果，双方的出生资料和四柱不会向其他人公开。" : "关系标签用于交流参考，不代表相处结果或成功率。")
                }
                Section {
                    ForEach(visibleListPairs) { pair in
                        Button {
                            selectedPairID = pair.id
                            showsRelationships = false
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text("\(pair.a.member.name) · \(pair.b.member.name)")
                                        .font(.subheadline.weight(.medium)).foregroundStyle(KikiPalette.text)
                                    Spacer(minLength: 4)
                                    if selectedPairID == pair.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(KikiPalette.purple)
                                    }
                                }
                                Text(pair.label).font(.subheadline).foregroundStyle(KikiRelationshipColors.color(for: pair.code))
                                Text(pair.explanation).font(.caption).foregroundStyle(KikiPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if mode == .bazi, pair.code != "UNAVAILABLE", let summary = pair.summary,
                                   let harmony = summary.harmonyIndex, let conflict = summary.conflictIndex {
                                    Text("合关系指数 \(harmony) · 冲关系指数 \(conflict)")
                                        .font(.caption2).foregroundStyle(KikiPalette.secondary)
                                    Text("按当前应用规则统计，不表示关系成功率。")
                                        .font(.caption2).foregroundStyle(KikiPalette.muted)
                                }
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                    if visibleListPairs.isEmpty {
                        Text("当前没有符合筛选的关系").font(.subheadline).foregroundStyle(KikiPalette.secondary)
                    }
                }
            }
            .navigationTitle("\(mode.title)关系").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { showsRelationships = false } }
            }
        }.kikiRoomSheet()
    }

    private var filterCategories: [KikiRelationshipCategory] { KikiRelationshipCategory.categories(for: mode) }

    private func updateMotion() {
        let current = currentSeatMap
        retainedSeats.merge(current) { _, new in new }
        motion.retarget(orderedIDs: seats.map(\.id), at: Date(), animated: !reduceMotion && !retainedSeats.isEmpty)
        isMoving = !reduceMotion
        motionGeneration = UUID()
        if reduceMotion { finishMotion() }
        if !seats.contains(where: { $0.id == rtc.roomState?.me.userID }) { onlyMe = false }
        if let selectedPairID, !pairs.contains(where: { $0.id == selectedPairID }) { self.selectedPairID = nil }
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
    let selectedPairID: String?
    let edgeOpacity: Double
    let onOpenPerson: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in drawEdges(context: &context, frame: frame, geometry: geometry) }
                .opacity(edgeOpacity)
                .allowsHitTesting(false).accessibilityHidden(true)
            ForEach(seats) { occupant in
                if let value = frame[occupant.id] {
                    avatar(occupant, geometry: geometry)
                        .opacity(value.opacity * nodeEmphasis(occupant.id))
                        .scaleEffect(0.94 + 0.06 * value.opacity)
                        .position(geometry.cellCenter(angle: value.angle))
                        .allowsHitTesting(activeIDs.contains(occupant.id) && value.opacity > 0.9)
                        .accessibilityHidden(!activeIDs.contains(occupant.id))
                        .transaction { $0.animation = nil }
                }
            }
        }
        .frame(width: geometry.width, height: geometry.height)
    }

    private func avatar(_ occupant: KikiRelationshipSeat, geometry: KikiRelationshipStageGeometry) -> some View {
        Button { onOpenPerson(occupant.id) } label: {
            VStack(spacing: 3) {
                KikiRoomSeatTile(slot: occupant.slot, member: occupant.member,
                    participant: participants.first { $0.id == occupant.id },
                    localUserID: localUserID, avatarSize: geometry.avatarSize)
                    .overlay(alignment: .topLeading) {
                        Text("\(occupant.slot.index)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(KikiPalette.secondary)
                            .frame(width: 17, height: 17)
                            .background(KikiPalette.surface.opacity(0.92), in: Circle())
                    }
                Text(publicTag(for: occupant.id) ?? " ")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KikiPalette.lavender).lineLimit(1)
                    .frame(height: 14)
                    .accessibilityHidden(publicTag(for: occupant.id) == nil)
            }
            .frame(width: geometry.cellWidth, height: geometry.cellHeight, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(occupant.slot.index)号麦，查看\(occupant.member.name)的个人主页")
        .accessibilityIdentifier("livekit.room.relationship.seat.\(occupant.id)")
    }

    private func publicTag(for userID: String) -> String? {
        guard let profile = profiles.first(where: { $0.userID == userID }) else { return nil }
        switch mode { case .bazi: return nil; case .mbti: return profile.mbtiType; case .zodiac: return profile.zodiacSign }
    }

    private func nodeEmphasis(_ id: String) -> Double {
        guard let selectedPair = pairs.first(where: { $0.id == selectedPairID }) else { return 1 }
        return selectedPair.a.id == id || selectedPair.b.id == id ? 1 : 0.55
    }

    private struct EdgeStyle {
        let color: Color
        let dash: [CGFloat]
        var offset: CGFloat = 0
    }

    private func styles(for code: String) -> [EdgeStyle] {
        switch code {
        case "HARMONY_ONLY": return [.init(color: KikiPalette.mint, dash: [])]
        case "CONFLICT_ONLY": return [.init(color: KikiPalette.warning, dash: [5, 4])]
        case "MIXED": return [.init(color: KikiPalette.mint, dash: [], offset: -3),
                              .init(color: KikiPalette.warning, dash: [5, 4], offset: 3)]
        case "GOLDEN": return [.init(color: KikiRelationshipColors.color(for: code), dash: [])]
        case "SILVER", "SAME_TYPE", "SAME_SIGN", "SEXTILE", "TRINE": return [.init(color: KikiRelationshipColors.color(for: code), dash: [])]
        case "PEDAGOGUE", "SQUARE", "OPPOSITION": return [.init(color: KikiRelationshipColors.color(for: code), dash: [5, 4])]
        case "ADJACENT", "QUINCUNX": return [.init(color: KikiRelationshipColors.color(for: code), dash: [2, 5])]
        default: return []
        }
    }

    private func drawEdges(context: inout GraphicsContext, frame: [String: KikiRelationshipMotion.Point],
                           geometry: KikiRelationshipStageGeometry) {
        for pair in pairs {
            guard let a = frame[pair.a.id], let b = frame[pair.b.id] else { continue }
            let start = geometry.point(angle: a.angle), end = geometry.point(angle: b.angle)
            let dx = end.x - start.x, dy = end.y - start.y
            let distance = hypot(dx, dy)
            guard distance > geometry.avatarSize + 16 else { continue }
            let ux = dx / distance, uy = dy / distance
            let trim = geometry.avatarSize / 2 + 7
            let selected = selectedPairID == nil || selectedPairID == pair.id
            let offline = !pair.a.member.online || !pair.b.member.online
            let opacity = min(a.opacity, b.opacity) * (selected ? (selectedPairID == nil ? 0.32 : 0.9) : 0.07)
                * (offline ? 0.35 : 1)
            for style in styles(for: pair.code) {
                var path = Path()
                path.move(to: CGPoint(x: start.x + ux * trim - uy * style.offset,
                                     y: start.y + uy * trim + ux * style.offset))
                path.addLine(to: CGPoint(x: end.x - ux * trim - uy * style.offset,
                                        y: end.y - uy * trim + ux * style.offset))
                context.stroke(path, with: .color(style.color.opacity(opacity)),
                               style: StrokeStyle(lineWidth: selectedPairID == pair.id ? 2 : 1.2,
                                                  lineCap: .round, dash: style.dash))
            }
        }
    }
}

private enum KikiRelationshipColors {
    static func color(for code: String) -> Color {
        switch code {
        case "HARMONY_ONLY", "SEXTILE", "TRINE": return KikiPalette.mint
        case "CONFLICT_ONLY", "SQUARE", "OPPOSITION": return KikiPalette.warning
        case "GOLDEN", "SAME_SIGN": return Color(hex: 0xB58C39)
        case "SILVER": return Color(hex: 0x7A9DBF)
        case "MIXED", "PEDAGOGUE", "ADJACENT", "QUINCUNX": return KikiPalette.lavender
        case "SAME_TYPE": return KikiPalette.purple
        default: return KikiPalette.secondary
        }
    }

}
