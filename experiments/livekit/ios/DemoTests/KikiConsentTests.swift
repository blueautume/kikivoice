import Foundation
import XCTest
@testable import KikiLiveKitLab

@MainActor
final class KikiConsentTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "KikiLiveKitConsentTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testNoConsentNeverCreatesNetworkSDKOrReadsSession() async throws {
        let identity = LabTestIdentity()
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        var apiCreated = 0
        var sdkCreated = 0
        let mock = KikiAPIMockServer { _ in XCTFail("No business request before consent"); return (500, Data()) }
        let store = KikiDemoStore(consent: consent, identity: identity,
            apiProvider: { apiCreated += 1; return mock.client }, rtcProvider: { sdkCreated += 1; return LabTestRTC() })
        await store.start()
        do { try await store.loginForLab(name: "测试", accessCode: "test-code", agreed: false, adultConfirmed: false); XCTFail("Must reject") }
        catch { }
        XCTAssertEqual(apiCreated, 0)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertTrue(store.startupFinished)
    }

    func testPackagedDocumentsDescribeIndependentExperimentAndBothChecksAreRequired() throws {
        let documents = try XCTUnwrap(KikiLegalBundle.bundled)
        XCTAssertTrue(documents.isValid)
        XCTAssertEqual(documents.privacyVersion, "2026-10-19-livekit-lab3")
        let consent = KikiConsentStore(defaults: defaults())
        XCTAssertThrowsError(try consent.accept(agreed: true, adultConfirmed: false))
        XCTAssertThrowsError(try consent.accept(agreed: false, adultConfirmed: true))
        try consent.accept(agreed: true, adultConfirmed: true)
        XCTAssertTrue(consent.hasCurrentConsent)
        let missing = KikiConsentStore(documents: nil, defaults: defaults())
        XCTAssertFalse(missing.canAccept)
        XCTAssertThrowsError(try missing.accept(agreed: true, adultConfirmed: true))
    }

    func testLabSessionRestoresWithoutAppleOrAccessCodeAndRegistersConsentBeforeSDK() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "existing-session", "labSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let requests = LabRequestLog()
        let mock = KikiAPIMockServer { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
            return try labConsentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: {
            XCTAssertEqual(Array(requests.values.prefix(2)), ["POST /v1/me/legal-consent", "POST /v1/auth/refresh"])
            return rtc
        })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(rtc.loginCount, 1)
        XCTAssertEqual(rtc.sessionToken, "existing-session")
        XCTAssertNil(identity.values["accessCode"])
    }

    func testCopiedAppleSessionCannotRestoreInLab() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "apple-session", "appleSubject": "old-subject", "appleSessionVersion": "1"])
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let mock = KikiAPIMockServer { _ in XCTFail("An unrelated session cannot reach the lab backend"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { sdkCreated += 1; return LabTestRTC() })
        await store.start()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["appleSubject"])
    }

    func testLabLoginPersistsOnlyIssuedSessionAndNeverAccessCode() async throws {
        let identity = LabTestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try labConsentResponse($0, documents: docs) }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc })
        try await store.loginForLab(name: "测试", accessCode: "test-invitation", agreed: true, adultConfirmed: true)
        XCTAssertEqual(identity.values, ["sessionToken": "new-session", "labSessionVersion": "1"])
        XCTAssertFalse(identity.values.values.contains("test-invitation"))
        XCTAssertTrue(store.isAuthenticated)
    }

    func testLogoutDuringDeferredRTCLoginCannotReauthenticate() async throws {
        let identity = LabTestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try labConsentResponse($0, documents: docs) }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC(); rtc.deferLogin = true
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc })
        let signingIn = Task { try await store.loginForLab(name: "测试", accessCode: "test", agreed: true, adultConfirmed: true) }
        try await waitUntil { rtc.loginContinuation != nil }
        await store.logout()
        let continuation = try XCTUnwrap(rtc.loginContinuation)
        rtc.loginContinuation = nil
        continuation.resume()
        do { try await signingIn.value; XCTFail("Late login must be cancelled") }
        catch is CancellationError { }
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertGreaterThan(rtc.stopCount, 0)
        XCTAssertNil(identity.values["sessionToken"])
    }

    func testHostLogoutOnlyRevokesOwnSessionWithoutEndingOtherMembersRoom() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "existing-session", "labSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let requests = LabRequestLog()
        let mock = KikiAPIMockServer { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
            if request.url?.path == "/v1/library" {
                return (200, try labJSON(["favorites": [], "recents": [], "created": [labRoomFixture]]))
            }
            XCTAssertNotEqual(request.httpMethod, "PATCH", "A room-closing PATCH cannot be part of account logout")
            return try labConsentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        rtc.currentSDKRoomID = "voice_lab_1"
        rtc.isPresentingRoom = true
        await store.logout()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertGreaterThan(rtc.stopCount, 0)
        XCTAssertTrue(requests.values.contains("POST /v1/auth/logout"))
        XCTAssertFalse(requests.values.contains { $0.hasPrefix("PATCH /v1/rooms/") })
    }

    func testObsoleteLoginCannotLogoutNewLabSession() async throws {
        let identity = LabTestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let attempts = LabRequestLog()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/auth/lab" {
                attempts.append("login")
                return (200, try labJSON(["token": attempts.values.count == 1 ? "session-A" : "session-B", "user": labUserFixture, "sdk": labSDKFixture]))
            }
            return try labConsentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC(); rtc.deferLogin = true
        // This intentionally simulates a noncooperative old SDK callback.
        rtc.ignoreLifecycleCancellation = true
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc })
        let first = Task { try await store.loginForLab(name: "A", accessCode: "test", agreed: true, adultConfirmed: true) }
        try await waitUntil { rtc.loginContinuation != nil }
        let late = try XCTUnwrap(rtc.loginContinuation)
        rtc.loginContinuation = nil
        await store.logout()
        rtc.deferLogin = false
        try await store.loginForLab(name: "B", accessCode: "test", agreed: true, adultConfirmed: true)
        let logoutCount = rtc.logoutCount
        late.resume()
        do { try await first.value; XCTFail("Obsolete completion must be cancelled") }
        catch is CancellationError { }
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(rtc.isLoggedIn)
        XCTAssertEqual(rtc.sessionToken, "session-B")
        XCTAssertEqual(identity.values["sessionToken"], "session-B")
        XCTAssertEqual(rtc.logoutCount, logoutCount)
    }

    func testWithdrawalWaitsForDeferredRenewalAndLeavesMediaStopped() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "existing-session", "labSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try labConsentResponse($0, documents: docs) }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = LabTestRTC(); rtc.deferLogin = true
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc })
        let starting = Task { await store.start() }
        try await waitUntil { rtc.loginContinuation != nil }
        let withdrawal = Task { await store.withdrawConsent() }
        try await waitUntil { rtc.stopCount > 0 }
        let continuation = try XCTUnwrap(rtc.loginContinuation)
        rtc.loginContinuation = nil
        continuation.resume()
        await starting.value
        await withdrawal.value
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertFalse(consent.isWithdrawalPending)
        XCTAssertNil(identity.values["sessionToken"])
    }

    func testFailedWithdrawalSurvivesRelaunchAndRetriesWithoutBusinessSDK() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "retry-session", "labSessionVersion": "1"])
        let preferences = defaults()
        let attempts = LabRequestLog()
        let mock = KikiAPIMockServer { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/me/legal-consent")
            attempts.append("withdraw")
            return attempts.values.count == 1 ? (503, Data(#"{"detail":"稍后重试"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
        }
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        await consent.withdraw(teardown: {})
        XCTAssertTrue(consent.isWithdrawalPending)
        XCTAssertEqual(identity.values["sessionToken"], "retry-session")
        let restored = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        await restored.retryWithdrawal()
        XCTAssertFalse(restored.isWithdrawalPending)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["labSessionVersion"])
    }

    func testProtocolVersionMismatchBlocksSDKAndClearsSession() async throws {
        let identity = LabTestIdentity(values: ["sessionToken": "session", "labSessionVersion": "1"])
        let mock = KikiAPIMockServer { _ in
            (428, try labJSON(["detail": "协议已更新", "requiredVersions": ["privacyVersion": "later", "termsVersion": "later", "documentHash": String(repeating: "b", count: 64)]]))
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        var created = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { created += 1; return LabTestRTC() })
        await store.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(created, 0)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertTrue(consent.requiresAppUpdate)
        XCTAssertNil(identity.values["sessionToken"])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for controlled continuation")
        throw URLError(.timedOut)
    }
}

private final class LabTestIdentity: KikiIdentityStoring {
    var values: [String: String]
    var readCount = 0
    init(values: [String: String] = [:]) { self.values = values }
    func read(_ key: String) -> String? { readCount += 1; return values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

@MainActor
private final class LabTestRTC: KikiRTCServicing {
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?
    var isLoggedIn = false
    var isPresentingRoom = false
    var currentSDKRoomID: String?
    var loginCount = 0
    var logoutCount = 0
    var stopCount = 0
    var deferLogin = false
    var ignoreLifecycleCancellation = false
    private var generation = 0
    var sessionToken: String?
    var loginContinuation: CheckedContinuation<Void, Error>?
    func isCurrentRoom(_ roomID: String) -> Bool { currentSDKRoomID == roomID }
    func requireNoActiveRoom() throws { }
    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws {
        loginCount += 1
        let expectedGeneration = generation
        self.sessionToken = sessionToken
        if deferLogin { try await withCheckedThrowingContinuation { loginContinuation = $0 } }
        if !ignoreLifecycleCancellation, generation != expectedGeneration { throw CancellationError() }
        isLoggedIn = true
    }
    func logout() async { logoutCount += 1; isLoggedIn = false }
    func stopMediaForPrivacy() { generation += 1; stopCount += 1; isPresentingRoom = false; currentSDKRoomID = nil }
    func logoutForPrivacy() async throws { await logout() }
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws { }
    func fetchRooms() async throws -> [KikiRTCListing] { [] }
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws { }
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws { }
}

private func labConsentResponse(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data) {
    let body: [String: Any]
    switch request.url!.path {
    case "/v1/me/legal-consent":
        if request.httpMethod == "DELETE" { body = ["ok": true] }
        else { body = ["requiredVersions": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash], "requiresAcceptance": false, "legalConsent": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash, "acceptedAt": 1_792_180_000, "withdrawnAt": NSNull()]] }
    case "/v1/auth/refresh": body = ["user": labUserFixture, "sdk": labSDKFixture]
    case "/v1/auth/lab": body = ["token": "new-session", "user": labUserFixture, "sdk": labSDKFixture]
    case "/v1/auth/logout": body = ["ok": true]
    case "/v1/library": body = ["favorites": [], "recents": [], "created": []]
    case "/v1/rooms": body = ["rooms": []]
    default: XCTFail("Unexpected lab request \(request.url!.path)"); body = ["ok": true]
    }
    return (200, try labJSON(body))
}
