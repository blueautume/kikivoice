import AVFoundation
import AVKit
import Foundation
import LiveKit
import SwiftUI
import UIKit

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

/// A temporary control-plane outage must not tear down a still-authorized
/// audio call. This never extends the credential lifetime or bypasses a
/// definitive authorization, consent, identity, or TLS failure.
enum KikiVoiceAuthorizationRecovery {
    static func canKeepCurrentSession(after error: Error, expiresAt: Int, now: Date = Date()) -> Bool {
        guard expiresAt > Int(now.timeIntervalSince1970) else { return false }
        if let error = error as? KikiTransportFailure {
            return [.requestTimeout, .networkUnavailable, .networkConnectionLost, .networkError].contains(error.code)
        }
        if let error = error as? URLError {
            return [.timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .networkConnectionLost].contains(error.code)
        }
        if let error = error as? KikiAPIError {
            switch error {
            case .rateLimited: return true
            case .server(let status, _): return status == 408 || (500...599).contains(status)
            default: return false
            }
        }
        return false
    }
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

/// Hints invalidate an HTTPS resource; they never carry displayed content,
/// member identity, or a permission grant. The same envelope can be emitted by
/// a committed client operation or the server without another connection.
struct KikiRoomSyncHint: Codable {
    enum Resource: String, Codable, CaseIterable { case state, chat }
    let version: Int
    let resources: [Resource]
    static let topic = "kiki.room.sync"

    static func decode(_ data: Data) -> Self? {
        guard data.count <= 512, let hint = try? JSONDecoder().decode(Self.self, from: data),
              hint.version == 1, !hint.resources.isEmpty,
              hint.resources.count <= Resource.allCases.count,
              Set(hint.resources).count == hint.resources.count else { return nil }
        return hint
    }
}

/// Coalesce bursts while retaining a trailing invalidation that arrived during
/// a request. Dropping a throttled hint would leave its change stale until the
/// compensating read; this gate instead schedules exactly one follow-up.
struct KikiRoomSyncHintGate {
    private(set) var pending: Set<KikiRoomSyncHint.Resource> = []
    private(set) var invalidationCount = 0
    private(set) var batchCount = 0
    private var nextAllowedAt = Date.distantPast
    let minimumInterval: TimeInterval

    init(minimumInterval: TimeInterval = 1.5) { self.minimumInterval = minimumInterval }

    mutating func invalidate(_ resources: Set<KikiRoomSyncHint.Resource>) {
        guard !resources.isEmpty else { return }
        invalidationCount += 1
        pending.formUnion(resources)
    }

    func delay(now: Date) -> TimeInterval? {
        pending.isEmpty ? nil : max(0, nextAllowedAt.timeIntervalSince(now))
    }

    mutating func take(now: Date) -> Set<KikiRoomSyncHint.Resource> {
        guard now >= nextAllowedAt, !pending.isEmpty else { return [] }
        let resources = pending
        pending = []
        batchCount += 1
        nextAllowedAt = now.addingTimeInterval(minimumInterval)
        return resources
    }
}

/// The service owns shared authorization reads. Cancelling a screen's waiter
/// never cancels the live call's read; only a lifecycle/privacy boundary may.
@MainActor
final class KikiSafetyReadOwner {
    struct Scope: Equatable {
        let lifecycle: Int
        let mutation: Int
        let privacy: Int
    }
    struct Lease {
        fileprivate let id: UUID
        let scope: Scope
    }
    private var task: Task<Void, Error>?
    private var lease: Lease?
    var isReading: Bool { task != nil }

    func isCurrent(_ lease: Lease) -> Bool { self.lease?.id == lease.id }

    func read(scope: Scope, operation: @escaping @MainActor (Lease) async throws -> Void) async throws {
        try Task.checkCancellation()
        let shared: Task<Void, Error>
        if let task, lease?.scope == scope {
            shared = task
        } else {
            cancel()
            let lease = Lease(id: UUID(), scope: scope)
            self.lease = lease
            shared = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                defer { if self.isCurrent(lease) { self.task = nil; self.lease = nil } }
                try await operation(lease)
                try Task.checkCancellation()
            }
            task = shared
        }
        do { try await shared.value }
        catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
    }

    func cancel() {
        let previous = task
        task = nil
        lease = nil
        previous?.cancel()
    }
}

enum KikiRoomTitlePolicy {
    static let maximumCharacters = 36
    static let maximumBytes = 100

    static func defaultTitle(nickname: String) -> String {
        let suffix = "的房间"
        let clean = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
        var prefix = ""
        for character in clean.isEmpty ? "我" : clean {
            let candidate = prefix + String(character) + suffix
            guard candidate.count <= maximumCharacters, candidate.utf8.count <= maximumBytes,
                  candidate.unicodeScalars.count <= 40 else { break }
            prefix.append(character)
        }
        return (prefix.isEmpty ? "我" : prefix) + suffix
    }

    static func resolved(_ proposed: String, nickname: String) throws -> String {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        return try validated(title.isEmpty ? defaultTitle(nickname: nickname) : title)
    }

    static func validated(_ proposed: String) throws -> String {
        let title = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maximumCharacters, title.utf8.count <= maximumBytes,
              title.unicodeScalars.count <= 40,
              !title.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw KikiAPIError.server(422, "房间名称须为 1–36 个字，且不超过 100 字节，请减少文字或表情。")
        }
        return title
    }
}

enum KikiRoomRefreshPolicy {
    // Reliable invalidations are the fast path. One bounded recovery interval
    // also covers a lost packet, an older client, or a partially failed send.
    static let compensationInterval: TimeInterval = 12
    static let metricsInterval: TimeInterval = 10
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
