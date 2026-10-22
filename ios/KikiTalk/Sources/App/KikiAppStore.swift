import SwiftUI
import UIKit
import Combine

/// Account state is loaded from the authenticated HTTPS API. Active rooms and
/// participant counts come from the independent voice server, with no seed data.
@MainActor final class KikiAppStore: ObservableObject {
    @Published private(set) var profileName = ""
    @Published private(set) var bio = ""
    @Published private(set) var avatarIndex = 0
    @Published private(set) var customAvatarURL: String?
    @Published private(set) var needsNickname = false
    @Published private(set) var userID = ""
    @Published private(set) var favoriteIDs: Set<String> = []
    @Published private(set) var recentRoomIDs: [String] = []
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var hideNotificationContent = false
    @Published private(set) var isUpdatingNotificationContent = false
    private var notificationContentRevision = 0
    private var notificationContentRequest: UUID?
    var notificationContentHiddenForPresentation: Bool { hideNotificationContent || isUpdatingNotificationContent }
    weak var pushController: KikiPushController?
    @Published private(set) var rooms: [KikiRoom] = []
    @Published private(set) var lastSuccessfulRoomTitle: String?
    @Published private(set) var isAuthenticated = false
    @Published private(set) var startupFinished = false
    @Published private(set) var isSigningIn = false
    @Published private(set) var isEndingSession = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isJoiningRoom = false
    @Published private(set) var loadingError: String?
    @Published private(set) var libraryError: String?
    @Published var toast: String?
    @Published private(set) var socialProfile: KikiPerson?
    @Published private(set) var followingUserIDs: Set<String> = []
    @Published private var followingOverrides: [String: Bool] = [:]
    @Published private var hasLoadedFollowingIDs = false
    @Published private(set) var unreadNotificationCount = 0
    @Published private(set) var unreadDirectMessageCount = 0
    @Published private(set) var directDrafts: [String: String] = [:]
    @Published private(set) var pendingDirectMessages: [String: KikiPendingDirectMessage] = [:]
    @Published private(set) var directMessageAccess: [String: KikiDirectMessageAccess] = [:]
    @Published private(set) var pendingDirectConversation: KikiDirectConversationRequest?
    @Published var directConversationPath: [KikiDirectConversationRoute] = []
    @Published private(set) var directContentRevision = 0
    private var directAccessRevision: [String: Int] = [:]
    private var directAccessFetchRevision: [String: Int] = [:]
    private let socialImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 40; cache.totalCostLimit = 24 * 1024 * 1024; return cache
    }()
    var unreadMessageCount: Int { unreadNotificationCount + unreadDirectMessageCount }
    @Published private(set) var directHistoryRevision: [String: Int] = [:]
    @Published private(set) var notificationHistoryRevision = 0
    @Published private(set) var socialRevision = 0
    @Published private(set) var momentContentRevision = 0
    @Published private(set) var socialPrivacyRevision = 0
    private var socialRefreshID = UUID()
    private var socialMutationRefreshTask: Task<Void, Never>?
    private var notificationUnreadGate = KikiUnreadRequestGate()
    private var directUnreadGate = KikiUnreadRequestGate()
    private var notificationForegroundScope: KikiForegroundNotificationScope?
    private var directForegroundScope: KikiForegroundNotificationScope?
    private var momentNotificationScope: KikiForegroundNotificationScope?
    private var momentNotificationSequence = 0
    private var legacyMomentNotificationIDs: Set<String> = []
    private var legacyMomentNotificationOrder: [String] = []
    private var appIsForeground = false
    private struct VisibleDirectConversation {
        let owner: UUID
        let personID: String
        let hasOverlay: Bool
    }
    private var visibleDirectConversations: [VisibleDirectConversation] = []

    var foregroundNotificationContext: KikiForegroundNotificationContext {
        // A covered parent may report its scene change after the nested chat.
        // Prefer the conversation the user can actually read in either order.
        let conversation = visibleDirectConversations.last(where: { !$0.hasOverlay }) ?? visibleDirectConversations.last
        return .init(isActive: appIsForeground, conversationPersonID: conversation?.personID,
                     hasConversationOverlay: conversation?.hasOverlay == true || isPresentingRoom)
    }

    func setAppForeground(_ isActive: Bool) {
        appIsForeground = isActive
        pushController?.foregroundContextDidChange()
    }

    func setDirectConversationVisibility(owner: UUID, personID: String, isVisible: Bool, hasOverlay: Bool) {
        visibleDirectConversations.removeAll { $0.owner == owner }
        if isVisible { visibleDirectConversations.append(.init(owner: owner, personID: personID, hasOverlay: hasOverlay)) }
        pushController?.foregroundContextDidChange()
    }

    let consent: KikiConsentStore
    let gifts = KikiGiftStore()
    private let identity: any KikiIdentityStoring
    private let apiProvider: () -> KikiAccountAPIClient
    private let voiceAPIProvider: () -> KikiAPIClient
    private let rtcProvider: @MainActor () -> any KikiRTCServicing
    private let appleProvider: @MainActor () -> any KikiAppleAuthorizing
    private var appleStorage: (any KikiAppleAuthorizing)?
    private var apple: any KikiAppleAuthorizing {
        if let appleStorage { return appleStorage }
        let value = appleProvider(); appleStorage = value; return value
    }
    private var apiStorage: KikiAccountAPIClient?
    private var voiceAPIStorage: KikiAPIClient?
    private var rtcStorage: (any KikiRTCServicing)?
    private var sessionGeneration = 0
    private var privacyStopped = false
    private var api: KikiAccountAPIClient {
        if let apiStorage { return apiStorage }
        let value = apiProvider(); apiStorage = value; return value
    }
    private var voiceAPI: KikiAPIClient {
        if let voiceAPIStorage { return voiceAPIStorage }
        let value = voiceAPIProvider(); voiceAPIStorage = value; return value
    }
    private var rtc: any KikiRTCServicing {
        if let rtcStorage { return rtcStorage }
        let value = rtcProvider(); rtcStorage = value
        if let service = value as? KikiRTCService {
            service.configure(api: voiceAPI)
            service.renewAuthorization = { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.renewSDKSession()
            }
        }
        configureRTC(value); return value
    }
    private var token: String? // Account token: kiki.group only.
    private var voiceToken: String? // Voice business token: furby.top only; never persisted.
    private var voiceUserID: String?
    private var user: KikiUser?
    private var credentialsExpiry = 0
    private var library = KikiLibrary(favorites: [], recents: [], created: [])
    private var roomMetadata: [KikiRoom] = []
    private var roomMetadataRevision: UInt = 0
    private enum RoomCatalogReadFailure: Error { case superseded }
    private var roomRefreshTask: Task<Void, Error>?
    private var roomRefreshID: UUID?
    private var roomRefreshWaiters: Set<UUID> = []
    private var roomCatalogWatchTask: Task<Void, Never>?
    private var roomCatalogWatchID: UUID?
    private var roomCatalogWatchSupported = true
    private var hasLoadedRoomCatalog = false
    private var roomPresentationObservation: AnyCancellable?
    private var toastTask: Task<Void, Never>?
    private var favoriteTasks: Set<String> = []
    private var didStart = false
    private var renewalTask: Task<Void, Error>?
    private var renewalAttempt: KikiRoomAttempt?
    private var leaseTask: Task<Void, Never>?
    private let leaseRenewalNanoseconds: UInt64
    private var profileNeedsRTCSync = false
    private let incidents: KikiIncidentReporter
    private var reservedRoomAttempts: [String: KikiRoomAttempt] = [:]

    var avatarURL: String { customAvatarURL ?? "" }
    var defaultRoomTitle: String { KikiRoomTitlePolicy.defaultTitle(nickname: profileName) }
    var suggestedRoomTitle: String { lastSuccessfulRoomTitle ?? defaultRoomTitle }
    // Current account sessions are issued only after server-verified Apple sign-in.
    // A saved Apple subject alone must never make a signed-out account look bound.
    var isAppleIDBound: Bool {
        isAuthenticated && !(token ?? "").isEmpty && !userID.isEmpty &&
            identity.read("appleSessionVersion") == "2" && !(identity.read("appleSubject") ?? "").isEmpty
    }
    var canReconnect: Bool { token != nil && permitsBusiness && !isAuthenticated }
    var isPresentingRoom: Bool { rtcStorage?.isPresentingRoom ?? false }
    private var permitsBusiness: Bool { consent.hasCurrentConsent && !privacyStopped && !isEndingSession }
    var pushSessionKey: String? {
        guard permitsBusiness, isAuthenticated, !needsNickname, !userID.isEmpty, token != nil else { return nil }
        return "\(sessionGeneration):\(userID)"
    }
    var favoriteRooms: [KikiRoom] { library.favorites.map(reconciled) }
    var recentRooms: [KikiRoom] { library.recents.map(reconciled) }
    var createdRooms: [KikiRoom] { library.created.map(reconciled) }

    init(consent: KikiConsentStore? = nil, identity: any KikiIdentityStoring = KikiKeychainStorage(),
         apiProvider: @escaping () -> KikiAccountAPIClient = { .shared },
         voiceAPIProvider: @escaping () -> KikiAPIClient = { .shared },
         rtcProvider: @escaping @MainActor () -> any KikiRTCServicing = { KikiRTCService.shared },
         appleProvider: @escaping @MainActor () -> any KikiAppleAuthorizing = { KikiAppleAuthorizationService() },
         leaseRenewalNanoseconds: UInt64 = 300_000_000_000, incidents: KikiIncidentReporter? = nil) {
        self.consent = consent ?? .shared
        self.identity = identity
        self.apiProvider = apiProvider
        self.voiceAPIProvider = voiceAPIProvider
        self.rtcProvider = rtcProvider
        self.appleProvider = appleProvider
        self.leaseRenewalNanoseconds = leaseRenewalNanoseconds
        self.incidents = incidents ?? .shared
    }

    private func configureRTC(_ rtc: any KikiRTCServicing) {
        (rtc as? KikiRTCService)?.socialStore = self
        // A computed presentation flag does not notify this store by itself.
        // Forward only real presentation transitions, never the SDK's speaking,
        // metrics, polling, or other high-frequency publications.
        roomPresentationObservation = rtc.roomPresentationChanges?
            .removeDuplicates().dropFirst()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.pushController?.foregroundContextDidChange()
            }
        rtc.onRoomClosed = { [weak self] roomID in
            Task { @MainActor in
                guard let self, self.permitsBusiness, self.isAuthenticated else { return }
                await self.refreshRooms()
                await self.refreshLibrary()
            }
        }
        rtc.onSessionExpired = { [weak self] in
            guard let self, self.permitsBusiness else { return }
                self.pushController?.endSession()
            self.sessionGeneration += 1
            self.isAuthenticated = false
            self.suspendExperience()
            self.credentialsExpiry = 0
            self.voiceToken = nil; self.voiceUserID = nil
            self.leaseTask?.cancel(); self.leaseTask = nil
            self.renewalTask?.cancel()
            self.isEndingSession = true
            self.loadingError = "语音连接已失效，请重新连接或登录。"
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.renewalTask?.result
                await self.rtcStorage?.logout()
                self.isEndingSession = false
            }
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
        guard identity.read("appleSessionVersion") == "2", let subject = identity.read("appleSubject"), !subject.isEmpty else {
            clearSession()
            return
        }
        guard let saved = identity.read("sessionToken") else { return }
        let generation = sessionGeneration
        token = saved
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let state = try await apple.credentialState(subject: subject)
            try requireAccess(generation: generation, token: saved)
            guard state == .authorized else {
                await appleCredentialRevoked()
                return
            }
            let acceptance = try consent.acceptance()
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

    func loginWithApple() async throws {
        let acceptance = try consent.acceptance()
        try requireAccess()
        guard !isSigningIn, !isEndingSession else { return }
        let generation = sessionGeneration
        let previousToken = token
        isSigningIn = true
        loadingError = nil
        defer { isSigningIn = false }
        var issuedToken: String?
        do {
            await retryPendingLogouts()
            try requireAccess(generation: generation)
            let challenge = try await performAPI { try await api.appleChallenge() }
            try requireAccess(generation: generation)
            let credential = try await apple.authorize(nonce: challenge.nonce, state: challenge.challengeID)
            try requireAccess(generation: generation)
            let response = try await performAPI {
                try await api.loginWithApple(challengeID: challenge.challengeID, identityToken: credential.identityToken,
                                             authorizationCode: credential.authorizationCode, legalConsent: acceptance)
            }
            issuedToken = response.token
            try requireAccess(generation: generation)
            if let previousToken, previousToken != response.token { queueLogout(previousToken) }
            try identity.write(credential.subject, key: "appleSubject")
            try identity.write("2", key: "appleSessionVersion")
            try identity.write(response.token, key: "sessionToken")
            token = response.token
            apply(response.user)
            try await renewSDKSession()
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

    /// A revoked system credential stops media and invalidates the backend session.
    /// Offline logout is retained only as a retry receipt, never as a usable login.
    func appleCredentialRevoked() async {
        guard permitsBusiness else { return }
        await logout(appleRevoked: true)
        loadingError = "Apple 授权已失效，请使用 Apple 重新登录。"
    }

    func checkAppleCredentialState() async {
        guard permitsBusiness, !isSigningIn, let token, let subject = identity.read("appleSubject") else { return }
        let generation = sessionGeneration
        do {
            let state = try await apple.credentialState(subject: subject)
            try requireAccess(generation: generation, token: token)
            if state != .authorized { await appleCredentialRevoked() }
        } catch {
            // Apple lookup/network errors do not delete a valid account or credential.
            if sessionGeneration == generation, !(error is CancellationError) {
                loadingError = "暂时无法检查 Apple 授权，请检查网络后重试。"
            }
        }
    }

    private func queueLogout(_ token: String, revoked: Bool = false) {
        var tokens = pendingLogoutTokens(revoked: revoked)
        if !tokens.contains(token) { tokens.append(token) }
        if let data = try? JSONEncoder().encode(tokens), let value = String(data: data, encoding: .utf8) {
            try? identity.write(value, key: revoked ? "applePendingRevocations" : "applePendingLogouts")
        }
    }

    private func pendingLogoutTokens(revoked: Bool = false) -> [String] {
        guard let value = identity.read(revoked ? "applePendingRevocations" : "applePendingLogouts"),
              let data = value.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    private func retryPendingLogouts(allowRightsOnly: Bool = false) async {
        guard consent.hasCurrentConsent || allowRightsOnly else { return }
        // These endpoints only end authorization. They never resume business services.
        for revoked in [true, false] {
            for pending in pendingLogoutTokens(revoked: revoked) {
                do {
                    if revoked { try await api.invalidateRevokedAppleSession(token: pending) }
                    else { try await api.logout(token: pending) }
                    removePendingLogout(pending, revoked: revoked)
                } catch let error as KikiAPIError where error.isUnauthorized {
                    removePendingLogout(pending, revoked: revoked)
                } catch { /* Retry when the user next opens or signs in to the app. */ }
            }
        }
    }

    private func removePendingLogout(_ token: String, revoked: Bool) {
        let key = revoked ? "applePendingRevocations" : "applePendingLogouts"
        let remaining = pendingLogoutTokens(revoked: revoked).filter { $0 != token }
        if remaining.isEmpty { identity.remove(key) }
        else if let data = try? JSONEncoder().encode(remaining), let value = String(data: data, encoding: .utf8) {
            try? identity.write(value, key: key)
        }
    }

    func reconnect() async throws {
        try requireAccess()
        let generation = sessionGeneration
        guard let token, let subject = identity.read("appleSubject") else { throw KikiAPIError.server(401, "请先使用 Apple 登录。") }
        isSigningIn = true
        defer { isSigningIn = false }
        let state = try await apple.credentialState(subject: subject)
        try requireAccess(generation: generation, token: token)
        guard state == .authorized else {
            await appleCredentialRevoked()
            throw KikiAPIError.security("Apple 授权已失效，请重新登录。")
        }
        try await renewSDKSession()
        try requireAccess(generation: generation)
        isAuthenticated = true
        loadingError = nil
        await refreshRooms()
        await refreshLibrary()
    }

    func recordForegroundActivity() async {
        guard UIApplication.shared.applicationState == .active, permitsBusiness, isAuthenticated, let token else { return }
        incidents.retry()
        // Best-effort, explicit foreground activity. Lease renewals and media polls
        // never call this endpoint and therefore do not count as daily activity.
        try? await api.recordForegroundActivity(token: token)
    }

    func refreshSafety() async {
        guard permitsBusiness, isAuthenticated, let service = rtcStorage as? KikiRTCService else { return }
        try? await service.refreshSafety(showsLoading: false)
    }

    func refreshRooms(showsLoading: Bool = false) async {
        guard permitsBusiness, isAuthenticated, !needsNickname, let token, !Task.isCancelled else { return }
        do {
            try await refreshRoomRecords(showsLoading: showsLoading)
        } catch {
            if !(error is RoomCatalogReadFailure) { handle(error, expectedToken: token) }
        }
    }

    /// A visible directory owns one cancellable long-poll. The response only
    /// invalidates the authenticated list; it is never a source of room cards.
    func watchRoomCatalog() async {
        guard permitsBusiness, isAuthenticated, !needsNickname, let token, !Task.isCancelled else { return }
        roomCatalogWatchTask?.cancel()
        let id = UUID()
        let generation = sessionGeneration
        roomCatalogWatchID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runRoomCatalogWatch(id: id, generation: generation, accountToken: token)
        }
        roomCatalogWatchTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        if roomCatalogWatchID == id { roomCatalogWatchTask = nil; roomCatalogWatchID = nil }
    }

    private func runRoomCatalogWatch(id: UUID, generation: Int, accountToken: String) async {
        var revision: Int?
        var failures = 0
        var needsInitialList = true
        var lastListReadAt = Date.distantPast
        while !Task.isCancelled {
            var attemptedInitialList = false
            do {
                try requireAccess(generation: generation, token: accountToken)
                guard isAuthenticated, !needsNickname, roomCatalogWatchID == id else { return }
                if !roomCatalogWatchSupported {
                    attemptedInitialList = true
                    try await refreshRoomRecords(showsLoading: false)
                    lastListReadAt = Date()
                    needsInitialList = false
                    failures = 0
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    continue
                }
                try await ensureSDKSession()
                try requireAccess(generation: generation, token: accountToken)
                let session = try currentVoiceToken()
                let startedAt = Date()
                let change: KikiRoomCatalogChange
                do {
                    change = try await performAPI {
                        try await voiceAPI.rtcRoomCatalogChanges(after: revision, waitSeconds: revision == nil ? 0 : 15, token: session)
                    }
                } catch let error as KikiAPIError where error.isUnauthorized && session != voiceToken {
                    // A lease may rotate during the wait. Retry with its
                    // replacement before expiring the account session.
                    continue
                } catch let error as KikiAPIError {
                    if case .server(let status, _) = error, status == 404 || status == 405 {
                        roomCatalogWatchSupported = false
                        continue
                    }
                    throw error
                }
                try requireAccess(generation: generation, token: accountToken)
                guard isAuthenticated, roomCatalogWatchID == id else { return }
                if needsInitialList || change.revision != revision || Date().timeIntervalSince(lastListReadAt) >= 60 {
                    // Acquire a revision before the list: a room created in
                    // between must either be in this GET or wake the next wait.
                    attemptedInitialList = true
                    if let earlierRead = roomRefreshTask {
                        // This GET may have taken its snapshot before the
                        // observed revision existed. Coalescing onto it would
                        // acknowledge the new cursor with an old list forever.
                        // Finish it, then start one trailing authoritative GET.
                        _ = await earlierRead.result
                    }
                    try requireAccess(generation: generation, token: accountToken)
                    guard isAuthenticated, roomCatalogWatchID == id else { return }
                    try await refreshRoomRecords(showsLoading: false)
                    lastListReadAt = Date()
                    needsInitialList = false
                } else {
                    // Defensive pacing also keeps an older/proxied endpoint
                    // that returns early from becoming an accidental hot loop.
                    let remaining = max(0, 15 - Date().timeIntervalSince(startedAt))
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                }
                revision = change.revision
                failures = 0
            } catch {
                guard !(error is CancellationError), !Task.isCancelled,
                      generation == sessionGeneration, token == accountToken,
                      permitsBusiness, isAuthenticated, roomCatalogWatchID == id else { return }
                if (error as? KikiAPIError)?.isUnauthorized == true { handle(error, expectedToken: accountToken); return }
                // Keep a usable cached list if only the lightweight watch is
                // unavailable. The cursor is not advanced after a failed read.
                let rateLimited: Bool
                if case .rateLimited = error as? KikiAPIError { rateLimited = true } else { rateLimited = false }
                let superseded = error is RoomCatalogReadFailure
                if needsInitialList, !attemptedInitialList, !rateLimited, !superseded {
                    do { try await refreshRoomRecords(showsLoading: false); needsInitialList = false }
                    catch { handle(error, expectedToken: accountToken) }
                }
                if !superseded { handle(error, expectedToken: accountToken) }
                guard permitsBusiness, isAuthenticated else { return }
                failures += 1
                let delay: TimeInterval
                if case .rateLimited(let seconds, _) = error as? KikiAPIError { delay = Double(seconds) }
                else { delay = min(30, pow(2, Double(min(failures, 5)))) }
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func refreshRoomRecords(showsLoading: Bool) async throws {
        try requireAccess()
        guard isAuthenticated, !needsNickname, let accountToken = token else { throw CancellationError() }
        let generation = sessionGeneration
        let waiter = UUID()
        roomRefreshWaiters.insert(waiter)
        let id: UUID
        let task: Task<Void, Error>
        if let existing = roomRefreshTask, !existing.isCancelled, let existingID = roomRefreshID {
            task = existing
            id = existingID
            if showsLoading, !isRefreshing { isRefreshing = true }
        } else {
            roomRefreshWaiters = [waiter]
            id = UUID()
            roomRefreshID = id
            if showsLoading || !hasLoadedRoomCatalog { isRefreshing = true }
            task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                defer {
                    if self.roomRefreshID == id {
                        self.roomRefreshTask = nil
                        self.roomRefreshID = nil
                        self.roomRefreshWaiters = []
                        if self.isRefreshing { self.isRefreshing = false }
                    }
                }
                try await self.ensureSDKSession()
                try self.requireAccess(generation: generation, token: accountToken)
                for attempt in 0..<2 {
                    let session = try self.currentVoiceToken()
                    let metadataRevision = self.roomMetadataRevision
                    let records: [KikiRoom]
                    do { records = try await self.performAPI { try await self.voiceAPI.rtcRooms(token: session) } }
                    catch let error as KikiAPIError where error.isUnauthorized && session != self.voiceToken && attempt == 0 { continue }
                    try self.requireAccess(generation: generation, token: accountToken)
                    guard self.isAuthenticated, self.roomRefreshID == id, !self.roomRefreshWaiters.isEmpty else { throw CancellationError() }
                    if self.roomMetadataRevision != metadataRevision {
                        // A delayed write acknowledgement may invalidate a GET
                        // whose catalog revision already includes that write.
                        // Do one bounded trailing GET; never report an unapplied
                        // snapshot as success and let the watch advance its cursor.
                        if attempt == 0 { continue }
                        throw RoomCatalogReadFailure.superseded
                    }
                    self.roomMetadata = records
                    self.hasLoadedRoomCatalog = true
                    let visible = records.filter { !$0.isLive && $0.status == "live" }
                    if self.rooms != visible { self.rooms = visible }
                    if self.loadingError != nil { self.loadingError = nil }
                    return
                }
                throw KikiAPIError.invalidResponse
            }
            roomRefreshTask = task
        }
        defer { releaseRoomRefreshWaiter(waiter, fetchID: id) }
        try await withTaskCancellationHandler(operation: {
            try await task.value
            try Task.checkCancellation()
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.releaseRoomRefreshWaiter(waiter, fetchID: id) }
        })
    }

    private func releaseRoomRefreshWaiter(_ waiter: UUID, fetchID: UUID) {
        guard roomRefreshID == fetchID else { return }
        roomRefreshWaiters.remove(waiter)
        if roomRefreshWaiters.isEmpty { roomRefreshTask?.cancel() }
    }

    private func cancelRoomCatalogRefreshes() {
        roomCatalogWatchTask?.cancel(); roomCatalogWatchTask = nil; roomCatalogWatchID = nil
        roomRefreshTask?.cancel(); roomRefreshTask = nil; roomRefreshID = nil; roomRefreshWaiters = []
        roomCatalogWatchSupported = true
        hasLoadedRoomCatalog = false
        if isRefreshing { isRefreshing = false }
    }

    func refreshLibrary() async {
        guard permitsBusiness, isAuthenticated, !needsNickname, let token else { return }
        let generation = sessionGeneration
        do {
            try await ensureSDKSession()
            let session = try currentVoiceToken()
            let metadataRevision = roomMetadataRevision
            let loaded = try await performAPI { try await voiceAPI.library(token: session) }
            try requireAccess(generation: generation, token: token)
            guard isAuthenticated, roomMetadataRevision == metadataRevision else { return }
            library = loaded
            if lastSuccessfulRoomTitle == nil,
               let previous = loaded.created.first(where: { $0.isCreatedByMe && (try? KikiRoomTitlePolicy.validated($0.title)) != nil }) {
                rememberRoomTitle(previous.title)
            }
            libraryError = nil
            favoriteIDs = Set(library.favorites.map(\.id))
            recentRoomIDs = library.recents.map(\.id)
        } catch {
            if !(error is CancellationError), self.token == token { libraryError = error.localizedDescription }
            handle(error, expectedToken: token)
        }
    }

    func removeHistory(roomID: String?) async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        try await ensureSDKSession()
        let session = try currentVoiceToken()
        try await performAPI { try await voiceAPI.removeHistory(roomID: roomID, token: session) }
        try requireAccess(token: token)
        await refreshLibrary()
    }

    func reserveRoom(title: String, category: String, isLive: Bool, theme: Int) async throws -> KikiRoom {
        let attempt = KikiRoomAttempt(operation: .createRoom, identityEpoch: incidents.identityEpoch)
        return try await KikiIncidentContext.$attempt.withValue(attempt) {
            do {
                try requireAccess()
                guard let token, isAuthenticated, !needsNickname else { throw KikiAPIError.server(401, "请先登录并设置昵称。") }
                guard !isLive else { throw KikiAPIError.server(422, "暂未开放视频直播，请创建语聊房。") }
                let title = try KikiRoomTitlePolicy.resolved(title, nickname: profileName)
                try rtc.requireNoActiveRoom()
                attempt.enter(.accountAuthorization)
                try await ensureSDKSession()
                let session = try currentVoiceToken()
                attempt.enter(.roomAPI)
                let room = try await performAPI { try await voiceAPI.reserveRoom(title: title, category: category, isLive: false, theme: theme, token: session) }
                try requireAccess(token: token)
                attempt.setRoom(room.id)
                reservedRoomAttempts = reservedRoomAttempts.filter { Date().timeIntervalSince($0.value.startedAt) < 300 }
                reservedRoomAttempts[room.id] = attempt
                roomMetadataRevision &+= 1
                roomMetadata.insert(room, at: 0)
                rememberRoomTitle(room.title)
                return room
            } catch {
                throw roomOperationFailure(error, attempt: attempt)
            }
        }
    }

    func updateRoomTitle(roomID: String, title: String) async throws -> KikiRoomState {
        try requireAccess()
        guard isAuthenticated, !needsNickname, let token else { throw KikiAPIError.server(401, "请先登录。") }
        let generation = sessionGeneration
        let title = try KikiRoomTitlePolicy.resolved(title, nickname: profileName)
        do {
            try await ensureSDKSession()
            let session = try currentVoiceToken()
            let state = try await performAPI { try await voiceAPI.updateRoomTitle(roomID, title: title, token: session) }
            try requireAccess(generation: generation, token: token)
            guard state.room.hostID == voiceUserID, state.room.isCreatedByMe, state.me.role == .owner,
                  state.me.userID == voiceUserID else {
                throw KikiAPIError.security("服务器返回的房主身份不匹配，请重新进入房间。")
            }
            // Reads that started before this committed write cannot restore
            // an older room title. New reads capture the new revision normally.
            roomMetadataRevision &+= 1
            func renamed(_ rooms: [KikiRoom]) -> [KikiRoom] {
                rooms.map { record in
                    guard record.id == roomID else { return record }
                    var updated = record; updated.title = state.room.title; return updated
                }
            }
            roomMetadata = renamed(roomMetadata)
            let updatedRooms = renamed(rooms)
            if rooms != updatedRooms { rooms = updatedRooms }
            let updatedLibrary = KikiLibrary(favorites: renamed(library.favorites), recents: renamed(library.recents), created: renamed(library.created))
            if library.favorites != updatedLibrary.favorites || library.recents != updatedLibrary.recents || library.created != updatedLibrary.created {
                objectWillChange.send()
                library = updatedLibrary
            }
            rememberRoomTitle(state.room.title)
            return state
        } catch { handle(error, expectedToken: token); throw error }
    }

    private func roomTitleStorageKey(for userID: String) -> String { "lastSuccessfulRoomTitle." + userID }

    private func rememberRoomTitle(_ value: String) {
        guard !userID.isEmpty, let title = try? KikiRoomTitlePolicy.validated(value) else { return }
        if lastSuccessfulRoomTitle != title { lastSuccessfulRoomTitle = title }
        // The remote room is already committed. Failure to save a local
        // preference must not turn a successful create/rename into a failure.
        try? identity.write(title, key: roomTitleStorageKey(for: userID))
    }

    func startRoom(_ room: KikiRoom) async throws {
        let attempt = reservedRoomAttempts.removeValue(forKey: room.id) ?? KikiRoomAttempt(operation: .createRoom, roomID: room.id, identityEpoch: incidents.identityEpoch)
        try await KikiIncidentContext.$attempt.withValue(attempt) {
            let generation = sessionGeneration
            var session: String?
            do {
                try requireAccess()
                guard !isJoiningRoom, !needsNickname, let token else { return }
                isJoiningRoom = true
                defer { isJoiningRoom = false }
                attempt.enter(.accountAuthorization)
                try await ensureSDKSession()
                session = try currentVoiceToken()
                try requireAccess(generation: generation, token: token)
                try await rtc.createRoom(roomID: room.id, title: room.title, category: room.category, isLive: room.isLive, theme: room.theme)
                try requireAccess(generation: generation, token: token)
                // POST /rooms already activates the server room. A second live
                // PATCH is redundant and could falsely fail an already presented room.
                attempt.complete()
                incidents.retry()
                await syncVisit(room.id, session: session!, created: true)
            } catch {
                let failure = roomOperationFailure(error, attempt: attempt)
                if permitsBusiness, !rtc.isCurrentRoom(room.id), let session { _ = try? await voiceAPI.setRoomStatus(room.id, status: "ended", token: session) }
                throw failure
            }
        }
    }

    func openRoom(_ room: KikiRoom) async throws {
        let attempt = KikiRoomAttempt(operation: .joinRoom, roomID: room.id, identityEpoch: incidents.identityEpoch)
        try await KikiIncidentContext.$attempt.withValue(attempt) {
            do {
                try requireAccess()
                let generation = sessionGeneration
                guard !isJoiningRoom, !needsNickname, let token else { return }
                isJoiningRoom = true
                defer { isJoiningRoom = false }
                attempt.enter(.accountAuthorization)
                try await ensureSDKSession()
                let session = try currentVoiceToken()
                try requireAccess(generation: generation, token: token)
                try await rtc.presentRoom(roomID: room.id, isLive: room.isLive, isOwner: room.isCreatedByMe)
                try requireAccess(generation: generation, token: token)
                attempt.complete()
                incidents.retry()
                await syncVisit(room.id, session: session, created: false)
            } catch { throw roomOperationFailure(error, attempt: attempt) }
        }
    }

    private func syncVisit(_ roomID: String, session: String, created: Bool) async {
        // Nonessential history failures are warnings, independent from the
        // completed create/join attempt, and retain their own response ID.
        let trace = KikiRoomAttempt(operation: .runtime, roomID: roomID, identityEpoch: incidents.identityEpoch)
        trace.enter(.stateSync)
        do {
            try await KikiIncidentContext.$attempt.withValue(trace) {
                try await performAPI { try await voiceAPI.visit(roomID, token: session) }
                await refreshLibrary()
            }
        } catch {
            incidents.record(error, trace: trace, severity: .warning, dedupeKey: "history_sync")
            notify(created ? "已创建房间，浏览记录暂未同步。" : "已加入房间，浏览记录暂未同步。")
        }
    }

    private func roomOperationFailure(_ error: Error, attempt: KikiRoomAttempt) -> Error {
        guard !(error is CancellationError) else { return error }
        let eventID = incidents.record(error, trace: attempt)
        let message: String
        if error is KikiTransportFailure || error is KikiAPIError { message = error.localizedDescription }
        else { message = attempt.operation == .createRoom ? "创建房间未完成，请稍后重试。" : "进入房间未完成，请稍后重试。" }
        return KikiRoomOperationFailure(message: message, eventID: eventID)
    }

    func toggleFavorite(_ room: KikiRoom) {
        guard permitsBusiness, let token, !favoriteTasks.contains(room.id) else { return }
        favoriteTasks.insert(room.id)
        let enabled = !favoriteIDs.contains(room.id)
        Task {
            defer { favoriteTasks.remove(room.id) }
            do {
                try await ensureSDKSession()
                let session = try currentVoiceToken()
                try await performAPI { try await voiceAPI.favorite(room.id, enabled: enabled, token: session) }
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
        let contentRevision = notificationContentRevision
        let updated = try await performAPI { try await api.updateProfile(name: name, bio: bio, avatarIndex: clearCustomAvatar && jpegData == nil ? avatarIndex : nil, token: token) }
        try requireAccess(token: token)
        apply(updated, contentRevision: contentRevision)
        profileNeedsRTCSync = true
        if let jpegData {
            let contentRevision = notificationContentRevision
            let uploaded = try await performAPI { try await api.uploadAvatar(jpegData: jpegData, token: token) }
            try requireAccess(token: token)
            apply(uploaded, contentRevision: contentRevision)
        }
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
        let contentRevision = notificationContentRevision
        let updated = try await performAPI { try await api.updateNotifications(value, token: token) }
        try requireAccess(token: token)
        apply(updated, contentRevision: contentRevision)
    }

    func setHideNotificationContent(_ value: Bool) async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        guard !isUpdatingNotificationContent else { throw CancellationError() }
        let generation = sessionGeneration, request = UUID()
        notificationContentRevision &+= 1
        notificationContentRequest = request
        isUpdatingNotificationContent = true
        // While saving, incoming previews stay generic. Cancellation/failure
        // never restores a detailed banner that was already on screen.
        pushController?.notificationContentPreferenceDidChange()
        defer {
            if notificationContentRequest == request {
                notificationContentRevision &+= 1
                notificationContentRequest = nil
                isUpdatingNotificationContent = false
            }
        }
        let updated = try await performAPI { try await api.updateNotificationContent(hidden: value, token: token) }
        try requireAccess(generation: generation, token: token)
        guard notificationContentRequest == request else { throw CancellationError() }
        hideNotificationContent = updated.hideNotificationContent
        user?.hideNotificationContent = updated.hideNotificationContent
    }

    func pushStatus() async throws -> KikiPushStatus {
        let contentRevision = notificationContentRevision
        let status = try await socialRequest { try await self.api.pushStatus(token: $0) }
        notificationsEnabled = status.enabled
        if contentRevision == notificationContentRevision, !isUpdatingNotificationContent,
           hideNotificationContent != status.hideNotificationContent {
            hideNotificationContent = status.hideNotificationContent
            user?.hideNotificationContent = status.hideNotificationContent
            notificationContentRevision &+= 1
            pushController?.notificationContentPreferenceDidChange()
        }
        return status
    }
    func registerPush(installationID: String, revision: Int64, deviceToken: String, environment: String, permission: String) async throws -> KikiPushReceipt {
        try await socialRequest {
            try await self.api.registerPushDevice(installationID: installationID, revision: revision, deviceToken: deviceToken,
                                                 environment: environment, permission: permission, token: $0)
        }
    }
    func pushUnbindOperation(installationID: String, revision: Int64) -> (() async throws -> Void)? {
        guard let oldToken = token else { return nil }
        let client = api
        return { try await client.unregisterPushDevice(installationID: installationID, revision: revision, token: oldToken) }
    }
    func resolvePush(_ deliveryID: String) async throws -> KikiPushRoute {
        try await socialRequest { try await self.api.resolvePush(deliveryID, token: $0) }
    }
    func requestDirectConversation(_ person: KikiPerson) {
        guard permitsBusiness, isAuthenticated, !isEndingSession, let key = pushSessionKey,
              !person.id.isEmpty, person.id != userID else { return }
        if let pending = pendingDirectConversation, pending.person.id == person.id,
           pending.sessionKey == key, pending.privacyRevision == socialPrivacyRevision { return }
        pendingDirectConversation = .init(person: person, sessionKey: key, privacyRevision: socialPrivacyRevision)
    }

    func isCurrentDirectConversationRequest(_ id: UUID) -> Bool {
        guard let request = pendingDirectConversation else { return false }
        return request.id == id && request.sessionKey == pushSessionKey
            && request.privacyRevision == socialPrivacyRevision && permitsBusiness && isAuthenticated && !isEndingSession
    }

    func cancelPendingDirectConversation() { pendingDirectConversation = nil }

    @discardableResult
    func completeDirectConversationNavigation(_ id: UUID) -> Bool {
        guard isCurrentDirectConversationRequest(id), let request = pendingDirectConversation else { return false }
        if directConversationPath.count != 1 || directConversationPath.first?.person.id != request.person.id {
            directConversationPath = [.init(person: request.person)]
        }
        pendingDirectConversation = nil
        return true
    }

    func prepareForMessageNavigation() async {
        guard permitsBusiness, isAuthenticated else { return }
        await (rtcStorage as? KikiRTCService)?.minimizeRoom()
    }

    func logout(appleRevoked: Bool = false) async {
        guard !isEndingSession else { return }
        pushController?.endSession()
        isEndingSession = true
        incidents.clear()
        sessionGeneration += 1
        appleStorage?.cancel()
        isSigningIn = true
        defer { isSigningIn = false; isEndingSession = false }
        let oldToken = token
        let oldVoiceToken = voiceToken
        let ownedRoomID = rtcStorage?.currentSDKRoomID.flatMap { id in
            (roomMetadata + library.created).contains(where: { $0.id == id && $0.isCreatedByMe }) ? id : nil
        }
        // Prevent room-close callbacks from starting a new SDK login while the
        // user is intentionally ending this session.
        isAuthenticated = false
        suspendExperience()
        rtcStorage?.stopMediaForPrivacy()
        leaseTask?.cancel(); leaseTask = nil
        renewalTask?.cancel()
        await apiStorage?.cancelRequestsAndClearAvatarCache()
        await voiceAPIStorage?.cancelRequestsAndClearAvatarCache()
        _ = await renewalTask?.result
        await rtcStorage?.logout()
        if let oldToken {
            if let ownedRoomID, let oldVoiceToken { _ = try? await voiceAPI.setRoomStatus(ownedRoomID, status: "ended", token: oldVoiceToken) }
            queueLogout(oldToken, revoked: appleRevoked)
            await retryPendingLogouts(allowRightsOnly: true)
        }
        clearSession()
        await pushController?.waitForTeardown()
    }

    func deleteAccount() async throws {
        try requireAccess()
        guard let token else { throw KikiAPIError.server(401, "请先登录。") }
        let roomTitleKey = roomTitleStorageKey(for: userID)
        pushController?.endSession()
        isSigningIn = true
        defer { isSigningIn = false }
        isEndingSession = true
        incidents.clear()
        sessionGeneration += 1
        isAuthenticated = false
        suspendExperience()
        rtcStorage?.stopMediaForPrivacy()
        leaseTask?.cancel(); leaseTask = nil
        renewalTask?.cancel()
        await apiStorage?.cancelRequestsAndClearAvatarCache()
        await voiceAPIStorage?.cancelRequestsAndClearAvatarCache()
        _ = await renewalTask?.result
        await rtcStorage?.logout()
        voiceToken = nil; voiceUserID = nil; credentialsExpiry = 0
        defer { isEndingSession = false }
        try await api.deleteAccount(token: token)
        identity.remove(roomTitleKey)
        clearSession()
        await pushController?.waitForTeardown()
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
        pushController?.endSession()
        privacyStopped = true
        incidents.clear()
        appleStorage?.cancel()
        isEndingSession = true
        isAuthenticated = false
        sessionGeneration += 1
        suspendExperience()
        rtcStorage?.stopMediaForPrivacy()
        leaseTask?.cancel(); leaseTask = nil
        renewalTask?.cancel()
        await apiStorage?.cancelRequestsAndClearAvatarCache()
        await voiceAPIStorage?.cancelRequestsAndClearAvatarCache()
        _ = await renewalTask?.result
        // Keep only the existing Keychain session as a retry credential until
        // the server acknowledges withdrawal; never resume SDKs from it.
        clearSession(removeCredential: false)
        await pushController?.waitForTeardown()
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

    private func reconciled(_ record: KikiRoom) -> KikiRoom {
        if let active = rooms.first(where: { $0.id == record.id }) { return active }
        var closed = record
        closed.audience = 0
        if closed.status == "live", loadingError == nil { closed.status = "ended" }
        return closed
    }

    private func apply(_ user: KikiUser, contentRevision: Int? = nil) {
        if userID != user.id {
            lastSuccessfulRoomTitle = identity.read(roomTitleStorageKey(for: user.id)).flatMap { try? KikiRoomTitlePolicy.validated($0) }
        }
        var user = user
        if isUpdatingNotificationContent || (contentRevision != nil && contentRevision != notificationContentRevision) {
            user.hideNotificationContent = hideNotificationContent
        }
        let contentChanged = hideNotificationContent != user.hideNotificationContent
        self.user = user
        if let token { incidents.bind(userID: user.id, token: token) }
        userID = user.id
        profileName = user.name
        bio = user.bio
        avatarIndex = user.avatarIndex
        customAvatarURL = user.avatarURL
        needsNickname = user.needsNickname
        notificationsEnabled = user.notificationsEnabled
        hideNotificationContent = user.hideNotificationContent
        if contentChanged {
            notificationContentRevision &+= 1
            pushController?.notificationContentPreferenceDidChange()
        }
    }

    private func ensureSDKSession() async throws {
        try requireAccess()
        if !rtc.isLoggedIn || credentialsExpiry < Int(Date().timeIntervalSince1970) + 300 { try await renewSDKSession() }
        else if profileNeedsRTCSync { try await syncRTCProfile() }
    }

    private func renewSDKSession() async throws {
        try requireAccess()
        if let task = renewalTask {
            do { return try await task.value }
            catch { renewalAttempt?.copyFailure(to: KikiIncidentContext.attempt); throw error }
        }
        guard let token else { throw KikiAPIError.server(401, "登录已过期，请重新登录。") }
        let generation = sessionGeneration
        let task = Task { @MainActor in
            let contentRevision = notificationContentRevision
            let refreshed = try await performAPI { try await api.refresh(token: token) }
            try Task.checkCancellation()
            try requireAccess(generation: generation, token: token)
            apply(refreshed.user, contentRevision: contentRevision)
            let session = try await performAPI { try await api.voiceSession(token: token) }
            try requireAccess(generation: generation, token: token)
            guard session.user.id == refreshed.user.id, !session.token.isEmpty,
                  session.expiresAt > Int(Date().timeIntervalSince1970),
                  session.sdk.expiresAt > Int(Date().timeIntervalSince1970) else {
                throw KikiAPIError.security("语聊授权与当前账号不一致，请重新登录。")
            }
            try await connectSDK(session.sdk, voiceSession: session.token,
                                 expiresAt: session.expiresAt, generation: generation, expectedToken: token)

        }
        renewalTask = task
        renewalAttempt = KikiIncidentContext.attempt
        defer { renewalTask = nil; renewalAttempt = nil }
        try await task.value
    }

    private func startLeaseRenewal() {
        guard leaseTask == nil else { return }
        let generation = sessionGeneration
        let interval = leaseRenewalNanoseconds
        leaseTask = Task { @MainActor [weak self] in
            var nextInterval = interval
            while !Task.isCancelled {
                // A live background call keeps renewing its authorization. A
                // temporary control-plane failure retries within the existing
                // lease, never turning a healthy media connection into a leave.
                guard let expiry = self?.credentialsExpiry else { return }
                let remaining = max(0, Double(expiry) - Date().timeIntervalSince1970)
                let delay = min(nextInterval, UInt64(remaining * 1_000_000_000))
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
                guard let self, self.permitsBusiness, self.token != nil,
                      self.sessionGeneration == generation else { return }
                let trace = KikiRoomAttempt(operation: .runtime, roomID: self.rtcStorage?.currentSDKRoomID, identityEpoch: self.incidents.identityEpoch)
                trace.enter(.accountAuthorization)
                do {
                    guard self.credentialsExpiry > Int(Date().timeIntervalSince1970) else {
                        throw KikiAPIError.server(401, "语聊授权已过期，请重新连接。")
                    }
                    try await KikiIncidentContext.$attempt.withValue(trace) { try await self.renewSDKSession() }
                    trace.complete()
                    nextInterval = interval
                } catch {
                    guard self.sessionGeneration == generation, !(error is CancellationError) else { return }
                    self.incidents.record(error, trace: trace, severity: .warning, dedupeKey: "voice_authorization_renewal")
                    if KikiVoiceAuthorizationRecovery.canKeepCurrentSession(after: error, expiresAt: self.credentialsExpiry) {
                        nextInterval = min(interval, 5_000_000_000)
                        continue
                    }
                    self.sessionGeneration += 1
                    self.isEndingSession = true
                    self.isAuthenticated = false
                    self.suspendExperience()
                    self.rtcStorage?.stopMediaForPrivacy()
                    self.voiceToken = nil; self.voiceUserID = nil; self.credentialsExpiry = 0
                    self.loadingError = "语聊授权暂时无法续期，请检查网络后重新连接。"
                    await self.rtcStorage?.logout()
                    self.isEndingSession = false
                    self.leaseTask = nil
                    return
                }
            }
        }
    }

    private func currentVoiceToken() throws -> String {
        guard let voiceToken, !voiceToken.isEmpty else { throw KikiAPIError.server(401, "语聊授权已失效，请重新连接。") }
        return voiceToken
    }

    func refreshExperience() async {
        guard permitsBusiness, isAuthenticated, !needsNickname else { return }
        let generation = sessionGeneration
        do {
            try await ensureSDKSession()
            try requireAccess(generation: generation)
            await gifts.refresh()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, generation == sessionGeneration else { return }
            notify(error.localizedDescription)
        }
    }

    private func connectSDK(_ credentials: KikiSDKCredentials, voiceSession: String, expiresAt: Int,
                            generation: Int, expectedToken: String) async throws {
        try requireAccess(generation: generation, token: expectedToken)
        try await rtc.login(credentials: credentials, sessionToken: voiceSession)
        do { try requireAccess(generation: generation, token: expectedToken) }
        catch { await rtcStorage?.logout(); throw error }
        voiceToken = voiceSession
        voiceUserID = credentials.userID
        gifts.configure(api: voiceAPI, token: voiceSession, userID: credentials.userID)
        rtc.configureGifts(gifts)
        credentialsExpiry = min(credentials.expiresAt, expiresAt)
        startLeaseRenewal()
        if !needsNickname { try await syncRTCProfile() }
    }

    private func syncRTCProfile() async throws {
        try requireAccess()
        guard let user, let voiceUserID else { return }
        // Re-exchange after a profile edit so the voice server receives only the
        // account server's authenticated profile; no client-claimed identity.
        if profileNeedsRTCSync {
            credentialsExpiry = 0
            if renewalTask == nil { try await renewSDKSession() }
        }
        try await rtc.updateProfile(userID: voiceUserID, name: user.name, bio: user.bio,
                                    avatarURL: user.avatarURL ?? "")
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
            isEndingSession = true
            rtcStorage?.stopMediaForPrivacy()
            clearSession()
            consent.requireUpdatedDocuments(required, message: message)
            Task { [self] in
                leaseTask?.cancel(); leaseTask = nil
                renewalTask?.cancel()
                await apiStorage?.cancelRequestsAndClearAvatarCache()
                await voiceAPIStorage?.cancelRequestsAndClearAvatarCache()
                _ = await renewalTask?.result
                await rtcStorage?.logout()
                isEndingSession = false
                consent.setServiceTransition(false)
            }
            return
        }
        if let error = error as? KikiAPIError, error.isUnauthorized {
            sessionGeneration += 1
            rtcStorage?.stopMediaForPrivacy()
            clearSession()
            loadingError = "登录已过期，请重新登录。"
            isEndingSession = true
            Task {
                leaseTask?.cancel(); leaseTask = nil
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
        do { return try await operation() }
        catch {
            if let apiError = error as? KikiAPIError, case .legalUpdateRequired = apiError { handle(apiError) }
            throw error
        }
    }

    // Every social response is checked against the account session that requested it.
    // Account tokens remain confined to kiki.group, including when opened from a room.
    func socialPeople(query: String = "", cursor: String? = nil) async throws -> KikiPeoplePage {
        try await socialRequest { try await self.api.socialPeople(query: query, cursor: cursor, token: $0) }
    }

    func socialPerson(_ id: String) async throws -> KikiPerson {
        try await socialRequest { try await self.api.socialPerson(id, token: $0) }
    }

    func socialRelationships(_ kind: KikiRelationshipKind, cursor: String? = nil) async throws -> KikiPeoplePage {
        try await socialRequest { try await self.api.socialRelationships(kind, cursor: cursor, token: $0) }
    }

    func isFollowing(_ person: KikiPerson) -> Bool {
        guard isAuthenticated, !isEndingSession else { return false }
        if let updated = followingOverrides[person.id] { return updated }
        return hasLoadedFollowingIDs ? followingUserIDs.contains(person.id) : person.following
    }

    func setFollowing(_ person: KikiPerson, enabled: Bool) async throws -> KikiPerson {
        let privacy = socialPrivacyRevision
        let result = try await socialRequest {
            try await self.api.socialFollow(person.id, enabled: enabled, requestID: UUID(), token: $0)
        }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        // A pre-mutation summary cannot overwrite the relationship that this
        // request has just committed. Secondary counters refresh separately.
        let summaryRequestID = UUID(); socialRefreshID = summaryRequestID
        followingOverrides[result.id] = result.following
        if result.following { followingUserIDs.insert(result.id) } else { followingUserIDs.remove(result.id) }
        socialRevision += 1
        socialMutationRefreshTask?.cancel()
        socialMutationRefreshTask = Task { [weak self] in await self?.refreshSocialSummary(requestID: summaryRequestID) }
        return result
    }

    func socialNotifications(cursor: String? = nil) async throws -> KikiNotificationsPage {
        let privacy = socialPrivacyRevision
        let scope = pushSessionKey.map { KikiForegroundNotificationScope(sessionKey: $0, privacyRevision: privacy) }
        let fetch = notificationUnreadGate.beginFetch()
        let result = try await socialRequest { try await self.api.socialNotifications(cursor: cursor, token: $0) }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        if notificationUnreadGate.accepts(fetch) {
            unreadNotificationCount = result.unreadCount
            if cursor == nil, let scope { acceptMomentNotifications(result.notifications, scope: scope) }
            if cursor == nil, let push = pushController, let scope, scope == push.currentForegroundScope {
                let baseline = notificationForegroundScope != scope
                notificationForegroundScope = scope
                let candidates = result.notifications.filter(\.isUnread)
                    .sorted { $0.createdAt < $1.createdAt }
                    .map { KikiForegroundNotificationCandidate(id: $0.id, kind: .notifications,
                        preview: .init(title: $0.actor?.name ?? $0.title, message: $0.text)) }
                push.receiveForegroundCandidates(candidates, scope: scope, baseline: baseline)
            }
        }
        return result
    }

    private func acceptMomentNotifications(_ notifications: [KikiSocialNotification], scope: KikiForegroundNotificationScope) {
        guard scope.sessionKey == pushSessionKey, scope.privacyRevision == socialPrivacyRevision else { return }
        let baseline = momentNotificationScope != scope
        if baseline {
            momentNotificationScope = scope
            momentNotificationSequence = 0
            legacyMomentNotificationIDs = []; legacyMomentNotificationOrder = []
        }
        let previousSequence = momentNotificationSequence
        var changed = false
        for notification in notifications {
            let fresh: Bool
            if notification.seq > 0 {
                fresh = notification.seq > previousSequence
                momentNotificationSequence = max(momentNotificationSequence, notification.seq)
            } else {
                fresh = legacyMomentNotificationIDs.insert(notification.id).inserted
                legacyMomentNotificationOrder.removeAll { $0 == notification.id }
                legacyMomentNotificationOrder.append(notification.id)
                if legacyMomentNotificationOrder.count > 512 {
                    legacyMomentNotificationIDs.remove(legacyMomentNotificationOrder.removeFirst())
                }
            }
            // The server currently uses kind=system for comment/like notices.
            // A verified moment reference is the contract; copy and kind are not.
            // Even the first snapshot can postdate the feed's initial GET.
            // Seed deduplication and request one content refresh; the separate
            // banner gate still keeps its own initial snapshot silent.
            if fresh, let momentID = notification.momentID, UUID(uuidString: momentID) != nil {
                changed = true
            }
        }
        if changed { momentContentRevision &+= 1 }
    }

    /// An account-verified push is only an invalidation hint. Feed permissions
    /// and content still come from the ordinary authenticated moments request.
    func momentContentPushReceived(scope: KikiForegroundNotificationScope) {
        guard permitsBusiness, isAuthenticated, scope.sessionKey == pushSessionKey,
              scope.privacyRevision == socialPrivacyRevision else { return }
        momentContentRevision &+= 1
    }

    private func resetMomentNotificationTracking() {
        momentNotificationScope = nil; momentNotificationSequence = 0
        legacyMomentNotificationIDs = []; legacyMomentNotificationOrder = []
        momentContentRevision &+= 1
    }

    func readNotifications(ids: [String] = [], all: Bool = false) async throws {
        let privacy = socialPrivacyRevision
        let generation = sessionGeneration, expectedToken = token
        let mutation = notificationUnreadGate.beginMutation()
        defer { notificationUnreadGate.finishMutation(mutation) }
        do {
            _ = try await socialRequest {
                try await self.api.socialReadNotifications(ids: ids, all: all, token: $0)
            }
        } catch {
            notificationUnreadGate.finishMutation(mutation)
            if privacy == socialPrivacyRevision, generation == sessionGeneration, token == expectedToken,
               permitsBusiness, isAuthenticated, !notificationUnreadGate.hasPendingMutation {
                _ = try? await socialNotifications()
            }
            throw error
        }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        notificationUnreadGate.finishMutation(mutation)
        // Concurrent reads can finish out of order. Fetch the authoritative total
        // after the last mutation instead of applying a stale mutation response.
        if !notificationUnreadGate.hasPendingMutation { _ = try await socialNotifications() }
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        await pushController?.refresh()
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
    }

    func refreshSocialSummary() async {
        guard permitsBusiness, isAuthenticated, !needsNickname, !userID.isEmpty else { return }
        socialMutationRefreshTask?.cancel(); socialMutationRefreshTask = nil
        let requestID = UUID(); socialRefreshID = requestID
        await refreshSocialSummary(requestID: requestID)
    }

    /// Keep the message tab and foreground alerts current on every tab without
    /// repeatedly fetching profiles, relationships or room state.
    func refreshInboxSummary() async {
        guard !Task.isCancelled, permitsBusiness, isAuthenticated, !needsNickname else { return }
        do {
            _ = try await socialNotifications()
        } catch is CancellationError { }
        catch { handleSocialFailure(error) }
        guard !Task.isCancelled, permitsBusiness, isAuthenticated else { return }
        do { _ = try await socialConversations() }
        catch is CancellationError { }
        catch { handleSocialFailure(error) }
    }

    private func refreshSocialSummary(requestID: UUID) async {
        // A queued mutation refresh must not supersede a newer explicit refresh
        // merely because its unstructured task was scheduled later.
        guard !Task.isCancelled, requestID == socialRefreshID,
              permitsBusiness, isAuthenticated, !needsNickname, !userID.isEmpty else { return }
        let privacy = socialPrivacyRevision
        do {
            let me = try await socialPerson(userID)
            _ = try await socialNotifications()
            let relationships = try await socialRequest { try await self.api.socialFollowingIDs(token: $0) }
            _ = try await socialConversations()
            guard requestID == socialRefreshID, privacy == socialPrivacyRevision, permitsBusiness, isAuthenticated else { return }
            if socialProfile != me { socialProfile = me }
            let following = Set(relationships.followingIDs)
            if followingUserIDs != following { followingUserIDs = following }
            if !followingOverrides.isEmpty { followingOverrides = [:] }
            if !hasLoadedFollowingIDs { hasLoadedFollowingIDs = true }
        } catch {
            if !(error is CancellationError) { handleSocialFailure(error) }
        }
    }

    func socialImage(_ media: KikiSocialMedia) async throws -> UIImage {
        try requireAccess()
        if let cached = socialImageCache.object(forKey: media.id as NSString) { return cached }
        let privacy = socialPrivacyRevision
        let image = try await socialRequest { try await self.api.socialImage(media, token: $0) }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        socialImageCache.setObject(image, forKey: media.id as NSString, cost: Int(image.size.width * image.size.height * 4))
        return image
    }
    func uploadSocialImage(_ jpeg: Data) async throws -> KikiSocialMedia {
        try await socialRequest { try await self.api.socialUpload(jpeg: jpeg, token: $0) }
    }
    func socialMoments(kind: KikiMomentKind, userID: String? = nil, cursor: String? = nil) async throws -> KikiMomentsPage {
        try await socialRequest { try await self.api.socialMoments(kind: kind, userID: userID, cursor: cursor, token: $0) }
    }
    func socialMoment(_ id: String) async throws -> KikiMoment {
        try await socialRequest { try await self.api.socialMoment(id, token: $0) }
    }
    func publishMoment(requestID: UUID, text: String, mediaIDs: [String]) async throws -> KikiMoment {
        try await momentMutation { try await self.api.socialPublishMoment(requestID: requestID, text: text, mediaIDs: mediaIDs, token: $0) }
    }
    func deleteMoment(_ id: String) async throws {
        try await momentMutation { try await self.api.socialDeleteMoment(id, token: $0) }
    }
    func likeMoment(_ moment: KikiMoment) async throws -> KikiMoment {
        try await momentMutation { try await self.api.socialLike(moment.id, enabled: !moment.liked, requestID: UUID(), token: $0) }
    }
    func socialComments(_ id: String, cursor: String? = nil) async throws -> KikiCommentsPage {
        try await socialRequest { try await self.api.socialComments(id, cursor: cursor, token: $0) }
    }
    func commentMoment(_ id: String, text: String, requestID: UUID) async throws -> KikiMomentComment {
        try await momentMutation { try await self.api.socialComment(id, text: text, requestID: requestID, token: $0) }
    }
    func deleteComment(_ id: String) async throws {
        try await momentMutation { try await self.api.socialDeleteComment(id, token: $0) }
    }

    private func momentMutation<Value>(_ operation: (String) async throws -> Value) async throws -> Value {
        let generation = sessionGeneration, privacy = socialPrivacyRevision, expectedToken = token
        let result = try await socialRequest(operation)
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        momentContentRevision &+= 1
        return result
    }
    func socialConversations(cursor: String? = nil) async throws -> KikiConversationsPage {
        let privacy = socialPrivacyRevision
        let scope = pushSessionKey.map { KikiForegroundNotificationScope(sessionKey: $0, privacyRevision: privacy) }
        let fetch = directUnreadGate.beginFetch()
        let result = try await socialRequest { try await self.api.socialConversations(cursor: cursor, token: $0) }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        if directUnreadGate.accepts(fetch) {
            unreadDirectMessageCount = result.unreadCount
            if cursor == nil, let push = pushController, let scope, scope == push.currentForegroundScope {
                let baseline = directForegroundScope != scope
                directForegroundScope = scope
                let candidates = result.conversations
                    .sorted { ($0.lastMessage?.createdAt ?? 0) < ($1.lastMessage?.createdAt ?? 0) }
                    .compactMap { conversation -> KikiForegroundNotificationCandidate? in
                        guard conversation.unreadCount > 0, let message = conversation.lastMessage,
                              message.senderID != userID else { return nil }
                        let preview: KikiForegroundNotificationPreview? = message.senderID == conversation.person.id
                            ? .init(title: conversation.person.name, message: message.text) : nil
                        return .init(id: message.id, kind: .direct(personID: conversation.person.id), preview: preview)
                    }
                push.receiveForegroundCandidates(candidates, scope: scope, baseline: baseline)
            }
        }
        return result
    }
    func socialInbox(cursor: String? = nil) async throws -> KikiInboxPage {
        let privacy = socialPrivacyRevision
        let notificationFetch = notificationUnreadGate.beginFetch()
        let directFetch = directUnreadGate.beginFetch()
        let result = try await socialRequest { try await self.api.socialInbox(cursor: cursor, token: $0) }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        if notificationUnreadGate.accepts(notificationFetch) { unreadNotificationCount = result.unreadNotificationCount }
        if directUnreadGate.accepts(directFetch) { unreadDirectMessageCount = result.unreadDirectMessageCount }
        return result
    }

    func inboxSnapshot() async throws -> KikiInboxSnapshot {
        try await socialRequest { try await self.api.socialInboxSnapshot(token: $0) }
    }

    /// The same signed cutoff and request ID survive uncertain acknowledgements.
    /// The server applies these watermarks to this account only, across all pages.
    func mutateInbox(snapshot: KikiInboxSnapshot, clear: Bool, requestID: UUID) async throws {
        let privacy = socialPrivacyRevision
        let generation = sessionGeneration, expectedToken = token
        let notificationMutation = notificationUnreadGate.beginMutation()
        let directMutation = directUnreadGate.beginMutation()
        defer {
            notificationUnreadGate.finishMutation(notificationMutation)
            directUnreadGate.finishMutation(directMutation)
        }
        do {
            try await socialRequest { try await self.api.socialMutateInbox(snapshot: snapshot, clear: clear, requestID: requestID, token: $0) }
        } catch {
            notificationUnreadGate.finishMutation(notificationMutation)
            directUnreadGate.finishMutation(directMutation)
            if privacy == socialPrivacyRevision, generation == sessionGeneration, token == expectedToken,
               permitsBusiness, isAuthenticated { _ = try? await socialInbox() }
            throw error
        }
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        if clear {
            // Drafts and pending sends are not inbox history. Preserve anything
            // the user typed or sent after the deletion cutoff was captured.
            directContentRevision += 1
            notificationHistoryRevision += 1
        }
        notificationUnreadGate.finishMutation(notificationMutation)
        directUnreadGate.finishMutation(directMutation)
        _ = try? await socialInbox()
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        await pushController?.refresh()
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
    }

    func setInboxPinned(_ entry: KikiInboxEntry, pinned: Bool, requestID: UUID) async throws {
        guard case .direct(let conversation) = entry.content else { throw KikiAPIError.invalidResponse }
        try await socialRequest { try await self.api.socialSetConversationPinned(conversation.person.id, pinned: pinned, requestID: requestID, token: $0) }
    }

    func clearInboxEntry(_ entry: KikiInboxEntry, throughID: String, requestID: UUID) async throws {
        guard case .direct(let conversation) = entry.content else { throw KikiAPIError.invalidResponse }
        let privacy = socialPrivacyRevision
        let generation = sessionGeneration, expectedToken = token
        let mutation = directUnreadGate.beginMutation()
        defer { directUnreadGate.finishMutation(mutation) }
        do {
            try await socialRequest { try await self.api.socialClearConversation(conversation.person.id, throughMessageID: throughID, requestID: requestID, token: $0) }
        } catch {
            directUnreadGate.finishMutation(mutation)
            if privacy == socialPrivacyRevision, generation == sessionGeneration, token == expectedToken,
               permitsBusiness, isAuthenticated, !directUnreadGate.hasPendingMutation { _ = try? await socialConversations() }
            throw error
        }
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        directDrafts[conversation.person.id] = nil; pendingDirectMessages[conversation.person.id] = nil
        directHistoryRevision[conversation.person.id, default: 0] += 1
        directUnreadGate.finishMutation(mutation)
        if !directUnreadGate.hasPendingMutation { _ = try? await socialConversations() }
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        await pushController?.refresh()
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
    }

    func socialDirectMessages(_ id: String, cursor: String? = nil) async throws -> KikiDirectMessagesPage {
        let revision = directAccessRevision[id, default: 0]
        directAccessFetchRevision[id, default: 0] += 1
        let fetch = directAccessFetchRevision[id, default: 0]
        do {
            let page = try await socialRequest { try await self.api.socialDirectMessages(id, cursor: cursor, token: $0) }
            if revision == directAccessRevision[id, default: 0], fetch == directAccessFetchRevision[id] { applyDirectAccess(page.directAccess, personID: id) }
            return page
        } catch {
            if revision == directAccessRevision[id, default: 0], fetch == directAccessFetchRevision[id], let api = error as? KikiAPIError,
               case .server(let status, _) = api, status == 403 || status == 404 {
                applyDirectAccess(.init(canSend: false), personID: id)
            }
            throw error
        }
    }
    func directMessagePushReceived() {
        guard permitsBusiness, isAuthenticated else { return }
        directContentRevision += 1
    }
    private func applyDirectAccess(_ access: KikiDirectMessageAccess, personID: String) {
        if directMessageAccess[personID] != access { directMessageAccess[personID] = access }
    }
    func updateDirectDraft(_ text: String, personID: String) {
        guard permitsBusiness, isAuthenticated, pendingDirectMessages[personID] == nil else { return }
        directDrafts[personID] = String(text.prefix(1000))
    }
    func sendDirectDraft(_ id: String) async throws -> KikiDirectMessageReceipt {
        try requireAccess()
        let generation = sessionGeneration, expectedToken = token, privacy = socialPrivacyRevision
        let pending: KikiPendingDirectMessage
        if let current = pendingDirectMessages[id] {
            guard !current.isSending else { throw CancellationError() }
            pending = .init(requestID: current.requestID, text: current.text, isSending: true, error: nil)
        } else {
            if let access = directMessageAccess[id], !access.canSend {
                throw KikiAPIError.server(403, access.explanation ?? "暂时无法发送消息。")
            }
            let text = (directDrafts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw KikiAPIError.server(422, "请先输入消息。") }
            pending = .init(requestID: UUID(), text: text, isSending: true, error: nil)
        }
        directAccessRevision[id, default: 0] += 1
        pendingDirectMessages[id] = pending
        do {
            let result = try await socialRequest { try await self.api.socialSendDirect(id, text: pending.text, requestID: pending.requestID, token: $0) }
            directAccessRevision[id, default: 0] += 1
            if let access = result.directAccess { applyDirectAccess(access, personID: id) }
            if pendingDirectMessages[id]?.requestID == pending.requestID {
                pendingDirectMessages[id] = nil; directDrafts[id] = nil
            }
            return result
        } catch {
            if !(error is CancellationError), generation == sessionGeneration, expectedToken == token, privacy == socialPrivacyRevision {
                directAccessRevision[id, default: 0] += 1
                if let denial = error as? KikiDirectMessageAdmissionError { applyDirectAccess(denial.access, personID: id) }
                else if let api = error as? KikiAPIError, case .server(403, _) = api { applyDirectAccess(.init(canSend: false), personID: id) }
            }
            if pendingDirectMessages[id]?.requestID == pending.requestID {
                if KikiSocialMutation.needsSameIDRetry(error) {
                    var failed = pending; failed.isSending = false; failed.error = error.localizedDescription
                    pendingDirectMessages[id] = failed
                } else { pendingDirectMessages[id] = nil }
            }
            throw error
        }
    }
    func readDirectMessages(_ id: String, throughMessageID: String) async throws {
        let privacy = socialPrivacyRevision
        let generation = sessionGeneration, expectedToken = token
        let mutation = directUnreadGate.beginMutation()
        defer { directUnreadGate.finishMutation(mutation) }
        do {
            _ = try await socialRequest { try await self.api.socialReadDirect(id, throughMessageID: throughMessageID, token: $0) }
        } catch {
            directUnreadGate.finishMutation(mutation)
            if privacy == socialPrivacyRevision, generation == sessionGeneration, token == expectedToken,
               permitsBusiness, isAuthenticated, !directUnreadGate.hasPendingMutation {
                _ = try? await socialConversations()
            }
            throw error
        }
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        directUnreadGate.finishMutation(mutation)
        if !directUnreadGate.hasPendingMutation { _ = try await socialConversations() }
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
        await pushController?.refresh()
        try requireAccess(generation: generation, token: expectedToken)
        guard privacy == socialPrivacyRevision else { throw CancellationError() }
    }
    func submitSocialReport(_ target: KikiSocialReportTarget, reason: KikiSocialReportReason, details: String, requestID: UUID) async throws -> KikiSocialReportReceipt {
        try await socialRequest { try await self.api.socialReport(target, reason: reason, details: details, requestID: requestID, token: $0) }
    }
    func socialReports() async throws -> KikiSocialReportsPage {
        try await socialRequest { try await self.api.socialReports(token: $0) }
    }
    func socialPolicyChanged(userID: String, blocked: Bool) {
        socialPrivacyRevision += 1
        resetMomentNotificationTracking()
        pendingDirectConversation = nil; directConversationPath = []
        socialRefreshID = UUID()
        socialMutationRefreshTask?.cancel(); socialMutationRefreshTask = nil
        notificationUnreadGate = KikiUnreadRequestGate(); directUnreadGate = KikiUnreadRequestGate()
        notificationForegroundScope = nil; directForegroundScope = nil
        if blocked { followingOverrides[userID] = false; followingUserIDs.remove(userID); directDrafts[userID] = nil; pendingDirectMessages[userID] = nil }
        directMessageAccess = [:]; directAccessRevision = [:]; directAccessFetchRevision = [:]
        socialImageCache.removeAllObjects(); socialRevision += 1
        pushController?.privacyChanged()
    }
    func setSocialBlock(_ id: String, enabled: Bool) async throws {
        try await socialRequest { try await self.api.socialBlock(id, enabled: enabled, requestID: UUID(), token: $0) }
        socialPolicyChanged(userID: id, blocked: enabled)
        await refreshSafety(); await refreshRooms(); await refreshSocialSummary()
    }

    private func socialRequest<Value>(_ operation: (String) async throws -> Value) async throws -> Value {
        try requireAccess()
        guard isAuthenticated, !needsNickname, let token else { throw KikiAPIError.server(401, "请先登录。") }
        let generation = sessionGeneration
        let privacyRevision = socialPrivacyRevision
        do {
            let value = try await performAPI { try await operation(token) }
            try requireAccess(generation: generation, token: token)
            guard privacyRevision == socialPrivacyRevision else { throw CancellationError() }
            return value
        } catch {
            try requireAccess(generation: generation, token: token)
            guard privacyRevision == socialPrivacyRevision else { throw CancellationError() }
            handleSocialFailure(error)
            throw error
        }
    }

    private func handleSocialFailure(_ error: Error) {
        if let error = error as? KikiAPIError, error.isUnauthorized { handle(error) }
    }

    private func suspendExperience() {
        // Invalidate queued writes synchronously, before session teardown awaits.
        gifts.reset()
        rtcStorage?.configureGifts(nil)
    }

    private func clearSession(removeCredential: Bool = true) {
        roomMetadataRevision &+= 1
        cancelRoomCatalogRefreshes()
        if token != nil || isAuthenticated || !userID.isEmpty { pushController?.endSession() }
        incidents.clear()
        reservedRoomAttempts = [:]
        socialMutationRefreshTask?.cancel(); socialMutationRefreshTask = nil
        socialRefreshID = UUID()
        socialPrivacyRevision += 1
        resetMomentNotificationTracking()
        pendingDirectConversation = nil; directConversationPath = []
        notificationUnreadGate = KikiUnreadRequestGate(); directUnreadGate = KikiUnreadRequestGate()
        notificationForegroundScope = nil; directForegroundScope = nil
        visibleDirectConversations = []
        directHistoryRevision = [:]; notificationHistoryRevision += 1
        socialProfile = nil; followingUserIDs = []; followingOverrides = [:]; hasLoadedFollowingIDs = false; unreadNotificationCount = 0; unreadDirectMessageCount = 0
        socialImageCache.removeAllObjects()
        directDrafts = [:]; pendingDirectMessages = [:]
        directMessageAccess = [:]; directAccessRevision = [:]; directAccessFetchRevision = [:]; directContentRevision += 1
        socialRevision += 1
        leaseTask?.cancel(); leaseTask = nil
        suspendExperience()
        if removeCredential {
            identity.remove("sessionToken")
            identity.remove("appleSubject")
            identity.remove("appleSessionVersion")
        }
        token = nil; voiceToken = nil; voiceUserID = nil; user = nil; credentialsExpiry = 0; profileNeedsRTCSync = false
        isAuthenticated = false
        profileName = ""; bio = ""; avatarIndex = 0; customAvatarURL = nil; needsNickname = false; userID = ""
        notificationsEnabled = false
        notificationContentRevision &+= 1
        notificationContentRequest = nil
        isUpdatingNotificationContent = false
        hideNotificationContent = false
        lastSuccessfulRoomTitle = nil
        favoriteIDs = []; recentRoomIDs = []; rooms = []
        roomMetadata = []; library = KikiLibrary(favorites: [], recents: [], created: [])
        loadingError = nil; libraryError = nil
    }
}
