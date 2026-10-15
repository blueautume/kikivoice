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
/// participant counts always come from Tencent's live SDK, with no seed data.
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

    private let api: KikiAPIClient
    private let rtc: KikiRTCService
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

    var avatarURL: String { customAvatarURL ?? KikiAvatarSource.url(for: avatarIndex).absoluteString }
    var rememberedID: String { KikiKeychain.read("lastUserID") ?? "" }
    var favoriteRooms: [DemoRoom] { library.favorites.map(reconciled) }
    var recentRooms: [DemoRoom] { library.recents.map(reconciled) }
    var createdRooms: [DemoRoom] { library.created.map(reconciled) }

    init(api: KikiAPIClient = .shared, rtc: KikiRTCService = .shared) {
        self.api = api
        self.rtc = rtc
        rtc.onRoomClosed = { [weak self] roomID in
            Task { @MainActor in
                guard let self, self.isAuthenticated else { return }
                if !self.rtc.isCurrentRoom(roomID),
                   (self.roomMetadata + self.library.created).contains(where: { $0.id == roomID && $0.isCreatedByMe }), let token = self.token {
                    _ = try? await self.api.setRoomStatus(roomID, status: "ended", token: token)
                }
                await self.refreshRooms()
                await self.refreshLibrary()
            }
        }
        rtc.onSessionExpired = { [weak self] in
            guard let self else { return }
            self.isAuthenticated = false
            self.credentialsExpiry = 0
            self.loadingError = "音视频登录已失效，请重新连接；同一账号不能同时在多个设备使用。"
        }
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        defer { startupFinished = true }
        guard let saved = KikiKeychain.read("sessionToken") else { return }
        token = saved
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await renewSDKSession()
            isAuthenticated = true
            await refreshRooms()
            await refreshLibrary()
        } catch {
            handle(error, expectedToken: saved)
        }
    }

    func login(id: String) async throws {
        guard !isSigningIn, !isEndingSession else { return }
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: "^[A-Za-z0-9_-]{3,32}$", options: .regularExpression) != nil else {
            throw KikiAPIError.server(422, "ID 需为 3–32 位字母、数字、下划线或短横线。")
        }
        isSigningIn = true
        loadingError = nil
        defer { isSigningIn = false }
        do {
            let response = try await api.login(userID: id, deviceSecret: KikiKeychain.deviceSecret())
            try KikiKeychain.write(response.token, key: "sessionToken")
            try KikiKeychain.write(id, key: "lastUserID")
            token = response.token
            apply(response.user)
            try await connectSDK(response.sdk)
            isAuthenticated = true
            await refreshRooms()
            await refreshLibrary()
        } catch {
            handle(error)
            throw error
        }
    }

    func reconnect() async throws {
        guard token != nil else { throw KikiAPIError.server(401, "请先输入 ID 登录。") }
        isSigningIn = true
        defer { isSigningIn = false }
        try await renewSDKSession()
        isAuthenticated = true
        loadingError = nil
        await refreshRooms()
        await refreshLibrary()
    }

    func refreshRooms() async {
        guard isAuthenticated, !needsNickname, !isRefreshing, let token else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await ensureSDKSession()
            let listings = try await rtc.fetchRooms()
            let records = try await api.roomMetadata(ids: listings.map(\.id), token: token)
            guard self.token == token, isAuthenticated else { return }
            roomMetadata = records
            let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rooms = listings.compactMap { live in
                guard var room = byID[live.id] else { return nil }
                room.title = live.title.isEmpty ? room.title : live.title
                room.host = live.host.isEmpty ? room.host : live.host
                room.audience = live.audience
                room.status = "live"
                return room
            }
            loadingError = nil
        } catch {
            handle(error, expectedToken: token)
        }
    }

    func refreshLibrary() async {
        guard isAuthenticated, !needsNickname, let token else { return }
        do {
            let loaded = try await api.library(token: token)
            guard self.token == token, isAuthenticated else { return }
            library = loaded
            favoriteIDs = Set(library.favorites.map(\.id))
            recentRoomIDs = library.recents.map(\.id)
        } catch { handle(error, expectedToken: token) }
    }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int) async throws -> DemoRoom {
        guard let token, isAuthenticated, !needsNickname else { throw KikiAPIError.server(401, "请先登录并设置昵称。") }
        let room = try await api.reserveRoom(title: title, category: category, isLive: isLive, theme: theme, token: token)
        guard self.token == token else { throw CancellationError() }
        roomMetadata.insert(room, at: 0)
        return room
    }

    func startRoom(_ room: DemoRoom) async throws {
        guard !isJoiningRoom, !needsNickname, let token else { return }
        isJoiningRoom = true
        defer { isJoiningRoom = false }
        try await ensureSDKSession()
        do {
            try await rtc.createRoom(roomID: room.id, title: room.title, category: room.category, isLive: room.isLive, theme: room.theme)
            _ = try await api.setRoomStatus(room.id, status: "live", token: token)
            try await api.visit(room.id, token: token)
            await refreshLibrary()
        } catch {
            if !rtc.isCurrentRoom(room.id) { _ = try? await api.setRoomStatus(room.id, status: "ended", token: token) }
            throw error
        }
    }

    func openRoom(_ room: DemoRoom) async throws {
        guard !isJoiningRoom, !needsNickname, let token else { return }
        isJoiningRoom = true
        defer { isJoiningRoom = false }
        try await ensureSDKSession()
        try await rtc.presentRoom(roomID: room.id, isLive: room.isLive, isOwner: room.isCreatedByMe)
        do { try await api.visit(room.id, token: token); await refreshLibrary() }
        catch { notify("已加入房间，浏览记录暂未同步：\(error.localizedDescription)") }
    }

    func toggleFavorite(_ room: DemoRoom) {
        guard let token, !favoriteTasks.contains(room.id) else { return }
        favoriteTasks.insert(room.id)
        let enabled = !favoriteIDs.contains(room.id)
        Task {
            defer { favoriteTasks.remove(room.id) }
            do {
                try await api.favorite(room.id, enabled: enabled, token: token)
                guard self.token == token else { return }
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
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        let updated = try await api.updateProfile(name: name, bio: bio, avatarIndex: clearCustomAvatar && jpegData == nil ? avatarIndex : nil, token: token)
        guard self.token == token else { throw CancellationError() }
        apply(updated)
        profileNeedsRTCSync = true
        if let jpegData {
            let uploaded = try await api.uploadAvatar(jpegData: jpegData, token: token)
            guard self.token == token else { throw CancellationError() }
            apply(uploaded)
        }
        // Profile is already committed to our server. Retry SDK synchronization
        // at next login if its transient request fails rather than losing edits.
        var profileSynced = false
        do { try await syncRTCProfile(); profileSynced = true }
        catch { notify("资料已保存，音视频名片将在下次进房或重新连接时同步。") }
        await refreshLibrary()
        guard self.token == token else { throw CancellationError() }
        if profileSynced { notify("个人资料已更新") }
    }

    func setNotificationsEnabled(_ value: Bool) async throws {
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        let updated = try await api.updateNotifications(value, token: token)
        guard self.token == token else { throw CancellationError() }
        apply(updated)
    }

    func logout() async {
        isSigningIn = true
        defer { isSigningIn = false }
        let oldToken = token
        let ownedRoomID = rtc.currentSDKRoomID.flatMap { id in
            (roomMetadata + library.created).contains(where: { $0.id == id && $0.isCreatedByMe }) ? id : nil
        }
        // Prevent room-close callbacks from starting a new SDK login while the
        // user is intentionally ending this session.
        isAuthenticated = false
        renewalTask?.cancel()
        _ = await renewalTask?.result
        await rtc.logout()
        if let oldToken {
            if let ownedRoomID { _ = try? await api.setRoomStatus(ownedRoomID, status: "ended", token: oldToken) }
            try? await api.logout(token: oldToken)
        }
        clearSession()
    }

    func deleteAccount() async throws {
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        isSigningIn = true
        defer { isSigningIn = false }
        // Keep the SDK session usable if the server rejects deletion or the
        // network is offline. Only tear it down after server confirmation.
        try await api.deleteAccount(token: token)
        isAuthenticated = false
        renewalTask?.cancel()
        _ = await renewalTask?.result
        await rtc.logout()
        clearSession()
        KikiKeychain.remove("lastUserID")
    }

    func notify(_ message: String) {
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
        customAvatarURL = user.avatarURL
        needsNickname = user.needsNickname
        notificationsEnabled = user.notificationsEnabled
    }

    private func ensureSDKSession() async throws {
        if !rtc.isLoggedIn || credentialsExpiry < Int(Date().timeIntervalSince1970) + 300 { try await renewSDKSession() }
        else if profileNeedsRTCSync { try await syncRTCProfile() }
    }

    private func renewSDKSession() async throws {
        if let task = renewalTask { return try await task.value }
        guard let token else { throw KikiAPIError.server(401, "登录已过期，请重新登录。") }
        let task = Task { @MainActor in
            let refreshed = try await api.refresh(token: token)
            try Task.checkCancellation()
            guard self.token == token else { throw CancellationError() }
            apply(refreshed.user)
            try await connectSDK(refreshed.sdk)
        }
        renewalTask = task
        defer { renewalTask = nil }
        try await task.value
    }

    private func connectSDK(_ credentials: KikiSDKCredentials) async throws {
        try await rtc.login(sdkAppID: credentials.sdkAppID, userID: credentials.userID, userSig: credentials.userSig)
        credentialsExpiry = credentials.expiresAt
        if !needsNickname { try await syncRTCProfile() }
    }

    private func syncRTCProfile() async throws {
        guard let user else { return }
        try await rtc.updateProfile(userID: user.sdkUserID, name: user.name, bio: user.bio,
                                    avatarURL: user.avatarURL ?? KikiAvatarSource.url(for: user.avatarIndex).absoluteString)
        profileNeedsRTCSync = false
    }

    private func handle(_ error: Error, expectedToken: String? = nil) {
        if let expectedToken, token != expectedToken { return }
        if error is CancellationError { return }
        loadingError = error.localizedDescription
        if let error = error as? KikiAPIError, error.isUnauthorized {
            clearSession()
            loadingError = "登录已过期，请重新登录。"
            isEndingSession = true
            Task {
                renewalTask?.cancel()
                _ = await renewalTask?.result
                await rtc.logout()
                isEndingSession = false
            }
        }
    }

    private func clearSession() {
        KikiKeychain.remove("sessionToken")
        token = nil; user = nil; credentialsExpiry = 0; profileNeedsRTCSync = false
        isAuthenticated = false
        profileName = ""; bio = ""; avatarIndex = 0; customAvatarURL = nil; needsNickname = false; userID = ""
        favoriteIDs = []; recentRoomIDs = []; rooms = []
        roomMetadata = []; library = KikiLibrary(favorites: [], recents: [], created: [])
        loadingError = nil
    }
}

enum KikiAvatarSource {
    static func url(for index: Int) -> URL {
        let safeIndex = max(0, min(11, index)) + 1
        return URL(string: "https://im.sdk.qcloud.com/download/tuikit-resource/avatar/avatar_\(safeIndex).png")!
    }
}

@available(iOS 16.0, *)
struct KikiAvatar: View {
    var index: Int
    var size: CGFloat = 40
    var customURL: String? = nil
    @State private var customImage: UIImage?
    private let faces = ["🧑🏻‍🚀", "👩🏻", "🧑🏼", "👩🏽‍🦱", "🧑🏻‍🎨", "👩🏼‍🦰", "🧑🏽‍🎤", "👨🏻‍🦱", "👩🏻‍🎤", "🧑🏼‍🚀", "👩🏾", "👨🏼"]
    private let colors: [Color] = [Color(hex: 0x6351A4), Color(hex: 0x958392), Color(hex: 0x758779), Color(hex: 0xAD796A), Color(hex: 0x6B8F9B)]
    var body: some View {
        Group {
            if let customURL {
                if let image = customImage ?? KikiAPIClient.shared.cachedAvatar(customURL) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else { placeholder }
            } else {
                AsyncImage(url: KikiAvatarSource.url(for: index)) { image in
                    image.resizable().scaledToFill()
                } placeholder: { placeholder }
            }
        }
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [colors[abs(index) % colors.count].opacity(0.8), colors[abs(index) % colors.count].opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: customURL) {
            customImage = nil
            guard let customURL else { return }
            do {
                let loaded = try await KikiAPIClient.shared.loadAvatar(customURL)
                try Task.checkCancellation()
                customImage = loaded
            } catch { /* Keep a stable avatar fallback when offline. */ }
        }
    }
    private var placeholder: some View {
        Text(faces[abs(index) % faces.count]).font(.system(size: size * 0.62))
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
