import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import KikiVoiceOps

final class CommunityOpsTests: XCTestCase {
    func testCommunityGrantIsIndependentAndMissingGrantFailsClosed() throws {
        let old = try JSONDecoder().decode(OpsPermissions.self, from: Data(#"{"voice":true,"account":true}"#.utf8))
        XCTAssertFalse(old.community); XCTAssertFalse(old.permits(.community))
        let community = OpsPermissions(voice: false, account: false, community: true)
        XCTAssertTrue(community.permits(.community)); XCTAssertFalse(community.permits(.voice)); XCTAssertFalse(community.permits(.account))
    }

    func testModerationBodyValidationAndFixedCentralRoutes() async throws {
        let request = OpsModerationRequest(requestID: UUID().uuidString.lowercased(), reportID: "report_fixture",
                                            action: .banUser, durationSeconds: 86400, note: "核实连续骚扰，限制语聊一天")
        let transport = ScriptedTransport { outgoing in
            XCTAssertEqual(outgoing.url?.host, "kiki.group")
            XCTAssertEqual(outgoing.httpMethod, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(outgoing.httpBody)) as? [String: Any])
            XCTAssertNil(body["opsActorID"]); XCTAssertNil(body["targetUserID"])
            if outgoing.url!.path.hasSuffix("query") {
                XCTAssertEqual(body["status"] as? String, "pending")
                return (200, communityFixtureData())
            }
            XCTAssertEqual(body["requestID"] as? String, request.requestID)
            XCTAssertEqual(body["note"] as? String, request.note)
            return (200, try moderationResultData(request))
        }
        let api = OpsIdentityAPI(transport: transport)
        let page = try await api.moderation(session: testSession(), filter: .pending)
        XCTAssertEqual(page.reports.count, 1)
        _ = try await api.moderate(request, session: testSession())
        for invalid in [
            OpsModerationRequest(requestID: request.requestID, reportID: request.reportID, action: .banUser, durationSeconds: nil, note: "理由"),
            OpsModerationRequest(requestID: request.requestID, reportID: request.reportID, action: .warn, durationSeconds: 3600, note: "理由"),
            OpsModerationRequest(requestID: request.requestID, reportID: request.reportID, action: .dismiss, durationSeconds: nil, note: " "),
            OpsModerationRequest(requestID: "invalid", reportID: request.reportID, action: .warn, durationSeconds: nil, note: "理由")
        ] { XCTAssertThrowsError(try invalid.validate()) }
        let paths = await transport.paths
        XCTAssertEqual(paths, ["/admin/v2/services/voice/moderation/query", "/admin/v2/services/voice/moderation/action"])
    }

    @MainActor func testReadOnlyViewerCannotFetchCommunityOrMutate() async throws {
        let api = CommunityFixtureAPI(allowed: false)
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.selectService(.community); store.setActive(true)
        await waitFor { store.authenticated && !store.isRefreshing }
        XCTAssertFalse(store.canAccessSelectedService); XCTAssertNil(store.moderationPage)
        let fetched = await api.queryCalls; XCTAssertEqual(fetched, 0)
        let result = await store.moderate(fixtureRequest())
        XCTAssertFalse(result)
        let actions = await api.actionCalls; XCTAssertEqual(actions, 0)
        store.setActive(false)
    }

    @MainActor func testCommunityOnlyGrantLoadsWithoutVoiceGrantAndMutationRechecksACL() async throws {
        let api = CommunityFixtureAPI(allowed: true)
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.selectService(.community); store.setActive(true)
        await waitFor { store.moderationPage != nil && !store.isRefreshing }
        XCTAssertTrue(store.canAccessSelectedService); XCTAssertFalse(store.account!.permissions.voice)
        await api.revoke()
        let result = await store.moderate(fixtureRequest())
        XCTAssertFalse(result)
        let actions = await api.actionCalls; XCTAssertEqual(actions, 0)
        XCTAssertNil(store.moderationPage); XCTAssertFalse(store.canAccessSelectedService)
        store.setActive(false)
    }

    @MainActor func testCommunityScreenshotsAndSuccessfulIdempotentRequest() async throws {
        let api = CommunityFixtureAPI(allowed: true)
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.selectService(.community); store.setActive(true)
        await waitFor { store.moderationPage != nil && !store.isRefreshing }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: OpsRootView(store: store))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; store.setActive(false) }
        await waitFor { host.view.window != nil && host.view.bounds.height > 100 }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image); attachment.name = "P0-社区举报处理"; attachment.lifetime = .keepAlways; add(attachment)
        let report = try XCTUnwrap(store.moderationPage?.reports.first)
        let detail = UIHostingController(rootView: NavigationStack { OpsReportDetail(store: store, report: report) })
        window.rootViewController = detail
        detail.view.setNeedsLayout(); detail.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let detailImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let detailAttachment = XCTAttachment(image: detailImage); detailAttachment.name = "P0-社区处置确认表单"; detailAttachment.lifetime = .keepAlways; add(detailAttachment)
        let succeeded = await store.moderate(fixtureRequest())
        XCTAssertTrue(succeeded)
        let actions = await api.actionCalls; XCTAssertEqual(actions, 1)
        XCTAssertNotNil(store.moderationNotice)
    }

    @MainActor func testUnknownOutcomeSurvivesClosedStoreAndRetriesExactOriginalRequest() async throws {
        let api = CommunityFixtureAPI(allowed: true)
        await api.failNextActionAfterCommit()
        let vault = MemoryVault(session: testSession())
        let first = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
        first.selectService(.community); first.setActive(true)
        await waitFor { first.moderationPage != nil && !first.isRefreshing }
        let original = fixtureRequest()
        let firstResult = await first.moderate(original)
        XCTAssertFalse(firstResult); XCTAssertEqual(first.pendingModeration?.request, original)
        first.setActive(false)
        let restored = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
        restored.selectService(.community); restored.setActive(true)
        await waitFor { restored.pendingModeration != nil && !restored.isRefreshing }
        let changed = OpsModerationRequest(requestID: UUID().uuidString.lowercased(), reportID: original.reportID,
                                           action: original.action, durationSeconds: nil, note: original.note)
        let rejected = await restored.moderate(changed)
        XCTAssertFalse(rejected)
        let resumed = await restored.retryPendingModeration()
        XCTAssertTrue(resumed)
        let requests = await api.requests, committed = await api.committedRequestIDs
        XCTAssertEqual(requests, [original, original]); XCTAssertEqual(committed.count, 1)
        XCTAssertNil(restored.pendingModeration); XCTAssertTrue(vault.pendingActions.isEmpty)
        restored.setActive(false)
    }

    @MainActor func testMutationInvalidatesLateQueryWhenCommunityGrantWasRevoked() async throws {
        let api = CommunityFixtureAPI(allowed: true)
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.selectService(.community); store.setActive(true)
        await waitFor { store.moderationPage != nil && !store.isRefreshing }
        await api.deferNextQuery()
        let refresh = Task { await store.refresh() }
        for _ in 0..<200 { if await api.queryStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
        await api.revoke()
        let result = await store.moderate(fixtureRequest())
        XCTAssertFalse(result)
        await api.releaseQuery(); await refresh.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(store.moderationPage); XCTAssertFalse(store.canAccessSelectedService)
        store.setActive(false)
    }

    func testPendingActionIsBoundToVerifiedOperatorInKeychain() throws {
        let namespace = ".p0.fixture." + UUID().uuidString
        let vault = KeychainSessionVault(namespace: namespace)
        let pending = OpsPendingModeration(accountID: "ops_fixture_community", request: fixtureRequest(), createdAt: Date())
        defer { try? vault.removePendingModeration(accountID: pending.accountID); try? vault.remove() }
        try vault.savePendingModeration(pending)
        let restored = KeychainSessionVault(namespace: namespace)
        XCTAssertEqual(try restored.loadPendingModeration(accountID: pending.accountID), pending)
        XCTAssertNil(try restored.loadPendingModeration(accountID: "ops_other"))
        try vault.remove()
        XCTAssertEqual(try restored.loadPendingModeration(accountID: pending.accountID)?.request.requestID, pending.request.requestID)
    }

    @MainActor func testFreshIdentityCannotIntroducePendingThenSendDifferentUnsavedRequest() async throws {
        let api = CommunityFixtureAPI(allowed: true)
        let vault = MemoryVault(session: testSession())
        let store = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
        store.selectService(.community); store.setActive(true)
        await waitFor { store.moderationPage != nil && !store.isRefreshing }
        let pending = OpsPendingModeration(accountID: "ops_fixture_community", request: fixtureRequest(), createdAt: Date())
        try vault.savePendingModeration(pending)
        let new = OpsModerationRequest(requestID: UUID().uuidString.lowercased(), reportID: pending.request.reportID,
                                        action: .warn, durationSeconds: nil, note: "另一项操作")
        let result = await store.moderate(new)
        XCTAssertFalse(result)
        let requests = await api.requests; XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(store.pendingModeration, pending)
        store.setActive(false)
    }

    @MainActor func testDefiniteRejectionClearsPendingSoOperatorIsNotLockedOut() async throws {
        for rejected in [OpsError.invalidModeration, .moderationConflict, .server(status: 404)] {
            let api = CommunityFixtureAPI(allowed: true); await api.rejectNextAction(rejected)
            let vault = MemoryVault(session: testSession())
            let store = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
            store.selectService(.community); store.setActive(true)
            await waitFor { store.moderationPage != nil && !store.isRefreshing }
            let result = await store.moderate(fixtureRequest())
            XCTAssertFalse(result); XCTAssertNil(store.pendingModeration); XCTAssertTrue(vault.pendingActions.isEmpty)
            store.setActive(false)
        }
    }

    @MainActor private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("expected community fixture state did not arrive")
    }
}

private func communityFixtureData() -> Data {
    Data(#"{"schemaVersion":1,"retentionDays":30,"reports":[{"id":"report_fixture","status":"pending","targetType":"message","roomID":"100001","roomTitle":"晚间中文闲聊","reporterID":"user_fixture_reporter","reporterName":"示例用户","targetUserID":"user_fixture_target","targetName":"示例成员","messageID":"message_fixture","reason":"harassment","details":"该成员在房间内连续发送骚扰消息，请核实。","messageExcerpt":"这是一条用于界面验证的示例消息。","createdAt":1792383600,"resolvedAt":null,"lastAction":null,"evidenceExpiresAt":1794975600}]}"#.utf8)
}
private func fixtureRequest() -> OpsModerationRequest {
    OpsModerationRequest(requestID: "de43e728-e339-49ad-92d7-7dba22534745", reportID: "report_fixture", action: .warn, durationSeconds: nil, note: "请遵守房间规则，停止骚扰其他成员。")
}
private func moderationResultData(_ request: OpsModerationRequest) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["ok":true,"requestID":request.requestID,"reportID":request.reportID,
        "action":request.action.rawValue,"status":"resolved","mediaCleanupPending":false])
}
private actor CommunityFixtureAPI: OpsAPI {
    var allowed: Bool
    var queryCalls = 0, actionCalls = 0
    var requests = [OpsModerationRequest]()
    var committedRequestIDs = Set<String>()
    var failAction = false
    var rejection: OpsError?
    var deferredQuery = false, queryStarted = false
    var queryContinuation: CheckedContinuation<Void, Never>?
    init(allowed: Bool) { self.allowed = allowed }
    func revoke() { allowed = false }
    func failNextActionAfterCommit() { failAction = true }
    func rejectNextAction(_ error: OpsError) { rejection = error }
    func deferNextQuery() { deferredQuery = true }
    func releaseQuery() { deferredQuery = false; queryContinuation?.resume(); queryContinuation = nil }
    func registrationOptions() async throws -> OpsRegistrationOptions { try JSONDecoder().decode(OpsRegistrationOptions.self, from: JSONSerialization.data(withJSONObject: registrationDictionary())) }
    func authenticationOptions() async throws -> OpsAuthenticationOptions { throw OpsError.authorizationUnavailable }
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.authorizationUnavailable }
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.authorizationUnavailable }
    func me(session: OpsSession) async throws -> OpsAccount {
        OpsAccount(id: "ops_fixture_community", name: "示例管理员", needsName: false,
                   permissions: OpsPermissions(voice: false, account: false, community: allowed))
    }
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount { try await me(session: session) }
    func dashboard(session: OpsSession) async throws -> OpsDashboard { throw OpsError.forbidden }
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard { throw OpsError.forbidden }
    func moderation(session: OpsSession, filter: OpsReportFilter) async throws -> OpsModerationPage {
        guard allowed else { throw OpsError.forbidden }; queryCalls += 1
        if deferredQuery { queryStarted = true; await withCheckedContinuation { queryContinuation = $0 } }
        return try JSONDecoder().decode(OpsModerationPage.self, from: communityFixtureData())
    }
    func moderate(_ request: OpsModerationRequest, session: OpsSession) async throws -> OpsModerationResult {
        guard allowed else { throw OpsError.forbidden }; actionCalls += 1
        if let error = rejection { rejection = nil; throw error }
        requests.append(request); committedRequestIDs.insert(request.requestID)
        if failAction { failAction = false; throw OpsError.server(status: 503) }
        return try JSONDecoder().decode(OpsModerationResult.self, from: moderationResultData(request))
    }
    func logout(session: OpsSession) async throws { }
}
