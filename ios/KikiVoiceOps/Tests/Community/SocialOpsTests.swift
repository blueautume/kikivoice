import Foundation
import Security
import SwiftUI
import XCTest
@testable import KikiVoiceOps

final class SocialOpsTests: XCTestCase {
    func testSocialEvidenceEndpointsStayOnAccountAndRequireExactMethodAndUUID() {
        let id = "11111111-2222-4333-8444-555555555555"
        let api = OpsIdentityAPI()
        XCTAssertNoThrow(try api.request(path: "/admin/v2/services/account/social/media/\(id).jpg", method: "GET", session: testSession()))
        for path in ["https://furby.top/admin/v2/services/account/social/media/\(id).jpg",
                     "/admin/v2/services/account/social/media/\(id).jpg?token=x",
                     "/admin/v2/services/account/social/media/%2e%2e.jpg",
                     "/admin/v2/services/account/social/media/not-a-uuid.jpg"] {
            XCTAssertThrowsError(try api.request(path: path, method: "GET", session: testSession()))
        }
        XCTAssertThrowsError(try api.request(path: "/admin/v2/services/account/social/media/\(id).jpg", method: "POST", session: testSession()))
    }
    func testSocialQueryUsesCommunityRouteAndAction422IsNotNameError() async throws {
        let transport = ScriptedTransport { req in
            XCTAssertEqual(req.url?.host, "kiki.group")
            XCTAssertEqual(req.httpMethod, "POST")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-ops-session")
            if req.url!.path.hasSuffix("/query") {
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
                XCTAssertEqual(object["status"] as? String, "pending"); XCTAssertEqual(object["limit"] as? Int, 50)
                return (200, socialOpsFixture())
            }
            return (422, Data(#"{"detail":"private text"}"#.utf8))
        }
        let api = OpsIdentityAPI(transport: transport)
        let result = try await api.socialModeration(session: testSession(), filter: .pending, cursor: nil)
        XCTAssertEqual(result.reports.first?.targetType, "moment")
        do { _ = try await api.socialModerate(socialAction(), session: testSession()); XCTFail("invalid action must fail") }
        catch { XCTAssertEqual(error as? OpsError, .invalidModeration) }
    }
    func testRestrictionDurationAndEvidenceSchemaAreBounded() throws {
        for seconds in [nil, 59, 2_592_001] as [Int?] {
            XCTAssertThrowsError(try OpsSocialActionRequest(requestID: UUID().uuidString, reportID: "report", action: .restrictPosting, durationSeconds: seconds, note: "核实骚扰行为").validate())
        }
        XCTAssertThrowsError(try OpsSocialActionRequest(requestID: UUID().uuidString, reportID: "report", action: .warn, durationSeconds: 60, note: "警告").validate())
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: socialOpsFixture()) as? [String: Any])
        value["retentionDays"] = 365
        let page = try JSONDecoder().decode(OpsSocialModerationPage.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try page.validate())
    }
    @MainActor func testCommunityPermissionWorksWithoutEitherDashboardButReadOnlyGrantsDoNot() async throws {
        for allowed in [false, true] {
            let api = SocialOpsFixtureAPI(allowed: allowed)
            let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
            parent.selectService(.community); parent.setActive(true)
            await waitFor { parent.authenticated && !parent.isRefreshing }
            let store = OpsSocialModerationStore(parent: parent, api: api, vault: SocialMemoryVault())
            await store.load()
            XCTAssertEqual(store.page != nil, allowed)
            let count = await api.queries; XCTAssertEqual(count, allowed ? 1 : 0)
            XCTAssertFalse(parent.account!.permissions.voice)
            parent.setActive(false)
        }
    }
    @MainActor func testLateReportPageCannotRestoreRevokedCommunityData() async throws {
        let api = SocialOpsFixtureAPI(allowed: true)
        let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        parent.selectService(.community); parent.setActive(true)
        await waitFor { parent.authenticated && !parent.isRefreshing }
        let store = OpsSocialModerationStore(parent: parent, api: api, vault: SocialMemoryVault())
        await api.deferQuery()
        let task = Task { await store.load() }
        await waitForAsync { await api.queryStarted }
        await api.revoke(); await api.releaseQuery(); await task.value
        XCTAssertNil(store.page); XCTAssertFalse(parent.canAccessSelectedService)
        parent.setActive(false)
    }
    @MainActor func testUnknownOutcomeSurvivesStoreRestartAndRetriesOriginalActionExactly() async throws {
        let api = SocialOpsFixtureAPI(allowed: true)
        let vault = SocialMemoryVault()
        let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        parent.selectService(.community); parent.setActive(true)
        await waitFor { parent.authenticated && !parent.isRefreshing }
        let first = OpsSocialModerationStore(parent: parent, api: api, vault: vault)
        await api.failAfterCommit()
        let request = socialAction()
        let failed = await first.act(request); XCTAssertFalse(failed)
        XCTAssertEqual(first.pending?.request, request)
        first.invalidate()
        let restored = OpsSocialModerationStore(parent: parent, api: api, vault: vault)
        await restored.load()
        XCTAssertEqual(restored.pending?.request, request)
        let changed = OpsSocialActionRequest(requestID: UUID().uuidString, reportID: request.reportID, action: .warn, durationSeconds: nil, note: "另一操作")
        let refused = await restored.act(changed); XCTAssertFalse(refused)
        let succeeded = await restored.retryPending(); XCTAssertTrue(succeeded)
        let requests = await api.requests; XCTAssertEqual(requests, [request, request])
        let commits = await api.commits; XCTAssertEqual(commits.count, 1)
        XCTAssertNil(restored.pending); XCTAssertTrue(vault.values.isEmpty)
        parent.setActive(false)
    }
    @MainActor func testActionRejectionAfterFreshIdentityClearsEvidenceButPreservesUnconfirmedReceipt() async throws {
        for rejection in [OpsError.unauthenticated, .forbidden] {
            let api = SocialOpsFixtureAPI(allowed: true)
            let vault = SocialMemoryVault()
            let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
            parent.selectService(.community); parent.setActive(true)
            await waitFor { parent.authenticated && !parent.isRefreshing }
            let store = OpsSocialModerationStore(parent: parent, api: api, vault: vault)
            await store.load(); await store.loadImage("44444444-5555-4666-8777-888888888888")
            XCTAssertNotNil(store.page); XCTAssertEqual(store.images.count, 1)
            await api.rejectNextAction(rejection)
            let request = socialAction()
            let accepted = await store.act(request)
            XCTAssertFalse(accepted); XCTAssertNil(store.page); XCTAssertTrue(store.images.isEmpty)
            XCTAssertEqual(vault.values["ops_fixture_social"]?.request, request)
            let requests = await api.requests; XCTAssertEqual(requests, [request])
            let commits = await api.commits; XCTAssertEqual(commits, [request.requestID])
            if rejection == .unauthenticated { XCTAssertFalse(parent.authenticated) }
            else { XCTAssertFalse(parent.canAccessSelectedService) }
            store.invalidate(); XCTAssertEqual(vault.values["ops_fixture_social"]?.request, request)
            parent.setActive(false)
        }
    }
    @MainActor func testImageRejectionClearsExistingEvidenceAndKeepsEarlierUnknownAction() async throws {
        for rejection in [OpsError.unauthenticated, .forbidden] {
            let api = SocialOpsFixtureAPI(allowed: true)
            let vault = SocialMemoryVault()
            let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
            parent.selectService(.community); parent.setActive(true)
            await waitFor { parent.authenticated && !parent.isRefreshing }
            let store = OpsSocialModerationStore(parent: parent, api: api, vault: vault)
            await store.load(); await store.loadImage("44444444-5555-4666-8777-888888888888")
            await api.failAfterCommit()
            let request = socialAction()
            let accepted = await store.act(request); XCTAssertFalse(accepted)
            XCTAssertNotNil(store.page); XCTAssertEqual(store.images.count, 1)
            await api.rejectNextImage(rejection)
            await store.loadImage("55555555-6666-4777-8888-999999999999")
            XCTAssertNil(store.page); XCTAssertTrue(store.images.isEmpty)
            XCTAssertEqual(vault.values["ops_fixture_social"]?.request, request)
            if rejection == .unauthenticated { XCTAssertFalse(parent.authenticated) }
            else { XCTAssertFalse(parent.canAccessSelectedService) }
            parent.setActive(false)
        }
    }
    func testSocialPaginationAcceptsBackendOpaqueCursorBeyondTwoHundredFiftySixBytes() async throws {
        let cursor = String(repeating: "A", count: 400)
        let transport = ScriptedTransport { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["cursor"] as? String, cursor)
            var page = try XCTUnwrap(JSONSerialization.jsonObject(with: socialOpsFixture()) as? [String: Any])
            page["nextCursor"] = cursor
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        let page = try await OpsIdentityAPI(transport: transport).socialModeration(session: testSession(), filter: .pending, cursor: cursor)
        XCTAssertEqual(page.nextCursor, cursor)
    }
    func testCanonicalUUIDActionReceiptAcceptsServerLowercase() throws {
        let request = OpsSocialActionRequest(requestID: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", reportID: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF", action: .warn, durationSeconds: nil, note: "请文明交流")
        let result = OpsSocialActionResult(ok: true, requestID: request.requestID.lowercased(), reportID: request.reportID.lowercased(), action: request.action.rawValue)
        XCTAssertNoThrow(try result.validate(request))
    }
    func testSocialPendingKeychainIsIsolatedFromVoiceActionAndOtherOperator() throws {
        let vault = KeychainSessionVault(namespace: ".p1." + UUID().uuidString)
        let pending = OpsSocialPendingAction(accountID: "ops_fixture_social", request: socialAction(), createdAt: Date())
        defer { try? vault.removeSocialPending(accountID: pending.accountID); try? vault.remove() }
        try vault.saveSocialPending(pending)
        XCTAssertEqual(try vault.loadSocialPending(accountID: pending.accountID), pending)
        XCTAssertNil(try vault.loadSocialPending(accountID: "ops_other_account"))
        XCTAssertNil(try vault.loadPendingModeration(accountID: pending.accountID))
        try vault.remove()
        XCTAssertEqual(try vault.loadSocialPending(accountID: pending.accountID), pending)
    }
    @MainActor func testSocialReportScreenshotsUseOnlyVisibleFixtureWindow() async throws {
        let api = SocialOpsFixtureAPI(allowed: true)
        let parent = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        parent.selectService(.community); parent.setActive(true)
        await waitFor { parent.authenticated && !parent.isRefreshing }
        let store = OpsSocialModerationStore(parent: parent, api: api, vault: SocialMemoryVault())
        await store.load()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene); window.makeKeyAndVisible()
        defer { window.isHidden = true; parent.setActive(false) }
        let report = try XCTUnwrap(store.page?.reports.first)
        for (name, view) in [
            ("P1-社交举报列表", AnyView(NavigationStack { OpsSocialModerationView(parent: parent, store: store) })),
            ("P1-社交举报处置", AnyView(NavigationStack { OpsSocialReportDetail(parent: parent, store: store, report: report) }))
        ] {
            window.rootViewController = UIHostingController(rootView: view)
            window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(350))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }; XCTFail("fixture did not settle")
    }
    @MainActor private func waitForAsync(_ predicate: () async -> Bool) async {
        for _ in 0..<200 { if await predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }; XCTFail("fixture did not settle")
    }
}

private func socialAction() -> OpsSocialActionRequest {
    OpsSocialActionRequest(requestID: "11111111-2222-4333-8444-555555555555", reportID: "22222222-3333-4444-8555-666666666666", action: .warn, durationSeconds: nil, note: "请停止骚扰，遵守社区交流规则。")
}
private func socialOpsFixture() -> Data {
    Data(#"{"schemaVersion":1,"retentionDays":30,"nextCursor":null,"activeRestrictions":[],"reports":[{"id":"22222222-3333-4444-8555-666666666666","reporterID":"kiki_fixture_reporter","reporterName":"示例用户","targetUserID":"kiki_fixture_target00","targetName":"示例成员","targetType":"moment","contentID":"33333333-4444-4555-8666-777777777777","reason":"harassment","details":"这条动态对其他成员进行了人身攻击，请核查。","evidence":{"text":"用于截图验收的模拟动态正文，不是真实用户内容。","media":[]},"status":"pending","createdAt":1792411800,"resolvedAt":null,"lastAction":null}]}"#.utf8)
}
private final class SocialMemoryVault: OpsSocialPendingVault {
    var values: [String: OpsSocialPendingAction] = [:]
    func loadSocialPending(accountID: String) throws -> OpsSocialPendingAction? { values[accountID] }
    func saveSocialPending(_ value: OpsSocialPendingAction) throws { values[value.accountID] = value }
    func removeSocialPending(accountID: String) throws { values.removeValue(forKey: accountID) }
}
private actor SocialOpsFixtureAPI: OpsAPI {
    var allowed: Bool
    var queries = 0
    var requests = [OpsSocialActionRequest]()
    var commits = Set<String>()
    var queryStarted = false
    private var holdQuery = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var throwAfterCommit = false
    private var actionRejection: OpsError?
    private var imageRejection: OpsError?
    init(allowed: Bool) { self.allowed = allowed }
    func revoke() { allowed = false }
    func deferQuery() { holdQuery = true }
    func releaseQuery() { continuation?.resume(); continuation = nil }
    func failAfterCommit() { throwAfterCommit = true }
    func rejectNextAction(_ value: OpsError) { actionRejection = value }
    func rejectNextImage(_ value: OpsError) { imageRejection = value }
    func registrationOptions() async throws -> OpsRegistrationOptions { try KikiVoiceOpsTestsRegistration() }
    func authenticationOptions() async throws -> OpsAuthenticationOptions { try KikiVoiceOpsTestsAuthentication() }
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.forbidden }
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.forbidden }
    func me(session: OpsSession) async throws -> OpsAccount { OpsAccount(id: "ops_fixture_social", name: "社区管理员", needsName: false, permissions: OpsPermissions(voice: false, account: true, community: allowed)) }
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount { try await me(session: session) }
    func dashboard(session: OpsSession) async throws -> OpsDashboard { throw OpsError.forbidden }
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard { throw OpsError.forbidden }
    func moderation(session: OpsSession, filter: OpsReportFilter) async throws -> OpsModerationPage {
        guard allowed else { throw OpsError.forbidden }
        return try JSONDecoder().decode(OpsModerationPage.self, from: Data(#"{"schemaVersion":1,"retentionDays":30,"reports":[]}"#.utf8))
    }
    func socialModeration(session: OpsSession, filter: OpsReportFilter, cursor: String?) async throws -> OpsSocialModerationPage {
        queries += 1
        guard allowed else { throw OpsError.forbidden }
        if holdQuery { holdQuery = false; queryStarted = true; await withCheckedContinuation { continuation = $0 } }
        return try JSONDecoder().decode(OpsSocialModerationPage.self, from: socialOpsFixture())
    }
    func socialModerate(_ request: OpsSocialActionRequest, session: OpsSession) async throws -> OpsSocialActionResult {
        guard allowed else { throw OpsError.forbidden }
        requests.append(request); commits.insert(request.requestID)
        if let failure = actionRejection { actionRejection = nil; allowed = false; throw failure }
        if throwAfterCommit { throwAfterCommit = false; throw OpsError.server(status: 503) }
        return OpsSocialActionResult(ok: true, requestID: request.requestID, reportID: request.reportID, action: request.action.rawValue)
    }
    func socialEvidenceImage(id: String, session: OpsSession) async throws -> Data {
        guard allowed else { throw OpsError.forbidden }
        if let failure = imageRejection { imageRejection = nil; allowed = false; throw failure }
        return Data([0xff, 0xd8, 0xff, 0xd9])
    }
    func logout(session: OpsSession) async throws { }
}
private func KikiVoiceOpsTestsRegistration() throws -> OpsRegistrationOptions { try registrationOptions() }
private func KikiVoiceOpsTestsAuthentication() throws -> OpsAuthenticationOptions { try authenticationOptions() }
