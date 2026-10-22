import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import KikiVoiceOps

final class AccountPushOpsTests: XCTestCase {
    func testOlderAccountDashboardWithoutPushSummaryStillDecodes() throws {
        let value = try JSONDecoder().decode(AccountOpsDashboard.self, from: dashboardData("account-dashboard-fixture"))
        try value.validateAccountBoundary()
        XCTAssertNil(value.push)
    }
    func testPushAggregateDecodesWithoutDeviceOrAccountDetails() throws {
        let data = try pushDashboard()
        let value = try JSONDecoder().decode(AccountOpsDashboard.self, from: data)
        try value.validateAccountBoundary()
        let push = try XCTUnwrap(value.push)
        XCTAssertEqual(push.activeDevices, 3)
        XCTAssertEqual(push.pending, 2)
        XCTAssertEqual(push.accepted, 12)
        XCTAssertEqual(push.failed, 1)
        XCTAssertTrue(push.configured && push.enabled)
    }
    func testPushAggregateRejectsInvalidCountersAndUnboundedFailureData() throws {
        let failure: [String: Any] = ["code":"transport_error","occurredAt":1792411800]
        for override: [String: Any] in [
            ["schemaVersion":2], ["activeDevices":-1], ["pending":-1], ["accepted":-1], ["failed":-1],
            ["recentFailures":Array(repeating:failure,count:11)],
            ["recentFailures":[["code":"https://private.invalid/token","occurredAt":1792411800]]],
            ["recentFailures":[["code":"transport_error","occurredAt":0]]]
        ] {
            let value = try JSONDecoder().decode(AccountOpsDashboard.self, from: pushDashboard(override))
            XCTAssertThrowsError(try value.validateAccountBoundary())
        }
    }
    func testUnknownSafeFailureCodeUsesGenericLocalMessage() throws {
        let value = try JSONDecoder().decode(AccountOpsDashboard.self, from: pushDashboard([
            "recentFailures":[["code":"future_provider_code","occurredAt":1792411800]]
        ]))
        try value.validateAccountBoundary()
        let failure = try XCTUnwrap(value.push?.recentFailures.first)
        XCTAssertEqual(failure.message,"通知请求失败")
        XCTAssertFalse(failure.message.contains(failure.code))
    }
    @MainActor func testAccountPushStatusVisibleFixtureScreenshot() async throws {
        let value = try JSONDecoder().decode(AccountOpsDashboard.self, from: pushDashboard())
        let summary = try XCTUnwrap(value.push)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = UIWindow(windowScene:scene)
        window.rootViewController = UIHostingController(rootView:NavigationStack {
            ScrollView { OpsPushStatusCard(summary:summary).padding(16) }
                .background(Color(.systemGroupedBackground)).navigationTitle("账号运维")
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded(); try await Task.sleep(for:.milliseconds(350))
        let screenshot = UIGraphicsImageRenderer(bounds:window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in:window.bounds,afterScreenUpdates:true))
        }
        let attachment = XCTAttachment(image:screenshot)
        attachment.name = "APNs-账号运维状态"; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func pushDashboard(_ changes: [String: Any] = [:]) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:dashboardData("account-dashboard-fixture")) as? [String: Any])
        var push: [String: Any] = ["schemaVersion":1,"configured":true,"enabled":true,
                                  "activeDevices":3,"pending":2,"accepted":12,"failed":1,
                                  "recentFailures":[["code":"transport_error","occurredAt":1792411800]]]
        changes.forEach { push[$0.key] = $0.value }
        object["push"] = push
        return try JSONSerialization.data(withJSONObject:object)
    }
}

final class AccountOpsTests: XCTestCase {
    @MainActor func testRestoredSessionWaitsForMeBeforeAccessAndKeepsIndependentACL() async throws {
        let api = FixtureAPI(account: testAccount(voice: false, account: true))
        let vault = MemoryVault(session: testSession())
        let store = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
        XCTAssertFalse(store.authenticated)
        XCTAssertTrue(store.isRestoring)
        store.setActive(true)
        await waitFor { store.authenticated && !store.isRefreshing }
        XCTAssertFalse(store.canAccessSelectedService); XCTAssertNil(store.dashboard)
        let deniedVoiceCalls = await api.voiceCalls; XCTAssertEqual(deniedVoiceCalls, 0)
        store.selectService(.account)
        await waitFor { store.accountDashboard != nil }
        XCTAssertTrue(store.canAccessSelectedService)
        let events = await api.events
        XCTAssertEqual(events.first, "me"); XCTAssertTrue(events.suffix(2).elementsEqual(["me", "account"]))
        XCTAssertEqual(vault.purgeCount, 1)
        store.setActive(false)
    }
    @MainActor func testRegistrationNeverGrantsAccessAndRequiresFirstName() async throws {
        let api = FixtureAPI(account: testAccount(name: nil, voice: false, account: false))
        let authorizer = FixturePasskeyAuthorizer()
        let store = OpsStore(api: api, vault: MemoryVault(), authorizer: authorizer)
        store.setActive(true)
        await store.login(create: true)
        await waitFor { store.authenticated && !store.isRefreshing }
        XCTAssertTrue(store.needsName)
        XCTAssertFalse(store.canAccessSelectedService)
        await store.saveName("  同名管理员  ")
        await waitFor { !store.needsName && !store.isRefreshing }
        XCTAssertEqual(store.account?.name, "同名管理员")
        XCTAssertFalse(store.canAccessSelectedService)
        XCTAssertEqual(store.account?.id, "ops_fixture_account")
        let voiceCalls = await api.voiceCalls, accountCalls = await api.accountCalls; XCTAssertEqual(voiceCalls + accountCalls, 0)
        XCTAssertEqual(authorizer.registrationCount, 1)
        store.logout()
    }
    @MainActor func testInactiveSystemSheetDoesNotCancelPasskeyAndBackgroundDoes() async throws {
        let authorizer = FixturePasskeyAuthorizer(); authorizer.deferred = true
        let store = OpsStore(api: FixtureAPI(), vault: MemoryVault(), authorizer: authorizer)
        store.setActive(true)
        let login = Task { await store.login(create: false) }
        await waitFor { authorizer.continuation != nil }
        store.setActive(false, cancelAuthorization: false)
        XCTAssertEqual(authorizer.cancelCount, 0)
        authorizer.release()
        await login.value
        XCTAssertTrue(store.authenticated)
        XCTAssertNil(store.dashboard)
        store.logout()
        let secondAuthorizer = FixturePasskeyAuthorizer(); secondAuthorizer.deferred = true
        let second = OpsStore(api: FixtureAPI(), vault: MemoryVault(), authorizer: secondAuthorizer)
        second.setActive(true)
        let pending = Task { await second.login(create: false) }
        await waitFor { secondAuthorizer.continuation != nil }
        second.setActive(false, cancelAuthorization: true)
        await pending.value
        XCTAssertFalse(second.authenticated)
        XCTAssertEqual(secondAuthorizer.cancelCount, 1)
    }
    @MainActor func testNoLoginOrBackgroundNeverFetchesDashboard() async throws {
        let api = FixtureAPI()
        let store = OpsStore(api: api, vault: MemoryVault(), authorizer: FixturePasskeyAuthorizer())
        store.setActive(true); await store.refresh(); store.setActive(false)
        await store.login(create: false); await store.refresh()
        let meCalls = await api.meCalls, voiceCalls = await api.voiceCalls
        XCTAssertEqual(meCalls, 0); XCTAssertEqual(voiceCalls, 0); XCTAssertFalse(store.authenticated)
    }
    @MainActor func test401ClosesUnifiedSessionAndBothSnapshots() async throws {
        let api = FixtureAPI(); await api.setMeError(.unauthenticated)
        let vault = MemoryVault(session: testSession())
        let store = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
        store.setActive(true)
        await waitFor { !store.hasSavedSession }
        XCTAssertFalse(store.authenticated); XCTAssertNil(vault.session)
        XCTAssertNil(store.dashboard); XCTAssertNil(store.accountDashboard); XCTAssertNil(store.account)
    }
    @MainActor func test403KeepsLoginRefreshesACLAndDoesNotAffectOtherServiceGrant() async throws {
        let api = FixtureAPI()
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.setActive(true)
        await waitFor { store.dashboard != nil && !store.isRefreshing }
        await api.denyVoiceAfterMe()
        await store.refresh()
        XCTAssertTrue(store.authenticated); XCTAssertNil(store.dashboard)
        XCTAssertFalse(store.account!.permissions.voice); XCTAssertTrue(store.account!.permissions.account)
        store.selectService(.account)
        await waitFor { store.accountDashboard != nil }
        store.setActive(false)
    }
    @MainActor func testServerFailureKeepsPreviousSnapshotTimestamp() async throws {
        let api = FixtureAPI()
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.setActive(true)
        await waitFor { store.dashboard != nil && !store.isRefreshing }
        let previous = store.lastUpdated
        await api.setVoiceError(.server(status: 503))
        await store.refresh()
        XCTAssertNotNil(store.dashboard); XCTAssertEqual(store.lastUpdated, previous); XCTAssertNotNil(store.error)
        store.setActive(false)
    }
    @MainActor func testLogoutAndServiceSwitchDiscardLateDashboardResponses() async throws {
        for logout in [true, false] {
            let api = FixtureAPI(); await api.deferNextVoice()
            let vault = MemoryVault(session: testSession())
            let store = OpsStore(api: api, vault: vault, authorizer: FixturePasskeyAuthorizer())
            store.setActive(true)
            for _ in 0..<100 { if await api.voiceStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
            if logout { store.logout() } else { store.selectService(.account) }
            try await api.releaseVoice()
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertNil(store.dashboard)
            if logout { XCTAssertFalse(store.authenticated); XCTAssertNil(store.accountDashboard); XCTAssertNil(vault.session) }
            else { XCTAssertEqual(store.service, .account); XCTAssertNotNil(vault.session) }
            store.setActive(false)
        }
    }
    @MainActor func testBackgroundDiscardsLateDashboardAndForegroundRechecksMe() async throws {
        let api = FixtureAPI(); await api.deferNextVoice()
        let store = OpsStore(api: api, vault: MemoryVault(session: testSession()), authorizer: FixturePasskeyAuthorizer())
        store.setActive(true)
        for _ in 0..<100 { if await api.voiceStarted { break }; try await Task.sleep(for: .milliseconds(10)) }
        store.setActive(false); try await api.releaseVoice()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(store.dashboard); XCTAssertFalse(store.isRefreshing)
        await api.setAccount(testAccount(voice: false, account: false))
        store.setActive(true)
        await waitFor { !store.isRefreshing && store.account?.permissions.voice == false }
        XCTAssertFalse(store.canAccessSelectedService); XCTAssertNil(store.dashboard)
        store.setActive(false)
    }
    func testDashboardSchemasPreserveRealSourceAndUnknownMetrics() throws {
        let voice = try JSONDecoder().decode(OpsDashboard.self, from: dashboardData("dashboard-fixture"))
        let account = try JSONDecoder().decode(AccountOpsDashboard.self, from: dashboardData("account-dashboard-fixture"))
        try voice.validateVoiceBoundary(); try account.validateAccountBoundary()
        XCTAssertEqual(voice.service.host, "furby.top"); XCTAssertEqual(account.service.host, "kiki.group")
        XCTAssertThrowsError(try JSONDecoder().decode(OpsDashboard.self, from: dashboardData("account-dashboard-fixture")))
    }
    @MainActor private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("expected fixture state did not arrive")
    }
}

final class MemoryVault: SessionVault {
    var session: OpsSession?
    var pendingActions = [String: OpsPendingModeration]()
    var purgeCount = 0
    init(session: OpsSession? = nil) { self.session = session }
    func load() throws -> OpsSession? { session }
    func save(_ session: OpsSession) throws { self.session = session }
    func remove() throws { session = nil }
    func loadPendingModeration(accountID: String) throws -> OpsPendingModeration? { pendingActions[accountID] }
    func savePendingModeration(_ value: OpsPendingModeration) throws { pendingActions[value.accountID] = value }
    func removePendingModeration(accountID: String) throws { pendingActions.removeValue(forKey: accountID) }
    func purgeLegacySessions() throws { purgeCount += 1 }
}

@MainActor final class FixturePasskeyAuthorizer: OpsPasskeyAuthorizing {
    var registrationCount = 0, authenticationCount = 0, cancelCount = 0
    var deferred = false
    var continuation: CheckedContinuation<OpsPasskeyCredential, Error>?
    func register(_ options: OpsRegistrationOptions) async throws -> OpsPasskeyCredential {
        registrationCount += 1
        if deferred { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try registrationCredential()
    }
    func authenticate(_ options: OpsAuthenticationOptions) async throws -> OpsPasskeyCredential {
        authenticationCount += 1
        if deferred { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return try assertionCredential()
    }
    func release() { let old = continuation; continuation = nil; old?.resume(returning: try! assertionCredential()) }
    func cancel() { cancelCount += 1; let old = continuation; continuation = nil; old?.resume(throwing: CancellationError()) }
}

actor FixtureAPI: OpsAPI {
    var identity: OpsAccount
    var events = [String]()
    var meCalls = 0, voiceCalls = 0, accountCalls = 0
    var meError: OpsError?, voiceError: OpsError?
    var revokeVoiceOnForbidden = false
    var deferVoice = false, voiceStarted = false
    var continuation: CheckedContinuation<OpsDashboard, Never>?
    init(account: OpsAccount = testAccount()) { identity = account }
    func setMeError(_ value: OpsError?) { meError = value }
    func setVoiceError(_ value: OpsError?) { voiceError = value }
    func setAccount(_ account: OpsAccount) { identity = account }
    func denyVoiceAfterMe() { voiceError = .forbidden; revokeVoiceOnForbidden = true }
    func deferNextVoice() { deferVoice = true }
    func releaseVoice() throws { deferVoice = false; continuation?.resume(returning: try JSONDecoder().decode(OpsDashboard.self, from: dashboardData("dashboard-fixture"))); continuation = nil }
    func registrationOptions() async throws -> OpsRegistrationOptions { try KikiVoiceOpsTests.registrationOptionsFixture() }
    func authenticationOptions() async throws -> OpsAuthenticationOptions { try KikiVoiceOpsTests.authenticationOptionsFixture() }
    func finishRegistration(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { OpsLoginResult(session: testSession(), account: identity) }
    func finishAuthentication(transactionID: String, credential: OpsPasskeyCredential) async throws -> OpsLoginResult { OpsLoginResult(session: testSession(), account: identity) }
    func me(session: OpsSession) async throws -> OpsAccount { events.append("me"); meCalls += 1; if let meError { throw meError }; return identity }
    func setName(_ name: String, session: OpsSession) async throws -> OpsAccount {
        identity = OpsAccount(id: identity.id, name: name, needsName: false, permissions: identity.permissions); return identity
    }
    func dashboard(session: OpsSession) async throws -> OpsDashboard {
        events.append("voice"); voiceCalls += 1
        if let voiceError {
            if revokeVoiceOnForbidden { identity = testAccount(voice: false, account: true) }
            throw voiceError
        }
        if deferVoice { voiceStarted = true; return await withCheckedContinuation { continuation = $0 } }
        return try JSONDecoder().decode(OpsDashboard.self, from: dashboardData("dashboard-fixture"))
    }
    func accountDashboard(session: OpsSession) async throws -> AccountOpsDashboard {
        events.append("account"); accountCalls += 1
        return try JSONDecoder().decode(AccountOpsDashboard.self, from: dashboardData("account-dashboard-fixture"))
    }
    func logout(session: OpsSession) async throws { events.append("logout") }
}

// Disambiguate protocol witness names from global fixture helpers.
private enum KikiVoiceOpsTests {
    static func registrationOptionsFixture() throws -> OpsRegistrationOptions { try registrationOptions() }
    static func authenticationOptionsFixture() throws -> OpsAuthenticationOptions { try authenticationOptions() }
}
