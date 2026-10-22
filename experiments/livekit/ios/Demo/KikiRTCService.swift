import AVFoundation
import Combine
import Foundation
import LiveKit
import SwiftUI
import UIKit

/// Live room information returned by the real RTC service, rather than a local seed list.
struct KikiRTCListing: Identifiable, Equatable {
    let id: String
    let title: String
    let host: String
    let hostID: String
    let audience: Int
    let isLive: Bool
    let category: String
    let theme: Int
    let coverURL: String
    let avatarURL: String
    let startTime: Int
}

enum KikiRTCError: Foundation.LocalizedError {
    case unavailable(String)
    case sdk(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .sdk(let code, let message): return "\(message)（\(code)）"
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
    func isCurrentRoom(_ roomID: String) -> Bool
    func requireNoActiveRoom() throws
    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws
    func logout() async
    func stopMediaForPrivacy()
    func logoutForPrivacy() async throws
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws
    func fetchRooms() async throws -> [KikiRTCListing]
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws
    func configureGifts(_ gifts: KikiGiftStore?)
}

extension KikiRTCServicing {
    func configureGifts(_ gifts: KikiGiftStore?) { }
}

extension Notification.Name {
    static let kikiRTCRoomClosed = Notification.Name("KikiRTCRoomClosed")
    static let kikiRTCSessionExpired = Notification.Name("KikiRTCSessionExpired")
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
}

/// This envelope contains no claimed sender. The authenticated LiveKit participant
/// attached to each data packet is the sole source of sender identity and name.
struct KikiVoiceChatPacket: Codable {
    let version: Int
    let id: String
    let text: String

    static let topic = "kiki.chat"
    static let maximumTextBytes = 2_000
    static let maximumPacketBytes = 4_096

    static func encode(_ text: String) throws -> (KikiVoiceChatPacket, Data) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= maximumTextBytes else {
            throw KikiRTCError.unavailable("消息不能为空，且不能超过 2000 字节。")
        }
        let packet = KikiVoiceChatPacket(version: 1, id: UUID().uuidString, text: text)
        let data = try JSONEncoder().encode(packet)
        guard data.count <= maximumPacketBytes else { throw KikiRTCError.unavailable("消息过长。") }
        return (packet, data)
    }

    static func decode(_ data: Data) -> KikiVoiceChatPacket? {
        guard data.count <= maximumPacketBytes,
              let packet = try? JSONDecoder().decode(Self.self, from: data),
              packet.version == 1, UUID(uuidString: packet.id) != nil,
              !packet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              packet.text.utf8.count <= maximumTextBytes else { return nil }
        return packet
    }
}

/// Owns a single real LiveKit session. Business authentication and short-lived
/// participant tokens come from the isolated lab backend; no signing key is in the app.
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
    @Published private(set) var serverDiagnostics: KikiServerDiagnostics?
    @Published private(set) var diagnosticsError: String?
    @Published private(set) var isLoadingDiagnostics = false
    @Published private(set) var roomInfo: DemoRoom?
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
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?

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
    private var recoveryTask: Task<Void, Never>?
    private var nextChatSyncAt = Date.distantPast
    private var nextChatHintAt = Date.distantPast
    private var nextRoomSyncAt = Date.distantPast
    private var chatFailureCount = 0
    private var stateFailureCount = 0
    private var lastQualityReportAt = Date.distantPast
    private var audioRecoveryGeneration = 0
    private var transportIsReconnecting = false
    private var recoveryCaptureIntent: KikiMicrophoneRecoveryIntent?
    private var lifecycleGeneration = 0
    private var loginAttemptGeneration = 0
    private var privacySuspended = false
    private var hasConnected = false
    private var profileName = ""
    private var lastMessageTime = Date.distantPast
    private var messageKeys: Set<String> = []
    private var pendingPrivacyDisconnect: Task<Void, Never>?
    private var privacyRoom: (id: String, token: String)?
    private var roomStateTask: Task<Void, Never>?
    private var audioPolicyGeneration = 0

    var isLoggedIn: Bool { !privacySuspended && credentials != nil && sessionToken != nil }
    var currentSDKRoomID: String? { currentRoomID }
    var currentRoomSID: String? { room?.sid?.stringValue }
    var roomPresentationID: ObjectIdentifier? { roomController.map(ObjectIdentifier.init) }
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

    func configure(api: KikiAPIClient) { self.api = api }
    func configureGifts(_ gifts: KikiGiftStore?) { }

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
            throw KikiRTCError.unavailable("LiveKit 实验服务配置无效。")
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
        self.credentials = credentials
        self.sessionToken = sessionToken
        privacySuspended = false
    }

    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws {
        try requireLogin()
        guard credentials?.userID == userID else { throw KikiRTCError.unavailable("账号状态已变化，请重新登录。") }
        // The Store saves profile changes through HTTPS first. Participant names
        // inside an active room remain the server-authenticated LiveKit name.
        profileName = name
    }

    func fetchRooms() async throws -> [KikiRTCListing] {
        let token = try requireLogin()
        let generation = lifecycleGeneration
        let rooms = try await api.rtcRooms(token: token)
        try checkLifecycle(generation)
        return rooms.map {
            KikiRTCListing(id: $0.id, title: $0.title, host: $0.host, hostID: $0.hostID,
                           audience: $0.audience, isLive: $0.isLive, category: $0.category,
                           theme: $0.theme, coverURL: "", avatarURL: $0.hostAvatarURL ?? "", startTime: $0.createdAt)
        }
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
        guard !isLive else { throw KikiRTCError.unavailable("LiveKit 实验版目前仅支持语聊，视频直播尚未接入。") }
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
            let connection = try await api.rtcJoin(roomID: roomID, token: token)
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
            messageKeys = []
            lastMessageTime = .distantPast
            try AudioManager.shared.setEngineAvailability(.default)
            AudioManager.shared.isSpeakerOutputPreferred = speakerPreferred
            let liveRoom = Room(delegate: self, roomOptions: RoomOptions(
                defaultAudioPublishOptions: AudioPublishOptions(encoding: .presetSpeech),
                reportRemoteTrackStatistics: true))
            room = liveRoom
            hasConnected = false
            try await liveRoom.connect(url: connection.serverURL, token: connection.participantToken)
            try checkLifecycle(generation)
            guard liveRoom.connectionState == .connected else { throw KikiRTCError.unavailable("语聊连接未完成，请重试。") }
            hasConnected = true
            connectionState = .connected
            try checkLifecycle(generation)
            let state = try await api.roomState(roomID: roomID, token: token)
            try checkLifecycle(generation)
            await applyRoomState(state, to: liveRoom)
            startAudioMonitoring(liveRoom)
            await synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
            startRoomStatePolling(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
            refreshParticipants(liveRoom)
            try await present(liveRoom: liveRoom, generation: generation)
        } catch {
            // A privacy transition may already have detached this room. Never
            // clear a newer session when an older connect operation finishes.
            if generation == lifecycleGeneration {
                let failedRoom = room
                failedRoom?.remove(delegate: self)
                await failedRoom?.disconnect()
                clearRoomState(notify: false)
            }
            if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
            throw error
        }
    }

    func toggleMicrophone() async {
        guard (canUseRoom || microphoneEnabled), !isChangingMicrophone, let room else { return }
        let generation = lifecycleGeneration
        let policyGeneration = audioPolicyGeneration
        let safetyGeneration = audioRecoveryGeneration
        let enabled = !microphoneEnabled
        if !enabled {
            audioRecoveryGeneration += 1
            recoveryCaptureIntent = nil
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
        }
        isChangingMicrophone = true
        defer { if generation == lifecycleGeneration, self.room === room { isChangingMicrophone = false } }
        do {
            if enabled {
                guard !audioState.interrupted else { throw KikiRTCError.unavailable("系统音频中断尚未结束。") }
                guard canPublishAudio else { throw KikiRTCError.unavailable(microphoneStatus) }
                guard await KikiMicrophonePermission.request() else {
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
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
                _ = try? await room.localParticipant.setMicrophone(enabled: false)
                throw KikiRTCError.unavailable("发言权限已变化，麦克风已关闭。请确认麦位后手动开麦。")
            }
            if enabled { audioMonitor.clearNotice() }
            refreshParticipants(room)
        } catch {
            if generation == lifecycleGeneration, self.room === room { roomError = "麦克风切换失败：\(error.localizedDescription)" }
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
            let confirmed = try await api.sendRoomMessage(roomID: roomID, clientMessageID: candidate.clientMessageID, text: text, token: token)
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
                else { roomError = "发送未确认，草稿已保留，可重试：\(error.localizedDescription)" }
            }
            return false
        }
    }

    func performRoomAction(_ action: KikiRoomAction, targetUserID: String? = nil, seatIndex: Int? = nil, enabled: Bool? = nil) async {
        guard canUseRoom, !isPerformingRoomAction, let roomID = currentRoomID,
              let token = sessionToken, let liveRoom = room else { return }
        let generation = lifecycleGeneration
        isPerformingRoomAction = true
        defer { if generation == lifecycleGeneration, room === liveRoom { isPerformingRoomAction = false } }
        do {
            let state = try await api.roomAction(action, roomID: roomID, targetUserID: targetUserID,
                                                seatIndex: seatIndex, enabled: enabled, token: token)
            try checkLifecycle(generation)
            guard room === liveRoom, currentRoomID == roomID else { return }
            await applyRoomState(state, to: liveRoom)
        } catch {
            guard generation == lifecycleGeneration, room === liveRoom else { return }
            if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
            else if !(error is CancellationError) { roomError = error.localizedDescription }
        }
    }

    func leaveRoom(endRoom: Bool = false) async {
        guard !isLeavingRoom, let roomID = currentRoomID else { return }
        isLeavingRoom = true
        let generation = lifecycleGeneration
        defer { if generation == lifecycleGeneration { isLeavingRoom = false } }
        do {
            if endRoom, isRoomOwner, disconnectionReason == nil, let token = sessionToken {
                // PATCH ended deletes the server room and ends media for everyone.
                // Keep the current connection if that operation fails, so hosts can retry.
                _ = try await api.setRoomStatus(roomID, status: "ended", token: token)
            } else if let token = sessionToken {
                if disconnectionReason == nil { try await api.leaveRoom(roomID: roomID, token: token) }
                else {
                    // Release a recoverable admission as soon as possible. A room
                    // already ended or revoked must still be locally dismissible.
                    try? await api.leaveRoom(roomID: roomID, token: token)
                }
            }
            try checkLifecycle(generation)
            let leavingRoom = room
            leavingRoom?.remove(delegate: self)
            await leavingRoom?.disconnect()
            roomController?.dismiss(animated: true)
            clearRoomState(notify: true)
        } catch {
            if generation == lifecycleGeneration {
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
        profileName = ""
        await pendingPrivacyDisconnect?.value
        pendingPrivacyDisconnect = nil
        KikiSDKAvatarTrust.clearPrivateImages()
        if let previousRoom {
            // The server releases this member and transfers ownership when needed.
            // Account logout / withdrawal separately revoke its session and room grants.
            try? await api.leaveRoom(roomID: previousRoom.id, token: previousRoom.token)
        }
    }

    private func startRoomStatePolling(roomID: String, token: String, liveRoom: Room, generation: Int) {
        roomStateTask?.cancel()
        roomStateTask = Task { [weak self, weak liveRoom] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(Double.random(in: 1.5...1.8) * 1_000_000_000)) } catch { return }
                guard let self, let liveRoom, self.room === liveRoom, self.currentRoomID == roomID,
                      generation == self.lifecycleGeneration, !self.privacySuspended,
                      self.disconnectionReason == nil else { return }
                await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
                guard self.room === liveRoom, self.disconnectionReason == nil, !self.privacySuspended else { return }
                await self.synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
                self.refreshNetworkMetrics(liveRoom)
                await self.reportQualityIfNeeded(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation)
            }
        }
    }

    private func synchronizeRoom(roomID: String, token: String, liveRoom: Room, generation: Int, force: Bool = false) async {
        guard force || Date() >= nextRoomSyncAt else { return }
        do {
            let state = try await api.roomState(roomID: roomID, token: token)
            try checkLifecycle(generation)
            guard room === liveRoom else { return }
            stateFailureCount = 0
            nextRoomSyncAt = .distantPast
            await applyRoomState(state, to: liveRoom)
            if isRecovering, !transportIsReconnecting, liveRoom.connectionState == .connected {
                if recoveryCaptureIntent?.mayResume(policy: audioPolicyGeneration, safety: audioRecoveryGeneration,
                    revision: state.revision, canPublish: state.me.canPublishAudio,
                    interrupted: audioState.interrupted, hasNotice: audioState.notice != nil) == true {
                    try AudioManager.shared.setEngineAvailability(.default)
                } else if liveRoom.localParticipant.isMicrophoneEnabled() {
                    _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false)
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
            await handleRoomReadError(error, liveRoom: liveRoom)
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
                    let page = try await self.api.roomMessages(roomID: roomID, afterSeq: cursor, token: token)
                    try self.checkLifecycle(generation)
                    guard self.room === liveRoom, self.currentRoomID == roomID, self.disconnectionReason == nil else { return }
                    if !self.chatWindow.apply(page, requestedAfterSeq: cursor) { cursor = 0; continue }
                    self.publishChatWindow()
                    self.chatFailureCount = 0
                    self.nextChatSyncAt = .distantPast
                    self.chatSyncNotice = self.chatWindow.isTruncated ? "仅显示最近 200 条、2 小时内的可用消息" : nil
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
                await self.handleRoomReadError(error, liveRoom: liveRoom)
            }
        }
        chatSyncTask = task
        await task.value
    }

    private func publishChatWindow() {
        messages = chatWindow.messages.map {
            KikiVoiceMessage(id: $0.id, senderID: $0.senderUserID, senderName: $0.senderName,
                             text: $0.text, isLocal: $0.senderUserID == credentials?.userID)
        }
        announcement = chatWindow.announcement
        if let pendingMessage, chatWindow.messages.contains(where: { $0.clientMessageID == pendingMessage.clientMessageID && $0.senderUserID == credentials?.userID }) {
            if messageDraft.trimmingCharacters(in: .whitespacesAndNewlines) == pendingMessage.text { messageDraft = "" }
            self.pendingMessage = nil
        }
    }

    private func backoff(_ error: Error, failures: Int) -> TimeInterval {
        if case .rateLimited(let seconds, _) = error as? KikiAPIError { return Double(seconds) + Double.random(in: 0.2...0.8) }
        return min(30, pow(2, Double(min(failures, 5)))) + Double.random(in: 0.2...0.8)
    }

    private func handleRoomReadError(_ error: Error, liveRoom: Room) async {
        if let error = error as? KikiAPIError {
            if error.isUnauthorized { expireSession(); return }
            if case .server(let status, let message) = error, [403, 404, 409, 410].contains(status) {
                disconnectionReason = message
                microphoneEnabled = false
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
                _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false)
                await liveRoom.disconnect()
                updateFloatingStatus()
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
            let value = try await api.setRoomAnnouncement(roomID: roomID, text: text, token: token)
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
            let value = try await api.diagnostics(token: token)
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
        connectionQuality = liveRoom.localParticipant.connectionQuality
        let tracks = ([liveRoom.localParticipant] as [Participant] + Array(liveRoom.remoteParticipants.values))
            .flatMap { Array($0.trackPublications.values) }.compactMap(\.track).filter { $0.kind == .audio }
        networkMetrics = KikiNetworkMetrics.collect(tracks)
    }

    private func reportQualityIfNeeded(roomID: String, token: String, liveRoom: Room, generation: Int) async {
        guard UIApplication.shared.applicationState == .active, canUseRoom,
              Date().timeIntervalSince(lastQualityReportAt) >= 10 else { return }
        lastQualityReportAt = Date()
        let sample = KikiRoomQualitySample(quality: connectionQuality.kikiValue, rttMs: networkMetrics.rttMs,
                                          jitterMs: networkMetrics.jitterMs, packetLossPercent: networkMetrics.packetLossPercent)
        do { try await api.reportRoomQuality(roomID: roomID, sample: sample, token: token) }
        catch {
            guard generation == lifecycleGeneration, room === liveRoom else { return }
            if (error as? KikiAPIError)?.isUnauthorized == true { expireSession() }
            if case .rateLimited(let delay, _) = error as? KikiAPIError { lastQualityReportAt = Date().addingTimeInterval(Double(delay)) }
        }
    }

    private func applyRoomState(_ state: KikiRoomState, to liveRoom: Room) async {
        guard room === liveRoom, !privacySuspended, state.room.id == currentRoomID,
              state.me.userID == credentials?.userID,
              state.revision >= (roomState?.revision ?? -1) else { return }
        if roomState?.me.canPublishAudio != state.me.canPublishAudio { audioPolicyGeneration += 1 }
        roomState = state
        roomInfo = state.room
        // A grant restoration never reopens the microphone. The user must choose to capture audio.
        if !state.me.canPublishAudio {
            // HTTP can report revoked rights before the signalling delegate.
            // Fence device input before awaiting the SDK's publication mute.
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
            if liveRoom.localParticipant.isMicrophoneEnabled() {
                _ = try? await liveRoom.localParticipant.setMicrophone(enabled: false)
            }
        }
        refreshParticipants(liveRoom)
    }

    @discardableResult
    private func requireLogin() throws -> String {
        guard isLoggedIn, let sessionToken else { throw KikiRTCError.unavailable("请先登录实验账号。") }
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
        NotificationCenter.default.post(name: .kikiRTCSessionExpired, object: nil)
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
        let child = UIHostingController(rootView: KikiLiveKitRoomView(rtc: self))
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
        floatingOverlay = KikiVoiceRoomFloatingOverlay(windowScene: scene, roomTitle: roomInfo?.title ?? "语聊房", avatarURL: nil) { [weak self] in
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
        floatingOverlay?.update(roomTitle: roomInfo?.title ?? "语聊房",
                                status: disconnectionReason != nil ? "已断开" : (isRecovering ? "重连中" : (microphoneEnabled ? "发言中" : "语聊中")))
    }

    private func startAudioMonitoring(_ liveRoom: Room) {
        audioMonitor.onUpdate = { [weak self, weak liveRoom] state, event in
            guard let self, let liveRoom, self.room === liveRoom, !self.privacySuspended else { return }
            self.audioState = state
            guard event?.mustStopCapture == true else { return }
            self.audioRecoveryGeneration += 1
            self.recoveryCaptureIntent = nil
            // Fence capture synchronously before any asynchronous SDK mute can run.
            try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
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
                      let roomID = self.currentRoomID, let token = self.sessionToken else { return }
                let generation = self.lifecycleGeneration
                await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
                await self.synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
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
            recoveryCaptureIntent = KikiMicrophoneRecoveryIntent(enabled: liveRoom.localParticipant.isMicrophoneEnabled(), policy: audioPolicyGeneration,
                                     safety: audioRecoveryGeneration, revision: roomState?.revision ?? -1)
            reconnectCount += 1
        }
        transportIsReconnecting = true
        isRecovering = true
        networkMetrics = .init()
        try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
        updateFloatingStatus()
    }

    private func completedReconnect(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended, liveRoom.connectionState == .connected,
              disconnectionReason == nil else { return }
        transportIsReconnecting = false
        recoveryTask?.cancel()
        let generation = lifecycleGeneration
        guard let roomID = currentRoomID, let token = sessionToken else { return }
        recoveryTask = Task { [weak self, weak liveRoom] in
            guard let self, let liveRoom else { return }
            await self.synchronizeRoom(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
            guard self.room === liveRoom, !self.privacySuspended else { return }
            await self.synchronizeChat(roomID: roomID, token: token, liveRoom: liveRoom, generation: generation, force: true)
        }
    }

    private func clearRoomState(notify: Bool) {
        let closedID = currentRoomID
        audioPolicyGeneration += 1
        roomStateTask?.cancel()
        roomStateTask = nil
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
        nextChatHintAt = .distantPast
        nextRoomSyncAt = .distantPast
        lastQualityReportAt = .distantPast
        chatFailureCount = 0
        stateFailureCount = 0
        isSavingAnnouncement = false
        isLoadingDiagnostics = false
        serverDiagnostics = nil
        diagnosticsError = nil
        participants = []
        messages = []
        messageKeys = []
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
            NotificationCenter.default.post(name: .kikiRTCRoomClosed, object: closedID)
        }
    }

    private func refreshParticipants(_ liveRoom: Room) {
        guard room === liveRoom, !privacySuspended else { return }
        let hostID = roomInfo?.hostID
        let local = liveRoom.localParticipant
        let all: [Participant] = [local] + Array(liveRoom.remoteParticipants.values)
        participants = all.compactMap { participant in
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
        microphoneEnabled = local.isMicrophoneEnabled()
        if audioState.notice != nil || isRecovering { microphoneEnabled = false }
        updateFloatingStatus()
    }

    private func disconnected(_ liveRoom: Room, error: LiveKitError?) {
        guard room === liveRoom, hasConnected, !privacySuspended, !isLeavingRoom, disconnectionReason == nil else { return }
        connectionState = .disconnected
        microphoneEnabled = false
        participants = []
        isRecovering = false
        transportIsReconnecting = false
        recoveryCaptureIntent = nil
        try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
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
                try? AudioManager.shared.setEngineAvailability(.init(isInputAvailable: false, isOutputAvailable: true))
                _ = try? await room.localParticipant.setMicrophone(enabled: false)
            }
            self.refreshParticipants(room)
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
            self.connectionQuality = quality
        }
    }
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !self.privacySuspended else { return }
            self.connectionState = connectionState
            if connectionState == .connected { self.refreshParticipants(room) }
        }
    }

    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in self?.disconnected(room, error: error) }
    }

    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: Participant, didUpdateName name: String) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
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
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.refreshParticipants(room) }
    }

    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        // All displayed text and sender identity come from authenticated HTTPS.
        // A participant can only hint that a poll may be useful, never inject chat.
        guard topic == KikiChatSyncHint.topic, KikiChatSyncHint.decode(data) != nil else { return }
        Task { @MainActor [weak self] in
            guard let self, self.room === room, self.canUseRoom, let roomID = self.currentRoomID,
                  let token = self.sessionToken, Date() >= self.nextChatHintAt else { return }
            self.nextChatHintAt = Date().addingTimeInterval(1.5)
            await self.synchronizeChat(roomID: roomID, token: token, liveRoom: room, generation: self.lifecycleGeneration)
        }
    }
}

