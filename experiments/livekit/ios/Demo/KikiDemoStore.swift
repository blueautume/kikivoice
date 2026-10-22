import SwiftUI
import UIKit

enum KikiPalette {
    static let background = Color(hex: 0x101014)
    static let surface = Color(hex: 0x1B1B23)
    static let elevated = Color(hex: 0x272632)
    static let purple = Color(hex: 0x8B66FF)
    static let lavender = Color(hex: 0xC6B5FF)
    static let text = Color(hex: 0xF7F5FF)
    static let secondary = Color(hex: 0xB3AFBF)
    static let muted = Color(hex: 0x777381)
    static let mint = Color(hex: 0xB9F2D1)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct DemoRoom: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var host: String
    var hostID: String
    var category: String
    var audience: Int
    var isLive: Bool
    var theme: Int
    var isCreatedByMe: Bool
    var status: String
    var createdAt: Int
    var hostAvatarIndex: Int
    var hostAvatarURL: String?
    var language: String { "中文" }

    init(id: String, title: String, host: String, hostID: String, category: String, audience: Int,
         isLive: Bool, theme: Int, isCreatedByMe: Bool, status: String, createdAt: Int = 0, hostAvatarIndex: Int = 0, hostAvatarURL: String? = nil) {
        self.id = id; self.title = title; self.host = host; self.hostID = hostID
        self.category = category; self.audience = audience; self.isLive = isLive; self.theme = theme
        self.isCreatedByMe = isCreatedByMe; self.status = status; self.createdAt = createdAt
        self.hostAvatarIndex = hostAvatarIndex
        self.hostAvatarURL = hostAvatarURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, host, hostID, category, audience, isLive, theme, isCreatedByMe, status, createdAt, hostAvatarIndex, hostAvatarURL
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        host = try values.decode(String.self, forKey: .host)
        hostID = try values.decode(String.self, forKey: .hostID)
        category = try values.decode(String.self, forKey: .category)
        audience = try values.decode(Int.self, forKey: .audience)
        isLive = try values.decode(Bool.self, forKey: .isLive)
        theme = try values.decode(Int.self, forKey: .theme)
        isCreatedByMe = try values.decode(Bool.self, forKey: .isCreatedByMe)
        status = try values.decode(String.self, forKey: .status)
        createdAt = try values.decodeIfPresent(Int.self, forKey: .createdAt) ?? 0
        hostAvatarIndex = try values.decodeIfPresent(Int.self, forKey: .hostAvatarIndex) ?? 0
        hostAvatarURL = try values.decodeIfPresent(String.self, forKey: .hostAvatarURL)
    }
}

/// Account state is loaded from the authenticated HTTPS API. Active rooms and
/// participant counts come from the independent LiveKit backend, with no seed data.
@MainActor final class KikiDemoStore: ObservableObject {
    @Published private(set) var profileName = ""
    @Published private(set) var bio = ""
    @Published private(set) var avatarIndex = 0
    @Published private(set) var customAvatarURL: String?
    @Published private(set) var needsNickname = false
    @Published private(set) var userID = ""
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var recentRoomIDs: [String] = []
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var rooms: [DemoRoom] = []
    @Published private(set) var isAuthenticated = false
    @Published private(set) var startupFinished = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var isEndingSession = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isJoiningRoom = false
    @Published private(set) var loadingError: String?
    @Published var toast: String?

    let consent: KikiConsentStore
    let gifts = KikiGiftStore()
    private let identity: any KikiIdentityStoring
    private let apiProvider: () -> KikiAPIClient
    private let rtcProvider: @MainActor () -> any KikiRTCServicing
    private var apiStorage: KikiAPIClient?
    private var rtcStorage: (any KikiRTCServicing)?
    private var sessionGeneration = 0
    private var signInAttemptID: UUID?
    private var privacyStopped = false
    private var api: KikiAPIClient {
        if let apiStorage { return apiStorage }
        let value = apiProvider(); apiStorage = value; return value
    }
    private var rtc: any KikiRTCServicing {
        if let rtcStorage { return rtcStorage }
        let value = rtcProvider(); rtcStorage = value; configureRTC(value); return value
    }
    private var token: String?
    private var user: KikiUser?
    private var credentialsExpiry = 0
    private var library = KikiLibrary(favorites: [], recents: [], created: [])
    private var roomMetadata: [DemoRoom] = []
    private var toastTask: Task<Void, Never>?
    private var favoriteTasks: Set<String> = []
    private var didStart = false
    private var renewalTask: Task<Void, Error>?
    private var profileNeedsRTCSync = false

    var avatarURL: String { "" }
    var canReconnect: Bool { token != nil && permitsBusiness && !isAuthenticated }
    var isPresentingRoom: Bool { rtcStorage?.isPresentingRoom ?? false }
    private var permitsBusiness: Bool { consent.hasCurrentConsent && !privacyStopped && !isEndingSession }
    var favoriteRooms: [DemoRoom] { library.favorites.map(reconciled) }
    var recentRooms: [DemoRoom] { library.recents.map(reconciled) }
    var createdRooms: [DemoRoom] { library.created.map(reconciled) }

    init(consent: KikiConsentStore? = nil, identity: any KikiIdentityStoring = KikiKeychainStorage(),
         apiProvider: @escaping () -> KikiAPIClient = { .shared },
         rtcProvider: @escaping @MainActor () -> any KikiRTCServicing = { KikiRTCService.shared }) {
        self.consent = consent ?? .shared
        self.identity = identity
        self.apiProvider = apiProvider
        self.rtcProvider = rtcProvider
    }

    private func configureRTC(_ rtc: any KikiRTCServicing) {
        rtc.onRoomClosed = { [weak self] roomID in
            Task { @MainActor in
                guard let self, self.permitsBusiness, self.isAuthenticated else { return }
                await self.refreshRooms()
                await self.refreshLibrary()
            }
        }
        rtc.onSessionExpired = { [weak self] in
            guard let self, self.permitsBusiness else { return }
            self.isAuthenticated = false
            self.credentialsExpiry = 0
            self.loadingError = "语音连接已失效，请重新连接或登录。"
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        defer { startupFinished = true }
        guard permitsBusiness else { return }
        // Old ID/device-bound accounts are intentionally unsupported.
        identity.remove("deviceSecret")
        identity.remove("lastUserID")
        await retryPendingLogouts()
        guard permitsBusiness else { return }
        guard identity.read("labSessionVersion") == "1" else {
            clearSession()
            return
        }
        guard let saved = identity.read("sessionToken") else { return }
        let generation = sessionGeneration
        token = saved
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let acceptance = try consent.acceptance(agreed: true, adultConfirmed: true)
            let status = try await performAPI { try await api.registerLegalConsent(acceptance, token: saved) }
            try requireAccess(generation: generation, token: saved)
            try consent.verify(status)
            try await renewSDKSession()
            try requireAccess(generation: generation, token: saved)
            isAuthenticated = true
            await refreshRooms()
            await refreshLibrary()
        } catch {
            if sessionGeneration == generation { handle(error, expectedToken: saved) }
        }
    }

    /// The access code only exists in this call; only the issued session enters Keychain.
    func loginForLab(name: String, accessCode: String, agreed: Bool, adultConfirmed: Bool) async throws {
        let acceptance = try consent.acceptance(agreed: agreed, adultConfirmed: adultConfirmed)
        try requireAccess()
        guard !isSigningIn, !isEndingSession else { return }
        let generation = sessionGeneration
        let previousToken = token
        let attemptID = UUID()
        signInAttemptID = attemptID
        isSigningIn = true
        loadingError = nil
        defer { if signInAttemptID == attemptID { isSigningIn = false; signInAttemptID = nil } }
        var issuedToken: String?
        do {
            await retryPendingLogouts()
            try requireAccess(generation: generation)
            let response = try await performAPI {
                try await api.loginForLab(name: name, accessCode: accessCode, legalConsent: acceptance)
            }
            issuedToken = response.token
            try requireAccess(generation: generation)
            if let previousToken, previousToken != response.token { queueLogout(previousToken) }
            try identity.write("1", key: "labSessionVersion")
            try identity.write(response.token, key: "sessionToken")
            token = response.token
            apply(response.user)
            try await connectSDK(response.sdk, generation: generation, expectedToken: response.token)
            try requireAccess(generation: generation, token: response.token)
            isAuthenticated = true
            await refreshRooms()
            await refreshLibrary()
        } catch {
            if let issuedToken, token != issuedToken {
                queueLogout(issuedToken)
                await retryPendingLogouts(allowRightsOnly: true)
            }
            if sessionGeneration == generation { handle(error) }
            throw error
        }
    }

    private func queueLogout(_ token: String) {
        var tokens = pendingLogoutTokens()
        if !tokens.contains(token) { tokens.append(token) }
        if let data = try? JSONEncoder().encode(tokens), let value = String(data: data, encoding: .utf8) {
            try? identity.write(value, key: "labPendingLogouts")
        }
    }

    private func pendingLogoutTokens() -> [String] {
        guard let value = identity.read("labPendingLogouts"),
              let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func retryPendingLogouts(allowRightsOnly: Bool = false) async {
        guard consent.hasCurrentConsent || allowRightsOnly else { return }
        // These endpoints only end authorization. They never resume business services.
        for pending in pendingLogoutTokens() {
            do {
                try await api.logout(token: pending)
                removePendingLogout(pending)
            } catch let error as KikiAPIError where error.isUnauthorized {
                removePendingLogout(pending)
            } catch { /* Retry only at the next deliberate start or sign-in. */ }
        }
    }

    private func removePendingLogout(_ token: String) {
        let remaining = pendingLogoutTokens().filter { $0 != token }
        if remaining.isEmpty { identity.remove("labPendingLogouts") }
        else if let data = try? JSONEncoder().encode(remaining), let value = String(data: data, encoding: .utf8) {
            try? identity.write(value, key: "labPendingLogouts")
        }
    }

    func reconnect() async throws {
        try requireAccess()
        let generation = sessionGeneration
        guard let token else { throw KikiAPIError.server(401, "请先使用实验邀请码登录。") }
        let attemptID = UUID()
        signInAttemptID = attemptID
        isSigningIn = true
        defer { if signInAttemptID == attemptID { isSigningIn = false; signInAttemptID = nil } }
        try await renewSDKSession()
        try requireAccess(generation: generation)
        isAuthenticated = true
        loadingError = nil
        await refreshRooms()
        await refreshLibrary()
    }

    func refreshRooms() async {
        guard permitsBusiness, isAuthenticated, !needsNickname, !isRefreshing, let token else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await ensureSDKSession()
            let records = try await performAPI { try await api.rtcRooms(token: token) }
            try requireAccess(token: token)
            guard isAuthenticated else { return }
            roomMetadata = records
            rooms = records.filter { !$0.isLive && $0.status == "live" }
            loadingError = nil
        } catch {
            handle(error, expectedToken: token)
        }
    }

    func refreshLibrary() async {
        guard permitsBusiness, isAuthenticated, !needsNickname, let token else { return }
        do {
            let loaded = try await performAPI { try await api.library(token: token) }
            guard permitsBusiness, self.token == token, isAuthenticated else { return }
            library = loaded
            favoriteIDs = Set(library.favorites.map(\.id))
            recentRoomIDs = library.recents.map(\.id)
        } catch { handle(error, expectedToken: token) }
    }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int) async throws -> DemoRoom {
        try requireAccess()
        guard let token, isAuthenticated, !needsNickname else { throw KikiAPIError.server(401, "请先登录并设置昵称。") }
        guard !isLive else { throw KikiAPIError.server(422, "实验版暂不支持视频直播，请创建语聊房。") }
        try rtc.requireNoActiveRoom()
        let room = try await performAPI { try await api.reserveRoom(title: title, category: category, isLive: isLive, theme: theme, token: token) }
        try requireAccess(token: token)
        roomMetadata.insert(room, at: 0)
        return room
    }

    func startRoom(_ room: DemoRoom) async throws {
        try requireAccess()
        let generation = sessionGeneration
        guard !isJoiningRoom, !needsNickname, let token else { return }
        isJoiningRoom = true
        defer { isJoiningRoom = false }
        try await ensureSDKSession()
        try requireAccess(generation: generation, token: token)
        do {
            try await rtc.createRoom(roomID: room.id, title: room.title, category: room.category, isLive: room.isLive, theme: room.theme)
            try requireAccess(generation: generation, token: token)
            _ = try await performAPI { try await api.setRoomStatus(room.id, status: "live", token: token) }
            try requireAccess(generation: generation, token: token)
            try await performAPI { try await api.visit(room.id, token: token) }
            await refreshLibrary()
        } catch {
            if permitsBusiness, !rtc.isCurrentRoom(room.id) { _ = try? await api.setRoomStatus(room.id, status: "ended", token: token) }
            throw error
        }
    }

    func openRoom(_ room: DemoRoom) async throws {
        try requireAccess()
        let generation = sessionGeneration
        guard !isJoiningRoom, !needsNickname, let token else { return }
        isJoiningRoom = true
        defer { isJoiningRoom = false }
        try await ensureSDKSession()
        try requireAccess(generation: generation, token: token)
        try await rtc.presentRoom(roomID: room.id, isLive: room.isLive, isOwner: room.isCreatedByMe)
        try requireAccess(generation: generation, token: token)
        do { try await performAPI { try await api.visit(room.id, token: token) }; await refreshLibrary() }
        catch { notify("已加入房间，浏览记录暂未同步：\(error.localizedDescription)") }
    }

    func toggleFavorite(_ room: DemoRoom) {
        guard permitsBusiness, let token, !favoriteTasks.contains(room.id) else { return }
        favoriteTasks.insert(room.id)
        let enabled = !favoriteIDs.contains(room.id)
        Task {
            defer { favoriteTasks.remove(room.id) }
            do {
                try await performAPI { try await api.favorite(room.id, enabled: enabled, token: token) }
                guard self.permitsBusiness, self.token == token else { return }
                await refreshLibrary()
                notify(enabled ? "已收藏房间" : "已取消收藏")
            } catch {
                guard self.token == token else { return }
                notify(error.localizedDescription); handle(error, expectedToken: token)
            }
        }
    }

    func completeNickname(_ name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 16 else {
            throw KikiAPIError.server(422, "请输入 1–16 字的昵称。")
        }
        try await updateProfile(name: trimmed, bio: bio, avatarIndex: avatarIndex)
        await refreshRooms()
    }

    func updateProfile(name: String, bio: String, avatarIndex: Int, jpegData: Data? = nil, clearCustomAvatar: Bool = false) async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        guard jpegData == nil else { throw KikiAPIError.server(422, "实验版暂不支持照片上传，请选择预设头像。") }
        let updated = try await performAPI { try await api.updateProfile(name: name, bio: bio, avatarIndex: avatarIndex, token: token) }
        try requireAccess(token: token)
        apply(updated)
        profileNeedsRTCSync = true
        // Profile is already committed to our server. Retry SDK synchronization
        // at next login if its transient request fails rather than losing edits.
        var profileSynced = false
        do { try await syncRTCProfile(); profileSynced = true }
        catch { try requireAccess(token: token); notify("资料已保存，音视频名片将在下次进房或重新连接时同步。") }
        await refreshLibrary()
        try requireAccess(token: token)
        if profileSynced { notify("个人资料已更新") }
    }

    func setNotificationsEnabled(_ value: Bool) async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        let updated = try await performAPI { try await api.updateNotifications(value, token: token) }
        try requireAccess(token: token)
        apply(updated)
    }

    func logout() async {
        guard !isEndingSession else { return }
        isEndingSession = true
        sessionGeneration += 1
        signInAttemptID = nil
        isSigningIn = true
        defer { isSigningIn = false; isEndingSession = false }
        let oldToken = token
        // Prevent room-close callbacks from starting a new SDK login while the
        // user is intentionally ending this session.
        isAuthenticated = false
        rtcStorage?.stopMediaForPrivacy()
        renewalTask?.cancel()
        await apiStorage?.cancelRequestsAndClearAvatarCache()
        _ = await renewalTask?.result
        await rtcStorage?.logout()
        if let oldToken {
            queueLogout(oldToken)
            await retryPendingLogouts(allowRightsOnly: true)
        }
        clearSession()
    }

    func deleteAccount() async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        isSigningIn = true
        defer { isSigningIn = false }
        // Keep the SDK session usable if the server rejects deletion or the
        // network is offline. Only tear it down after server confirmation.
        try await performAPI { try await api.deleteAccount(token: token) }
        try requireAccess(token: token)
        isEndingSession = true
        sessionGeneration += 1
        isAuthenticated = false
        rtcStorage?.stopMediaForPrivacy()
        renewalTask?.cancel()
        _ = await renewalTask?.result
        await rtcStorage?.logout()
        clearSession()
        isEndingSession = false
    }

    func legalStatus() async throws -> KikiLegalStatus {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        let status = try await performAPI { try await api.legalStatus(token: token) }
        try requireAccess(token: token)
        do { try consent.verify(status) }
        catch { handle(error, expectedToken: token); throw error }
        return status
    }

    func withdrawConsent() async {
        await consent.withdraw { [self] in try await stopForPrivacyWithdrawal() }
    }

    private func stopForPrivacyWithdrawal() async throws {
        privacyStopped = true
        isEndingSession = true
        isAuthenticated = false
        sessionGeneration += 1
        rtcStorage?.stopMediaForPrivacy()
        renewalTask?.cancel()
        await apiStorage?.cancelRequestsAndClearAvatarCache()
        _ = await renewalTask?.result
        // Keep only the existing Keychain session as a retry credential until
        // the server acknowledges withdrawal; never resume SDKs from it.
        clearSession(removeCredential: false)
        try await rtcStorage?.logoutForPrivacy()
    }

    func notify(_ message: String) {
        guard permitsBusiness else { return }
        toastTask?.cancel()
        withAnimation { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    private func reconciled(_ record: DemoRoom) -> DemoRoom {
        if let active = rooms.first(where: { $0.id == record.id }) { return active }
        var closed = record
        closed.audience = 0
        if closed.status == "live", loadingError == nil { closed.status = "ended" }
        return closed
    }

    private func apply(_ user: KikiUser) {
        self.user = user
        userID = user.id
        profileName = user.name
        bio = user.bio
        avatarIndex = user.avatarIndex
        customAvatarURL = nil
        needsNickname = user.needsNickname
        notificationsEnabled = user.notificationsEnabled
    }

    private func ensureSDKSession() async throws {
        try requireAccess()
        if !rtc.isLoggedIn || credentialsExpiry < Int(Date().timeIntervalSince1970) + 300 { try await renewSDKSession() }
        else if profileNeedsRTCSync { try await syncRTCProfile() }
    }

    private func renewSDKSession() async throws {
        try requireAccess()
        if let task = renewalTask { return try await task.value }
        guard let token else { throw KikiAPIError.server(401, "登录已过期，请重新登录。") }
        let generation = sessionGeneration
        let task = Task { @MainActor in
            let refreshed = try await performAPI { try await api.refresh(token: token) }
            try Task.checkCancellation()
            try requireAccess(generation: generation, token: token)
            apply(refreshed.user)
            try await connectSDK(refreshed.sdk, generation: generation, expectedToken: token)
        }
        renewalTask = task
        defer { renewalTask = nil }
        try await task.value
    }

    private func connectSDK(_ credentials: KikiSDKCredentials, generation: Int, expectedToken: String) async throws {
        try requireAccess(generation: generation, token: expectedToken)
        try await rtc.login(credentials: credentials, sessionToken: expectedToken)
        do { try requireAccess(generation: generation, token: expectedToken) }
        catch {
            // A newer login may already own the shared RTC service. Obsolete
            // completion must never terminate that newer business session.
            if token == expectedToken { await rtcStorage?.logout() }
            throw error
        }
        credentialsExpiry = credentials.expiresAt
        if !needsNickname { try await syncRTCProfile() }
    }

    private func syncRTCProfile() async throws {
        try requireAccess()
        guard let user else { return }
        try await rtc.updateProfile(userID: user.sdkUserID, name: user.name, bio: user.bio,
                                    avatarURL: "")
        profileNeedsRTCSync = false
    }

    private func handle(_ error: Error, expectedToken: String? = nil) {
        if let expectedToken, token != expectedToken { return }
        if error is CancellationError { return }
        guard consent.hasCurrentConsent, !privacyStopped else { return }
        loadingError = error.localizedDescription
        if let error = error as? KikiAPIError, case .legalUpdateRequired(let message, let required) = error {
            consent.setServiceTransition(true)
            sessionGeneration += 1
            signInAttemptID = nil
            isSigningIn = false
            isEndingSession = true
            rtcStorage?.stopMediaForPrivacy()
            clearSession()
            consent.requireUpdatedDocuments(required, message: message)
            Task { [self] in
                renewalTask?.cancel()
                await apiStorage?.cancelRequestsAndClearAvatarCache()
                _ = await renewalTask?.result
                await rtcStorage?.logout()
                isEndingSession = false
                consent.setServiceTransition(false)
            }
            return
        }
        if let error = error as? KikiAPIError, error.isUnauthorized {
            sessionGeneration += 1
            signInAttemptID = nil
            isSigningIn = false
            rtcStorage?.stopMediaForPrivacy()
            clearSession()
            loadingError = "登录已过期，请重新登录。"
            isEndingSession = true
            Task {
                renewalTask?.cancel()
                _ = await renewalTask?.result
                await rtcStorage?.logout()
                isEndingSession = false
            }
        }
    }

    private func requireAccess(generation: Int? = nil, token expectedToken: String? = nil) throws {
        try Task.checkCancellation()
        guard permitsBusiness, generation == nil || generation == sessionGeneration,
              expectedToken == nil || expectedToken == token else { throw CancellationError() }
    }

    private func performAPI<Value>(_ operation: () async throws -> Value) async throws -> Value {
        let generation = sessionGeneration
        let expectedToken = token
        do { return try await operation() }
        catch {
            if generation == sessionGeneration, expectedToken == token,
               let apiError = error as? KikiAPIError, case .legalUpdateRequired = apiError { handle(apiError) }
            throw error
        }
    }

    private func clearSession(removeCredential: Bool = true) {
        gifts.reset()
        rtcStorage?.configureGifts(nil)
        if removeCredential {
            identity.remove("sessionToken")
            identity.remove("appleSubject")
            identity.remove("appleSessionVersion")
            identity.remove("labSessionVersion")
        }
        token = nil; user = nil; credentialsExpiry = 0; profileNeedsRTCSync = false
        isAuthenticated = false
        profileName = ""; bio = ""; avatarIndex = 0; customAvatarURL = nil; needsNickname = false; userID = ""
        favoriteIDs = []; recentRoomIDs = []; rooms = []
        roomMetadata = []; library = KikiLibrary(favorites: [], recents: [], created: [])
        loadingError = nil
    }
}

/// Packaged emoji avatars keep the original circular style without external image requests.
@available(iOS 16.0, *)
struct KikiAvatar: View {
    var index: Int
    var size: CGFloat = 40
    var customURL: String? = nil
    private let faces = ["🧑🏻‍🚀", "👩🏻", "🧑🏼", "👩🏽‍🦱", "🧑🏻‍🎨", "👩🏼‍🦰", "🧑🏽‍🎤", "👨🏻‍🦱", "👩🏻‍🎤", "🧑🏼‍🚀", "👩🏾", "👨🏼"]
    private let colors: [Color] = [Color(hex: 0x6351A4), Color(hex: 0x958392), Color(hex: 0x758779), Color(hex: 0xAD796A), Color(hex: 0x6B8F9B)]
    private var safeIndex: Int { max(0, index) }
    var body: some View {
        Text(faces[safeIndex % faces.count]).font(.system(size: size * 0.62))
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [colors[safeIndex % colors.count].opacity(0.8), colors[safeIndex % colors.count].opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(Circle())
            .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

@available(iOS 16.0, *)
struct KikiWave: View {
    var color: Color = KikiPalette.lavender
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<4) { i in Capsule().fill(color).frame(width: 3, height: [8.0, 16, 12, 6][i]) }
        }.accessibilityHidden(true)
    }
}

@available(iOS 16.0, *)
struct KikiCover: View {
    var theme: Int
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(colors.last!.opacity(0.7)).frame(width: 200, height: 200).blur(radius: 26).offset(x: geo.size.width * 0.3, y: -40)
                ForEach(0..<5) { i in
                    Ellipse().stroke(.white.opacity(0.07), lineWidth: 1)
                        .frame(width: 170 + CGFloat(i * 44), height: 85 + CGFloat(i * 30))
                        .rotationEffect(.degrees(-35)).offset(x: geo.size.width * 0.32, y: 30)
                }
                Image(systemName: ["moon.stars.fill", "globe.asia.australia.fill", "music.note", "sparkles", "leaf.fill"][abs(theme) % 5])
                    .font(.system(size: 96, weight: .ultraLight)).foregroundStyle(.white.opacity(0.1))
                    .rotationEffect(.degrees(-12)).offset(x: geo.size.width * 0.33, y: -3)
                ForEach(0..<12) { i in
                    Circle().fill(.white.opacity(i % 3 == 0 ? 0.35 : 0.12)).frame(width: i % 3 == 0 ? 3 : 2)
                        .position(x: geo.size.width * CGFloat((i * 37 + 13) % 100) / 100,
                                  y: geo.size.height * CGFloat((i * 23 + 7) % 100) / 100)
                }
            }
        }.clipped().accessibilityHidden(true)
    }
    private var colors: [Color] {
        [[Color(hex: 0x292244), Color(hex: 0x49406B)],
         [Color(hex: 0x12353A), Color(hex: 0x316363)],
         [Color(hex: 0x472D3C), Color(hex: 0x8A5B50)],
         [Color(hex: 0x21233D), Color(hex: 0x474C78)],
         [Color(hex: 0x333A32), Color(hex: 0x66705A)]][abs(theme) % 5]
    }
}
