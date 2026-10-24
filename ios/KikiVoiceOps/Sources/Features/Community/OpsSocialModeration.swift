import Foundation
import Combine

struct OpsSocialModerationPage: Decodable {
    let schemaVersion: Int
    let reports: [OpsSocialReport]
    let nextCursor: String?
    let retentionDays: Int
    let activeRestrictions: [OpsSocialRestriction]
    func validate() throws {
        guard schemaVersion == 1, retentionDays == 30, reports.count <= 50,
              Set(reports.map(\.id)).count == reports.count,
              nextCursor == nil || nextCursor!.utf8.count <= 1024,
              activeRestrictions.count <= 5000 else { throw OpsError.invalidResponse }
        try reports.forEach { try $0.validate() }
        try activeRestrictions.forEach { try $0.validate() }
    }
}
struct OpsSocialReport: Decodable, Identifiable {
    let id, reporterID, reporterName, targetUserID, targetName, targetType: String
    let reporterDisplayID, targetDisplayID: String?
    var reporterLabel: String { reporterDisplayID ?? reporterID }
    var targetLabel: String { targetDisplayID ?? targetUserID }
    let contentID: String?
    let reason, details, status: String
    let evidence: Evidence
    let createdAt: Double
    let resolvedAt: Double?
    let lastAction: String?
    struct Evidence: Decodable { let text: String }
    var typeTitle: String {
        switch targetType { case "profile": "个人资料"; default: "私聊消息" }
    }
    var reasonTitle: String {
        switch reason { case "harassment": "骚扰或辱骂"; case "spam": "垃圾广告"; case "sexual": "色情内容"; case "fraud": "诈骗"; default: "其他" }
    }
    var statusTitle: String { status == "pending" ? "待处理" : status == "dismissed" ? "已驳回" : "已处理" }
    func validate() throws {
        guard OpsPublicAccountNumber.isValid(reporterDisplayID), OpsPublicAccountNumber.isValid(targetDisplayID),
              !id.isEmpty, id.utf8.count <= 128,
              [reporterID, targetUserID].allSatisfy({ $0.range(of: "^kiki_[A-Za-z0-9_]{8,64}$", options: .regularExpression) != nil }),
              [reporterName, targetName].allSatisfy({ $0.count <= 32 }),
              ["profile", "direct_message"].contains(targetType),
              ["pending", "resolved", "dismissed"].contains(status),
              details.count <= 500, evidence.text.count <= 4096,
              createdAt.isFinite, createdAt > 0 else { throw OpsError.invalidResponse }
    }
}
struct OpsSocialRestriction: Decodable, Identifiable {
    let userID, userName, sourceReportID: String
    let userDisplayID: String?
    var accountLabel: String { userDisplayID ?? userID }
    let until: Double
    var id: String { userID }
    func validate() throws {
        guard OpsPublicAccountNumber.isValid(userDisplayID),
              userID.range(of: "^kiki_[A-Za-z0-9_]{8,64}$", options: .regularExpression) != nil,
              !sourceReportID.isEmpty, userName.count <= 32, until.isFinite, until > 0 else { throw OpsError.invalidResponse }
    }
}
enum OpsSocialAction: String, Codable, CaseIterable, Identifiable {
    case warn, removeContent = "remove_content", restrictPosting = "restrict_posting", restoreUser = "restore_user", dismiss
    var id: String { rawValue }
    var title: String {
        switch self { case .warn: "发送警告"; case .removeContent: "删除违规内容"; case .restrictPosting: "临时社交禁言"; case .restoreUser: "解除社交禁言"; case .dismiss: "驳回举报" }
    }
}
struct OpsSocialActionRequest: Codable, Equatable {
    let requestID, reportID: String
    let action: OpsSocialAction
    let durationSeconds: Int?
    let note: String
    func validate() throws {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: requestID) != nil, !reportID.isEmpty, reportID.utf8.count <= 128,
              !text.isEmpty, text.unicodeScalars.count <= 500,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }) else { throw OpsError.invalidModeration }
        guard action == .restrictPosting ? durationSeconds.map({ (60...2_592_000).contains($0) }) == true : durationSeconds == nil else { throw OpsError.invalidModeration }
    }
}
struct OpsSocialActionResult: Decodable {
    let ok: Bool
    let requestID, reportID, action: String
    func validate(_ request: OpsSocialActionRequest) throws {
        guard ok, let resultRequestID = UUID(uuidString: requestID), let expectedRequestID = UUID(uuidString: request.requestID),
              let resultReportID = UUID(uuidString: reportID), let expectedReportID = UUID(uuidString: request.reportID),
              resultRequestID == expectedRequestID, resultReportID == expectedReportID, action == request.action.rawValue else { throw OpsError.invalidResponse }
    }
}
struct OpsSocialPendingAction: Codable, Equatable {
    let accountID: String
    let request: OpsSocialActionRequest
    let createdAt: Date
}
struct OpsCommunityAuthorization {
    let session: OpsSession
    let accountID: String
    let generation, context, identityRevision: UUID
}

@MainActor final class OpsSocialModerationStore: ObservableObject {
    @Published private(set) var page: OpsSocialModerationPage?
    @Published private(set) var filter: OpsReportFilter = .pending
    @Published private(set) var isLoading = false
    @Published private(set) var isActing = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var pending: OpsSocialPendingAction?
    private let parent: OpsStore
    private let api: any OpsAPI
    private let vault: any OpsSocialPendingVault
    private var serial = UUID()
    private var queryTask: Task<Void, Never>?
    private var actionTask: Task<Bool, Never>?
    init(parent: OpsStore, api: any OpsAPI = OpsIdentityAPI(), vault: any OpsSocialPendingVault = KeychainSessionVault()) {
        self.parent = parent; self.api = api; self.vault = vault
    }
    func invalidate() {
        serial = UUID(); queryTask?.cancel(); actionTask?.cancel(); queryTask = nil; actionTask = nil
        page = nil; pending = nil; error = nil; notice = nil; isLoading = false; isActing = false
    }
    func load(filter proposed: OpsReportFilter? = nil, more: Bool = false) async {
        guard !isActing else { return }
        let nextFilter = proposed ?? filter
        let cursor: String?
        if more { guard !isLoading, nextFilter == filter, let value = page?.nextCursor else { return }; cursor = value }
        else { cursor = nil }
        queryTask?.cancel(); serial = UUID()
        let expected = serial
        filter = nextFilter; isLoading = true; error = nil
        if !more { page = nil }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.serial == expected { self.isLoading = false; self.queryTask = nil } }
            do {
                let auth = try await self.parent.communityAuthorization()
                guard self.serial == expected, !Task.isCancelled else { return }
                self.pending = try self.vault.loadSocialPending(accountID: auth.accountID)
                let result = try await self.api.socialModeration(session: auth.session, filter: nextFilter, cursor: cursor)
                try result.validate()
                guard self.serial == expected, self.parent.isCurrentCommunity(auth), !Task.isCancelled else { return }
                let confirmed = try await self.parent.communityAuthorization()
                guard self.serial == expected, self.parent.isCurrentCommunity(auth), confirmed.accountID == auth.accountID else { return }
                if more, let previous = self.page {
                    guard result.nextCursor != cursor else { throw OpsError.invalidResponse }
                    let known = Set(previous.reports.map(\.id))
                    self.page = OpsSocialModerationPage(schemaVersion: 1, reports: previous.reports + result.reports.filter { !known.contains($0.id) }, nextCursor: result.nextCursor, retentionDays: result.retentionDays, activeRestrictions: result.activeRestrictions)
                } else { self.page = result }
            } catch {
                guard self.serial == expected, !(error is CancellationError) else { return }
                if await self.rejectAccess(error) { return }
                if more, error as? OpsError == .invalidModeration { self.page = nil }
                self.error = self.message(error)
            }
        }
        queryTask = task; await task.value
    }
    func act(_ request: OpsSocialActionRequest) async -> Bool {
        guard !isActing else { return false }
        if let pending, pending.request != request { error = OpsError.unresolvedModeration.localizedDescription; return false }
        queryTask?.cancel(); queryTask = nil; serial = UUID(); isLoading = false
        let expected = serial
        isActing = true; error = nil; notice = nil
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { if self.serial == expected { self.isActing = false; self.actionTask = nil } }
            do {
                try request.validate()
                let auth = try await self.parent.communityAuthorization()
                guard self.serial == expected, self.parent.isCurrentCommunity(auth), !Task.isCancelled else { return false }
                let saved = try self.vault.loadSocialPending(accountID: auth.accountID)
                self.pending = saved
                guard saved == nil || saved?.request == request else { throw OpsError.unresolvedModeration }
                let pending = saved ?? OpsSocialPendingAction(accountID: auth.accountID, request: request, createdAt: Date())
                guard Date().timeIntervalSince(pending.createdAt) < 89 * 86400 else { throw OpsError.unresolvedModeration }
                try self.vault.saveSocialPending(pending); self.pending = pending
                let result = try await self.api.socialModerate(pending.request, session: auth.session)
                try result.validate(pending.request)
                guard self.serial == expected, self.parent.isCurrentCommunity(auth), !Task.isCancelled else { return false }
                _ = try await self.parent.communityAuthorization()
                guard self.serial == expected, self.parent.isCurrentCommunity(auth) else { return false }
                try self.vault.removeSocialPending(accountID: auth.accountID)
                self.pending = nil; self.page = nil; self.notice = "处理已完成。"
                return true
            } catch {
                guard self.serial == expected, !(error is CancellationError) else { return false }
                if await self.rejectAccess(error) { return false }
                if let failure = error as? OpsError, [.invalidModeration, .moderationConflict, .server(status: 404)].contains(failure), let pending = self.pending {
                    do { try self.vault.removeSocialPending(accountID: pending.accountID); self.pending = nil }
                    catch { self.error = "无法清除本机待确认记录，请重新核对。"; return false }
                }
                self.error = self.pending == nil ? self.message(error) : "结果尚未确认，请恢复原操作核对，避免重复处理。"
                return false
            }
        }
        actionTask = task; return await task.value
    }
    func retryPending() async -> Bool { guard let pending else { return false }; return await act(pending.request) }
    private func rejectAccess(_ error: Error) async -> Bool {
        guard let value = error as? OpsError, [.forbidden, .unauthenticated, .expired].contains(value) else { return false }
        page = nil; self.error = value.localizedDescription
        await parent.communityRequestRejected(value)
        return true
    }
    private func message(_ error: Error) -> String { (error as? OpsError)?.localizedDescription ?? "暂时无法连接社区管理，请稍后重试。" }
}
