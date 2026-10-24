import AVFoundation
import Combine
import Foundation
import LiveKit
import SwiftUI
import UIKit

enum KikiRTCError: Foundation.LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

enum KikiMicrophonePermission {
    static var isUndetermined: Bool {
        if #available(iOS 17.0, *) { return AVAudioApplication.shared.recordPermission == .undetermined }
        return AVAudioSession.sharedInstance().recordPermission == .undetermined
    }

    static var description: String {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return "已允许"
            case .denied: return "未允许"
            default: return "未申请"
            }
        }
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted: return "已允许"
        case .denied: return "未允许"
        default: return "未申请"
        }
    }

    static func request() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }
}

@MainActor
protocol KikiRTCServicing: AnyObject {
    var onRoomClosed: ((String) -> Void)? { get set }
    var onSessionExpired: (() -> Void)? { get set }
    var isLoggedIn: Bool { get }
    var isPresentingRoom: Bool { get }
    var currentSDKRoomID: String? { get }
    var roomPresentationChanges: AnyPublisher<Bool, Never>? { get }
    func isCurrentRoom(_ roomID: String) -> Bool
    func requireNoActiveRoom() throws
    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws
    func logout() async
    func stopMediaForPrivacy()
    func logoutForPrivacy() async throws
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws
}

extension KikiRTCServicing {
    var roomPresentationChanges: AnyPublisher<Bool, Never>? { nil }
}

struct KikiVoiceParticipant: Identifiable, Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    let isHost: Bool
    let isSpeaking: Bool
    let microphoneEnabled: Bool
}

struct KikiVoiceMessage: Identifiable, Equatable {
    let id: String
    let senderID: String
    let senderName: String
    let text: String
    let isLocal: Bool
    var createdAt: Int = 0
    var sequence: Int = 0
    var senderAvatarIndex: Int = 0
}

extension KikiVoiceMessage {
    init(confirmed message: KikiChatMessage, localUserID: String?) {
        self.init(id: message.id, senderID: message.senderUserID, senderName: message.senderName,
                  text: message.text, isLocal: message.senderUserID == localUserID,
                  createdAt: message.createdAt, sequence: message.seq, senderAvatarIndex: message.senderAvatarIndex)
    }
}

/// Owns a single real LiveKit session. Business authentication and short-lived
/// participant tokens come from the independent voice backend; no signing key is in the app.
@MainActor
final class KikiRTCService: NSObject, ObservableObject, KikiRTCServicing {
    static let shared = KikiRTCService()

    @Published private(set) var isPresentingRoom = false
    @Published private(set) var currentRoomID: String?
    @Published private(set) var isVoiceRoomMinimized = false
    @Published private(set) var isTransitioningRoom = false
    @Published private(set) var isRecovering = false
    @Published private(set) var reconnectCount = 0
    @Published private(set) var connectionQuality: ConnectionQuality = .unknown
    @Published private(set) var networkMetrics = KikiNetworkMetrics()
    @Published private(set) var audioState = KikiAudioRuntimeState()
    @Published private(set) var speakerPreferred = true
    @Published private(set) var pendingMessage: KikiPendingChatMessage?
    @Published var messageDraft = ""
    @Published private(set) var announcement = KikiRoomAnnouncement.empty
    @Published private(set) var chatSyncNotice: String?
    @Published private(set) var isSavingAnnouncement = false
    @Published private(set) var isUpdatingRoomDetails = false
    @Published private(set) var serverDiagnostics: KikiServerDiagnostics?
    @Published private(set) var diagnosticsError: String?
    @Published private(set) var isLoadingDiagnostics = false
    weak var socialStore: KikiAppStore?
    @Published private(set) var roomInfo: KikiRoom?
    @Published private(set) var roomState: KikiRoomState?
    @Published private(set) var isPerformingRoomAction = false
    @Published private(set) var participants: [KikiVoiceParticipant] = []
    @Published private(set) var messages: [KikiVoiceMessage] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var microphoneEnabled = false
    @Published private(set) var isChangingMicrophone = false
    @Published private(set) var isSendingMessage = false
    @Published private(set) var isLeavingRoom = false
    @Published private(set) var disconnectionReason: String?
    @Published var roomError: String?
    @Published private(set) var safetyState = KikiSafetyState.empty
    @Published private(set) var safetyError: String?
    @Published private(set) var isLoadingSafety = false
    @Published private(set) var isUpdatingBlock = false
    @Published private(set) var myReports: [KikiSafetyReport] = []
    @Published private(set) var reportRetentionDays = 30
    private var safetyMutationGeneration = 0
    private let safetyReads = KikiSafetyReadOwner()
    private let reportReads = KikiSafetyReadOwner()
    private var safetyLoadingWaiters: Set<UUID> = []
    private var safetyLoaded = false
    private var nextSafetySyncAt = Date.distantPast
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?
    var renewAuthorization: (() async throws -> Void)?

    private var api = KikiAPIClient.shared
    private var credentials: KikiSDKCredentials?
    private var sessionToken: String?
    private var room: Room?
    private var roomController: UIViewController?
    private var floatingOverlay: KikiVoiceRoomFloatingOverlay?
    private let audioMonitor = KikiRoomAudioMonitor()
    private var foregroundObserver: NSObjectProtocol?
    private var chatWindow = KikiChatWindow()
    private var chatSyncTask: Task<Void, Never>?
    private var stateSyncTask: Task<Void, Never>?
    private var roomHintTask: Task<Void, Never>?
    private var roomHintGate = KikiRoomSyncHintGate()
    private var outgoingRoomHints: Set<KikiRoomSyncHint.Resource> = []
    private var publishRoomHintTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var nextChatSyncAt = Date.distantPast
    private var nextRoomSyncAt = Date.distantPast
    private var chatFailureCount = 0
    private var stateFailureCount = 0
    private var lastQualityReportAt = Date.distantPast
    private var nextMetricsSyncAt = Date.distantPast
    private var audioRecoveryGeneration = 0
    private var transportIsReconnecting = false
    private var recoveryCaptureIntent: KikiMicrophoneRecoveryIntent?
    private var lifecycleGeneration = 0
    private var loginAttemptGeneration = 0
    private var privacySuspended = false
    private var hasConnected = false
    private var lastMessageTime = Date.distantPast
    private var pendingPrivacyDisconnect: Task<Void, Never>?
    private var privacyRoom: (id: String, token: String)?
    private var roomStateTask: Task<Void, Never>?
    private var audioPolicyGeneration = 0

    var isLoggedIn: Bool { !privacySuspended && (credentials?.expiresAt ?? 0) > Int(Date().timeIntervalSince1970) && sessionToken != nil }
    var currentSDKRoomID: String? { currentRoomID }
    var currentRoomSID: String? { room?.sid?.stringValue }
    var roomPresentationID: ObjectIdentifier? { roomController.map(ObjectIdentifier.init) }
    var roomPresentationChanges: AnyPublisher<Bool, Never>? { $isPresentingRoom.eraseToAnyPublisher() }
    var isRoomOwner: Bool { roomState?.room.hostID == credentials?.userID }
    var canUseRoom: Bool { connectionState == .connected && !isRecovering && disconnectionReason == nil && !isLeavingRoom && !privacySuspended }
    var canManageRoom: Bool { roomState?.me.isModerator == true }
    var canPublishAudio: Bool {
        guard canUseRoom, roomState?.me.canPublishAudio == true, let permissions = room?.localParticipant.permissions else { return false }
        return permissions.canPublish && (permissions.canPublishSources.isEmpty || permissions.canPublishSources.contains(Track.Source.microphone.rawValue))
    }
    var canSendChat: Bool { canUseRoom && roomState?.me.canPublishData == true && room?.localParticipant.permissions.canPublishData == true }
    var microphoneStatus: String {
        if let notice = audioState.notice { return notice }
        guard let state = roomState else { return "正在同步麦位权限" }
        if state.me.seatIndex == nil { return state.me.isModerator ? "听众 · 上麦后可发言" : "听众 · 申请上麦后可发言" }
        if state.me.audioMuted { return "已被管理者禁麦" }
        if state.seats.first(where: { $0.index == state.me.seatIndex })?.audioLocked == true { return "此麦位已锁音频" }
        return microphoneEnabled ? "麦克风已开启" : "已上麦 · 点击开麦后发言"
    }

    private override init() { super.init() }

    private func observed<Value>(_ stage: KikiIncidentStage, independent: Bool = false,
                                 _ operation: () async throws -> Value) async throws -> Value {
        if !independent, let trace = KikiIncidentContext.attempt, trace.isActive {
            trace.enter(stage)
            do { return try await operation() }
            catch {
                if stage == .mediaConnect, let sdk = error as? LiveKitError {
                    trace.noteFailure(code: sdk.type == .timedOut ? .mediaConnectTimeout : .mediaConnectFailed)
                }
                throw error
            }
        }
        let trace = KikiRoomAttempt(operation: .runtime, roomID: currentRoomID, identityEpoch: KikiIncidentReporter.shared.identityEpoch)
        trace.enter(stage)
        do { return try await KikiIncidentContext.$attempt.withValue(trace) { try await operation() } }
        catch {
            KikiIncidentReporter.shared.record(error, trace: trace, stage: stage,
                code: stage == .mediaConnect ? .mediaConnectFailed : .unknown,
                severity: [.roomAction, .roomLeave, .audioPolicy].contains(stage) && trace.failureCode != .forbidden && trace.failureCode != .rateLimited ? .error : .warning,
                dedupeKey: "\(currentRoomID ?? "none"):\(stage.rawValue):\(trace.failureCode?.rawValue ?? "unknown")")
            throw error
        }
    }

    private func runtimeIssue(_ error: Error? = nil, stage: KikiIncidentStage = .mediaRuntime,
                              code: KikiIncidentCode, key: String, severity: KikiIncidentSeverity = .warning) {
        // HTTP failures have already been recorded with their response correlation.
        guard !(error is CancellationError), !(error is KikiAPIError), !(error is KikiTransportFailure) else { return }
        KikiIncidentReporter.shared.record(error, stage: stage, code: code, severity: severity,
            roomID: currentRoomID, dedupeKey: "\(currentRoomID ?? "none"):\(key)")
    }

    func configure(api: KikiAPIClient) { self.api = api }
    func isCurrentRoom(_ roomID: String) -> Bool {
        currentRoomID == roomID && disconnectionReason == nil
    }

    func requireNoActiveRoom() throws {
        guard currentRoomID == nil, !isPresentingRoom, room == nil else {
            throw KikiRTCError.unavailable("请先退出当前房间。")
        }
    }

    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws {
        guard credentials.provider == "livekit", !credentials.userID.isEmpty,
              !sessionToken.isEmpty, Self.isLabServer(credentials.serverURL) else {
            throw KikiRTCError.unavailable("语聊服务配置无效。")
        }
        let generation = lifecycleGeneration
        loginAttemptGeneration += 1
        let attempt = loginAttemptGeneration
        await pendingPrivacyDisconnect?.value
        guard generation == lifecycleGeneration, attempt == loginAttemptGeneration else { throw CancellationError() }
        try Task.checkCancellation()
        pendingPrivacyDisconnect = nil
        if self.credentials?.userID != credentials.userID, room != nil {
            throw KikiRTCError.unavailable("请先退出当前语聊账号。")
        }
        // Privacy shutdown is synchronous. Restore the audio device only after
        // any prior session has fully disconnected, so it cannot resume capture.
        if room == nil { try AudioManager.shared.setEngineAvailability(.default) }
        if self.credentials?.userID != credentials.userID {
            safetyMutationGeneration += 1
            safetyReads.cancel(); reportReads.cancel(); safetyLoadingWaiters = []; isLoadingSafety = false
            safetyState = .empty; safetyLoaded = false; safetyError = nil; myReports = []
        }
        self.credentials = credentials
        self.sessionToken = sessionToken
        privacySuspended = false
    }

    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws {
        try requireLogin()
        guard credentials?.userID == userID else { throw KikiRTCError.unavailable("账号状态已变化，请重新登录。") }
        // The Store saves profile changes through HTTPS first. Participant names
        // inside an active room remain the server-authenticated LiveKit name.
    }

    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws {
        try await connectRoom(roomID: roomID, isLive: isLive, requiresOwnership: true)
    }

    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws {
        if currentRoomID == roomID, isVoiceRoomMinimized {
            try await resumeRoom()
            return
        }
        // Never trust the UI's owner hint; use hostID returned by the backend.
        try await connectRoom(roomID: roomID, isLive: isLive, requiresOwnership: false)
    }

    private func connectRoom(roomID: String, isLive: Bool, requiresOwnership: Bool) async throws {
        let token = try requireLogin()
        guard !isLive else { throw KikiRTCError.unavailable("暂未开放视频直播，请使用语聊房。") }
        try requireNoActiveRoom()
        guard roomID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else {
            throw KikiRTCError.unavailable("房间编号无效。")
        }
        let generation = lifecycleGeneration
        currentRoomID = roomID // Reserve the operation before the first network await.
        disconnectionReason = nil
        roomError = nil
        connectionState = .connecting
        do {
            // Fail closed: obtain the durable account block list before any media
            // subscription is possible, including a newly installed device.
            try await refreshSafety()
            try checkLifecycle(generation)
            let connection = try await observed(.tokenAPI) { try await api.rtcJoin(roomID: roomID, token: token) }
            try checkLifecycle(generation)
            guard connection.room.id == roomID, !connection.room.isLive,
                  Self.isLabServer(connection.serverURL), !connection.participantToken.isEmpty else {
                throw KikiRTCError.unavailable("服务器返回的语聊房间信息无效。")
            }
            let isHost = connection.room.hostID == credentials?.userID
            guard !requiresOwnership || isHost else { throw KikiRTCError.unavailable("只有房主可以开启房间。") }
            try checkLifecycle(generation)
            roomInfo = connection.room
            messages = []
            chatWindow = .init()
            pendingMessage = nil
            messageDraft = ""
            announcement = .empty
            chatSyncNotice = nil
            lastMessageTime = .distantPast
            try AudioManager.shared.setEngineAvailability(.default)
            AudioManager.shared.isSpeakerOutputPreferred = speakerPreferred
            let liveRoom = Room(delegate: self, roomOptions: RoomOptions(
                defaultAudioPublishOptions: AudioPublishOptions(encoding: .presetSpeech),
                reportRemoteTrackStatistics: true))
            room = liveRoom
            hasConnected = false
            try await observed(.mediaConnect) { try await liveRoom.connect(url: connection.serverURL, token: connection.participantToken, connectOptions: ConnectOptions(autoSubscribe: false)) }
            try checkLifecycle(generation)
            guard liveRoom.connectionState == .connected else { throw KikiRTCError.unavailable("语聊连接未完成，请重试。") }
            await applyAudioBlocks(to: liveRoom)
            try checkLifecycle(generation)
            guard room === liveRoom else { throw CancellationError() }
            hasConnected = true
            connectionState = .connected
            try checkLifecycle(generation)
            let state = try await observed(.stateSync) { try await api.roomState(roomID: roomID, token: token) }
            try checkLifecycle(generation)
            await applyRoomState(state, to: liveRoom)
            try checkLifecycle(generation)
            guard room === liveRoom else { throw CancellationError() }
            startAudioMonitoring(liveRoom)
            await synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
            try checkLifecycle(generation)
            guard room === liveRoom else { throw CancellationError() }
            nextRoomSyncAt = Date().addingTimeInterval(KikiRoomRefreshPolicy.compensationInterval)
            startRoomRefreshDriver(roomID: roomID, liveRoom: liveRoom, generation: generation)
            refreshParticipants(liveRoom)
            try await present(liveRoom: liveRoom, generation: generation)
        } catch {
            // A privacy transition may already have detached this room. Never
            // clear a newer session when an older connect operation finishes.
            if generation == lifecycleGeneration, currentRoomID == roomID {
                let failedRoom = room
                failedRoom?.remove(delegate: self)
                await failedRoom?.disconnect()
                if generation == lifecycleGeneration, currentRoomID == roomID, room === failedRoom {
                    clearRoomState(notify: false)
                    if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
                }
            }
            throw error
        }
    }

    func toggleMicrophone() async {
        guard (canUseRoom || microphoneEnabled), !isChangingMicrophone, let room else { return }
        let generation = lifecycleGeneration
        let policyGeneration = audioPolicyGeneration
        let safetyGeneration = audioRecoveryGeneration
        let enabled = !microphoneEnabled
        var failureCode = KikiIncidentCode.audioPublishFailed
        if !enabled {
            audioRecoveryGeneration += 1
            recoveryCaptureIntent = nil
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
        }
        isChangingMicrophone = true
        defer { if generation == lifecycleGeneration, self.room === room { isChangingMicrophone = false } }
        do {
            if enabled {
                guard !audioState.interrupted else { throw KikiRTCError.unavailable("系统音频中断尚未结束。") }
                guard canPublishAudio else { failureCode = .voiceMuted; throw KikiRTCError.unavailable(microphoneStatus) }
                guard await KikiMicrophonePermission.request() else {
                    failureCode = .audioPermissionDenied
                    throw KikiRTCError.unavailable("请在系统设置中允许麦克风权限。")
                }
            }
            try checkLifecycle(generation)
            guard (!enabled || canUseRoom), self.room === room else { return }
            guard !enabled || (canPublishAudio && policyGeneration == audioPolicyGeneration && safetyGeneration == audioRecoveryGeneration) else { throw KikiRTCError.unavailable(microphoneStatus) }
            if enabled { try AudioManager.shared.setEngineAvailability(.default) }
            try await room.localParticipant.setMicrophone(enabled: enabled)
            try checkLifecycle(generation)
            guard self.room === room else {
                _ = try? await room.localParticipant.setMicrophone(enabled: false)
                return
            }
            if enabled, !canPublishAudio || policyGeneration != audioPolicyGeneration || safetyGeneration != audioRecoveryGeneration {
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
                _ = try? await room.localParticipant.setMicrophone(enabled: false)
                throw KikiRTCError.unavailable("发言权限已变化，麦克风已关闭。请确认麦位后手动开麦。")
            }
            if enabled { audioMonitor.clearNotice() }
            refreshParticipants(room)
        } catch {
            if generation == lifecycleGeneration, self.room === room {
                runtimeIssue(error, stage: .audioPolicy, code: failureCode, key: "microphone_toggle_\(failureCode.rawValue)")
                roomError = "麦克风切换失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func sendMessage(_ text: String) async -> Bool {
        guard canSendChat, !isSendingMessage, let room, let roomID = currentRoomID, let token = sessionToken else { return false }
        let generation = lifecycleGeneration
        isSendingMessage = true
        defer { if generation == lifecycleGeneration, self.room === room { isSendingMessage = false } }
        do {
            guard Date().timeIntervalSince(lastMessageTime) >= 0.4 else {
                throw KikiRTCError.unavailable("消息发送太快，请稍后再试。")
            }
            let text = try KikiChatMessage.validatedText(text)
            let candidate = pendingMessage?.text == text ? pendingMessage! : KikiPendingChatMessage(clientMessageID: UUID().uuidString.lowercased(), text: text)
            pendingMessage = KikiPendingChatMessage(clientMessageID: candidate.clientMessageID, text: candidate.text)
            let confirmed = try await observed(.chatSync) { try await api.sendRoomMessage(roomID: roomID, clientMessageID: candidate.clientMessageID, text: text, token: token) }
            try checkLifecycle(generation)
            guard self.room === room else { return false }
            lastMessageTime = Date()
            chatWindow.appendConfirmed(confirmed)
            publishChatWindow()
            pendingMessage = nil
            let hint = KikiChatSyncHint(version: 1, latestSeq: confirmed.seq, historyRevision: chatWindow.historyRevision ?? 0,
                                       announcementRevision: announcement.revision)
            // Receipt of this hint is optional; HTTPS polling covers packet loss.
            if let data = try? JSONEncoder().encode(hint) {
                _ = try? await room.localParticipant.publish(data: data, options: DataPublishOptions(topic: KikiChatSyncHint.topic, reliable: true))
            }
            return true
        } catch {
            if generation == lifecycleGeneration, self.room === room {
                if let pendingMessage, chatWindow.messages.contains(where: { $0.clientMessageID == pendingMessage.clientMessageID && $0.senderUserID == credentials?.userID }) {
                    self.pendingMessage = nil
                    return true
                }
                pendingMessage?.failure = error.localizedDescription
                if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
                else { roomError = "消息发送遇到问题，草稿已保留，可重试：\(error.localizedDescription)" }
            }
            return false
        }
    }

    func refreshSafety(includeReports: Bool = false, showsLoading: Bool = true) async throws {
        try Task.checkCancellation()
        let token = try requireLogin()
        let scope = currentSafetyReadScope
        let loadingID = showsLoading ? UUID() : nil
        if let loadingID {
            safetyLoadingWaiters.insert(loadingID)
            if !isLoadingSafety { isLoadingSafety = true }
        }
        defer {
            if let loadingID {
                safetyLoadingWaiters.remove(loadingID)
                if safetyLoadingWaiters.isEmpty, isLoadingSafety { isLoadingSafety = false }
            }
        }
        try await safetyReads.read(scope: scope) { [weak self] lease in
            guard let self else { throw CancellationError() }
            try await self.readSafety(token: token, lease: lease)
        }
        try checkLifecycle(scope.lifecycle)
        guard scope == currentSafetyReadScope else { throw CancellationError() }
        if includeReports {
            // Reports are an explicit, independent resource. Their failure
            // cannot undo a verified block list or pause a healthy voice call.
            try await reportReads.read(scope: scope) { [weak self] lease in
                guard let self else { throw CancellationError() }
                let page = try await self.observed(.safetySync) { try await self.api.myReports(token: token) }
                try self.checkLifecycle(scope.lifecycle)
                guard self.reportReads.isCurrent(lease), scope == self.currentSafetyReadScope else { throw CancellationError() }
                if self.myReports != page.reports { self.myReports = page.reports }
                if self.reportRetentionDays != page.retentionDays { self.reportRetentionDays = page.retentionDays }
            }
        }
    }

    private var currentSafetyReadScope: KikiSafetyReadOwner.Scope {
        .init(lifecycle: lifecycleGeneration, mutation: safetyMutationGeneration,
              privacy: socialStore?.socialPrivacyRevision ?? 0)
    }

    private func readSafety(token: String, lease: KikiSafetyReadOwner.Lease) async throws {
        let scope = lease.scope
        do {
            let state = try await observed(.safetySync) { try await api.safety(token: token) }
            try checkLifecycle(scope.lifecycle)
            guard safetyReads.isCurrent(lease), scope == currentSafetyReadScope else { throw CancellationError() }
            let wasPausedForSafety = safetyError != nil && !safetyLoaded
            if safetyState != state { safetyState = state }
            safetyLoaded = true
            if safetyError != nil { safetyError = nil }
            nextSafetySyncAt = Date().addingTimeInterval(15)
            publishChatWindow()
            if let room {
                await applyAudioBlocks(to: room)
                try checkLifecycle(scope.lifecycle)
                guard safetyReads.isCurrent(lease), scope == currentSafetyReadScope,
                      self.room === room else { throw CancellationError() }
                if wasPausedForSafety, !isRecovering, !privacySuspended, room.connectionState == .connected {
                    try AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
                }
            }
        } catch {
            // A superseded recovery task can finish an awaited request after
            // cancellation. It must not fence the newer task's audio session.
            guard !(error is CancellationError), !Task.isCancelled else { throw error }
            if safetyReads.isCurrent(lease), scope == currentSafetyReadScope, !privacySuspended {
                safetyError = error.localizedDescription
                safetyLoaded = false
                try? AudioManager.shared.setEngineAvailability(.none)
                if let room {
                    await applyAudioBlocks(to: room)
                    guard safetyReads.isCurrent(lease), scope == currentSafetyReadScope,
                          self.room === room, !privacySuspended, !Task.isCancelled, !safetyLoaded else { throw error }
                    do { _ = try await room.localParticipant.setMicrophone(enabled: false) }
                    catch { runtimeIssue(error, stage: .audioPolicy, code: .audioPublishFailed, key: "safety_microphone_stop", severity: .error) }
                }
            }
            throw error
        }
    }

    func setBlocked(_ userID: String, enabled: Bool) async throws {
        guard !isUpdatingBlock else { throw KikiRTCError.unavailable("正在更新黑名单，请稍候。") }
        // The production account route also removes both follow directions.
        // Refreshing safety inside that route never calls this mutation again.
        if let socialStore {
            let generation = lifecycleGeneration
            isUpdatingBlock = true
            defer { if generation == lifecycleGeneration { isUpdatingBlock = false } }
            try await socialStore.setSocialBlock(userID, enabled: enabled)
            return
        }
        let token = try requireLogin()
        let generation = lifecycleGeneration
        isUpdatingBlock = true
        safetyMutationGeneration += 1
        defer { if generation == lifecycleGeneration { isUpdatingBlock = false } }
        let state = try await observed(.safetySync) { try await api.blockUser(userID, enabled: enabled, token: token) }
        try checkLifecycle(generation)
        safetyMutationGeneration += 1
        safetyState = state
        safetyLoaded = true
        publishChatWindow()
        if let room { await applyAudioBlocks(to: room) }
        socialStore?.socialPolicyChanged(userID: userID, blocked: enabled)
        Task { [weak self] in await self?.socialStore?.refreshSocialSummary() }
    }

    func submitReport(_ report: KikiSafetyReportRequest) async throws -> KikiSafetyReport {
        let token = try requireLogin()
        let generation = lifecycleGeneration
        let result = try await observed(.safetySync) { try await api.submitReport(report, token: token) }
        try checkLifecycle(generation)
        myReports.removeAll { $0.id == result.id }
        myReports.insert(result, at: 0)
        return result
    }

    /// Auto-subscribe is disabled at connection time. Only known, unblocked
    /// identities may be subscribed; blocking mutes the existing track before
    /// waiting for the server unsubscribe. Other participants' gain is untouched.
    private func applyAudioBlocks(to liveRoom: Room) async {
        guard room === liveRoom, !privacySuspended else { return }
        for participant in liveRoom.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                guard let publication = publication as? RemoteTrackPublication, publication.kind == .audio else { continue }
                let blocked = !safetyLoaded || participant.identity.map { safetyState.blockedIDs.contains($0.stringValue) } != false
                if blocked { (publication.track as? RemoteAudioTrack)?.volume = 0 }
                do { try await publication.set(subscribed: !blocked) }
                catch {
                    guard room === liveRoom, !privacySuspended else { return }
                    runtimeIssue(error, stage: .audioPolicy, code: .stateSyncFailed, key: "audio_subscription")
                    safetyError = "部分音频订阅未更新，正在重试。"
                }
                guard room === liveRoom, !privacySuspended else { return }
                // A block operation may complete while a subscription is in flight.
                if participant.identity.map({ safetyState.blockedIDs.contains($0.stringValue) }) != false {
                    (publication.track as? RemoteAudioTrack)?.volume = 0
                    try? await publication.set(subscribed: false)
                }
            }
        }
    }

    @discardableResult
    func performRoomAction(_ action: KikiRoomAction, targetUserID: String? = nil, seatIndex: Int? = nil, enabled: Bool? = nil) async -> Bool {
        guard canUseRoom, !isPerformingRoomAction, let roomID = currentRoomID,
              let token = sessionToken, let liveRoom = room else { return false }
        let generation = lifecycleGeneration
        isPerformingRoomAction = true
        defer { if generation == lifecycleGeneration, room === liveRoom { isPerformingRoomAction = false } }
        do {
            let state = try await observed(.roomAction) { try await api.roomAction(action, roomID: roomID, targetUserID: targetUserID,
                                                seatIndex: seatIndex, enabled: enabled, token: token) }
            try checkLifecycle(generation)
            guard room === liveRoom, currentRoomID == roomID else { return false }
            await applyRoomState(state, to: liveRoom)
            guard generation == lifecycleGeneration, room === liveRoom, currentRoomID == roomID else { return false }
            publishRoomSyncHint([.state])
            return true
        } catch {
            guard generation == lifecycleGeneration, room === liveRoom else { return false }
            if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
            else if !(error is CancellationError) { roomError = error.localizedDescription }
            return false
        }
    }

    func updateRoomDetails(_ proposedTitle: String, theme: Int) async throws {
        guard canUseRoom, isRoomOwner, !isUpdatingRoomDetails,
              let roomID = currentRoomID, let liveRoom = room, let socialStore else {
            throw KikiRTCError.unavailable("只有房主可以在当前房间编辑房间。")
        }
        let generation = lifecycleGeneration
        let title = try KikiRoomTitlePolicy.resolved(proposedTitle, nickname: socialStore.profileName)
        isUpdatingRoomDetails = true
        defer { if generation == lifecycleGeneration, room === liveRoom { isUpdatingRoomDetails = false } }
        let state = try await observed(.roomAction) { try await socialStore.updateRoomTitle(roomID: roomID, title: title, theme: KikiRoomBackgroundStyle(theme: theme).rawValue) }
        try checkLifecycle(generation)
        guard room === liveRoom, currentRoomID == roomID else { throw CancellationError() }
        // The write returns its complete authoritative state/revision. No
        // secondary GET can falsely report that an already saved edit failed.
        await applyRoomState(state, to: liveRoom)
        publishRoomSyncHint([.state])
        updateFloatingStatus()
    }

    func leaveRoom(endRoom: Bool = false) async {
        guard !isLeavingRoom, let roomID = currentRoomID else { return }
        isLeavingRoom = true
        let generation = lifecycleGeneration
        let leavingRoom = room
        let leavingController = roomController
        defer { if generation == lifecycleGeneration { isLeavingRoom = false } }
        do {
            if endRoom, isRoomOwner, disconnectionReason == nil, let token = sessionToken {
                // PATCH ended deletes the server room and ends media for everyone.
                // Keep the current connection if that operation fails, so hosts can retry.
                _ = try await observed(.roomLeave) { try await api.setRoomStatus(roomID, status: "ended", token: token) }
            } else if let token = sessionToken {
                if disconnectionReason == nil { try await observed(.roomLeave) { try await api.leaveRoom(roomID: roomID, token: token) } }
                else {
                    // Release a recoverable admission as soon as possible. A room
                    // already ended or revoked must still be locally dismissible.
                    try? await api.leaveRoom(roomID: roomID, token: token)
                }
            }
            try checkLifecycle(generation)
            guard currentRoomID == roomID, room === leavingRoom else { return }
            leavingRoom?.remove(delegate: self)
            await leavingRoom?.disconnect()
            guard generation == lifecycleGeneration, currentRoomID == roomID, room === leavingRoom else { return }
            leavingController?.dismiss(animated: true)
            clearRoomState(notify: true)
        } catch {
            if generation == lifecycleGeneration, currentRoomID == roomID, room === leavingRoom {
                if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
                else { roomError = "退出失败，请重试：\(error.localizedDescription)" }
            }
        }
    }

    func stopMediaForPrivacy() {
        privacySuspended = true
        lifecycleGeneration += 1
        // This SDK call synchronously stops both capture and playback and prevents
        // a racing publication from restarting them while disconnect is pending.
        try? AudioManager.shared.setEngineAvailability(.none)
        if let id = currentRoomID, let token = sessionToken {
            privacyRoom = (id, token)
        }
        let previous = pendingPrivacyDisconnect
        let detachedRoom = room
        detachedRoom?.remove(delegate: self)
        pendingPrivacyDisconnect = Task {
            await previous?.value
            await detachedRoom?.disconnect()
        }
        roomController?.dismiss(animated: false)
        clearRoomState(notify: false)
    }

    func logout() async { try? await logoutForPrivacy() }

    func logoutForPrivacy() async throws {
        stopMediaForPrivacy()
        let previousRoom = privacyRoom
        privacyRoom = nil
        credentials = nil
        sessionToken = nil
        safetyState = .empty; safetyLoaded = false; safetyError = nil; myReports = []
        safetyMutationGeneration += 1
        isLoadingSafety = false; isUpdatingBlock = false
        await pendingPrivacyDisconnect?.value
        pendingPrivacyDisconnect = nil
        URLCache.shared.removeAllCachedResponses()
        if let previousRoom {
            // The server releases this member; an owner's departure closes the room.
            // Account logout / withdrawal separately revoke its session and room grants.
            try? await api.leaveRoom(roomID: previousRoom.id, token: previousRoom.token)
        }
    }

    private func startRoomRefreshDriver(roomID: String, liveRoom: Room, generation: Int) {
        roomStateTask?.cancel()
        roomStateTask = Task { [weak self, weak liveRoom] in
            while !Task.isCancelled {
                // This is a local scheduler, not a one-second network poll.
                // Each resource has its own due time and coalesced read.
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, let liveRoom, self.room === liveRoom, self.currentRoomID == roomID,
                      generation == self.lifecycleGeneration, !self.privacySuspended,
                      self.disconnectionReason == nil else { return }
                if Date() >= self.nextSafetySyncAt {
                    do { try await self.refreshSafety(showsLoading: false) }
                    catch {
                        guard generation == self.lifecycleGeneration, self.room === liveRoom,
                              !self.privacySuspended, !Task.isCancelled else { return }
                        self.safetyError = error.localizedDescription
                        self.nextSafetySyncAt = Date().addingTimeInterval(5)
                    }
                }
                // Authorization is renewed while a call stays in the background.
                // Never pin this long-lived loop to the initial join credential.
                guard let token = self.sessionToken else { return }
                await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
                guard self.room === liveRoom, self.disconnectionReason == nil, !self.privacySuspended else { return }
                await self.synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      self.disconnectionReason == nil, !self.privacySuspended else { return }
                if Date() >= self.nextMetricsSyncAt {
                    self.nextMetricsSyncAt = Date().addingTimeInterval(KikiRoomRefreshPolicy.metricsInterval)
                    self.refreshNetworkMetrics(liveRoom)
                }
                await self.reportQualityIfNeeded(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
            }
        }
    }

    private func publishRoomSyncHint(_ resources: Set<KikiRoomSyncHint.Resource>) {
        guard canUseRoom, let liveRoom = room else { return }
        outgoingRoomHints.formUnion(resources)
        guard publishRoomHintTask == nil else { return }
        let generation = lifecycleGeneration
        publishRoomHintTask = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            defer { if generation == self.lifecycleGeneration { self.publishRoomHintTask = nil } }
            while !self.outgoingRoomHints.isEmpty {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      self.canUseRoom, !Task.isCancelled else { return }
                let resources = self.outgoingRoomHints.sorted { $0.rawValue < $1.rawValue }
                self.outgoingRoomHints = []
                let hint = KikiRoomSyncHint(version: 1, resources: resources)
                guard let data = try? JSONEncoder().encode(hint) else { return }
                // Failure is repaired by the bounded compensating GET. A hint
                // must never turn an already committed action into a failure.
                _ = try? await liveRoom.localParticipant.publish(data: data,
                    options: DataPublishOptions(topic: KikiRoomSyncHint.topic, reliable: true))
            }
        }
    }

    private func requestRoomRefresh(_ resources: Set<KikiRoomSyncHint.Resource>, in liveRoom: Room) {
        guard room === liveRoom, canUseRoom, !resources.isEmpty else { return }
        roomHintGate.invalidate(resources)
        guard roomHintTask == nil else { return }
        let generation = lifecycleGeneration
        roomHintTask = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            defer { if generation == self.lifecycleGeneration { self.roomHintTask = nil } }
            while let delay = self.roomHintGate.delay(now: Date()) {
                do { try await Task.sleep(nanoseconds: UInt64(max(0.15, delay) * 1_000_000_000)) } catch { return }
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      self.canUseRoom, !Task.isCancelled, let roomID = self.currentRoomID,
                      let token = self.sessionToken else { return }
                let resources = self.roomHintGate.take(now: Date())
                if resources.contains(.state) {
                    // A request that began before this invalidation may carry
                    // an older snapshot. Finish it, then perform one trailing
                    // read rather than treating its response as this hint's read.
                    if let inFlight = self.stateSyncTask { await inFlight.value }
                    guard self.room === liveRoom, generation == self.lifecycleGeneration,
                          !Task.isCancelled, !self.privacySuspended else { return }
                    // Hints may advance a healthy resource's next read, but
                    // cannot override rate-limit or failure backoff.
                    if self.stateFailureCount == 0 { self.nextRoomSyncAt = .distantPast }
                    await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
                }
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      !self.privacySuspended, !Task.isCancelled, let currentToken = self.sessionToken else { return }
                if resources.contains(.chat) {
                    if let inFlight = self.chatSyncTask { await inFlight.value }
                    guard self.room === liveRoom, generation == self.lifecycleGeneration,
                          !Task.isCancelled, !self.privacySuspended else { return }
                    if self.chatFailureCount == 0 { self.nextChatSyncAt = .distantPast }
                    await self.synchronizeChat(roomID: roomID, token: currentToken, liveRoom: liveRoom, generation: generation)
                }
            }
        }
    }

    private func synchronizeRoom(roomID: String, token: String, liveRoom: Room, generation: Int, force: Bool = false) async {
        guard force || Date() >= nextRoomSyncAt else { return }
        if let stateSyncTask { await stateSyncTask.value; return }
        let task = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            defer { if generation == self.lifecycleGeneration, self.room === liveRoom { self.stateSyncTask = nil } }
            await self.readRoomState(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
        }
        stateSyncTask = task
        await task.value
    }

    private func readRoomState(roomID: String, token: String, liveRoom: Room, generation: Int) async {
        do {
            let state = try await observed(.stateSync) { try await api.roomState(roomID: roomID, token: token) }
            try checkLifecycle(generation)
            guard room === liveRoom else { return }
            stateFailureCount = 0
            nextRoomSyncAt = Date().addingTimeInterval(KikiRoomRefreshPolicy.compensationInterval)
            await applyRoomState(state, to: liveRoom)
            if isRecovering, safetyLoaded, !transportIsReconnecting, liveRoom.connectionState == .connected {
                if recoveryCaptureIntent?.mayResume(policy: audioPolicyGeneration, safety: audioRecoveryGeneration,
                    revision: state.revision, canPublish: state.me.canPublishAudio,
                    interrupted: audioState.interrupted, hasNotice: audioState.notice != nil) == true {
                    try AudioManager.shared.setEngineAvailability(.default)
                } else {
                    try AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
                    if liveRoom.localParticipant.isMicrophoneEnabled() { _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false) }
                }
                try checkLifecycle(generation)
                guard room === liveRoom else { return }
                recoveryCaptureIntent = nil
                isRecovering = false
                refreshParticipants(liveRoom)
                updateFloatingStatus()
            }
        } catch {
            guard generation == lifecycleGeneration, room === liveRoom, !Task.isCancelled else { return }
            stateFailureCount += 1
            nextRoomSyncAt = Date().addingTimeInterval(backoff(error, failures: stateFailureCount))
            await handleRoomReadError(error, liveRoom: liveRoom, expectedToken: token)
        }
    }

    private func synchronizeChat(roomID: String, token: String, liveRoom: Room, generation: Int, force: Bool = false) async {
        guard disconnectionReason == nil, !privacySuspended, room === liveRoom,
              force || Date() >= nextChatSyncAt else { return }
        if let chatSyncTask { await chatSyncTask.value; return }
        let task = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            defer { if generation == self.lifecycleGeneration, self.room === liveRoom { self.chatSyncTask = nil } }
            do {
                var cursor = self.chatWindow.afterSeq
                for _ in 0..<4 {
                    let page = try await self.observed(.chatSync, independent: true) { try await self.api.roomMessages(roomID: roomID, afterSeq: cursor, token: token) }
                    try self.checkLifecycle(generation)
                    guard self.room === liveRoom, self.currentRoomID == roomID, self.disconnectionReason == nil else { return }
                    if !self.chatWindow.apply(page, requestedAfterSeq: cursor) { cursor = 0; continue }
                    self.publishChatWindow()
                    self.chatFailureCount = 0
                    self.nextChatSyncAt = Date().addingTimeInterval(KikiRoomRefreshPolicy.compensationInterval)
                    let notice = self.chatWindow.isTruncated ? "仅显示最近 200 条、2 小时内的可用消息" : nil
                    if self.chatSyncNotice != notice { self.chatSyncNotice = notice }
                    if !page.hasMore { return }
                    guard page.nextAfterSeq > cursor else { throw KikiAPIError.invalidResponse }
                    cursor = page.nextAfterSeq
                }
                self.chatSyncNotice = "聊天记录正在继续同步…"
            } catch {
                guard generation == self.lifecycleGeneration, self.room === liveRoom, !Task.isCancelled else { return }
                self.chatFailureCount += 1
                self.nextChatSyncAt = Date().addingTimeInterval(self.backoff(error, failures: self.chatFailureCount))
                self.chatSyncNotice = "聊天同步暂缓，网络恢复后会补齐。"
                await self.handleRoomReadError(error, liveRoom: liveRoom, expectedToken: token)
            }
        }
        chatSyncTask = task
        await task.value
    }

    private func publishChatWindow() {
        let visibleMessages = chatWindow.messages.filter { !safetyState.blockedIDs.contains($0.senderUserID) }.map {
            KikiVoiceMessage(confirmed: $0, localUserID: credentials?.userID)
        }
        if messages != visibleMessages { messages = visibleMessages }
        let visibleAnnouncement = chatWindow.announcement.updatedByUserID.map { safetyState.blockedIDs.contains($0) } == true ? KikiRoomAnnouncement.empty : chatWindow.announcement
        if announcement != visibleAnnouncement { announcement = visibleAnnouncement }
        if let pendingMessage, chatWindow.messages.contains(where: { $0.clientMessageID == pendingMessage.clientMessageID && $0.senderUserID == credentials?.userID }) {
            if messageDraft.trimmingCharacters(in: .whitespacesAndNewlines) == pendingMessage.text { messageDraft = "" }
            self.pendingMessage = nil
        }
    }

    private func backoff(_ error: Error, failures: Int) -> TimeInterval {
        if case .rateLimited(let seconds, _) = error as? KikiAPIError { return Double(seconds) + Double.random(in: 0.2...0.8) }
        return min(30, pow(2, Double(min(failures, 5)))) + Double.random(in: 0.2...0.8)
    }

    private func handleRoomReadError(_ error: Error, liveRoom: Room, expectedToken: String) async {
        guard room === liveRoom, !privacySuspended else { return }
        let generation = lifecycleGeneration
        if let error = error as? KikiAPIError {
            if error.isUnauthorized {
                guard expectedToken == sessionToken else {
                    // A renewal may finish while an older request is in flight.
                    // Retry using its replacement before declaring it expired.
                    nextRoomSyncAt = .distantPast
                    nextChatSyncAt = .distantPast
                    return
                }
                expireSession(); return
            }
            if case .server(let status, let message) = error, [403, 404, 409, 410].contains(status) {
                disconnectionReason = message
                microphoneEnabled = false
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
                _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false)
                guard generation == lifecycleGeneration, room === liveRoom, !privacySuspended else { return }
                await liveRoom.disconnect()
                guard generation == lifecycleGeneration, room === liveRoom, !privacySuspended else { return }
                updateFloatingStatus()
                dismissTerminatedMinimizedRoom(message, expectedRoom: liveRoom, generation: generation)
            }
        }
    }

    func saveAnnouncement(_ text: String) async -> Bool {
        guard canUseRoom, canManageRoom, !isSavingAnnouncement, let roomID = currentRoomID,
              let token = sessionToken, let liveRoom = room else { return false }
        let generation = lifecycleGeneration
        isSavingAnnouncement = true
        defer { if generation == lifecycleGeneration, room === liveRoom { isSavingAnnouncement = false } }
        do {
            let value = try await observed(.chatSync) { try await api.setRoomAnnouncement(roomID: roomID, text: text, token: token) }
            try checkLifecycle(generation)
            guard room === liveRoom else { return false }
            chatWindow.setAnnouncement(value)
            publishChatWindow()
            return true
        } catch {
            if generation == lifecycleGeneration, room === liveRoom {
                if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
                else { roomError = "公告保存失败：\(error.localizedDescription)" }
            }
            return false
        }
    }

    func loadServerDiagnostics() async {
        guard !isLoadingDiagnostics, let token = sessionToken, !privacySuspended else { return }
        let generation = lifecycleGeneration
        isLoadingDiagnostics = true
        diagnosticsError = nil
        defer { if generation == lifecycleGeneration { isLoadingDiagnostics = false } }
        do {
            let value = try await observed(.stateSync) { try await api.diagnostics(token: token) }
            try checkLifecycle(generation)
            serverDiagnostics = value
        } catch {
            if generation == lifecycleGeneration {
                if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
                else { diagnosticsError = error.localizedDescription }
            }
        }
    }

    private func refreshNetworkMetrics(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended else { return }
        guard !isRecovering, liveRoom.connectionState == .connected else { networkMetrics = .init(); return }
        let quality = liveRoom.localParticipant.connectionQuality
        if connectionQuality != quality { connectionQuality = quality }
        if connectionQuality == .poor || connectionQuality == .lost {
            runtimeIssue(code: connectionQuality == .poor ? .qualityPoor : .qualityLost, key: "quality_\(connectionQuality.kikiValue)")
        }
        let tracks = ([liveRoom.localParticipant] as [Participant] + Array(liveRoom.remoteParticipants.values))
            .flatMap { Array($0.trackPublications.values) }.compactMap(\.track).filter { $0.kind == .audio }
        let metrics = KikiNetworkMetrics.collect(tracks)
        if networkMetrics != metrics { networkMetrics = metrics }
    }

    private func reportQualityIfNeeded(roomID: String, token: String, liveRoom: Room, generation: Int) async {
        guard UIApplication.shared.applicationState == .active, canUseRoom,
              Date().timeIntervalSince(lastQualityReportAt) >= 10 else { return }
        lastQualityReportAt = Date()
        let sample = KikiRoomQualitySample(quality: connectionQuality.kikiValue, rttMs: networkMetrics.rttMs,
                                          jitterMs: networkMetrics.jitterMs, packetLossPercent: networkMetrics.packetLossPercent)
        do { try await observed(.stateSync, independent: true) { try await api.reportRoomQuality(roomID: roomID, sample: sample, token: token) } }
        catch {
            guard generation == lifecycleGeneration, room === liveRoom, !privacySuspended, !Task.isCancelled else { return }
            if (error as? KikiAPIError)?.isUnauthorized == true, token == sessionToken { expireSession() }
            if case .rateLimited(let delay, _) = error as? KikiAPIError { lastQualityReportAt = Date().addingTimeInterval(Double(delay)) }
        }
    }

    private func applyRoomState(_ state: KikiRoomState, to liveRoom: Room) async {
        guard room === liveRoom, !privacySuspended, state.room.id == currentRoomID,
              state.me.userID == credentials?.userID,
              state.revision >= (roomState?.revision ?? -1) else { return }
        let audioPermissionChanged = roomState?.me.canPublishAudio != state.me.canPublishAudio
        if audioPermissionChanged { audioPolicyGeneration += 1 }
        if roomState != state { roomState = state }
        if roomInfo != state.room { roomInfo = state.room }
        // A grant restoration never reopens the microphone. The user must choose to capture audio.
        if !state.me.canPublishAudio, audioPermissionChanged || liveRoom.localParticipant.isMicrophoneEnabled() {
            // HTTP can report revoked rights before the signalling delegate.
            // Fence device input before awaiting the SDK's publication mute.
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
            if liveRoom.localParticipant.isMicrophoneEnabled() {
                do { _ = try await liveRoom.localParticipant.setMicrophone(enabled: false) }
                catch { runtimeIssue(error, stage: .audioPolicy, code: .audioPublishFailed, key: "permission_microphone_stop", severity: .error) }
            }
        }
        refreshParticipants(liveRoom)
    }

    @discardableResult
    private func requireLogin() throws -> String {
        guard isLoggedIn, let sessionToken else { throw KikiRTCError.unavailable("请先登录账号。") }
        return sessionToken
    }

    private func checkLifecycle(_ generation: Int) throws {
        guard generation == lifecycleGeneration, !privacySuspended else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func isLabServer(_ value: String) -> Bool {
        guard let url = URL(string: value) else { return false }
        return url.scheme == "wss" && url.host == "furby.top" && url.user == nil && url.password == nil
            && url.port == nil && url.query == nil && url.fragment == nil && (url.path.isEmpty || url.path == "/")
    }

    private func expireSession() {
        stopMediaForPrivacy()
        onSessionExpired?()
    }

    private func present(liveRoom: Room, generation: Int) async throws {
        // The create-room sheet may still be finishing its dismissal animation.
        for _ in 0..<15 {
            if Self.topController()?.isBeingDismissed != true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try checkLifecycle(generation)
        guard room === liveRoom, liveRoom.connectionState == .connected,
              let presenter = Self.topController(), presenter.viewIfLoaded?.window != nil else {
            throw KikiRTCError.unavailable("当前页面尚未准备好，请稍后重试。")
        }
        let child = KikiRoomHostingController(rootView: KikiLiveKitRoomView(rtc: self))
        child.modalPresentationStyle = .fullScreen
        child.isModalInPresentation = true
        roomController = child
        isPresentingRoom = true
        UIApplication.shared.isIdleTimerDisabled = true
        await withCheckedContinuation { continuation in
            presenter.present(child, animated: true) { continuation.resume() }
        }
        try checkLifecycle(generation)
    }

    func minimizeRoom() async {
        guard isPresentingRoom, !isVoiceRoomMinimized, !isTransitioningRoom, !isLeavingRoom,
              let controller = roomController, let liveRoom = room,
              let scene = controller.viewIfLoaded?.window?.windowScene else { return }
        let generation = lifecycleGeneration
        isTransitioningRoom = true
        controller.view.endEditing(true)
        floatingOverlay = KikiVoiceRoomFloatingOverlay(windowScene: scene, roomTitle: roomInfo?.title ?? "语聊房",
                                                      avatarURL: roomInfo?.hostAvatarURL,
                                                      avatarIndex: roomInfo?.hostAvatarIndex ?? 0,
                                                      hostName: roomInfo?.host ?? "") { [weak self] in
            Task { try? await self?.resumeRoom() }
        }
        await withCheckedContinuation { continuation in controller.dismiss(animated: true) { continuation.resume() } }
        guard generation == lifecycleGeneration, room === liveRoom else { return }
        isPresentingRoom = false
        isVoiceRoomMinimized = true
        isTransitioningRoom = false
        UIApplication.shared.isIdleTimerDisabled = false
        updateFloatingStatus()
        floatingOverlay?.show()
    }

    func resumeRoom() async throws {
        guard isVoiceRoomMinimized, !isTransitioningRoom, !isLeavingRoom,
              let controller = roomController, let liveRoom = room,
              let presenter = Self.topController(), presenter.viewIfLoaded?.window != nil else { return }
        let generation = lifecycleGeneration
        isTransitioningRoom = true
        floatingOverlay?.hide()
        presenter.view.endEditing(true)
        await withCheckedContinuation { continuation in presenter.present(controller, animated: true) { continuation.resume() } }
        guard generation == lifecycleGeneration, room === liveRoom else { return }
        isVoiceRoomMinimized = false
        isPresentingRoom = true
        isTransitioningRoom = false
        UIApplication.shared.isIdleTimerDisabled = disconnectionReason == nil
    }

    private func updateFloatingStatus() {
        let hostOnline = roomState?.members.first { $0.userID == roomInfo?.hostID }?.online ?? false
        let isOnline = hostOnline && connectionState == .connected && !isRecovering && disconnectionReason == nil
        floatingOverlay?.update(roomTitle: roomInfo?.title ?? "语聊房",
                                status: isOnline ? "语聊中" : "已离线",
                                avatarURL: roomInfo?.hostAvatarURL, avatarIndex: roomInfo?.hostAvatarIndex ?? 0,
                                hostName: roomInfo?.host ?? "",
                                isSpeaking: isOnline && participants.contains { $0.isSpeaking && !safetyState.blockedIDs.contains($0.id) },
                                isOnline: isOnline)
    }

    private func dismissTerminatedMinimizedRoom(_ message: String, expectedRoom: Room, generation: Int) {
        guard room === expectedRoom, generation == lifecycleGeneration, !privacySuspended, isVoiceRoomMinimized else { return }
        room?.remove(delegate: self)
        clearRoomState(notify: true)
        socialStore?.toast = message
    }

    private func startAudioMonitoring(_ liveRoom: Room) {
        audioMonitor.onUpdate = { [weak self, weak liveRoom] state, event in
            guard let self, let liveRoom, self.room === liveRoom, !self.privacySuspended else { return }
            if self.audioState != state { self.audioState = state }
            if event == .mediaServicesLost {
                self.runtimeIssue(stage: .audioPolicy, code: .audioPublishFailed, key: "system_audio_unavailable")
            }
            guard event?.mustStopCapture == true else { return }
            self.audioRecoveryGeneration += 1
            self.recoveryCaptureIntent = nil
            // Fence capture synchronously before any asynchronous SDK mute can run.
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
            self.microphoneEnabled = false
            self.updateFloatingStatus()
            let generation = self.lifecycleGeneration
            Task { [weak self, weak liveRoom] in
                guard let self, let liveRoom, self.room === liveRoom, generation == self.lifecycleGeneration else { return }
                _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false)
                self.refreshParticipants(liveRoom)
            }
        }
        audioMonitor.start()
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self, weak liveRoom] _ in
            Task { @MainActor in
                guard let self, let liveRoom, self.room === liveRoom, !self.privacySuspended,
                      let roomID = self.currentRoomID else { return }
                let generation = self.lifecycleGeneration
                do { try await self.observed(.accountAuthorization, independent: true) { try await self.renewAuthorization?() } }
                catch {
                    guard self.room === liveRoom, generation == self.lifecycleGeneration, !self.privacySuspended else { return }
                    guard !(error is CancellationError), !Task.isCancelled else { return }
                    self.runtimeIssue(error, stage: .reconnect, code: .reconnectFailed, key: "renew_authorization")
                    guard KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: error, expiresAt: self.credentials?.expiresAt ?? 0) else {
                        self.expireSession(); return
                    }
                    // Foreground entry does not end a background call. Keep the
                    // unexpired authorization while the lease task retries.
                }
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      !self.privacySuspended, !Task.isCancelled, let token = self.sessionToken else { return }
                await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
                guard self.room === liveRoom, generation == self.lifecycleGeneration,
                      !self.privacySuspended, !Task.isCancelled, let currentToken = self.sessionToken else { return }
                await self.synchronizeChat(roomID: roomID, token: currentToken, liveRoom: liveRoom, generation: generation, force: true)
            }
        }
    }

    func setSpeakerPreferred(_ enabled: Bool) {
        guard room != nil, !privacySuspended else { return }
        speakerPreferred = enabled
        AudioManager.shared.isSpeakerOutputPreferred = enabled
        audioMonitor.refresh()
    }

    private func startedReconnect(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended, disconnectionReason == nil else { return }
        if !transportIsReconnecting {
            runtimeIssue(stage: .reconnect, code: .networkConnectionLost, key: "reconnecting")
            recoveryCaptureIntent = KikiMicrophoneRecoveryIntent(enabled: liveRoom.localParticipant.isMicrophoneEnabled(), policy: audioPolicyGeneration,
                                     safety: audioRecoveryGeneration, revision: roomState?.revision ?? -1)
            reconnectCount += 1
        }
        transportIsReconnecting = true
        isRecovering = true
        safetyLoaded = false
        safetyMutationGeneration += 1
        nextSafetySyncAt = .distantPast
        networkMetrics = .init()
        // Playback remains fenced until the durable block list has refreshed.
        // A failed refresh cannot resume a track newly blocked on another device.
        try? AudioManager.shared.setEngineAvailability(.none)
        updateFloatingStatus()
    }

    private func completedReconnect(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended, liveRoom.connectionState == .connected,
              disconnectionReason == nil else { return }
        transportIsReconnecting = false
        recoveryTask?.cancel()
        let generation = lifecycleGeneration
        guard let roomID = currentRoomID, sessionToken != nil else { return }
        recoveryTask = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            do { try await self.observed(.accountAuthorization, independent: true) { try await self.renewAuthorization?() } }
            catch {
                guard self.room === liveRoom, generation == self.lifecycleGeneration, !self.privacySuspended else { return }
                guard !(error is CancellationError), !Task.isCancelled else { return }
                self.runtimeIssue(error, stage: .reconnect, code: .reconnectFailed, key: "renew_authorization")
                guard KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: error, expiresAt: self.credentials?.expiresAt ?? 0) else {
                    self.expireSession(); return
                }
                // Media transport recovered; a temporary refresh failure may
                // reuse valid credentials, with safety and room grants checked
                // below before the previous microphone intent can resume.
            }
            guard self.room === liveRoom, generation == self.lifecycleGeneration,
                  !self.privacySuspended, !Task.isCancelled else { return }
            do { try await self.refreshSafety() }
            catch {
                guard generation == self.lifecycleGeneration, self.room === liveRoom,
                      !self.privacySuspended, !Task.isCancelled else { return }
                self.safetyError = "黑名单暂未同步，音频暂停，稍后自动重试。"
                self.nextSafetySyncAt = Date().addingTimeInterval(5)
                return
            }
            guard self.room === liveRoom, generation == self.lifecycleGeneration,
                  !self.privacySuspended, !Task.isCancelled else { return }
            await self.applyAudioBlocks(to: liveRoom)
            guard self.room === liveRoom, generation == self.lifecycleGeneration,
                  !self.privacySuspended, !Task.isCancelled, let renewedToken = self.sessionToken else { return }
            await self.synchronizeRoom(roomID: roomID, token: renewedToken, liveRoom: liveRoom, generation: generation, force: true)
            guard self.room === liveRoom, generation == self.lifecycleGeneration,
                  !self.privacySuspended, !Task.isCancelled, let currentToken = self.sessionToken else { return }
            await self.synchronizeChat(roomID: roomID, token: currentToken, liveRoom: liveRoom, generation: generation, force: true)
        }
    }

    private func clearRoomState(notify: Bool) {
        let closedID = currentRoomID
        lifecycleGeneration += 1
        safetyReads.cancel(); reportReads.cancel(); safetyLoadingWaiters = []; isLoadingSafety = false
        audioPolicyGeneration += 1
        roomStateTask?.cancel()
        roomStateTask = nil
        stateSyncTask?.cancel()
        stateSyncTask = nil
        roomHintTask?.cancel()
        roomHintTask = nil
        roomHintGate = .init()
        publishRoomHintTask?.cancel()
        publishRoomHintTask = nil
        outgoingRoomHints = []
        chatSyncTask?.cancel()
        chatSyncTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        floatingOverlay?.hide()
        floatingOverlay = nil
        audioMonitor.stop()
        audioMonitor.onUpdate = nil
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        foregroundObserver = nil
        room = nil
        roomController = nil
        currentRoomID = nil
        roomInfo = nil
        roomState = nil
        isPerformingRoomAction = false
        isPresentingRoom = false
        isVoiceRoomMinimized = false
        isTransitioningRoom = false
        isRecovering = false
        transportIsReconnecting = false
        recoveryCaptureIntent = nil
        reconnectCount = 0
        connectionQuality = .unknown
        networkMetrics = .init()
        audioState = .init()
        chatWindow = .init()
        pendingMessage = nil
        messageDraft = ""
        announcement = .empty
        chatSyncNotice = nil
        nextChatSyncAt = .distantPast
        nextRoomSyncAt = .distantPast
        nextMetricsSyncAt = .distantPast
        lastQualityReportAt = .distantPast
        chatFailureCount = 0
        stateFailureCount = 0
        isSavingAnnouncement = false
        isUpdatingRoomDetails = false
        isLoadingDiagnostics = false
        serverDiagnostics = nil
        diagnosticsError = nil
        participants = []
        messages = []
        microphoneEnabled = false
        isChangingMicrophone = false
        isSendingMessage = false
        isLeavingRoom = false
        connectionState = .disconnected
        hasConnected = false
        disconnectionReason = nil
        roomError = nil
        UIApplication.shared.isIdleTimerDisabled = false
        if notify, let closedID {
            onRoomClosed?(closedID)
        }
    }

    private func refreshParticipants(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended else { return }
        let hostID = roomInfo?.hostID
        let local = liveRoom.localParticipant
        let all: [Participant] = [local] + Array(liveRoom.remoteParticipants.values)
        let updatedParticipants = all.compactMap { participant -> KikiVoiceParticipant? in
            guard let id = participant.identity?.stringValue, !id.isEmpty else { return nil }
            let sdkName = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = sdkName.isEmpty ? (id == hostID ? (roomInfo?.host ?? id) : id) : sdkName
            return KikiVoiceParticipant(id: id, name: name, isLocal: participant === local,
                                        isHost: id == hostID, isSpeaking: participant.isSpeaking,
                                        microphoneEnabled: participant.isMicrophoneEnabled())
        }.sorted {
            if $0.isHost != $1.isHost { return $0.isHost }
            return $0.id < $1.id
        }
        if participants != updatedParticipants { participants = updatedParticipants }
        let enabled = local.isMicrophoneEnabled() && audioState.notice == nil && !isRecovering
        if microphoneEnabled != enabled { microphoneEnabled = enabled }
        updateFloatingStatus()
    }

    private func disconnected(_ liveRoom: Room, error: LiveKitError?) {
        guard room === liveRoom, hasConnected, !privacySuspended, !isLeavingRoom, disconnectionReason == nil else { return }
        let wasReconnecting = transportIsReconnecting || isRecovering
        connectionState = .disconnected
        microphoneEnabled = false
        participants = []
        isRecovering = false
        transportIsReconnecting = false
        recoveryCaptureIntent = nil
        try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
        if error?.type != .roomDeleted && error?.type != .participantRemoved {
            runtimeIssue(error, stage: wasReconnecting ? .reconnect : .mediaRuntime, code: wasReconnecting ? .reconnectFailed : .mediaDisconnected, key: "unexpected_disconnect", severity: .error)
        }
        switch error?.type {
        case .roomDeleted: disconnectionReason = "本次语聊已结束。"
        case .participantRemoved:
            disconnectionReason = "当前连接已被移出房间，请返回大厅。"
            // Removal also covers a revoked / expired session. Ask the business
            // service for the precise reason rather than presenting every removal as a ban.
            if let roomID = currentRoomID, let token = sessionToken {
                let generation = lifecycleGeneration
                Task { [weak self, weak liveRoom] in
                    guard let self, let liveRoom else { return }
                    do { _ = try await self.api.roomState(roomID: roomID, token: token) }
                    catch {
                        guard self.room === liveRoom, self.currentRoomID == roomID,
                              generation == self.lifecycleGeneration, !self.privacySuspended else { return }
                        if let error = error as? KikiAPIError {
                            if error.isUnauthorized { self.expireSession() }
                            else if case .server(let status, let message) = error, [403, 404, 409, 410].contains(status) {
                                self.disconnectionReason = message
                            }
                        }
                    }
                }
            }
        case .serverShutdown: disconnectionReason = "语聊服务器已停止，请稍后重新进入。"
        default: disconnectionReason = "语聊连接已断开，请返回后重新进入。"
        }
        UIApplication.shared.isIdleTimerDisabled = false
        updateFloatingStatus()
        if error?.type == .roomDeleted {
            dismissTerminatedMinimizedRoom("本次语聊已结束。", expectedRoom: liveRoom, generation: lifecycleGeneration)
        }
    }

    private static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let current = controller {
            if let presented = current.presentedViewController { controller = presented }
            else if let navigation = current as? UINavigationController { controller = navigation.visibleViewController }
            else if let tab = current as? UITabBarController { controller = tab.selectedViewController }
            else { return current }
        }
        return controller
    }
}

extension KikiRTCService: RoomDelegate {
    nonisolated func room(_ room: Room, participant: Participant, didUpdatePermissions permissions: ParticipantPermissions) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.privacySuspended else { return }
            if participant === room.localParticipant, !permissions.canPublish || (!permissions.canPublishSources.isEmpty && !permissions.canPublishSources.contains(Track.Source.microphone.rawValue)) {
                self.audioPolicyGeneration += 1
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: self.safetyLoaded && !self.privacySuspended))
                do { _ = try await room.localParticipant.setMicrophone(enabled: false) }
                catch { self.runtimeIssue(error, stage: .audioPolicy, code: .audioPublishFailed, key: "permission_microphone_stop", severity: .error) }
            }
            self.refreshParticipants(room)
            self.requestRoomRefresh([.state], in: room)
        }
    }

    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in self?.startedReconnect(room) }
    }

    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in self?.completedReconnect(room) }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, participant === room.localParticipant, !self.privacySuspended else { return }
            if self.connectionQuality != quality { self.connectionQuality = quality }
        }
    }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.privacySuspended else { return }
            if self.connectionState != connectionState { self.connectionState = connectionState }
            if connectionState == .connected { self.refreshParticipants(room) }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in self?.disconnected(room, error: error) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyAudioBlocks(to: room)
            self.refreshParticipants(room)
            self.requestRoomRefresh([.state], in: room)
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
            self?.requestRoomRefresh([.state], in: room)
        }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateName name: String) {
        Task { @MainActor [weak self] in
            self?.refreshParticipants(room)
            self?.requestRoomRefresh([.state], in: room)
        }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateMetadata metadata: String?) {
        Task { @MainActor [weak self] in self?.requestRoomRefresh([.state], in: room) }
    }

    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.privacySuspended else { return }
            await publication.track?.set(reportStatistics: true)
            self.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyAudioBlocks(to: room)
            self.refreshParticipants(room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.applyAudioBlocks(to: room)
        }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        // All displayed text and sender identity come from authenticated HTTPS.
        // A participant can only hint that a poll may be useful, never inject chat.
        let resources: Set<KikiRoomSyncHint.Resource>
        if topic == KikiChatSyncHint.topic, KikiChatSyncHint.decode(data) != nil { resources = [.chat] }
        else if topic == KikiRoomSyncHint.topic, let hint = KikiRoomSyncHint.decode(data) { resources = Set(hint.resources) }
        else { return }
        Task { @MainActor [weak self] in
            self?.requestRoomRefresh(resources, in: room)
        }
    }
}
