import Foundation
import XCTest
@testable import KikiTalk

@MainActor
final class KikiConsentTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "KikiConsentTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    func testPackagedLegalDocumentsAndPrivacyManifestExist() throws {
        let documents = try XCTUnwrap(KikiLegalBundle.bundled)
        XCTAssertTrue(documents.isValid)
        XCTAssertEqual(documents.minimumAge, 18)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertTrue(accessed.contains { ($0["NSPrivacyAccessedAPITypeReasons"] as? [String]) == ["CA92.1"] })
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    }

    func testNoConsentNeverCreatesSDKNetworkOrDeviceCredential() async throws {
        let identity = TestIdentity()
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        var apiCreated = 0
        var sdkCreated = 0
        var appleCreated = 0
        let mock = KikiAPIMockServer { _ in XCTFail("No request before consent"); return (500, Data()) }
        let store = KikiDemoStore(consent: consent, identity: identity,
                                  apiProvider: { apiCreated += 1; return mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { appleCreated += 1; return TestApple() })
        await store.start()
        do { try await store.loginWithApple(agreed: false, adultConfirmed: false); XCTFail("Must reject") }
        catch { }
        XCTAssertEqual(apiCreated, 0)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertEqual(appleCreated, 0)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertTrue(store.startupFinished)
    }

    func testBothCheckboxesAreRequiredAndReceiptIsVersioned() throws {
        let consent = KikiConsentStore(defaults: defaults())
        XCTAssertThrowsError(try consent.accept(agreed: true, adultConfirmed: false))
        XCTAssertThrowsError(try consent.accept(agreed: false, adultConfirmed: true))
        XCTAssertFalse(consent.hasCurrentConsent)
        try consent.accept(agreed: true, adultConfirmed: true)
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertThrowsError(try consent.acceptance(agreed: false, adultConfirmed: true))
        let documents = try XCTUnwrap(consent.documents)
        let newer = KikiLegalVersions(privacyVersion: "later", termsVersion: "later", documentHash: String(repeating: "b", count: 64))
        consent.requireUpdatedDocuments(newer, message: "更新协议")
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertTrue(consent.requiresAppUpdate)
        XCTAssertThrowsError(try consent.accept(agreed: true, adultConfirmed: true))
        XCTAssertNotEqual(documents.versions, newer)
    }

    func testMissingDocumentsFailClosed() {
        let consent = KikiConsentStore(documents: nil, defaults: defaults())
        XCTAssertFalse(consent.canAccept)
        XCTAssertThrowsError(try consent.accept(agreed: true, adultConfirmed: true))
    }

    func testExistingSessionRegistersConsentBeforeRefreshOrSDKCreation() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = TestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: {
            XCTAssertEqual(requests.values.prefix(2), ["POST /v1/me/legal-consent", "POST /v1/auth/refresh"])
            return rtc
        }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(rtc.loginCount, 1)
    }

    func testServerVersionMismatchBlocksSDKAndRequiresAppUpdate() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { _ in
            (428, try JSONSerialization.data(withJSONObject: ["detail": "协议已更新", "requiredVersions": ["privacyVersion": "later", "termsVersion": "later", "documentHash": String(repeating: "b", count: 64)]]))
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertTrue(consent.requiresAppUpdate)
        XCTAssertNil(identity.values["sessionToken"])
    }

    func testFailedWithdrawalSurvivesRelaunchAndRetryClearsCredentials() async throws {
        let identity = TestIdentity(values: ["sessionToken": "retry-session", "lastUserID": "legal_qa", "deviceSecret": "bound-credential"])
        let preferences = defaults()
        let attempts = TestRequests()
        let mock = KikiAPIMockServer { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/v1/me/legal-consent")
            attempts.append("withdraw")
            return attempts.values.count == 1 ? (503, Data(#"{"detail":"服务暂不可用"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
        }
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        await consent.withdraw(teardown: {})
        XCTAssertTrue(consent.isWithdrawalPending)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertNotNil(consent.withdrawalError)
        XCTAssertEqual(identity.values["sessionToken"], "retry-session")
        let restored = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        XCTAssertTrue(restored.isWithdrawalPending)
        await restored.retryWithdrawal()
        XCTAssertFalse(restored.isWithdrawalPending)
        XCTAssertFalse(restored.hasCurrentConsent)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["lastUserID"])
        XCTAssertNil(identity.values["deviceSecret"])
    }

    func testWithdrawalWaitsForInflightSDKLoginThenLeavesItLoggedOut() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try consentResponse($0, documents: docs) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = TestRTC()
        rtc.deferLogin = true
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc }, appleProvider: { TestApple() })
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
        XCTAssertGreaterThan(rtc.logoutCount, 0)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertFalse(consent.isWithdrawalPending)
    }

    func testSDKFailureStillWithdrawsServerAndColdRetryNeedsNoRevokedToken() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "deviceSecret": "bound"])
        let preferences = defaults()
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            requests.append(request.httpMethod ?? "")
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        await consent.withdraw { throw KikiRTCError.unavailable("模拟第三方退出失败") }
        XCTAssertEqual(requests.values, ["DELETE"])
        XCTAssertTrue(consent.isWithdrawalPending)
        XCTAssertEqual(consent.receipt?.serverWithdrawalConfirmed, true)
        XCTAssertNotNil(consent.withdrawalError)
        XCTAssertNil(identity.values["sessionToken"])
        let restored = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: {
            XCTFail("Confirmed server withdrawal must not depend on a revoked token after relaunch")
            return mock.client
        })
        await restored.retryWithdrawal()
        XCTAssertFalse(restored.isWithdrawalPending)
        XCTAssertNil(restored.receipt)
        XCTAssertNil(identity.values["deviceSecret"])
    }

    func testDelayedRoomListCannotStartBusinessRequestAfterWithdrawal() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client })
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = TestRTC()
        rtc.deferRooms = true
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        let starting = Task { await store.start() }
        try await waitUntil { rtc.roomContinuation != nil }
        await store.withdrawConsent()
        let continuation = try XCTUnwrap(rtc.roomContinuation)
        rtc.roomContinuation = nil
        continuation.resume(returning: [KikiRTCListing(id: "room", title: "room", host: "host", hostID: "host", audience: 0, isLive: false, category: "随心聊", theme: 0, coverURL: "", avatarURL: "", startTime: 0)])
        await starting.value
        XCTAssertFalse(paths.values.contains("/v1/rooms/lookup"))
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
    }

    func testLegacyIDSessionCannotRestoreOrCreateSDK() async throws {
        let identity = TestIdentity(values: ["sessionToken": "old-id-session", "deviceSecret": "old-secret", "lastUserID": "old-user"])
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let mock = KikiAPIMockServer { _ in XCTFail("Legacy session must not reach the API"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["deviceSecret"])
        XCTAssertNil(identity.values["lastUserID"])
    }

    func testAppleCancellationNeverCreatesAccountOrSDK() async throws {
        let identity = TestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let apple = TestApple()
        apple.shouldCancel = true
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        do { try await store.loginWithApple(agreed: true, adultConfirmed: true); XCTFail("Must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(paths.values, ["/v1/auth/apple/challenge"])
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["appleSubject"])
    }

    func testAppleLoginUsesFreshChallengeThenSavesSystemSubject() async throws {
        let identity = TestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            if request.url!.path == "/v1/auth/apple" {
                let body = try requestBody(request)
                XCTAssertEqual(body["challengeID"] as? String, "challenge")
                XCTAssertEqual(body["identityToken"] as? String, "system-token")
                XCTAssertEqual(body["authorizationCode"] as? String, "system-code")
                XCTAssertNil(body["userID"])
                XCTAssertNil(body["deviceSecret"])
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let apple = TestApple()
        let rtc = TestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc }, appleProvider: { apple })
        try await store.loginWithApple(agreed: true, adultConfirmed: true)
        XCTAssertEqual(apple.receivedNonce, "server-nonce")
        XCTAssertEqual(apple.receivedState, "challenge")
        XCTAssertEqual(Array(paths.values.prefix(2)), ["/v1/auth/apple/challenge", "/v1/auth/apple"])
        XCTAssertEqual(identity.values["appleSubject"], "apple-subject")
        XCTAssertEqual(identity.values["sessionToken"], "new-session")
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(rtc.isLoggedIn)
    }

    func testRevokedAppleCredentialInvalidatesServerSessionBeforeSDKRestore() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let apple = TestApple(); apple.state = .revoked
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        await store.start()
        XCTAssertEqual(paths.values, ["/v1/auth/apple/revoked"])
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["appleSubject"])
    }

    func testTemporaryAppleStateFailureKeepsCredentialWithoutStartingSDK() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let apple = TestApple(); apple.stateError = URLError(.notConnectedToInternet)
        let mock = KikiAPIMockServer { _ in XCTFail("Must wait for verified Apple state"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        await store.start()
        XCTAssertEqual(identity.values["sessionToken"], "existing-session")
        XCTAssertEqual(identity.values["appleSubject"], "apple-subject")
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertFalse(store.isAuthenticated)
    }

    func testWithdrawalDuringSystemAuthorizationCannotLogBackIn() async throws {
        let identity = TestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let apple = TestApple(); apple.deferAuthorization = true
        var sdkCreated = 0
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        let signingIn = Task { try await store.loginWithApple(agreed: true, adultConfirmed: true) }
        try await waitUntil { apple.authorizationContinuation != nil }
        await store.withdrawConsent()
        do { try await signingIn.value; XCTFail("Withdrawal must cancel sign-in") }
        catch is CancellationError { }
        XCTAssertEqual(paths.values, ["/v1/auth/apple/challenge"])
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertNil(identity.values["sessionToken"])
    }

    func testOfflineRevocationStopsMediaAndRetriesAllSessionInvalidation() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let revocations = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url!.path == "/v1/auth/apple/revoked" {
                revocations.append("revoke")
                return revocations.values.count == 1 ? (503, Data(#"{"detail":"暂不可用"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = TestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(rtc.isLoggedIn)
        await store.appleCredentialRevoked()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertGreaterThan(rtc.stopCount, 0)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNotNil(identity.values["applePendingRevocations"])
        var sdkCreated = 0
        let restored = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                     rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await restored.start()
        XCTAssertEqual(revocations.values.count, 2)
        XCTAssertNil(identity.values["applePendingRevocations"])
        XCTAssertFalse(restored.isAuthenticated)
        XCTAssertEqual(sdkCreated, 0)
    }

    func testFailedAccountDeletionKeepsAppleAccountAndSession() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            if request.url!.path == "/v1/account" {
                return (503, Data(#"{"detail":"删除未完成，请重试"}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity)
        try consent.accept(agreed: true, adultConfirmed: true)
        let rtc = TestRTC()
        let store = KikiDemoStore(consent: consent, identity: identity, apiProvider: { mock.client }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        do { try await store.deleteAccount(); XCTFail("Server must confirm deletion") }
        catch { }
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(rtc.isLoggedIn)
        XCTAssertEqual(identity.values["sessionToken"], "existing-session")
        XCTAssertEqual(identity.values["appleSubject"], "apple-subject")
    }

    func testNonceUsesSHA256OfServerValue() {
        XCTAssertEqual(KikiAppleAuthorizationService.hashedNonce("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for controlled test continuation")
        throw URLError(.timedOut)
    }
}

private final class TestIdentity: KikiIdentityStoring {
    var values: [String: String]
    var readCount = 0
    init(values: [String: String] = [:]) { self.values = values }
    func read(_ key: String) -> String? { readCount += 1; return values[key] }
    func write(_ value: String, key: String) throws { values[key] = value }
    func remove(_ key: String) { values.removeValue(forKey: key) }
}

@MainActor
private final class TestRTC: KikiRTCServicing {
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?
    var isLoggedIn = false
    var isPresentingRoom = false
    var currentSDKRoomID: String?
    var loginCount = 0
    var logoutCount = 0
    var stopCount = 0
    var deferLogin = false
    var deferRooms = false
    var loginContinuation: CheckedContinuation<Void, Error>?
    var roomContinuation: CheckedContinuation<[KikiRTCListing], Error>?
    func isCurrentRoom(_ roomID: String) -> Bool { currentSDKRoomID == roomID }
    func requireNoActiveRoom() throws { }
    func login(sdkAppID: Int, userID: String, userSig: String) async throws {
        loginCount += 1
        if deferLogin { try await withCheckedThrowingContinuation { loginContinuation = $0 } }
        isLoggedIn = true
    }
    func logout() async { logoutCount += 1; isLoggedIn = false }
    func stopMediaForPrivacy() { stopCount += 1; isPresentingRoom = false; currentSDKRoomID = nil }
    func logoutForPrivacy() async throws { await logout() }
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws { }
    func fetchRooms() async throws -> [KikiRTCListing] {
        if deferRooms { return try await withCheckedThrowingContinuation { roomContinuation = $0 } }
        return []
    }
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws { }
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws { }
}

private final class TestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func consentResponse(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data) {
    let user: [String: Any] = ["id": "legal_qa", "sdkUserID": "sdk_qa", "name": "测试昵称", "bio": "", "avatarIndex": 0, "notificationsEnabled": false, "needsNickname": false]
    let sdk: [String: Any] = ["sdkAppID": 12345, "userID": "sdk_qa", "userSig": "test-signature", "expiresAt": 2_000_000_000]
    let body: [String: Any]
    switch request.url!.path {
    case "/v1/me/legal-consent":
        if request.httpMethod == "DELETE" { body = ["ok": true] }
        else { body = ["requiredVersions": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash], "requiresAcceptance": false, "legalConsent": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash, "acceptedAt": 1_792_180_000, "withdrawnAt": NSNull()]] }
    case "/v1/auth/refresh": body = ["user": user, "sdk": sdk]
    case "/v1/auth/apple": body = ["token": "new-session", "user": user, "sdk": sdk]
    case "/v1/auth/apple/challenge": body = ["challengeID": "challenge", "nonce": "server-nonce", "expiresAt": 2_000_000_000]
    case "/v1/auth/logout": body = ["ok": true]
    case "/v1/library": body = ["favorites": [], "recents": [], "created": []]
    case "/v1/rooms/lookup": body = ["rooms": []]
    default: XCTFail("Unexpected test request \(request.url!.path)"); body = ["ok": true]
    }
    return (200, try JSONSerialization.data(withJSONObject: body))
}

@MainActor
private final class TestApple: KikiAppleAuthorizing {
    var state: KikiAppleCredentialState = .authorized
    var stateError: Error?
    var shouldCancel = false
    var deferAuthorization = false
    var authorizationContinuation: CheckedContinuation<KikiAppleCredential, Error>?
    var receivedNonce: String?
    var receivedState: String?
    func authorize(nonce: String, state: String) async throws -> KikiAppleCredential {
        receivedNonce = nonce; receivedState = state
        if shouldCancel { throw CancellationError() }
        if deferAuthorization { return try await withCheckedThrowingContinuation { authorizationContinuation = $0 } }
        return KikiAppleCredential(subject: "apple-subject", identityToken: "system-token", authorizationCode: "system-code")
    }
    func credentialState(subject: String) async throws -> KikiAppleCredentialState {
        if let stateError { throw stateError }
        return state
    }
    func cancel() {
        let pending = authorizationContinuation; authorizationContinuation = nil
        pending?.resume(throwing: CancellationError())
    }
}
