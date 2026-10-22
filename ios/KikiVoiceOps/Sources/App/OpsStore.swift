import Foundation
import Combine

@MainActor final class OpsStore: ObservableObject {
    @Published private(set) var service: OpsService = .voice
    @Published private(set) var account: OpsAccount?
    @Published private(set) var authenticated = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var isRestoring = false
    @Published private(set) var isSavingName = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var dashboard: OpsDashboard?
    @Published private(set) var accountDashboard: AccountOpsDashboard?
    @Published private(set) var moderationPage: OpsModerationPage?
    @Published private(set) var incidentPage: OpsIncidentPage?
    @Published private(set) var incidentFilter = OpsIncidentFilter()
    @Published private(set) var isLoadingIncidents = false
    @Published private(set) var incidentError: String?
    @Published private(set) var incidentsUpdatedAt: Date?
    @Published private(set) var moderationFilter: OpsReportFilter = .pending
    @Published private(set) var isModerating = false
    @Published private(set) var moderationNotice: String?
    @Published private(set) var pendingModeration: OpsPendingModeration?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var error: String?
    @Published private(set) var sessionExpiresAt: Date?
    @Published private(set) var socialContextRevision = UUID()

    private let api: any OpsAPI
    private let vault: any SessionVault
    private let authorizer: any OpsPasskeyAuthorizing
    private var session: OpsSession?
    private var generation = UUID()
    private var active = false
    private var backgrounded = false
    private var refreshID = UUID()
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var authenticationTask: Task<Void, Never>?
    private var moderationTask: Task<Bool, Never>?
    private var moderationID = UUID()
    private var incidentTask: Task<Void, Never>?
    private var incidentID = UUID()
    // ACL loss invalidates reads independently of refreshID, so the current
    // refresh still runs its restoring/loading cleanup in defer.
    private var identityRevision = UUID()

    var needsName: Bool { account?.needsName == true }
    var canAccessSelectedService: Bool { authenticated && !needsName && account?.permissions.permits(service) == true }
    var hasSavedSession: Bool { session != nil }

    init(api: any OpsAPI = OpsIdentityAPI(), vault: any SessionVault = KeychainSessionVault(),
         authorizer: (any OpsPasskeyAuthorizing)? = nil) {
        self.api = api; self.vault = vault; self.authorizer = authorizer ?? SystemOpsPasskeyAuthorizer()
        do {
            try vault.purgeLegacySessions()
            if let restored = try vault.load(), restored.isValid() {
                session = restored; sessionExpiresAt = restored.expiresAt; isRestoring = true
            } else { try vault.remove() }
        } catch { self.error = "无法读取安全会话，请重新登录。" }
    }
    func selectService(_ value: OpsService) {
        guard service != value else { return }
        cancelRefresh(); service = value; clearSnapshots(); error = nil
        if active, authenticated { startPolling() }
    }
    func selectModerationFilter(_ value: OpsReportFilter) {
        guard value != moderationFilter, !isModerating else { return }
        cancelRefresh(); moderationFilter = value; moderationPage = nil; error = nil
        if active, authenticated { startPolling() }
    }
    /// Inactive can mean a system Passkey sheet. It pauses data but does not cancel that sheet.
    func setActive(_ value: Bool, cancelAuthorization: Bool = true) {
        active = value
        pollTask?.cancel(); pollTask = nil
        if !value {
            socialContextRevision = UUID()
            cancelRefresh()
            if cancelAuthorization {
                backgrounded = true
                if isLoggingIn {
                    generation = UUID(); authenticationTask?.cancel(); authenticationTask = nil
                    authorizer.cancel(); isLoggingIn = false
                }
            }
            return
        }
        backgrounded = false
        guard let session else { isRestoring = false; return }
        guard session.isValid() else { endSession(message: OpsError.expired.localizedDescription); return }
        // Existing ACL snapshots cannot authorize a foreground request. GET me runs first.
        clearSnapshots()
        startPolling()
    }
    func login(create: Bool) async {
        guard active, !isLoggingIn, !isRestoring else { return }
        let current = generation
        isLoggingIn = true; error = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.isLoggingIn = false; self.authenticationTask = nil } }
            do {
                let received: OpsLoginResult
                if create {
                    let options = try await self.api.registrationOptions()
                    try self.requireAuthorization(current)
                    let credential = try await self.authorizer.register(options)
                    try self.requireAuthorization(current)
                    received = try await self.api.finishRegistration(transactionID: options.transactionID, credential: credential)
                } else {
                    let options = try await self.api.authenticationOptions()
                    try self.requireAuthorization(current)
                    let credential = try await self.authorizer.authenticate(options)
                    try self.requireAuthorization(current)
                    received = try await self.api.finishAuthentication(transactionID: options.transactionID, credential: credential)
                }
                guard self.generation == current, !self.backgrounded, !Task.isCancelled else {
                    try? await self.api.logout(session: received.session); return
                }
                guard received.session.isValid() else { throw OpsError.invalidResponse }
                try received.account.validate()
                do { try self.vault.save(received.session) }
                catch { try? await self.api.logout(session: received.session); throw error }
                self.session = received.session; self.sessionExpiresAt = received.session.expiresAt
                self.account = received.account; self.authenticated = true; self.isRestoring = false
                if self.active { self.startPolling() }
            } catch {
                guard self.generation == current, !self.backgrounded, !(error is CancellationError) else { return }
                self.error = self.safeMessage(error)
            }
        }
        authenticationTask = task
        await task.value
    }
    func saveName(_ value: String) async {
        guard !isSavingName, authenticated, let session, let name = OpsAccount.validName(value) else {
            error = OpsError.invalidName.localizedDescription; return
        }
        let current = generation
        isSavingName = true; error = nil
        defer { if generation == current { isSavingName = false } }
        do {
            let updated = try await api.setName(name, session: session)
            guard generation == current, !backgrounded, !Task.isCancelled else { return }
            try updateIdentity(updated)
            if active { startPolling() }
        } catch { if generation == current { handle(error) } }
    }
    func refresh() async {
        guard active, !isRefreshing, !isModerating, let session else { return }
        guard session.isValid() else { endSession(message: OpsError.expired.localizedDescription); return }
        let current = generation, selected = service, requestID = UUID(), initialIdentityRevision = identityRevision
        refreshID = requestID; isRefreshing = true
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var expectedIdentityRevision = initialIdentityRevision
            defer {
                if self.generation == current, self.refreshID == requestID {
                    self.isRefreshing = false; self.isRestoring = false
                }
            }
            do {
                let identity = try await self.api.me(session: session)
                guard self.isCurrent(current, requestID, selected), self.identityRevision == initialIdentityRevision else { return }
                try self.updateIdentity(identity)
                expectedIdentityRevision = self.identityRevision
                self.authenticated = true
                guard !identity.needsName, identity.permissions.permits(selected) else {
                    self.clearSnapshots(); self.error = nil; return
                }
                let grantedIdentityRevision = self.identityRevision
                let voice: OpsDashboard?, account: AccountOpsDashboard?, moderation: OpsModerationPage?
                switch selected {
                case .voice: voice = try await self.api.dashboard(session: session); account = nil; moderation = nil
                case .account: account = try await self.api.accountDashboard(session: session); voice = nil; moderation = nil
                case .community: moderation = try await self.api.moderation(session: session, filter: self.moderationFilter); voice = nil; account = nil
                }
                guard self.isCurrent(current, requestID, selected), self.identityRevision == grantedIdentityRevision,
                      self.account?.needsName == false, self.account?.permissions.permits(selected) == true else { return }
                self.dashboard = voice; self.accountDashboard = account; self.moderationPage = moderation
                self.lastUpdated = Date(); self.error = nil
            } catch {
                guard self.isCurrent(current, requestID, selected), self.identityRevision == expectedIdentityRevision else { return }
                if error as? OpsError == .forbidden {
                    self.clearSnapshots()
                    // A grant can disappear between me and dashboard. Re-read it;
                    // never infer or grant access from a successful login.
                    do {
                        let identity = try await self.api.me(session: session)
                        guard self.isCurrent(current, requestID, selected), self.identityRevision == expectedIdentityRevision else { return }
                        try self.updateIdentity(identity)
                    } catch { self.handle(error) }
                    self.error = OpsError.forbidden.localizedDescription
                } else { self.handle(error) }
            }
        }
        refreshTask = task; await task.value
        if generation == current, refreshID == requestID { refreshTask = nil }
    }
    func logout() {
        let old = session
        endSession(message: nil)
        if let old { Task { try? await api.logout(session: old) } }
    }
    /// Diagnostics are read-only and use the voice grant. This independent task
    /// never reuses moderation mutations or their persisted recovery request.
    func loadIncidents(filter proposed: OpsIncidentFilter? = nil, loadMore: Bool = false) async {
        guard active, authenticated, !needsName, service == .voice,
              account?.permissions.voice == true, let session else { return }
        guard session.isValid() else { endSession(message: OpsError.expired.localizedDescription); return }
        let filter: OpsIncidentFilter
        do { filter = try (proposed ?? incidentFilter).validated() }
        catch { incidentError = OpsError.invalidIncidentQuery.localizedDescription; return }
        let cursor: String?
        if loadMore {
            guard !isLoadingIncidents, filter == incidentFilter, let next = incidentPage?.nextCursor else { return }
            cursor = next
        } else { cursor = nil }
        cancelIncidentQuery()
        if !loadMore { incidentPage = nil; incidentsUpdatedAt = nil }
        incidentFilter = filter; incidentError = nil; isLoadingIncidents = true
        let current = generation, requestID = UUID(), expectedAccountID = account?.id
        incidentID = requestID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.generation == current, self.incidentID == requestID { self.isLoadingIncidents = false; self.incidentTask = nil } }
            do {
                let identity = try await self.api.me(session: session)
                guard self.isCurrentIncident(current, requestID, session, filter), identity.id == expectedAccountID else { return }
                try self.updateIdentity(identity)
                guard !identity.needsName, identity.permissions.voice else { throw OpsError.forbidden }
                let query = try OpsIncidentQuery(filter: filter, cursor: cursor)
                let page = try await self.api.incidents(query, session: session)
                guard self.isCurrentIncident(current, requestID, session, filter) else { return }
                try page.validate()
                guard cursor == nil || page.nextCursor != cursor else { throw OpsError.invalidResponse }
                // Re-read permissions after a slow query, even if the endpoint
                // returned 200 immediately before an operator was revoked.
                let confirmed = try await self.api.me(session: session)
                guard self.isCurrentIncident(current, requestID, session, filter), confirmed.id == expectedAccountID else { return }
                try self.updateIdentity(confirmed)
                guard !confirmed.needsName, confirmed.permissions.voice else { throw OpsError.forbidden }
                if loadMore, let previous = self.incidentPage {
                    let known = Set(previous.events.map(\.eventID))
                    self.incidentPage = OpsIncidentPage(schemaVersion: 1,
                        events: previous.events + page.events.filter { !known.contains($0.eventID) },
                        nextCursor: page.nextCursor, retentionDays: page.retentionDays)
                } else { self.incidentPage = page }
                self.incidentsUpdatedAt = Date(); self.incidentError = nil
            } catch {
                guard self.isCurrentIncident(current, requestID, session, filter), !(error is CancellationError) else { return }
                if error as? OpsError == .forbidden {
                    self.incidentPage = nil; self.incidentsUpdatedAt = nil
                    do {
                        let identity = try await self.api.me(session: session)
                        guard self.isCurrentIncident(current, requestID, session, filter) else { return }
                        try self.updateIdentity(identity)
                    } catch { self.handle(error) }
                }
                if error as? OpsError == .invalidIncidentQuery, loadMore {
                    // No further request may reuse a cursor pruned by the
                    // seven-day retention or global bound. Refresh starts over.
                    self.incidentPage = nil; self.incidentsUpdatedAt = nil
                }
                if error as? OpsError == .unauthenticated || error as? OpsError == .expired { self.handle(error) }
                else { self.incidentError = self.safeMessage(error) }
            }
        }
        incidentTask = task; await task.value
    }
    /// A fresh ACL check precedes every mutation. No dashboard grant authorizes it.
    func moderate(_ request: OpsModerationRequest) async -> Bool {
        guard active, authenticated, !needsName, service == .community, !isModerating,
              account?.permissions.community == true, let session else { return false }
        if let pendingModeration, pendingModeration.request != request {
            error = OpsError.unresolvedModeration.localizedDescription; return false
        }
        cancelRefresh(cancelModeration: false)
        let current = generation, mutationID = UUID()
        moderationID = mutationID
        isModerating = true; error = nil; moderationNotice = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer {
                if self.generation == current, self.moderationID == mutationID {
                    self.isModerating = false; self.moderationTask = nil
                    if self.active { self.startPolling() }
                }
            }
            do {
                try request.validate()
                let identity = try await self.api.me(session: session)
                guard self.generation == current, self.moderationID == mutationID, self.active, self.service == .community, !Task.isCancelled else { return false }
                try self.updateIdentity(identity)
                guard identity.permissions.community, !identity.needsName else { throw OpsError.forbidden }
                if let existing = self.pendingModeration, existing.request != request { throw OpsError.unresolvedModeration }
                let pending = self.pendingModeration ?? OpsPendingModeration(accountID: identity.id, request: request, createdAt: Date())
                // Persist before sending. A timeout, app restart or closed sheet
                // must not mint a second action ID for the same unknown outcome.
                try self.vault.savePendingModeration(pending)
                self.pendingModeration = pending
                let result = try await self.api.moderate(pending.request, session: session)
                guard self.generation == current, self.moderationID == mutationID, self.active, self.service == .community, !Task.isCancelled else { return false }
                try self.vault.removePendingModeration(accountID: identity.id)
                self.pendingModeration = nil
                self.moderationNotice = result.mediaCleanupPending ? "处理已登记，媒体清理正在重试，请刷新确认。" : "处理已完成。"
                self.moderationPage = nil; self.lastUpdated = nil
                return true
            } catch {
                guard self.generation == current, self.moderationID == mutationID, self.active, self.service == .community, !(error is CancellationError) else { return false }
                if let failure = error as? OpsError,
                   failure == .invalidModeration || failure == .moderationConflict || failure == .server(status: 404),
                   let pending = self.pendingModeration {
                    do {
                        try self.vault.removePendingModeration(accountID: pending.accountID)
                        self.pendingModeration = nil
                    } catch { self.error = "无法清除已确认的本机操作记录，请重试核对。"; return false }
                }
                if error as? OpsError == .forbidden { self.moderationPage = nil }
                self.handle(error)
                if self.pendingModeration != nil, error as? OpsError != .forbidden,
                   error as? OpsError != .unauthenticated, error as? OpsError != .expired {
                    self.error = "处理结果尚未确认。请恢复待确认操作，系统将复用原编号核对，不重复处罚。"
                }
                return false
            }
        }
        moderationTask = task
        return await task.value
    }
    func retryPendingModeration() async -> Bool {
        guard let pendingModeration else { return false }
        guard Date().timeIntervalSince(pendingModeration.createdAt) < 89 * 86400 else {
            error = "该操作已超出自动核对期限，请联系负责人核查服务器审计记录。"; return false
        }
        return await moderate(pendingModeration.request)
    }
    func communityAuthorization() async throws -> OpsCommunityAuthorization {
        guard active, !backgrounded, authenticated, !needsName, service == .community,
              account?.permissions.community == true, let session, session.isValid() else { throw OpsError.forbidden }
        let current = generation, context = socialContextRevision, revision = identityRevision
        do {
            let identity = try await api.me(session: session)
            guard current == generation, context == socialContextRevision, revision == identityRevision,
                  self.session == session, active, !backgrounded, service == .community, !Task.isCancelled else { throw CancellationError() }
            try updateIdentity(identity)
            guard !identity.needsName, identity.permissions.community else { throw OpsError.forbidden }
            return OpsCommunityAuthorization(session: session, accountID: identity.id, generation: generation, context: socialContextRevision, identityRevision: identityRevision)
        } catch {
            if current == generation, context == socialContextRevision { handle(error) }
            throw error
        }
    }
    func isCurrentCommunity(_ value: OpsCommunityAuthorization) -> Bool {
        value.generation == generation && value.context == socialContextRevision && value.identityRevision == identityRevision
            && value.session == session && value.session.isValid() && active && !backgrounded && authenticated
            && !needsName && service == .community && account?.id == value.accountID && account?.permissions.community == true
    }
    func communityRequestRejected(_ error: OpsError) async {
        if error == .unauthenticated || error == .expired { endSession(message: error.localizedDescription); return }
        guard error == .forbidden else { return }
        clearSnapshots()
        guard active, authenticated, let session else { return }
        let current = generation, revision = identityRevision
        do {
            let identity = try await api.me(session: session)
            guard generation == current, self.session == session, revision == identityRevision, active else { return }
            try updateIdentity(identity)
        } catch { if generation == current { handle(error) } }
    }
    private func updateIdentity(_ identity: OpsAccount) throws {
        try identity.validate()
        guard account == nil || account?.id == identity.id else { throw OpsError.invalidResponse }
        if let previous = account,
           (previous.permissions.voice && !identity.permissions.voice
            || previous.permissions.account && !identity.permissions.account
            || previous.permissions.community && !identity.permissions.community
            || !previous.needsName && identity.needsName) {
            identityRevision = UUID()
        }
        account = identity
        pendingModeration = try vault.loadPendingModeration(accountID: identity.id)
        if identity.needsName || !identity.permissions.permits(service) { clearSnapshots() }
    }
    private func requireAuthorization(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected, !backgrounded else { throw CancellationError() }
    }
    private func isCurrent(_ expected: UUID, _ requestID: UUID, _ selected: OpsService) -> Bool {
        generation == expected && refreshID == requestID && service == selected && active && !Task.isCancelled
    }
    private func isCurrentIncident(_ expected: UUID, _ requestID: UUID, _ expectedSession: OpsSession, _ filter: OpsIncidentFilter) -> Bool {
        guard expectedSession.isValid() else {
            if generation == expected, session == expectedSession { endSession(message: OpsError.expired.localizedDescription) }
            return false
        }
        return generation == expected && incidentID == requestID && session == expectedSession
            && service == .voice && active && !backgrounded && authenticated && !needsName
            && account?.permissions.voice == true && incidentFilter == filter && !Task.isCancelled
    }
    private func cancelIncidentQuery() {
        incidentID = UUID(); incidentTask?.cancel(); incidentTask = nil; isLoadingIncidents = false
    }
    private func cancelRefresh(cancelModeration: Bool = true) {
        cancelIncidentQuery()
        refreshID = UUID(); refreshTask?.cancel(); refreshTask = nil; isRefreshing = false
        pollTask?.cancel(); pollTask = nil
        if cancelModeration {
            moderationID = UUID(); moderationTask?.cancel(); moderationTask = nil; isModerating = false
        }
    }
    private func clearSnapshots() {
        socialContextRevision = UUID()
        cancelIncidentQuery(); incidentPage = nil; incidentError = nil; incidentsUpdatedAt = nil
        dashboard = nil; accountDashboard = nil; moderationPage = nil; moderationNotice = nil; lastUpdated = nil
    }
    private func handle(_ value: Error) {
        if let value = value as? OpsError, value == .unauthenticated || value == .expired {
            endSession(message: value.localizedDescription)
        } else if !(value is CancellationError) { error = safeMessage(value) }
    }
    private func endSession(message: String?) {
        generation = UUID(); cancelRefresh()
        authenticationTask?.cancel(); authenticationTask = nil; authorizer.cancel()
        session = nil; account = nil; authenticated = false; isLoggingIn = false; isRestoring = false; isSavingName = false
        pendingModeration = nil
        sessionExpiresAt = nil; clearSnapshots()
        incidentFilter = OpsIncidentFilter()
        do { try vault.remove(); error = message }
        catch { self.error = "会话已关闭，但安全存储清理失败，请重试退出或重新安装应用。" }
    }
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.active, self.session != nil else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    private func safeMessage(_ value: Error) -> String {
        (value as? OpsError)?.localizedDescription ?? "暂时无法连接管理服务，请检查网络后重试。"
    }
}
