import AVFoundation
import AVKit
import Foundation
import LiveKit
import SwiftUI

struct KikiChatMessage: Codable, Equatable, Identifiable {
    let id: String
    let seq: Int
    let clientMessageID: String
    let senderUserID: String
    let senderName: String
    let senderAvatarIndex: Int
    let text: String
    let createdAt: Int

    static func validatedText(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 2_000 else {
            throw KikiRTCError.unavailable("消息不能为空，且不能超过 2000 字节。")
        }
        return text
    }
}

struct KikiRoomAnnouncement: Codable, Equatable {
    let text: String
    let revision: Int
    let updatedAt: Int
    let updatedByUserID: String?
    static let empty = Self(text: "", revision: 0, updatedAt: 0, updatedByUserID: nil)
}

struct KikiChatPage: Codable {
    let messages: [KikiChatMessage]
    let nextAfterSeq: Int
    let latestSeq: Int
    let oldestSeq: Int
    let truncated: Bool
    let hasMore: Bool
    let historyRevision: Int
    let announcement: KikiRoomAnnouncement
}

/// Only HTTPS responses enter this window. Data-channel packets merely request a refresh.
struct KikiChatWindow {
    private(set) var messages: [KikiChatMessage] = []
    private(set) var afterSeq = 0
    private(set) var historyRevision: Int?
    private(set) var isTruncated = false
    private(set) var announcement = KikiRoomAnnouncement.empty

    /// Return false to request a complete window after deletion or retention changed.
    mutating func apply(_ page: KikiChatPage, requestedAfterSeq: Int) -> Bool {
        guard page.nextAfterSeq >= requestedAfterSeq, page.historyRevision >= (historyRevision ?? 0) else { return false }
        if let historyRevision, historyRevision != page.historyRevision, requestedAfterSeq != 0 { return false }
        if requestedAfterSeq == 0 { messages = [] }
        historyRevision = page.historyRevision
        isTruncated = isTruncated || page.truncated
        if page.announcement.revision >= announcement.revision { announcement = page.announcement }
        merge(page.messages)
        afterSeq = max(requestedAfterSeq, page.nextAfterSeq)
        return true
    }

    mutating func appendConfirmed(_ message: KikiChatMessage) {
        // A completed GET already described every retained message through this
        // cursor. A delayed POST response cannot restore a deletion or old window.
        guard message.seq > afterSeq || messages.contains(where: { $0.id == message.id }) else { return }
        merge([message])
    }

    mutating func setAnnouncement(_ value: KikiRoomAnnouncement) {
        if value.revision >= announcement.revision { announcement = value }
    }

    private mutating func merge(_ incoming: [KikiChatMessage]) {
        var known = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for message in incoming { known[message.id] = message }
        messages = Array(known.values).sorted { $0.seq < $1.seq }
        if messages.count > 200 { messages.removeFirst(messages.count - 200); isTruncated = true }
    }
}

struct KikiPendingChatMessage: Equatable {
    let clientMessageID: String
    let text: String
    var failure: String?
}

struct KikiMicrophoneRecoveryIntent {
    let enabled: Bool
    let policy: Int
    let safety: Int
    let revision: Int

    func mayResume(policy: Int, safety: Int, revision: Int, canPublish: Bool, interrupted: Bool, hasNotice: Bool) -> Bool {
        enabled && self.policy == policy && self.safety == safety && self.revision == revision
            && canPublish && !interrupted && !hasNotice
    }
}

/// A notification cannot add a message or supply a claimed sender.
struct KikiChatSyncHint: Codable {
    let version: Int
    let latestSeq: Int
    let historyRevision: Int
    let announcementRevision: Int
    static let topic = "kiki.chat.sync"
    static func decode(_ data: Data) -> Self? {
        guard data.count <= 512, let hint = try? JSONDecoder().decode(Self.self, from: data),
              hint.version == 1, hint.latestSeq >= 0, hint.historyRevision >= 0, hint.announcementRevision >= 0 else { return nil }
        return hint
    }
}

struct KikiNetworkMetrics: Equatable {
    var rttMs: Double?
    var jitterMs: Double?
    var packetLossPercent: Double?

    static func valid(_ value: Double?, upperBound: Double) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= upperBound else { return nil }
        return value
    }

    static func collect(_ tracks: [Track]) -> Self {
        let stats = tracks.compactMap(\.statistics)
        let rtt = stats.flatMap { value in
            value.iceCandidatePair.filter { $0.id == value.transportStats?.selectedCandidatePairId }
                .compactMap(\.currentRoundTripTime)
        }.max()
        let inbound = stats.flatMap(\.inboundRtpStream)
        let jitter = inbound.compactMap(\.jitter).max()
        let reports = inbound.filter { $0.packetsLost != nil && $0.packetsReceived != nil }
        let lost = reports.reduce(0.0) { $0 + Double(max(0, $1.packetsLost ?? 0)) }
        let received = reports.reduce(0.0) { $0 + Double($1.packetsReceived ?? 0) }
        return Self(rttMs: valid(rtt.map { $0 * 1_000 }, upperBound: 60_000),
                    jitterMs: valid(jitter.map { $0 * 1_000 }, upperBound: 10_000),
                    packetLossPercent: valid(lost + received > 0 ? lost / (lost + received) * 100 : nil, upperBound: 100))
    }
}

struct KikiRoomQualitySample: Encodable {
    let quality: String
    let rttMs: Double?
    let jitterMs: Double?
    let packetLossPercent: Double?
}

struct KikiServerDiagnostics: Decodable {
    struct Capacity: Decodable {
        let activeRooms: Int?
        let activeParticipants: Int?
        let admittedParticipants: Int?
        let maxRooms: Int?
        let maxParticipantsPerRoom: Int?
        let maxParticipantsTotal: Int?
    }
    struct Connections: Decodable {
        let attempts: Int
        let accepted: Int
        let rejected: Int
        let reconnects: Int
        let activeSignals: Int
        let handshakeMsP50: Double?
    }
    struct Quality: Decodable {
        let samples: Int
        let excellent: Int
        let good: Int
        let poor: Int
        let lost: Int
        let unknown: Int
        let rttMsP50: Double?
        let jitterMsP50: Double?
        let packetLossPercentP50: Double?
    }
    struct Alert: Decodable, Identifiable {
        let code: String
        let level: String
        let message: String
        var id: String { code }
    }
    let serverTime: String
    let windowSeconds: Int
    let capacity: Capacity
    let connections: Connections
    let quality: Quality
    let alerts: [Alert]
}

enum KikiAudioSafetyEvent {
    case interruptionBegan, interruptionEnded, oldDeviceUnavailable, mediaServicesLost, mediaServicesReset
    var mustStopCapture: Bool { self != .interruptionEnded }
    var message: String {
        switch self {
        case .interruptionBegan: return "音频被系统中断，麦克风已关闭。结束后请手动开麦。"
        case .interruptionEnded: return "音频中断已结束，请确认设备后手动开麦。"
        case .oldDeviceUnavailable: return "耳机或音频设备已断开，麦克风已关闭，请确认后手动开麦。"
        case .mediaServicesLost: return "系统音频服务暂不可用，麦克风已关闭。"
        case .mediaServicesReset: return "系统音频服务已恢复，请确认设备后手动开麦。"
        }
    }
}

struct KikiAudioRuntimeState: Equatable {
    var output = "尚未启用"
    var input = "尚未启用"
    var interrupted = false
    var notice: String?
}

@MainActor
final class KikiRoomAudioMonitor {
    var onUpdate: ((KikiAudioRuntimeState, KikiAudioSafetyEvent?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private(set) var state = KikiAudioRuntimeState()

    func start() {
        guard observers.isEmpty else { return }
        observe(AVAudioSession.routeChangeNotification) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            self?.refresh(event: raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue ? .oldDeviceUnavailable : nil)
        }
        observe(AVAudioSession.interruptionNotification) { [weak self] note in
            guard let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            self?.refresh(event: type == .began ? .interruptionBegan : .interruptionEnded)
        }
        observe(AVAudioSession.mediaServicesWereLostNotification) { [weak self] _ in self?.refresh(event: .mediaServicesLost) }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in self?.refresh(event: .mediaServicesReset) }
        refresh()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        state = .init()
    }

    func clearNotice() { state.notice = nil; refresh() }

    func refresh(event: KikiAudioSafetyEvent? = nil) {
        let route = AVAudioSession.sharedInstance().currentRoute
        state.output = route.outputs.map(\.portName).joined(separator: "、")
        state.input = route.inputs.map(\.portName).joined(separator: "、")
        if state.output.isEmpty { state.output = "尚未启用" }
        if state.input.isEmpty { state.input = "未采集" }
        if let event {
            state.notice = event.message
            if event == .interruptionBegan || event == .mediaServicesLost { state.interrupted = true }
            if event == .interruptionEnded || event == .mediaServicesReset { state.interrupted = false }
        }
        onUpdate?(state, event)
    }

    private func observe(_ name: Notification.Name, callback: @escaping @MainActor (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            Task { @MainActor in callback(note) }
        })
    }
}

struct KikiAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(red: 0.73, green: 0.63, blue: 1, alpha: 1)
        view.prioritizesVideoDevices = false
        view.accessibilityLabel = "选择耳机或音频输出设备"
        return view
    }
    func updateUIView(_ view: AVRoutePickerView, context: Context) { }
}

extension ConnectionQuality {
    var kikiLabel: String {
        switch self {
        case .excellent: return "优秀"
        case .good: return "良好"
        case .poor: return "较差"
        case .lost: return "连接丢失"
        default: return "等待采样"
        }
    }
    var kikiValue: String {
        switch self {
        case .excellent: return "excellent"
        case .good: return "good"
        case .poor: return "poor"
        case .lost: return "lost"
        default: return "unknown"
        }
    }
}

struct KikiRoomDiagnosticsView: View {
    @ObservedObject var rtc: KikiRTCService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("当前连接") {
                    LabeledContent("连接状态", value: rtc.isRecovering ? "恢复并校准中" : (rtc.connectionState == .connected ? "已连接" : "已断开"))
                    LabeledContent("本机连接质量", value: rtc.connectionQuality.kikiLabel)
                    LabeledContent("本次入房重连次数", value: String(rtc.reconnectCount))
                    LabeledContent("媒体往返延迟", value: metric(rtc.networkMetrics.rttMs, suffix: " ms"))
                    LabeledContent("接收最大抖动", value: metric(rtc.networkMetrics.jitterMs, suffix: " ms"))
                    LabeledContent("接收累计丢包", value: metric(rtc.networkMetrics.packetLossPercent, suffix: "%"))
                    Text("指标来自本机 LiveKit 媒体统计；没有音频流或尚无报告时显示未采到，不代表零延迟或零丢包。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("音频设备") {
                    LabeledContent("声音输出", value: rtc.audioState.output)
                    LabeledContent("声音输入", value: rtc.audioState.input)
                    LabeledContent("麦克风权限", value: KikiMicrophonePermission.description)
                    LabeledContent("本机麦克风", value: rtc.microphoneEnabled ? "已开启" : "已关闭")
                    Toggle("内置设备优先使用扬声器", isOn: Binding(get: { rtc.speakerPreferred }, set: rtc.setSpeakerPreferred))
                    HStack {
                        Text("选择音频输出")
                        Spacer()
                        KikiAudioRoutePicker().frame(width: 36, height: 36)
                    }
                    if let notice = rtc.audioState.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    Text("耳机和蓝牙由系统选择。来电中断、设备断开或权限收回后，需手动开麦。锁屏和切后台可继续收听；系统仍可能限制网络及后台执行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("实验服务器 · 最近 5 分钟") {
                    Button { Task { await rtc.loadServerDiagnostics() } } label: {
                        HStack { Text("刷新服务器状态"); if rtc.isLoadingDiagnostics { Spacer(); ProgressView() } }
                    }.disabled(rtc.isLoadingDiagnostics)
                    if let value = rtc.serverDiagnostics {
                        LabeledContent("活跃房间", value: "\(count(value.capacity.activeRooms)) / \(count(value.capacity.maxRooms))")
                        LabeledContent("实际在线", value: count(value.capacity.activeParticipants))
                        LabeledContent("已占入房名额", value: "\(count(value.capacity.admittedParticipants)) / \(count(value.capacity.maxParticipantsTotal))")
                        LabeledContent("单房人数上限", value: count(value.capacity.maxParticipantsPerRoom))
                        LabeledContent("信令接受 / 拒绝", value: "\(value.connections.accepted) / \(value.connections.rejected)")
                        LabeledContent("信令握手中位数", value: metric(value.connections.handshakeMsP50, suffix: " ms"))
                        LabeledContent("质量样本", value: String(value.quality.samples))
                        LabeledContent("较差 / 丢失样本", value: "\(value.quality.poor) / \(value.quality.lost)")
                        LabeledContent("样本延迟中位数", value: metric(value.quality.rttMsP50, suffix: " ms"))
                        ForEach(value.alerts) { alert in Text(alert.message).font(.caption).foregroundStyle(.orange) }
                        Text("容量为当前保护配置，不是压测容量。质量为登录房内客户端自报的去标识短期聚合。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = rtc.diagnosticsError { Text(error).font(.caption).foregroundStyle(.orange) }
                }
            }
            .scrollContentBackground(.hidden).background(Color(hex: 0x241747))
            .navigationTitle("连接与音频").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.preferredColorScheme(.dark).tint(Color(hex: 0xB69AFF))
    }

    private func metric(_ value: Double?, suffix: String) -> String {
        guard let value, value.isFinite else { return "未采到" }
        return String(format: "%.1f", value) + suffix
    }
    private func count(_ value: Int?) -> String { value.map(String.init) ?? "未知" }
}

struct KikiRoomAnnouncementView: View {
    @ObservedObject var rtc: KikiRTCService
    @State private var text = ""
    @State private var hasLoaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if rtc.canManageRoom {
                    TextEditor(text: $text).scrollContentBackground(.hidden)
                        .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .accessibilityIdentifier("livekit.room.announcement.editor")
                    Text("最多 2000 字节；清空并保存可移除公告。").font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { if await rtc.saveAnnouncement(text) { dismiss() } }
                    } label: {
                        HStack { Spacer(); if rtc.isSavingAnnouncement { ProgressView() }; Text("保存公告"); Spacer() }
                            .padding(14).background(Color(hex: 0x8B66FF), in: Capsule())
                    }.disabled(!rtc.canUseRoom || rtc.isSavingAnnouncement || text.utf8.count > 2_000)
                        .accessibilityIdentifier("livekit.room.announcement.save")
                } else {
                    ScrollView { Text(rtc.announcement.text.isEmpty ? "暂无公告" : rtc.announcement.text).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(20).background(Color(hex: 0x241747))
                .navigationTitle("房间公告").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onAppear { if !hasLoaded { text = rtc.announcement.text; hasLoaded = true } }
        }.preferredColorScheme(.dark).tint(Color(hex: 0xB69AFF))
    }
}
