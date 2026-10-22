import CryptoKit
import Foundation
import LiveKit
import Network
import UIKit

enum KikiIncidentOperation: String, Codable, Sendable { case createRoom = "create_room", joinRoom = "join_room", runtime = "room_runtime" }
enum KikiIncidentStage: String, Codable, Sendable {
    case accountAuthorization = "account_authorization", roomAPI = "room_api", tokenAPI = "token_api"
    case mediaConnect = "media_connect", stateSync = "state_sync", mediaRuntime = "media_runtime", reconnect
    case safetySync = "safety_sync", chatSync = "chat_sync", audioPolicy = "audio_policy", roomAction = "room_action", roomLeave = "room_leave"
}
enum KikiIncidentSeverity: String, Codable, Sendable { case warning, error }
enum KikiIncidentCode: String, Codable, Sendable {
    case requestTimeout = "request_timeout", networkUnavailable = "network_unavailable", networkConnectionLost = "network_connection_lost"
    case networkTLSFailed = "network_tls_failed", networkError = "network_error"
    case unauthorized = "http_unauthorized", forbidden = "http_forbidden", notFound = "http_not_found", conflict = "http_conflict"
    case rateLimited = "http_rate_limited", serverError = "http_server_error", invalidResponse = "http_invalid_response"
    case consentRequired = "consent_required", capacityReached = "capacity_reached", roomEnded = "room_ended"
    case voiceBanned = "voice_banned", chatMuted = "chat_muted", voiceMuted = "voice_muted", contentFiltered = "content_filtered"
    case mediaConnectTimeout = "media_connect_timeout", mediaConnectFailed = "media_connect_failed", mediaDisconnected = "media_disconnected"
    case reconnectFailed = "reconnect_failed", stateSyncFailed = "state_sync_failed", audioPublishFailed = "audio_publish_failed"
    case audioPermissionDenied = "audio_permission_denied", qualityPoor = "quality_poor", qualityLost = "quality_lost", unknown = "unknown_error"

    static func transport(_ error: URLError) -> Self {
        switch error.code {
        case .timedOut: return .requestTimeout
        case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .networkUnavailable
        case .networkConnectionLost: return .networkConnectionLost
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired: return .networkTLSFailed
        default: return .networkError
        }
    }

    static func http(_ status: Int, serverCode: String?) -> Self {
        if let serverCode, let trusted = Self(rawValue: serverCode),
           [.capacityReached, .roomEnded, .voiceBanned, .chatMuted, .voiceMuted, .contentFiltered].contains(trusted) { return trusted }
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 409: return .conflict
        case 410: return .roomEnded
        case 428: return .consentRequired
        case 429: return .rateLimited
        case 500...599: return .serverError
        default: return .invalidResponse
        }
    }
}

/// A closed schema: no raw errors, URLs, headers, names, messages, Apple IDs or credentials.
struct KikiIncident: Codable, Equatable, Sendable {
    let eventID: String
    let attemptID: String
    let operation: KikiIncidentOperation
    let stage: KikiIncidentStage
    let severity: KikiIncidentSeverity
    let code: KikiIncidentCode
    let occurredAt: Int
    let elapsedMs: Int?
    let roomID: String?
    let requestID: String?
    let httpStatus: Int?
    let platform: String
    let appVersion: String
    let osVersion: String

    static func safeVersion(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .()_-").contains($0) }.prefix(32))
    }
    static func safeRoomID(_ value: String?) -> String? {
        guard let value, value.range(of: "^lk_[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
        return value
    }
}

/// This reference is scoped to one user gesture. Shared renewal tasks retain its
/// correlation ID without sharing any credentials or HTTP bodies.
final class KikiRoomAttempt: @unchecked Sendable {
    struct Failure: Sendable { let code: KikiIncidentCode; let requestID: String?; let status: Int?; let stage: KikiIncidentStage }
    let id: String
    let operation: KikiIncidentOperation
    let startedAt: Date
    let identityEpoch: UUID?
    private let lock = NSLock()
    private var stageValue: KikiIncidentStage = .accountAuthorization
    private var roomValue: String?
    private var failureValue: Failure?
    private var reported = false
    private var completed = false

    init(operation: KikiIncidentOperation, roomID: String? = nil, id: String = UUID().uuidString.lowercased(), now: Date = Date(), identityEpoch: UUID? = nil) {
        self.id = id; self.operation = operation; self.startedAt = now; self.identityEpoch = identityEpoch; self.roomValue = KikiIncident.safeRoomID(roomID)
    }
    var isActive: Bool { lock.withLock { !completed && !reported } }
    func complete() { lock.withLock { completed = true } }
    var failureCode: KikiIncidentCode? { lock.withLock { failureValue?.code } }
    var stage: KikiIncidentStage { lock.withLock { stageValue } }
    var roomID: String? { lock.withLock { roomValue } }
    func enter(_ stage: KikiIncidentStage) { lock.withLock { stageValue = stage; failureValue = nil } }
    func setRoom(_ roomID: String) { lock.withLock { roomValue = KikiIncident.safeRoomID(roomID) } }
    func noteFailure(code: KikiIncidentCode, requestID: String? = nil, status: Int? = nil) {
        lock.withLock { failureValue = Failure(code: code, requestID: requestID.flatMap { UUID(uuidString: $0)?.uuidString.lowercased() }, status: status, stage: stageValue) }
    }
    func copyFailure(to other: KikiRoomAttempt?) {
        guard let other, other !== self, let failure = lock.withLock({ failureValue }) else { return }
        other.noteFailure(code: failure.code, requestID: failure.requestID, status: failure.status)
    }
    func takeFailureOnce(fallback: KikiIncidentCode = .unknown) -> Failure? {
        lock.withLock { guard !reported else { return nil }; reported = true; return failureValue ?? Failure(code: fallback, requestID: nil, status: nil, stage: stageValue) }
    }
}

enum KikiIncidentContext {
    @TaskLocal static var attempt: KikiRoomAttempt?

    static func prepare(_ request: inout URLRequest) {
        request.setValue(attempt?.id ?? UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Kiki-Attempt-ID")
        request.setValue(attempt?.operation.rawValue ?? KikiIncidentOperation.runtime.rawValue, forHTTPHeaderField: "X-Kiki-Operation")
    }
    static func note(_ error: URLError) { attempt?.noteFailure(code: .transport(error)) }
    static func note(_ response: HTTPURLResponse, serverCode: String? = nil) {
        attempt?.noteFailure(code: .http(response.statusCode, serverCode: serverCode), requestID: response.value(forHTTPHeaderField: "X-Kiki-Request-ID"), status: (400...599).contains(response.statusCode) ? response.statusCode : nil)
    }
}

/// The only network-specific public error stores an enum, never the URLSession
/// error's userInfo, which can contain a signed URL or authorization data.
struct KikiTransportFailure: LocalizedError, Sendable {
    let code: KikiIncidentCode
    var errorDescription: String? {
        switch code {
        case .requestTimeout: return "请求超时，请稍后重试。"
        case .networkUnavailable, .networkConnectionLost: return "网络连接暂不可用，请检查网络后重试。"
        case .networkTLSFailed: return "服务器身份校验失败，请使用最新版本或联系管理员。"
        default: return "网络请求失败，请稍后重试。"
        }
    }
}

/// A small account-bound durable outbox. Uploading never blocks room actions;
/// retry triggers are network recovery, foreground entry, room success and a
/// capped backoff timer. Logout/withdrawal/account switches destroy the outbox.
@MainActor
final class KikiIncidentReporter {
    static let shared = KikiIncidentReporter()
    typealias Sender = (KikiIncident, String) async throws -> Void
    private struct Envelope: Codable { let ownerHash: String; var events: [KikiIncident] }
    private let queueURL: URL
    private let now: () -> Date
    private let sender: Sender
    private let automaticRetry: Bool
    private var ownerHash: String?
    private var token: String?
    private var events: [KikiIncident] = []
    private var generation = 0
    private var flushTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var monitor: NWPathMonitor?
    private var wasConnected: Bool?
    private var foregroundObserver: NSObjectProtocol?
    private var dedupe: [String: Date] = [:]
    private(set) var identityEpoch = UUID()
    private(set) var lastEventID: String?
    var pendingCount: Int { events.count }

    init(queueURL: URL? = nil, now: @escaping () -> Date = Date.init, automaticRetry: Bool = true,
         sender: @escaping Sender = { event, token in try await KikiAccountAPIClient.shared.reportIncident(event, token: token) }) {
        self.queueURL = queueURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KikiPrivateDiagnostics", isDirectory: true).appendingPathComponent("incidents.json")
        self.now = now; self.sender = sender; self.automaticRetry = automaticRetry
    }

    func bind(userID: String, token: String) {
        guard !userID.isEmpty, !token.isEmpty else { clear(); return }
        let hash = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        if let ownerHash, ownerHash != hash { clear() }
        if self.token != nil, self.token != token {
            generation += 1
            flushTask?.cancel(); flushTask = nil; retryTask?.cancel(); retryTask = nil
        }
        self.ownerHash = hash; self.token = token
        if events.isEmpty, let data = try? Data(contentsOf: queueURL), data.count <= 256_000,
           let saved = try? JSONDecoder().decode(Envelope.self, from: data), saved.ownerHash == hash {
            events = saved.events
        }
        prune(); persist(); startRecoveryObservers(); retry()
    }

    func clear() {
        generation += 1
        identityEpoch = UUID()
        flushTask?.cancel(); flushTask = nil; retryTask?.cancel(); retryTask = nil
        monitor?.cancel(); monitor = nil; wasConnected = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        ownerHash = nil; token = nil; events = []; dedupe = [:]; lastEventID = nil; failures = 0
        try? FileManager.default.removeItem(at: queueURL)
    }

    @discardableResult
    func record(_ error: Error? = nil, trace: KikiRoomAttempt? = nil, stage: KikiIncidentStage = .mediaRuntime,
                code fallback: KikiIncidentCode = .unknown, severity: KikiIncidentSeverity = .error,
                roomID: String? = nil, dedupeKey: String? = nil, dedupeSeconds: TimeInterval = 300) -> String? {
        guard ownerHash != nil, token != nil, !(error is CancellationError), (error as? URLError)?.code != .cancelled, (error as? LiveKitError)?.type != .cancelled else { return nil }
        guard trace?.identityEpoch == nil || trace?.identityEpoch == identityEpoch else { return nil }
        let date = now()
        if let dedupeKey, let last = dedupe[dedupeKey], date.timeIntervalSince(last) < dedupeSeconds { return nil }
        if let dedupeKey { dedupe[dedupeKey] = date }
        dedupe = dedupe.filter { date.timeIntervalSince($0.value) < 3600 }
        let failure: KikiRoomAttempt.Failure?
        if let trace { guard let value = trace.takeFailureOnce(fallback: fallback) else { return nil }; failure = value }
        else { failure = nil }
        var code = failure?.code ?? fallback
        if code == .unknown {
            if let transport = error as? KikiTransportFailure { code = transport.code }
            else if let url = error as? URLError { code = .transport(url) }
            else if let api = error as? KikiAPIError {
                switch api {
                case .server(let status, _): code = .http(status, serverCode: nil)
                case .rateLimited: code = .rateLimited
                case .legalUpdateRequired: code = .consentRequired
                case .invalidResponse: code = .invalidResponse
                case .security: code = .forbidden
                }
            } else if (trace?.stage ?? stage) == .mediaConnect {
                code = (error as? LiveKitError)?.type == .timedOut ? .mediaConnectTimeout : .mediaConnectFailed
            }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let event = KikiIncident(eventID: UUID().uuidString.lowercased(), attemptID: trace?.id ?? UUID().uuidString.lowercased(),
            operation: trace?.operation ?? .runtime, stage: failure?.stage ?? stage, severity: severity, code: code,
            occurredAt: Int(date.timeIntervalSince1970), elapsedMs: trace.map { max(0, min(3_600_000, Int(date.timeIntervalSince($0.startedAt) * 1000))) },
            roomID: KikiIncident.safeRoomID(trace?.roomID ?? roomID), requestID: failure?.requestID, httpStatus: failure?.status,
            platform: UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios",
            appVersion: KikiIncident.safeVersion("\(version)(\(build))"), osVersion: KikiIncident.safeVersion(UIDevice.current.systemVersion))
        events.append(event); prune(); lastEventID = event.eventID; persist(); retry()
        return event.eventID
    }

    func connectivityChanged(isAvailable: Bool) {
        let recovered = wasConnected == false && isAvailable
        wasConnected = isAvailable
        if recovered { retry() }
    }

    func retry() {
        guard automaticRetry, flushTask == nil, token != nil, !events.isEmpty else { return }
        retryTask?.cancel(); retryTask = nil
        let expected = generation
        flushTask = Task { [weak self] in
            await self?.flushNow()
            guard let self, expected == self.generation else { return }
            self.flushTask = nil
        }
    }

    func flushNow() async {
        guard let token, let ownerHash else { return }
        let expected = generation
        prune(); persist()
        while let event = events.first, !Task.isCancelled {
            do {
                try await sender(event, token)
                guard expected == generation, self.ownerHash == ownerHash, self.token == token else { return }
                events.removeAll { $0.eventID == event.eventID }; failures = 0; persist()
            } catch {
                guard expected == generation, self.ownerHash == ownerHash else { return }
                // Invalid/expired schema data must not permanently block newer
                // events. Authorization errors wait for a fresh foreground/login.
                if case .server(let status, _) = error as? KikiAPIError, [400, 404, 409, 422].contains(status) {
                    events.removeAll { $0.eventID == event.eventID }; persist(); continue
                }
                if let api = error as? KikiAPIError {
                    if case .server(let status, _) = api, [401, 403, 428].contains(status) { return }
                    if case .legalUpdateRequired = api { return }
                }
                failures += 1
                if automaticRetry {
                    let delay: Double
                    if case .rateLimited(let seconds, _) = error as? KikiAPIError { delay = Double(seconds) }
                    else { delay = min(300, 5 * pow(2, Double(min(failures - 1, 6)))) }
                    retryTask?.cancel()
                    retryTask = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        guard let self, expected == self.generation else { return }
                        self.retry()
                    }
                }
                return
            }
        }
    }

    private func prune() {
        let seconds = Int(now().timeIntervalSince1970)
        events = Array(events.filter { $0.occurredAt > seconds - 7 * 86400 && $0.occurredAt <= seconds + 300 }.suffix(100))
    }
    private func persist() {
        guard let ownerHash else { return }
        do {
            let directory = queueURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
            var privateDirectory = directory; try privateDirectory.setResourceValues(excluded)
            let data = try JSONEncoder().encode(Envelope(ownerHash: ownerHash, events: events))
            try data.write(to: queueURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
            var file = queueURL; try file.setResourceValues(excluded)
        } catch { /* Diagnostics must never prevent opening or leaving a room. */ }
    }
    private func startRecoveryObservers() {
        guard automaticRetry, monitor == nil else { return }
        let path = NWPathMonitor()
        path.pathUpdateHandler = { [weak self] value in
            let available = value.status == .satisfied
            Task { @MainActor in self?.connectivityChanged(isAvailable: available) }
        }
        path.start(queue: DispatchQueue(label: "com.kikitalk.incidents.network")); monitor = path
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.retry() }
        }
    }
}

struct KikiRoomOperationFailure: LocalizedError {
    let message: String
    let eventID: String?
    var errorDescription: String? {
        guard let eventID else { return message }
        return "\(message)\n问题编号：\(eventID.prefix(8).uppercased())"
    }
}
