import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import KikiVoiceOps

final class IncidentOpsTests: XCTestCase {
    func testIncidentEndpointOnlyAllowsCentralPOSTAnd422HasItsOwnMeaning() async throws {
        let url = URL(string: "https://kiki.group/admin/v2/services/voice/incidents/query")!
        var request = URLRequest(url: url); request.httpMethod = "POST"
        XCTAssertTrue(OpsIdentityEndpoint.permits(request))
        request.httpMethod = "GET"; XCTAssertFalse(OpsIdentityEndpoint.permits(request))
        let transport = ScriptedTransport { request in
            XCTAssertEqual(request.url, url); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-ops-session")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["userQuery"] as? String, "穷奇0000")
            XCTAssertEqual(body["severity"] as? String, "error"); XCTAssertEqual(body["operation"] as? String, "join_room")
            XCTAssertNil(body["token"]); XCTAssertNil(body["opsActorID"])
            return (422, Data(#"{"detail":"do not expose raw server information"}"#.utf8))
        }
        let query = try OpsIncidentQuery(filter: OpsIncidentFilter(severity: .error, operation: .joinRoom, userQuery: " 穷奇0000 "))
        do { _ = try await OpsIdentityAPI(transport: transport).incidents(query, session: testSession()); XCTFail("must reject") }
        catch { XCTAssertEqual(error as? OpsError, .invalidIncidentQuery); XCTAssertFalse(error.localizedDescription.contains("raw server")) }
    }

    func testModelsAcceptExactContractAndKeepOldDashboardCompatible() throws {
        let dashboard = try JSONDecoder().decode(OpsDashboard.self, from: dashboardData("dashboard-fixture"))
        XCTAssertNil(dashboard.incidents); try dashboard.validateVoiceBoundary()
        let updated = try JSONDecoder().decode(OpsDashboard.self, from: incidentDashboardData())
        try updated.validateVoiceBoundary()
        XCTAssertEqual(updated.incidents?.errorsLast24Hours, 2)
        let page = try JSONDecoder().decode(OpsIncidentPage.self, from: incidentPageData())
        try page.validate()
        XCTAssertEqual(page.events.first?.platformTitle, "iPad / iPadOS")
        XCTAssertEqual(page.events.first?.stageTitle, "媒体连接")
    }

    func testModelsRejectUnsafeUnexpectedDiagnosticMetadataAndInvalidPagination() throws {
        for (key, value) in [
            ("requestID", "https://unsafe.invalid"), ("stage", "arbitrary text"), ("source", "untrusted"),
            ("platform", "web"), ("roomID", "https://unsafe.invalid"), ("code", "raw secret error"),
            ("httpStatus", 200), ("elapsedMs", -1), ("appVersion", "https://unsafe.invalid")
        ] as [(String, Any)] {
            var incident = incidentDictionary(); incident[key] = value
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"retentionDays":7,"events":[incident],"nextCursor":NSNull()])
            do { let page = try JSONDecoder().decode(OpsIncidentPage.self, from: data); try page.validate(); XCTFail("invalid \(key)") } catch { }
        }
        let repeated = try JSONDecoder().decode(OpsIncidentPage.self, from: incidentPageData(events: [incidentDictionary(), incidentDictionary()]))
        XCTAssertThrowsError(try repeated.validate())
        let wrongCursor = try JSONDecoder().decode(OpsIncidentPage.self, from: incidentPageData(next: secondIncidentID))
        XCTAssertThrowsError(try wrongCursor.validate())
        for filter in [OpsIncidentFilter(userQuery: "a\nsecret"), OpsIncidentFilter(userQuery: String(repeating: "名", count: 81))] {
            XCTAssertThrowsError(try OpsIncidentQuery(filter: filter))
        }
        XCTAssertThrowsError(try OpsIncidentQuery(cursor: "not-a-uuid"))
    }

    func testSafeMessageComesFromKnownClassificationRatherThanRawText() throws {
        var value = incidentDictionary(); value["message"] = "unexpected sensitive server text"
        let incident = try JSONDecoder().decode(OpsIncident.self, from: JSONSerialization.data(withJSONObject: value))
        try incident.validate()
        XCTAssertEqual(incident.safeMessage, "媒体连接建立超时")
        XCTAssertFalse(incident.safeMessage.contains("sensitive"))
    }

    @MainActor func testReadOnlyVoiceGrantQueriesWithoutCommunityAndFreshACLPrecedesRead() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        defer { store.setActive(false) }
        await store.loadIncidents()
        XCTAssertEqual(store.incidentPage?.events.count, 1)
        XCTAssertFalse(store.account!.permissions.community)
        let calls = await api.calls
        XCTAssertTrue(calls.suffix(3).elementsEqual(["me", "incidents", "me"]))
        await api.revoke()
        await store.loadIncidents()
        XCTAssertNil(store.incidentPage); XCTAssertFalse(store.canAccessSelectedService)
        let queries = await api.queries; XCTAssertEqual(queries.count, 1)
    }

    @MainActor func testCommunityGrantDoesNotPermitIncidentRead() async throws {
        let api = IncidentFixtureAPI(voice: false); let store = await prepared(api)
        defer { store.setActive(false) }
        XCTAssertTrue(store.account!.permissions.community); XCTAssertFalse(store.canAccessSelectedService)
        await store.loadIncidents()
        let queries = await api.queries; XCTAssertTrue(queries.isEmpty)
    }

    @MainActor func testGrantRevokedDuringSuccessfulReadDiscardsReturnedRecords() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        defer { store.setActive(false) }
        await api.revokeOnNextQuery()
        await store.loadIncidents()
        XCTAssertNil(store.incidentPage); XCTAssertFalse(store.canAccessSelectedService)
    }

    @MainActor func testLateDashboardCannotRestoreDataAfterIncidentIdentityRevokesVoice() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        defer { store.setActive(false) }
        XCTAssertNotNil(store.dashboard)
        await api.holdNextDashboard()
        let stale = Task { await store.refresh() }
        await waitForDashboard(api)
        // The query's final me sees revocation while an earlier authorized
        // dashboard is in flight and will still return a successful payload.
        await api.revokeOnNextQuery()
        await store.loadIncidents()
        XCTAssertFalse(store.canAccessSelectedService); XCTAssertNil(store.dashboard)
        await api.releaseDashboard(); await stale.value
        XCTAssertNil(store.dashboard); XCTAssertNil(store.incidentPage)
        XCTAssertFalse(store.canAccessSelectedService)
        XCTAssertFalse(store.isRefreshing); XCTAssertFalse(store.isRestoring)
    }

    @MainActor func testLateIdentityCannotRegrantPermissionAfterAnotherReadRevokesVoice() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        defer { store.setActive(false) }
        await api.holdNextIdentity()
        let stale = Task { await store.refresh() }
        for _ in 0..<200 { if await api.identityHeld { break }; try await Task.sleep(for: .milliseconds(10)) }
        let identityHeld = await api.isIdentityHeld(); XCTAssertTrue(identityHeld)
        await api.revoke(); await store.loadIncidents()
        XCTAssertFalse(store.canAccessSelectedService)
        await api.releaseIdentity(); await stale.value
        XCTAssertFalse(store.canAccessSelectedService); XCTAssertNil(store.dashboard)
        XCTAssertFalse(store.isRefreshing); XCTAssertFalse(store.isRestoring)
    }

    @MainActor func testPaginationAppendsDistinctEventsAndPreservesExactCursor() async throws {
        let api = IncidentFixtureAPI(); await api.usePagination()
        let store = await prepared(api); defer { store.setActive(false) }
        await store.loadIncidents()
        XCTAssertEqual(store.incidentPage?.nextCursor, firstIncidentID)
        await store.loadIncidents(loadMore: true)
        XCTAssertEqual(store.incidentPage?.events.map(\.eventID), [firstIncidentID, secondIncidentID])
        XCTAssertNil(store.incidentPage?.nextCursor)
        let queries = await api.queries
        XCTAssertNil(queries[0].cursor); XCTAssertEqual(queries[1].cursor, firstIncidentID)
    }

    @MainActor func testExpiredPaginationCursorClearsOldPageAndRefreshStartsAtBeginning() async throws {
        let api = IncidentFixtureAPI(); await api.usePagination(expired: true)
        let store = await prepared(api); defer { store.setActive(false) }
        await store.loadIncidents(); await store.loadIncidents(loadMore: true)
        XCTAssertNil(store.incidentPage); XCTAssertNotNil(store.incidentError)
        await store.loadIncidents()
        XCTAssertEqual(store.incidentPage?.events.count, 1)
        let queries = await api.queries; XCTAssertNil(queries.last?.cursor)
    }

    @MainActor func testChangedFiltersDiscardLateQueryEvenWhenTransportIgnoresCancellation() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        defer { store.setActive(false) }
        await api.holdNextQuery()
        let old = Task { await store.loadIncidents() }
        await waitForQuery(api)
        await store.loadIncidents(filter: OpsIncidentFilter(operation: .createRoom, userQuery: "穷奇"))
        await api.release(); await old.value
        XCTAssertEqual(store.incidentFilter.operation, .createRoom)
        XCTAssertEqual(store.incidentPage?.events.first?.operation, .createRoom)
    }

    @MainActor func testBackgroundLogoutAndServiceChangeCannotPublishLateQuery() async throws {
        for action in ["background", "logout", "service"] {
            let api = IncidentFixtureAPI(); let store = await prepared(api)
            await api.holdNextQuery()
            let query = Task { await store.loadIncidents() }; await waitForQuery(api)
            if action == "background" { store.setActive(false) }
            if action == "logout" { store.logout() }
            if action == "service" { store.selectService(.account) }
            await api.release(); await query.value
            XCTAssertNil(store.incidentPage, action); XCTAssertFalse(store.isLoadingIncidents)
            store.setActive(false)
        }
    }

    @MainActor func testSessionExpiryDuringReadEndsSessionBeforePublishing() async throws {
        let api = IncidentFixtureAPI()
        let session = OpsSession(token: "fixture-ops-session", expiresAt: Date().addingTimeInterval(0.4))
        let store = await prepared(api, session: session)
        await api.holdNextQuery()
        let query = Task { await store.loadIncidents() }; await waitForQuery(api)
        try await Task.sleep(for: .milliseconds(450))
        await api.release(); await query.value
        XCTAssertNil(store.incidentPage); XCTAssertFalse(store.authenticated); XCTAssertFalse(store.hasSavedSession)
        store.setActive(false)
    }

    @MainActor func testReadOnlyFixtureScreenshotsListDetailAndCorrelation() async throws {
        let api = IncidentFixtureAPI(); let store = await prepared(api)
        await store.loadIncidents()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; store.setActive(false) }
        let list = UIHostingController(rootView: NavigationStack { OpsIncidentsView(store: store) })
        window.rootViewController = list; window.makeKeyAndVisible()
        try await capture(window, name: "故障记录-只读筛选与摘要")
        let detail = UIHostingController(rootView: NavigationStack { OpsIncidentDetailView(store: store, eventID: firstIncidentID) })
        window.rootViewController = detail
        try await capture(window, name: "故障记录-详情与设备阶段")
        if let scroll = scrollView(in: detail.view) {
            scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height-scroll.bounds.height+scroll.adjustedContentInset.bottom)), animated: false)
        }
        try await capture(window, name: "故障记录-关联编号与安全分类")
    }

    @MainActor private func capture(_ window: UIWindow, name: String) async throws {
        window.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
    @MainActor private func prepared(_ api: IncidentFixtureAPI, session: OpsSession = testSession()) async -> OpsStore {
        let store = OpsStore(api: api, vault: MemoryVault(session: session), authorizer: FixturePasskeyAuthorizer())
        store.setActive(true)
        for _ in 0..<200 { if store.authenticated && !store.isRefreshing { return store }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Fixture account restore timed out"); return store
    }
    @MainActor private func waitForQuery(_ api: IncidentFixtureAPI) async {
        for _ in 0..<200 { if await api.queryHeld { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Fixture query did not suspend")
    }
    @MainActor private func waitForDashboard(_ api: IncidentFixtureAPI) async {
        for _ in 0..<200 { if await api.dashboardHeld { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Fixture dashboard did not suspend")
    }
}

private let firstIncidentID = "11111111-1111-4111-8111-111111111111"
private let secondIncidentID = "22222222-2222-4222-8222-222222222222"
private func incidentDictionary(id: String = firstIncidentID, operation: String = "join_room") -> [String: Any] {
    ["eventID":id,"attemptID":"33333333-3333-4333-8333-333333333333","operation":operation,
     "stage":"media_connect","severity":"error","code":"media_connect_timeout","message":"媒体连接建立超时",
     "occurredAt":Int(Date().timeIntervalSince1970)-120,"receivedAt":Int(Date().timeIntervalSince1970)-110,
     "elapsedMs":15000,"roomID":"lk_0123456789abcdef0123456789abcdef",
     "requestID":"44444444-4444-4444-8444-444444444444","httpStatus":504,
     "platform":"ipados","appVersion":"1.0(10)","osVersion":"26.0",
     "userID":"kiki_0123456789abcdef","userName":"示例用户0000","source":"client"]
}
private func incidentPageData(events: [[String: Any]]? = nil, next: String? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"retentionDays":7,
        "events":events ?? [incidentDictionary()],"nextCursor":next as Any? ?? NSNull()])
}
private func incidentDashboardData() throws -> Data {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: dashboardData("dashboard-fixture")) as? [String: Any])
    root["incidents"] = ["schemaVersion":1,"trackingSince":Int(Date().timeIntervalSince1970)-3600,"retentionDays":7,
        "totalEvents":3,"errorsLast24Hours":2,"warningsLast24Hours":1,"failedAttemptsLast24Hours":2,
        "events":[incidentDictionary()]] as [String: Any]
    return try JSONSerialization.data(withJSONObject: root)
}
private actor IncidentFixtureAPI: OpsAPI {
    var voice: Bool
    var calls = [String](), queries = [OpsIncidentQuery]()
    var holding = false, queryHeld = false, pagination = false, expiredCursor = false, revokeDuringQuery = false
    var continuation: CheckedContinuation<OpsIncidentPage, Error>?
    var heldPage: OpsIncidentPage?
    var dashboardHolding = false, dashboardHeld = false, identityHolding = false, identityHeld = false
    var dashboardContinuation: CheckedContinuation<OpsDashboard, Never>?
    var heldDashboard: OpsDashboard?
    var identityContinuation: CheckedContinuation<OpsAccount, Never>?
    var heldIdentity: OpsAccount?
    init(voice: Bool = true) { self.voice = voice }
    func revoke() { voice = false }
    func revokeOnNextQuery() { revokeDuringQuery = true }
    func holdNextQuery() { holding = true; queryHeld = false }
    func usePagination(expired: Bool = false) { pagination = true; expiredCursor = expired }
    func holdNextDashboard() { dashboardHolding = true; dashboardHeld = false }
    func releaseDashboard() { if let heldDashboard { dashboardContinuation?.resume(returning: heldDashboard) }; dashboardContinuation = nil; heldDashboard = nil; dashboardHeld = false }
    func holdNextIdentity() { identityHolding = true; identityHeld = false }
    func isIdentityHeld() -> Bool { identityHeld }
    func releaseIdentity() { if let heldIdentity { identityContinuation?.resume(returning: heldIdentity) }; identityContinuation = nil; heldIdentity = nil; identityHeld = false }
    func release() { if let heldPage { continuation?.resume(returning: heldPage) }; continuation = nil; heldPage = nil; queryHeld = false }
    func registrationOptions() async throws -> OpsRegistrationOptions { throw OpsError.authorizationUnavailable }
    func authenticationOptions() async throws -> OpsAuthenticationOptions { throw OpsError.authorizationUnavailable }
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.authorizationUnavailable }
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { throw OpsError.authorizationUnavailable }
    func me(session: OpsSession) async throws -> OpsAccount {
        calls.append("me")
        let identity = OpsAccount(id:"ops_incident_fixture",name:"示例查看员",needsName:false,
                          permissions:OpsPermissions(voice:voice,account:true,community:!voice))
        if identityHolding {
            identityHolding = false; identityHeld = true; heldIdentity = identity
            return await withCheckedContinuation { identityContinuation = $0 }
        }
        return identity
    }
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount { try await me(session: session) }
    func dashboard(session: OpsSession) async throws -> OpsDashboard {
        calls.append("dashboard")
        let dashboard = try JSONDecoder().decode(OpsDashboard.self, from: incidentDashboardData())
        if dashboardHolding {
            dashboardHolding = false; dashboardHeld = true; heldDashboard = dashboard
            return await withCheckedContinuation { dashboardContinuation = $0 }
        }
        return dashboard
    }
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard {
        try JSONDecoder().decode(AccountOpsDashboard.self, from: dashboardData("account-dashboard-fixture"))
    }
    func incidents(_ query: OpsIncidentQuery, session: OpsSession) async throws -> OpsIncidentPage {
        calls.append("incidents"); queries.append(query)
        if revokeDuringQuery { voice = false; revokeDuringQuery = false }
        if query.cursor != nil && expiredCursor { throw OpsError.invalidIncidentQuery }
        let operation = query.operation == .createRoom ? "create_room" : "join_room"
        let records = query.cursor == nil ? [incidentDictionary(operation: operation)] : [incidentDictionary(),incidentDictionary(id:secondIncidentID)]
        let page = try JSONDecoder().decode(OpsIncidentPage.self,
            from: incidentPageData(events:records,next:pagination && query.cursor == nil ? firstIncidentID : nil))
        if holding {
            holding = false; queryHeld = true; heldPage = page
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        return page
    }
    func logout(session: OpsSession) async throws { }
}
