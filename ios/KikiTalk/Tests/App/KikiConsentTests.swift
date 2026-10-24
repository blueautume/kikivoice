import Foundation
import Combine
import CryptoKit
import SwiftUI
import UIKit
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
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        var apiCreated = 0
        var sdkCreated = 0
        var appleCreated = 0
        let mock = KikiAPIMockServer { _ in XCTFail("No request before consent"); return (500, Data()) }
        let store = KikiAppStore(consent: consent, identity: identity,
                                  apiProvider: { apiCreated += 1; return mock.client },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { appleCreated += 1; return TestApple() })
        await store.start()
        do { try await store.loginWithApple(); XCTFail("Must reject") }
        catch { }
        XCTAssertEqual(apiCreated, 0)
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertEqual(appleCreated, 0)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertTrue(store.startupFinished)
    }

    func testSingleExplicitActionPersistsVersionedAdultConsent() throws {
        let preferences = defaults()
        let identity = TestIdentity()
        let consent = KikiConsentStore(defaults: preferences, identity: identity, requiresRemoteDocuments: false)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertThrowsError(try consent.acceptance(), "Login must never manufacture consent")
        XCTAssertNil(preferences.data(forKey: KikiConsentStore.storageKey))
        try consent.accept()
        let original = try XCTUnwrap(consent.receipt)
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertTrue(original.adultConfirmed)
        XCTAssertEqual(try consent.acceptance(), KikiLegalAcceptance(versions: original.versions, accepted: true, adultConfirmed: true))
        try consent.accept()
        XCTAssertEqual(consent.receipt, original, "A duplicate button action must not replace an existing receipt")
        let restored = KikiConsentStore(defaults: preferences, identity: identity, requiresRemoteDocuments: false)
        XCTAssertTrue(restored.hasCurrentConsent)
        XCTAssertEqual(restored.receipt, original)
        XCTAssertEqual(identity.readCount, 0, "Offline consent must not touch device/account credentials")
        let newer = KikiLegalVersions(privacyVersion: "later", termsVersion: "later", documentHash: String(repeating: "b", count: 64))
        restored.requireUpdatedDocuments(newer, message: "更新协议")
        XCTAssertFalse(restored.hasCurrentConsent)
        XCTAssertTrue(restored.requiresDocumentRefresh)
        XCTAssertFalse(restored.requiresAppUpdate)
        XCTAssertThrowsError(try restored.accept())
        XCTAssertThrowsError(try restored.acceptance())
    }

    func testPreviouslyAcceptedCurrentReceiptDoesNotNeedNewUIConfirmation() throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let preferences = defaults()
        let existing = KikiConsentStore.Receipt(versions: docs.versions, acceptedAt: Date(timeIntervalSince1970: 1_792_180_000), adultConfirmed: true, status: .accepted)
        preferences.set(try JSONEncoder().encode(existing), forKey: KikiConsentStore.storageKey)
        let consent = KikiConsentStore(documents: docs, defaults: preferences, requiresRemoteDocuments: false)
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt, existing)
        XCTAssertTrue(try consent.acceptance().accepted)
        XCTAssertEqual(consent.receipt?.acceptedAt, existing.acceptedAt)
    }

    func testChangedBundledLegalVersionRequiresOneNewExplicitAction() throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let preferences = defaults()
        let old = KikiConsentStore.Receipt(versions: KikiLegalVersions(privacyVersion: "2026-10-19-r6", termsVersion: "2026-10-19-r6", documentHash: String(repeating: "a", count: 64)), acceptedAt: Date(timeIntervalSince1970: 1_792_180_000), adultConfirmed: true, status: .accepted)
        preferences.set(try JSONEncoder().encode(old), forKey: KikiConsentStore.storageKey)
        let consent = KikiConsentStore(documents: docs, defaults: preferences, requiresRemoteDocuments: false)
        XCTAssertNotEqual(old.versions, docs.versions)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertThrowsError(try consent.acceptance())
        XCTAssertEqual(consent.receipt, old, "An upgrade cannot silently rewrite prior consent")
        try consent.accept()
        XCTAssertTrue(consent.hasCurrentConsent)
        let current = consent.receipt
        let restarted = KikiConsentStore(documents: docs, defaults: preferences, requiresRemoteDocuments: false)
        XCTAssertTrue(restarted.hasCurrentConsent)
        XCTAssertEqual(restarted.receipt, current)
        XCTAssertEqual(try restarted.acceptance().documentHash, docs.documentHash)
    }

    func testMissingDocumentsFailClosed() {
        let consent = KikiConsentStore(documents: nil, defaults: defaults(), requiresRemoteDocuments: false)
        XCTAssertFalse(consent.canAccept)
        XCTAssertThrowsError(try consent.accept())
    }

    func testExistingSessionRegistersConsentBeforeRefreshOrSDKCreation() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            requests.append("\(request.httpMethod ?? "GET") \(request.url!.path)")
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: {
            XCTAssertEqual(requests.values.prefix(2), ["POST /v1/me/legal-consent", "POST /v1/auth/refresh"])
            return rtc
        }, appleProvider: { TestApple() })
        XCTAssertFalse(store.isAppleIDBound, "Saved Apple credentials alone must not appear as an authenticated binding")
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(store.isAppleIDBound)
        XCTAssertEqual(rtc.loginCount, 1)
        await store.logout()
        XCTAssertFalse(store.isAppleIDBound, "Signing out must clear the account binding presented by this session")
    }

    func testAppleBindingRequiresCurrentSubjectAndSessionVersion() async throws {
        let unsupportedCredentials: [[String: String]] = [
            ["sessionToken": "existing-session", "appleSessionVersion": "2"],
            ["sessionToken": "existing-session", "appleSubject": "", "appleSessionVersion": "2"],
            ["sessionToken": "existing-session", "appleSubject": "apple-subject"],
            ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "1"],
            ["appleSubject": "apple-subject", "appleSessionVersion": "2"]
        ]
        for values in unsupportedCredentials {
            let identity = TestIdentity(values: values)
            let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
            try consent.accept()
            let mock = KikiAPIMockServer { _ in
                XCTFail("Incomplete or unsupported credentials must not reach the account or voice API")
                return (500, Data())
            }
            var sdkCreated = 0
            let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                      rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
            XCTAssertFalse(store.isAppleIDBound)
            await store.start()
            XCTAssertFalse(store.isAuthenticated)
            XCTAssertFalse(store.isAppleIDBound)
            XCTAssertEqual(sdkCreated, 0)
        }
    }

    func testServerVersionMismatchBlocksSDKAndRequiresDocumentRefresh() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { _ in
            (428, try JSONSerialization.data(withJSONObject: ["detail": "协议已更新", "requiredVersions": ["privacyVersion": "later", "termsVersion": "later", "documentHash": String(repeating: "b", count: 64)]]))
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertTrue(consent.requiresDocumentRefresh)
        XCTAssertFalse(consent.requiresAppUpdate)
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
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        await consent.withdraw(teardown: {})
        XCTAssertTrue(consent.isWithdrawalPending)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertNotNil(consent.withdrawalError)
        XCTAssertEqual(identity.values["sessionToken"], "retry-session")
        let restored = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        XCTAssertTrue(restored.isWithdrawalPending)
        await restored.retryWithdrawal()
        XCTAssertFalse(restored.isWithdrawalPending)
        XCTAssertFalse(restored.hasCurrentConsent)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["lastUserID"])
        XCTAssertNil(identity.values["deviceSecret"])
    }

    func testWithdrawalWaitsForInflightSDKLoginThenLeavesItLoggedOut() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try consentResponse($0, documents: docs) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        rtc.deferLogin = true
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() })
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
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        await consent.withdraw { throw KikiRTCError.unavailable("模拟第三方退出失败") }
        XCTAssertEqual(requests.values, ["DELETE"])
        XCTAssertTrue(consent.isWithdrawalPending)
        XCTAssertEqual(consent.receipt?.serverWithdrawalConfirmed, true)
        XCTAssertNotNil(consent.withdrawalError)
        XCTAssertNil(identity.values["sessionToken"])
        let restored = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: {
            XCTFail("Confirmed server withdrawal must not depend on a revoked token after relaunch")
            return mock.client
        }, requiresRemoteDocuments: false)
        await restored.retryWithdrawal()
        XCTAssertFalse(restored.isWithdrawalPending)
        XCTAssertNil(restored.receipt)
        XCTAssertNil(identity.values["deviceSecret"])
    }

    func testLegacyIDSessionCannotRestoreOrCreateSDK() async throws {
        let identity = TestIdentity(values: ["sessionToken": "old-id-session", "deviceSecret": "old-secret", "lastUserID": "old-user"])
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let mock = KikiAPIMockServer { _ in XCTFail("Legacy session must not reach the API"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
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
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let apple = TestApple()
        apple.shouldCancel = true
        let acceptedReceipt = consent.receipt
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        do { try await store.loginWithApple(); XCTFail("Must cancel") }
        catch is CancellationError { }
        XCTAssertEqual(paths.values, ["/v1/auth/apple/challenge"])
        XCTAssertEqual(consent.receipt, acceptedReceipt)
        XCTAssertTrue(consent.hasCurrentConsent)
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
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let apple = TestApple()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { apple })
        try await store.loginWithApple()
        XCTAssertEqual(apple.receivedNonce, "server-nonce")
        XCTAssertEqual(apple.receivedState, "challenge")
        XCTAssertEqual(Array(paths.values.prefix(2)), ["/v1/auth/apple/challenge", "/v1/auth/apple"])
        XCTAssertEqual(identity.values["appleSubject"], "apple-subject")
        XCTAssertEqual(identity.values["sessionToken"], "new-session")
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(rtc.isLoggedIn)
    }

    func testRevokedAppleCredentialInvalidatesServerSessionBeforeSDKRestore() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let paths = TestRequests()
        let mock = KikiAPIMockServer { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
            return (200, Data(#"{"ok":true}"#.utf8))
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let apple = TestApple(); apple.state = .revoked
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        await store.start()
        XCTAssertEqual(paths.values, ["/v1/auth/apple/revoked"])
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNil(identity.values["appleSubject"])
    }

    func testTemporaryAppleStateFailureKeepsCredentialWithoutStartingSDK() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let apple = TestApple(); apple.stateError = URLError(.notConnectedToInternet)
        let mock = KikiAPIMockServer { _ in XCTFail("Must wait for verified Apple state"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
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
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let apple = TestApple(); apple.deferAuthorization = true
        var sdkCreated = 0
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { apple })
        let signingIn = Task { try await store.loginWithApple() }
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
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let revocations = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url!.path == "/v1/auth/apple/revoked" {
                revocations.append("revoke")
                return revocations.values.count == 1 ? (503, Data(#"{"detail":"暂不可用"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(rtc.isLoggedIn)
        XCTAssertTrue(store.isAppleIDBound)
        await store.appleCredentialRevoked()
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(store.isAppleIDBound, "A retained revocation receipt must not keep Apple ID marked as bound")
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertGreaterThan(rtc.stopCount, 0)
        XCTAssertNil(identity.values["sessionToken"])
        XCTAssertNotNil(identity.values["applePendingRevocations"])
        var sdkCreated = 0
        let restored = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                     rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await restored.start()
        XCTAssertEqual(revocations.values.count, 2)
        XCTAssertNil(identity.values["applePendingRevocations"])
        XCTAssertFalse(restored.isAuthenticated)
        XCTAssertFalse(restored.isAppleIDBound)
        XCTAssertEqual(sdkCreated, 0)
    }

    func testFailedAccountDeletionStopsMediaAndKeepsRetryCredential() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            if request.url!.path == "/v1/account" {
                return (503, Data(#"{"detail":"删除未完成，请重试"}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        do { try await store.deleteAccount(); XCTFail("Server must confirm deletion") }
        catch { }
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertEqual(identity.values["sessionToken"], "existing-session")
        XCTAssertEqual(identity.values["appleSubject"], "apple-subject")
    }

    func testAccountAndVoiceCredentialsStayOnTheirOwnOrigins() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let seen = TestRequests()
        let mock = KikiAPIMockServer { request in
            let voiceOrigin = request.url!.host!.hasPrefix("voice-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), voiceOrigin ? "Bearer voice-session" : "Bearer account-only")
            seen.append((voiceOrigin ? "voice " : "account ") + request.url!.path)
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(rtc.lastSessionToken, "voice-session")
        XCTAssertTrue(seen.values.contains("account /v1/voice/session"))
        XCTAssertTrue(seen.values.contains("voice /v1/rooms"))
        XCTAssertTrue(seen.values.contains("voice /v1/library"))
        XCTAssertEqual(identity.values["sessionToken"], "account-only")
        XCTAssertFalse(identity.values.values.contains("voice-session"))
        await store.logout()
    }

    func testTemporaryVoiceLeaseRenewalFailureKeepsMediaAndRetriesWithoutLabFallback() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let renewals = TestRequests()
        let mock = KikiAPIMockServer { request in
            XCTAssertNotEqual(request.url!.path, "/v1/auth/lab")
            if request.url!.path == "/v1/voice/session" {
                renewals.append("exchange")
                if renewals.values.count == 2 { return (503, Data(#"{"detail":"voice unavailable"}"#.utf8)) }
                if renewals.values.count > 2 {
                    let response = try consentResponse(request, documents: docs)
                    var body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.1) as? [String: Any])
                    body["token"] = "renewed-voice-session"
                    return (200, try JSONSerialization.data(withJSONObject: body))
                }
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() },
                                  leaseRenewalNanoseconds: 50_000_000)
        await store.start()
        let roomID = "lk_" + String(repeating: "a", count: 32)
        rtc.currentSDKRoomID = roomID
        rtc.isPresentingRoom = true
        try await waitUntil { rtc.lastSessionToken == "renewed-voice-session" }
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertTrue(rtc.isLoggedIn)
        XCTAssertEqual(rtc.stopCount, 0, "A temporary authorization endpoint failure cannot end a still-authorized call")
        XCTAssertEqual(rtc.logoutCount, 0)
        XCTAssertEqual(rtc.currentSDKRoomID, roomID)
        XCTAssertTrue(rtc.isPresentingRoom)
        XCTAssertGreaterThanOrEqual(rtc.loginCount, 2, "The failed renewal must be retried, not ignored forever")
        XCTAssertGreaterThanOrEqual(renewals.values.count, 3)
        XCTAssertEqual(identity.values["sessionToken"], "account-only")
        await store.logout()
    }

    func testUnauthorizedVoiceLeaseRenewalStopsMediaWithoutLabFallback() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let renewals = TestRequests()
        let mock = KikiAPIMockServer { request in
            XCTAssertNotEqual(request.url!.path, "/v1/auth/lab")
            if request.url!.path == "/v1/voice/session" {
                renewals.append("exchange")
                if renewals.values.count > 1 { return (401, Data(#"{"detail":"voice authorization revoked"}"#.utf8)) }
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() },
                                  leaseRenewalNanoseconds: 50_000_000)
        await store.start()
        try await waitUntil { rtc.stopCount > 0 && rtc.logoutCount > 0 }
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertTrue(store.canReconnect)
        XCTAssertEqual(identity.values["sessionToken"], "account-only")
        XCTAssertEqual(renewals.values.count, 2)
        await store.logout()
    }

    func testLogoutCancelsTemporaryVoiceLeaseRetryAndCannotRestoreSession() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let renewals = TestRequests()
        let mock = KikiAPIMockServer { request in
            XCTAssertNotEqual(request.url!.path, "/v1/auth/lab")
            if request.url!.path == "/v1/voice/session" {
                renewals.append("exchange")
                if renewals.values.count > 1 { return (503, Data(#"{"detail":"voice unavailable"}"#.utf8)) }
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                  voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() },
                                  leaseRenewalNanoseconds: 50_000_000)
        await store.start()
        try await waitUntil { renewals.values.count >= 2 }
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(rtc.stopCount, 0)
        await store.logout()
        let exchangesAfterLogout = renewals.values.count
        let loginsAfterLogout = rtc.loginCount
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertEqual(renewals.values.count, exchangesAfterLogout, "An explicit logout must cancel the scheduled authorization retry")
        XCTAssertEqual(rtc.loginCount, loginsAfterLogout, "A retry from the old account generation cannot restore media")
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(rtc.isLoggedIn)
        XCTAssertNil(identity.values["sessionToken"])
    }

    func testNonceUsesSHA256OfServerValue() {
        XCTAssertEqual(KikiAppleAuthorizationService.hashedNonce("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for controlled test continuation", file: file, line: line)
        throw URLError(.timedOut)
    }
}

extension KikiConsentTests {
    private func directIntroductionStore(documents: KikiLegalBundle, api: KikiAccountAPIClient, voice: KikiAPIClient) async throws -> KikiAppStore {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let consent = KikiConsentStore(documents: documents, defaults: defaults(), identity: identity, apiProvider: { api }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { api }, voiceAPIProvider: { voice }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        return store
    }

    func testDirectFifthReceiptDisablesFurtherIntroductionUntilAuthoritativeReplyRefresh() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let sends = TestRequests(), replies = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" {
                    sends.append(try XCTUnwrap(requestBody(request)["requestID"] as? String))
                    return (200, try directIntroductionFixture(remaining: max(0, 5 - sends.values.count), established: !replies.values.isEmpty, receipt: sends.values.count))
                }
                return (200, try directIntroductionFixture(remaining: max(0, 5 - sends.values.count), established: !replies.values.isEmpty))
            }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        XCTAssertEqual(store.directMessageAccess[peer]?.remainingBeforeReply, 5)
        for index in 1...5 {
            store.updateDirectDraft("第 \(index) 条", personID: peer)
            _ = try await store.sendDirectDraft(peer)
        }
        XCTAssertEqual(store.directMessageAccess[peer]?.canSend, false)
        XCTAssertEqual(store.directMessageAccess[peer]?.requiresReply, true)
        XCTAssertNil(store.pendingDirectMessages[peer])
        store.updateDirectDraft("等回复再发", personID: peer)
        do { _ = try await store.sendDirectDraft(peer); XCTFail("Fifth receipt must immediately stop a new introduction") } catch { }
        XCTAssertEqual(sends.values.count, 5)
        XCTAssertEqual(store.directDrafts[peer], "等回复再发")
        replies.append("recipient committed a reply")
        _ = try await store.socialDirectMessages(peer)
        XCTAssertEqual(store.directMessageAccess[peer]?.replyEstablished, true)
        _ = try await store.sendDirectDraft(peer)
        XCTAssertEqual(sends.values.count, 6)
        XCTAssertNil(store.directDrafts[peer])
        await store.logout()
        XCTAssertTrue(store.directMessageAccess.isEmpty)
    }

    func testStructuredSixthDenialImmediatelyCachesWaitingStateAndKeepsEditableDraft() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" {
                    return (403, Data(#"{"detail":{"code":"direct_message_reply_required","message":"等待对方回复","canSend":false,"remainingBeforeReply":0,"requiresReply":true,"replyEstablished":false,"initialMessageLimit":5}}"#.utf8))
                }
                return (200, try directIntroductionFixture(remaining: 1))
            }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        store.updateDirectDraft("另一台设备刚好用完额度", personID: peer)
        do { _ = try await store.sendDirectDraft(peer); XCTFail("Admission must fail") }
        catch { XCTAssertTrue(error is KikiDirectMessageAdmissionError) }
        XCTAssertEqual(store.directMessageAccess[peer]?.requiresReply, true)
        XCTAssertEqual(store.directMessageAccess[peer]?.canSend, false)
        XCTAssertNil(store.pendingDirectMessages[peer])
        XCTAssertEqual(store.directDrafts[peer], "另一台设备刚好用完额度")
        await store.logout()
    }

    func testLatePreSendMessagePageCannotRestoreAllowanceAfterTheFifthReceipt() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let arrived = expectation(description: "Old message page is in flight")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let fetches = TestRequests()
        let mock = KikiConcurrentConsentServer { request in
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" { return (200, try directIntroductionFixture(remaining: 0, receipt: 5)) }
                fetches.append("page")
                if fetches.values.count > 1 { arrived.fulfill(); _ = release.wait(timeout: .now() + 5) }
                return (200, try directIntroductionFixture(remaining: 1))
            }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        let stale = Task { try await store.socialDirectMessages(peer) }
        await fulfillment(of: [arrived], timeout: 3)
        store.updateDirectDraft("第五条", personID: peer)
        _ = try await store.sendDirectDraft(peer)
        release.signal(); _ = try await stale.value
        XCTAssertEqual(store.directMessageAccess[peer]?.remainingBeforeReply, 0)
        XCTAssertEqual(store.directMessageAccess[peer]?.canSend, false)
        await store.logout()
    }

    func testUncertainFifthSendRetriesOriginalUUIDEvenAfterPageReportsNoAllowance() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let writes = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" {
                    writes.append(try XCTUnwrap(requestBody(request)["requestID"] as? String))
                    if writes.values.count == 1 { return (503, Data(#"{"detail":"回执暂未确认"}"#.utf8)) }
                    return (200, try directIntroductionFixture(remaining: 0, receipt: 5))
                }
                return (200, try directIntroductionFixture(remaining: writes.values.isEmpty ? 1 : 0))
            }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        store.updateDirectDraft("第五条网络超时", personID: peer)
        do { _ = try await store.sendDirectDraft(peer); XCTFail("First send is uncertain") } catch { }
        XCTAssertNotNil(store.pendingDirectMessages[peer])
        _ = try await store.socialDirectMessages(peer)
        XCTAssertEqual(store.directMessageAccess[peer]?.canSend, false)
        _ = try await store.sendDirectDraft(peer)
        XCTAssertEqual(writes.values.count, 2); XCTAssertEqual(Set(writes.values).count, 1)
        XCTAssertNil(store.pendingDirectMessages[peer]); XCTAssertNil(store.directDrafts[peer])
        XCTAssertEqual(store.directMessageAccess[peer]?.canSend, false)
        await store.logout()
    }

    func testClearingOwnConversationDoesNotResetCachedIntroductionAdmission() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_fixture0002"
        let mock = KikiAPIMockServer { request in
            switch request.url?.path {
            case "/v1/social/conversations/" + peer + "/messages": return (200, try directIntroductionFixture(remaining: 0))
            case "/v1/social/conversations/" + peer + "/clear": return (200, Data(#"{"ok":true}"#.utf8))
            case "/v1/social/conversations": return (200, Data(#"{"conversations":[],"nextCursor":null,"unreadCount":0}"#.utf8))
            default: return try consentResponse(request, documents: docs)
            }
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        let before = store.directMessageAccess[peer]
        try await store.clearInboxEntry(inboxMutationEntry(), throughID: UUID().uuidString, requestID: UUID())
        XCTAssertEqual(store.directMessageAccess[peer], before)
        XCTAssertEqual(store.directMessageAccess[peer]?.requiresReply, true)
        XCTAssertEqual(store.directHistoryRevision[peer], 1)
        await store.logout()
    }

    func testLegacyServerDenialRemainsAuthoritativeWithoutMutualFollowFallback() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let writes = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" { writes.append("unexpected write"); return (500, Data()) }
                return (200, Data(#"{"conversationID":null,"messages":[],"nextCursor":null,"canSend":false,"unreadCount":0}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        store.updateDirectDraft("旧服务端未授权", personID: peer)
        do { _ = try await store.sendDirectDraft(peer); XCTFail("Legacy server denial is still authoritative") } catch { }
        XCTAssertTrue(writes.values.isEmpty)
        XCTAssertNil(store.directMessageAccess[peer]?.remainingBeforeReply)
        XCTAssertEqual(store.directDrafts[peer], "旧服务端未授权")
        store.socialPolicyChanged(userID: peer, blocked: true)
        XCTAssertTrue(store.directMessageAccess.isEmpty)
        await store.logout()
    }
}

extension KikiConsentTests {
    /// Offline API fixtures rendered by the production conversation view. This
    /// checks native controls/layout; it never taps Send or creates a real DM.
    func testDirectAdmissionProductionViewNativeControlsAndScreenshots() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_target0000"
        let folder = URL(fileURLWithPath: "/tmp/kiki-direct-access-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let person = KikiPerson(id: peer, name: "小岛 · 离线界面验收", bio: "", avatarIndex: 4, avatarURL: nil,
                                following: false, followsYou: false, mutual: false, followingCount: 0, followerCount: 0, currentRoomID: nil)
        var checks: [[String: Any]] = []
        for (name, remaining, established) in [("intro-five", 5, false), ("waiting-reply", 0, false), ("reply-unlocked", 0, true)] {
            let requests = TestRequests()
            let mock = KikiAPIMockServer { request in
                if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                    XCTAssertEqual(request.httpMethod, "GET", "Offline UI validation must never send a message")
                    requests.append("page")
                    return (200, try directIntroductionFixture(remaining: remaining, established: established))
                }
                return try consentResponse(request, documents: docs)
            }
            let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
            store.updateDirectDraft("离线验收草稿 😀", personID: peer)
            let expectedEnabled = established || remaining > 0
            try await withSocialWindow { window in
                window.rootViewController = UIHostingController(rootView: NavigationStack {
                    KikiDirectConversationView(person: person, store: store)
                }.environment(\.scenePhase, .active).preferredColorScheme(.light))
                window.makeKeyAndVisible()
                try await self.waitUntil { !requests.values.isEmpty && store.directMessageAccess[peer]?.canSend == expectedEnabled && !self.socialEditableViews(window).isEmpty }
                try await Task.sleep(nanoseconds: 350_000_000)
                window.layoutIfNeeded()
                let input = try XCTUnwrap(self.socialEditableViews(window).filter { !$0.isHidden && $0.bounds.width > 100 && $0.bounds.height > 15 }.first,
                                          "Production DM composer must contain a native UIKit text input")
                var hierarchyEnabled = true
                var ancestor: UIView? = input
                while let view = ancestor { hierarchyEnabled = hierarchyEnabled && view.isUserInteractionEnabled; ancestor = view.superview }
                let nativeEnabled: Bool
                if let field = input as? UITextField { nativeEnabled = field.isEnabled && hierarchyEnabled }
                else if let text = input as? UITextView { nativeEnabled = text.isEditable && hierarchyEnabled }
                else { throw XCTSkip("No public UIKit input state is exposed by this OS") }
                XCTAssertEqual(nativeEnabled, expectedEnabled, "\(name): native input admission must match the server")
                let frame = input.convert(input.bounds, to: window)
                XCTAssertGreaterThan(frame.width, 100)
                XCTAssertGreaterThanOrEqual(frame.minX, window.bounds.minX - 1)
                XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX + 1)
                func controls(_ view: UIView) -> [UIControl] {
                    ((view as? UIControl).map { [$0] } ?? []) + view.subviews.flatMap(controls)
                }
                let send = controls(window).first { $0.accessibilityIdentifier == "social.direct.send" }
                if let send { XCTAssertEqual(send.isEnabled, expectedEnabled) }
                checks.append(["state": name, "canSend": expectedEnabled, "nativeInputEnabled": nativeEnabled,
                               "nativeSendButtonInspected": send != nil, "inputWidth": frame.width, "viewportWidth": window.bounds.width])
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image); attachment.name = device + "-" + name; attachment.lifetime = .keepAlways; self.add(attachment)
                try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + ".png"))
                window.rootViewController = nil
            }
            XCTAssertEqual(store.directMessageAccess[peer]?.canSend, expectedEnabled)
            await store.logout()
        }
        let manifest: [String: Any] = ["scope": "Offline API fixtures in production KikiDirectConversationView; native control/layout checks only; no Send tap, production account or real chat", "device": device, "checks": checks]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(device + "-validation.json"))
    }
}

private func directIntroductionFixture(remaining: Int, established: Bool = false, receipt: Int? = nil) throws -> Data {
    var body: [String: Any] = ["conversationID": "11111111-1111-4111-8111-111111111111", "canSend": established || remaining > 0,
                              "remainingBeforeReply": established ? NSNull() as Any : remaining as Any, "requiresReply": !established && remaining == 0,
                              "replyEstablished": established, "initialMessageLimit": 5]
    if let receipt {
        body["message"] = ["id": "message-\(receipt)", "seq": receipt, "senderID": "legal_qa", "text": "已提交消息", "createdAt": Date().timeIntervalSince1970]
    } else {
        body["messages"] = []; body["nextCursor"] = NSNull(); body["unreadCount"] = 0
    }
    return try JSONSerialization.data(withJSONObject: body)
}

extension KikiConsentTests {
    private func roomCatalogFixture(_ state: KikiCatalogFixtureState) async throws -> (KikiAppStore, KikiConcurrentConsentServer) {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiConcurrentConsentServer { request in
            if let response = try state.respond(request) { return response }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        return (store, mock)
    }

    func testRoomTitleMemoryIsAccountScopedAndServerHistoryIsFallback() async throws {
        for savedTitle in [Optional("本设备上次名称"), nil] {
            let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2",
                                                "lastSuccessfulRoomTitle.other-account": "其他账号的私人房名"])
            if let savedTitle { identity.values["lastSuccessfulRoomTitle.legal_qa"] = savedTitle }
            let docs = try XCTUnwrap(KikiLegalBundle.bundled)
            let previous = KikiRoom(id: "previous", title: "服务器上次名称", host: "测试昵称", hostID: "sdk_qa", category: "随心聊", audience: 0,
                                    isLive: false, theme: 0, isCreatedByMe: true, status: "ended")
            let mock = KikiAPIMockServer { request in
                if request.url?.path == "/v1/library" {
                    return (200, try labJSON(["favorites": [], "recents": [], "created": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous))]]))
                }
                return try consentResponse(request, documents: docs)
            }
            let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
            try consent.accept()
            let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                      rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
            await store.start()
            XCTAssertEqual(store.defaultRoomTitle, "测试昵称的房间")
            XCTAssertEqual(store.suggestedRoomTitle, savedTitle ?? "服务器上次名称")
            XCTAssertNotEqual(store.suggestedRoomTitle, "其他账号的私人房名")
            await store.logout()
            XCTAssertNil(store.lastSuccessfulRoomTitle)
            XCTAssertEqual(identity.values["lastSuccessfulRoomTitle.legal_qa"], savedTitle ?? "服务器上次名称")
        }
    }

    func testBlankCreateAndConfirmedRenameRememberTitleAndUpdateRoomCachesOnlyOnSuccess() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let failure = TestRequests()
        let room = KikiRoom(id: "voice_title", title: "原来的房名", host: "测试昵称", hostID: "sdk_qa", category: "随心聊", audience: 5,
                            isLive: false, theme: 2, isCreatedByMe: true, status: "live")
        let roomObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as! [String: Any]
        let mock = KikiAPIMockServer { request in
            switch (request.httpMethod, request.url!.path) {
            case ("GET", "/v1/rooms"): return (200, try labJSON(["rooms": [roomObject]]))
            case ("GET", "/v1/library"): return (200, try labJSON(["favorites": [roomObject], "recents": [roomObject], "created": [roomObject]]))
            case ("POST", "/v1/rooms"):
                if !failure.values.isEmpty { return (503, try labJSON(["detail": "controlled failure"])) }
                let body = try voiceRequestBody(request)
                XCTAssertEqual(body["title"] as? String, "测试昵称的房间")
                var created = roomObject; created["title"] = body["title"]
                return (200, try labJSON(created))
            case ("PATCH", "/v1/rooms/voice_title"):
                let body = try voiceRequestBody(request)
                XCTAssertEqual(Set(body.keys), ["title"])
                var renamed = roomObject; renamed["title"] = body["title"]
                let owner = labRoomMember("sdk_qa", role: "owner", seat: 1)
                var state = labRoomStateFixture
                state["room"] = renamed; state["me"] = owner; state["members"] = [owner]; state["revision"] = 9
                return (200, try labJSON(state))
            default: return try consentResponse(request, documents: docs)
            }
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        _ = try await store.reserveRoom(title: "  ", category: "随心聊", isLive: false, theme: 2)
        XCTAssertEqual(store.suggestedRoomTitle, "测试昵称的房间")
        _ = try await store.updateRoomTitle(roomID: room.id, title: "  已保存的新房名  ")
        XCTAssertEqual(store.rooms.first?.title, "已保存的新房名")
        XCTAssertEqual(store.favoriteRooms.first?.title, "已保存的新房名")
        XCTAssertEqual(store.recentRooms.first?.title, "已保存的新房名")
        XCTAssertEqual(store.createdRooms.first?.title, "已保存的新房名")
        XCTAssertTrue(store.rooms.first?.isCreatedByMe == true)
        XCTAssertEqual(store.rooms.first?.audience, 5)
        XCTAssertEqual(identity.values["lastSuccessfulRoomTitle.legal_qa"], "已保存的新房名")
        failure.append("fail subsequent create")
        do { _ = try await store.reserveRoom(title: "失败不记忆", category: "随心聊", isLive: false, theme: 1); XCTFail("Create should fail") }
        catch { }
        XCTAssertEqual(store.suggestedRoomTitle, "已保存的新房名")
        await store.logout()
    }

    func testCommittedRoomRenameCannotBeOverwrittenByOlderListOrLibraryReads() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let phase = TestRequests()
        let listStarted = expectation(description: "older room list is pending")
        let libraryStarted = expectation(description: "older library is pending")
        let listGate = DispatchSemaphore(value: 0), libraryGate = DispatchSemaphore(value: 0)
        defer { listGate.signal(); libraryGate.signal() }
        let original = KikiRoom(id: "voice_title_race", title: "旧房名", host: "测试昵称", hostID: "sdk_qa", category: "随心聊", audience: 5,
                                isLive: false, theme: 2, isCreatedByMe: true, status: "live")
        let originalObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        let mock = KikiConcurrentConsentServer { request in
            let flags = phase.values
            var snapshot = originalObject
            if flags.contains("renamed") { snapshot["title"] = "新房名"; snapshot["audience"] = 9 }
            switch (request.httpMethod, request.url!.path) {
            case ("GET", "/v1/rooms"):
                if flags.contains("hold"), !flags.contains("released") {
                    listStarted.fulfill(); _ = listGate.wait(timeout: .now() + 10)
                }
                return (200, try labJSON(["rooms": flags.contains("empty") && !flags.contains("fresh") ? [] : [snapshot]]))
            case ("GET", "/v1/library"):
                if flags.contains("hold"), !flags.contains("released") {
                    libraryStarted.fulfill(); _ = libraryGate.wait(timeout: .now() + 10)
                }
                return (200, try labJSON(["favorites": [snapshot], "recents": [snapshot], "created": [snapshot]]))
            case ("PATCH", "/v1/rooms/voice_title_race"):
                phase.append("renamed")
                snapshot["title"] = "新房名"
                let owner = labRoomMember("sdk_qa", role: "owner", seat: 1)
                var state = labRoomStateFixture
                state["room"] = snapshot; state["me"] = owner; state["members"] = [owner]; state["revision"] = 9
                return (200, try labJSON(state))
            default: return try consentResponse(request, documents: docs)
            }
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        phase.append("hold")
        let oldList = Task { await store.refreshRooms() }
        let oldLibrary = Task { await store.refreshLibrary() }
        await fulfillment(of: [listStarted, libraryStarted], timeout: 2)
        var observedTitles: [String] = []
        let titleObservation = store.$rooms.dropFirst().sink { records in observedTitles.append(contentsOf: records.map(\.title)) }
        _ = try await store.updateRoomTitle(roomID: original.id, title: "新房名")
        XCTAssertEqual(store.rooms.first?.title, "新房名")
        phase.append("released"); listGate.signal(); libraryGate.signal()
        await oldList.value; await oldLibrary.value
        XCTAssertEqual(store.rooms.first?.title, "新房名")
        XCTAssertEqual(store.rooms.first?.audience, 9, "The old response is rejected, then one fresh trailing snapshot may apply")
        XCTAssertFalse(observedTitles.contains("旧房名"), "An invalidated snapshot cannot temporarily restore the old title")
        // Hide the active card so reconciliation cannot conceal an old title
        // that may have incorrectly overwritten the private library cache.
        phase.append("empty")
        await store.refreshRooms()
        XCTAssertTrue(store.rooms.isEmpty)
        XCTAssertEqual(store.createdRooms.first?.title, "新房名")
        XCTAssertEqual(store.favoriteRooms.first?.title, "新房名")
        XCTAssertEqual(store.recentRooms.first?.title, "新房名")
        phase.append("fresh")
        await store.refreshRooms(); await store.refreshLibrary()
        XCTAssertEqual(store.rooms.first?.title, "新房名")
        XCTAssertEqual(store.rooms.first?.audience, 9, "A new read is never permanently blocked by the metadata fence")
        XCTAssertEqual(store.suggestedRoomTitle, "新房名")
        titleObservation.cancel()
        await store.logout()
    }

    func testCatalogWatchDoesNotAcknowledgeRevisionWhenCreateAckInvalidatesItsList() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let phase = TestRequests(), reads = TestRequests()
        let postCommitted = expectation(description: "server create committed but acknowledgement held")
        let listStarted = expectation(description: "watch read started after new catalog revision but before create acknowledgement")
        let postGate = DispatchSemaphore(value: 0), listGate = DispatchSemaphore(value: 0)
        defer { postGate.signal(); listGate.signal() }
        let room = KikiRoom(id: "voice_ack", title: "创建中的房名", host: "测试昵称", hostID: "sdk_qa", category: "随心聊", audience: 0,
                            isLive: false, theme: 1, isCreatedByMe: true, status: "live")
        let roomObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(room))
        let mock = KikiConcurrentConsentServer { request in
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/v1/rooms"):
                phase.append("server-committed")
                postCommitted.fulfill()
                _ = postGate.wait(timeout: .now() + 10)
                return (200, try labJSON(roomObject))
            case ("GET", "/v1/rooms"):
                reads.append("list")
                let flags = phase.values
                if !flags.contains("server-committed") { return (200, try labJSON(["rooms": []])) }
                if !flags.contains("release-list") { listStarted.fulfill(); _ = listGate.wait(timeout: .now() + 10) }
                return (200, try labJSON(["rooms": [roomObject]]))
            case ("GET", "/v1/room-catalog/changes"):
                let hasCursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "after" } == true
                return (200, try labJSON(["revision": 2, "changed": !hasCursor]))
            default: return try consentResponse(request, documents: docs)
            }
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        let create = Task { try await store.reserveRoom(title: room.title, category: room.category, isLive: false, theme: room.theme) }
        await fulfillment(of: [postCommitted], timeout: 2)
        let watch = Task { await store.watchRoomCatalog() }
        await fulfillment(of: [listStarted], timeout: 2)
        postGate.signal()
        _ = try await create.value
        XCTAssertTrue(store.rooms.isEmpty)
        phase.append("release-list"); listGate.signal()
        try await waitUntil { store.rooms.contains { $0.id == room.id } }
        XCTAssertEqual(reads.values.count, 3, "Startup plus invalidated GET plus one trailing GET; no new server revision is required")
        XCTAssertNil(store.loadingError)
        watch.cancel(); await watch.value
        await store.logout()
    }

    func testStoreForwardsOnlyRoomPresentationTransitions() async throws {
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try consentResponse($0, documents: docs) }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
                                  rtcProvider: { rtc }, appleProvider: { TestApple() })
        await store.start()
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }
        rtc.isPresentingRoom = true
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(store.isPresentingRoom)
        rtc.isPresentingRoom = true
        XCTAssertEqual(publications, 1, "A repeated SDK value must not invalidate the whole root view")
        rtc.isLoggedIn = false
        XCTAssertEqual(publications, 1, "Unrelated RTC publications are not bridged to the store")
        rtc.isPresentingRoom = false
        XCTAssertEqual(publications, 2, "Minimizing a room must wake the now-visible directory subscription")
        XCTAssertFalse(store.isPresentingRoom)
        rtc.isLoggedIn = true
        observation.cancel()
        await store.logout()
    }

    func testVisibleRoomCatalogFetchesNewRoomWhenRevisionChanges() async throws {
        let state = KikiCatalogFixtureState()
        defer { state.releaseAll() }
        let (store, mock) = try await roomCatalogFixture(state)
        withExtendedLifetime(mock) { }
        let watch = Task { await store.watchRoomCatalog() }
        defer { watch.cancel() }
        try await waitUntil { state.waitingWatchCount > 0 }
        XCTAssertEqual(state.roomReadCount, 2, "Startup plus one visible-page revalidation")
        state.replaceRooms([KikiCatalogFixtureState.room("first"), KikiCatalogFixtureState.room("new")])
        try await waitUntil { store.rooms.contains { $0.id == "new" } }
        XCTAssertEqual(state.roomReadCount, 3, "A changed revision fetches the authoritative list immediately")
        XCTAssertEqual(state.watchQueries.first?.after, nil)
        XCTAssertEqual(state.watchQueries.first?.wait, 0)
        XCTAssertTrue(state.watchQueries.dropFirst().allSatisfy { $0.wait == 15 })
        watch.cancel()
        await watch.value
        await store.logout()
    }

    func testUnchangedCatalogDoesNotFetchListOrPublishLoadingAndCancelsLongPoll() async throws {
        let state = KikiCatalogFixtureState()
        defer { state.releaseAll() }
        let (store, mock) = try await roomCatalogFixture(state)
        withExtendedLifetime(mock) { }
        let watch = Task { await store.watchRoomCatalog() }
        try await waitUntil { state.waitingWatchCount > 0 }
        var changedRooms = 0
        var loadingValues: [Bool] = []
        let roomObservation = store.$rooms.dropFirst().sink { _ in changedRooms += 1 }
        let loadingObservation = store.$isRefreshing.dropFirst().sink { loadingValues.append($0) }
        let reads = state.roomReadCount
        state.releaseUnchangedWatch()
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(state.roomReadCount, reads)
        XCTAssertEqual(changedRooms, 0)
        XCTAssertTrue(loadingValues.isEmpty)
        XCTAssertFalse(store.isRefreshing)
        // Cancelling a view's task must also cancel its pending sleep/wait.
        watch.cancel()
        await watch.value
        let secondWatch = Task { await store.watchRoomCatalog() }
        try await waitUntil { state.waitingWatchCount > 0 }
        let stopped = expectation(description: "visible subscription cancellation finishes without waiting for server response")
        secondWatch.cancel()
        let completion = Task { await secondWatch.value; stopped.fulfill() }
        await fulfillment(of: [stopped], timeout: 1)
        await completion.value
        let afterCancellation = state.roomReadCount
        state.replaceRooms([KikiCatalogFixtureState.room("late")])
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(state.roomReadCount, afterCancellation)
        XCTAssertFalse(store.rooms.contains { $0.id == "late" })
        roomObservation.cancel(); loadingObservation.cancel()
        await store.logout()
    }

    func testConcurrentRoomRefreshesShareOneRequestAndCancelCannotApplyLateList() async throws {
        let state = KikiCatalogFixtureState()
        defer { state.releaseAll() }
        let (store, mock) = try await roomCatalogFixture(state)
        withExtendedLifetime(mock) { }
        state.replaceRooms([KikiCatalogFixtureState.room("first"), KikiCatalogFixtureState.room("shared")])
        state.holdRoomReads(true)
        let first = Task { await store.refreshRooms() }
        try await waitUntil { state.waitingRoomCount == 1 }
        let second = Task { await store.refreshRooms() }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(state.roomReadCount, 2, "Concurrent readers must join one authoritative GET")
        first.cancel()
        try await Task.sleep(nanoseconds: 40_000_000)
        state.releaseRoomReads()
        await first.value; await second.value
        XCTAssertEqual(state.roomReadCount, 2)
        XCTAssertEqual(store.rooms.map(\.id), ["first", "shared"], "Cancelling one reader must preserve another reader's shared request")
        state.replaceRooms([KikiCatalogFixtureState.room("cancelled-response")])
        state.holdRoomReads(true)
        let cancelled = Task { await store.refreshRooms() }
        try await waitUntil { state.waitingRoomCount == 1 }
        cancelled.cancel()
        await cancelled.value
        state.releaseRoomReads()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(store.rooms.map(\.id), ["first", "shared"], "A cancelled view's late response must not restore cards")
        await store.logout()
    }

    func testCatalogRevisionCannotBeAcknowledgedByAnOlderInflightList() async throws {
        for alreadyWatching in [false, true] {
            let state = KikiCatalogFixtureState()
            defer { state.releaseAll() }
            let (store, mock) = try await roomCatalogFixture(state)
            withExtendedLifetime(mock) { }
            var watch: Task<Void, Never>?
            if alreadyWatching {
                watch = Task { await store.watchRoomCatalog() }
                try await waitUntil { state.waitingWatchCount > 0 }
            }
            let baselineReads = state.roomReadCount
            state.holdRoomReads(true)
            let olderRead = Task { await store.refreshRooms() }
            try await waitUntil { state.waitingRoomCount == 1 }
            state.replaceRooms([KikiCatalogFixtureState.room("first"), KikiCatalogFixtureState.room("created-during-read")])
            if !alreadyWatching { watch = Task { await store.watchRoomCatalog() } }
            try await waitUntil { state.watchReadCount >= (alreadyWatching ? 2 : 1) }
            try await Task.sleep(nanoseconds: 60_000_000)
            XCTAssertEqual(state.roomReadCount, baselineReads + 1, "A watch waits for the older GET without starting parallel duplicate readers")
            state.releaseRoomReads()
            await olderRead.value
            try await waitUntil { store.rooms.contains { $0.id == "created-during-read" } }
            XCTAssertEqual(state.roomReadCount, baselineReads + 2,
                           "Both initial and changed revisions need one GET started after observing that revision")
            watch?.cancel()
            await watch?.value
            await store.logout()
        }
    }

    func testLegacyCatalogEndpointFallsBackSlowlyAndCachesUnsupportedForSession() async throws {
        let state = KikiCatalogFixtureState()
        state.watchStatus = 404
        defer { state.releaseAll() }
        let (store, mock) = try await roomCatalogFixture(state)
        withExtendedLifetime(mock) { }
        let watch = Task { await store.watchRoomCatalog() }
        try await waitUntil { state.roomReadCount == 2 }
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(state.watchReadCount, 1)
        XCTAssertEqual(state.roomReadCount, 2, "Unsupported service must not produce a hot failure loop")
        watch.cancel(); await watch.value
        let resumed = Task { await store.watchRoomCatalog() }
        try await waitUntil { state.roomReadCount == 3 }
        XCTAssertEqual(state.watchReadCount, 1, "The unsupported endpoint is not retried on every view appearance")
        resumed.cancel(); await resumed.value
        XCTAssertEqual(store.rooms.map(\.id), ["first"])
        await store.logout()
    }

    func testCatalogWatchFailureKeepsCardsAndRespectsRetryAfter() async throws {
        for status in [503, 429] {
            let state = KikiCatalogFixtureState()
            state.watchStatus = status
            defer { state.releaseAll() }
            let (store, mock) = try await roomCatalogFixture(state)
            withExtendedLifetime(mock) { }
            let watch = Task { await store.watchRoomCatalog() }
            try await waitUntil { state.watchReadCount == 1 }
            try await Task.sleep(nanoseconds: 120_000_000)
            XCTAssertEqual(store.rooms.map(\.id), ["first"], "A failed watch must not blank a usable room list")
            XCTAssertEqual(state.watchReadCount, 1)
            XCTAssertEqual(state.roomReadCount, status == 429 ? 1 : 2,
                           "429 must not be bypassed by an immediate compensating list GET")
            watch.cancel(); await watch.value
            await store.logout()
        }
    }
}

/// Controlled server waits run on the existing concurrent URLProtocol fixture,
/// so cancellation can be proved without sleeping for a real 15-second poll.
private final class KikiCatalogFixtureState: @unchecked Sendable {
    struct Query { let after: Int?; let wait: Int }
    private let lock = NSLock()
    private var records = [KikiCatalogFixtureState.room("first")]
    private var revision = 1
    private var status = 200
    private var heldRooms = false
    private var roomReads = 0
    private var watchReads: [Query] = []
    private var roomWaits: [DispatchSemaphore] = []
    private var watchWaits: [DispatchSemaphore] = []
    var roomReadCount: Int { locked { roomReads } }
    var watchReadCount: Int { locked { watchReads.count } }
    var waitingRoomCount: Int { locked { roomWaits.count } }
    var waitingWatchCount: Int { locked { watchWaits.count } }
    var watchQueries: [Query] { locked { watchReads } }
    var watchStatus: Int { get { locked { status } } set { locked { status = newValue } } }

    static func room(_ id: String) -> KikiRoom {
        KikiRoom(id: id, title: id, host: "房主", hostID: "other", category: "随心聊", audience: 1,
                 isLive: false, theme: 0, isCreatedByMe: false, status: "live")
    }
    private func locked<Value>(_ operation: () -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }; return operation()
    }
    func replaceRooms(_ value: [KikiRoom]) {
        let waits = locked { records = value; revision += 1; let waits = watchWaits; watchWaits = []; return waits }
        waits.forEach { $0.signal() }
    }
    func holdRoomReads(_ value: Bool) { locked { heldRooms = value } }
    func releaseRoomReads() {
        let waits = locked { heldRooms = false; let waits = roomWaits; roomWaits = []; return waits }
        waits.forEach { $0.signal() }
    }
    func releaseUnchangedWatch() {
        let waits = locked { let waits = watchWaits; watchWaits = []; return waits }
        waits.forEach { $0.signal() }
    }
    func releaseAll() { releaseRoomReads(); releaseUnchangedWatch() }

    func respond(_ request: URLRequest) throws -> (Int, Data)? {
        switch request.url?.path {
        case "/v1/rooms":
            let (snapshot, wait): ([KikiRoom], DispatchSemaphore?) = locked {
                roomReads += 1
                let wait = heldRooms ? DispatchSemaphore(value: 0) : nil
                if let wait { roomWaits.append(wait) }
                return (records, wait)
            }
            if let wait { _ = wait.wait(timeout: .now() + 10) }
            return (200, try JSONEncoder().encode(CatalogRoomsResponse(rooms: snapshot)))
        case "/v1/room-catalog/changes":
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Query(after: items.first { $0.name == "after" }?.value.flatMap(Int.init),
                              wait: items.first { $0.name == "waitSeconds" }?.value.flatMap(Int.init) ?? -1)
            let (status, wait): (Int, DispatchSemaphore?) = locked {
                watchReads.append(query)
                let wait = self.status == 200 && query.after == revision && query.wait > 0 ? DispatchSemaphore(value: 0) : nil
                if let wait { watchWaits.append(wait) }
                return (self.status, wait)
            }
            if status != 200 { return (status, try JSONSerialization.data(withJSONObject: ["detail": "controlled watch failure"])) }
            if let wait { _ = wait.wait(timeout: .now() + 10) }
            let current = locked { revision }
            return (200, try JSONSerialization.data(withJSONObject: ["revision": current, "changed": query.after != current]))
        default: return nil
        }
    }
    private struct CatalogRoomsResponse: Encodable { let rooms: [KikiRoom] }
}

extension KikiConsentTests {
    func testConfirmedProfileFollowReturnsBeforeASlowSecondarySummary() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let person = socialFixturePerson(following: false)
        var confirmed = person; confirmed.following = true
        let personData = try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed))])
        let summaryArrived = expectation(description: "Secondary profile summary is in flight")
        let followReturned = expectation(description: "Confirmed follow returned without waiting for the summary")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let writes = TestRequests()
        let mock = KikiConcurrentConsentServer { request in
            if request.url?.path == "/v1/social/follows/" + person.id {
                writes.append(request.httpMethod ?? "")
                return (200, personData)
            }
            if request.url?.path == "/v1/social/people/kiki_fixture0001", !writes.values.isEmpty {
                summaryArrived.fulfill(); _ = release.wait(timeout: .now() + 5)
                return (503, Data(#"{"detail":"Secondary counters are temporarily unavailable"}"#.utf8))
            }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        let follow = Task {
            let result = try await store.setFollowing(person, enabled: true)
            followReturned.fulfill()
            return result
        }
        await fulfillment(of: [followReturned, summaryArrived], timeout: 2)
        let result = try await follow.value
        XCTAssertTrue(result.following)
        XCTAssertTrue(store.isFollowing(person), "A stale profile snapshot must immediately reflect the confirmed account mutation")
        XCTAssertEqual(writes.values, ["PUT"])
        release.signal()
        await store.logout()
    }

    func testProfileBlockAndSettingsUnblockShareAccountRouteAndClearCachedPrivateContent() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_fixture0002"
        let writes = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/blocks/" + peer {
                XCTAssertFalse(request.url!.host!.hasPrefix("voice-"), "Profile and settings must use the same account block authority")
                writes.append(request.httpMethod ?? "")
                return (200, try JSONSerialization.data(withJSONObject: ["ok": true, "blocked": request.httpMethod == "PUT"]))
            }
            if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod == "POST" { return (503, Data(#"{"detail":"Unconfirmed write"}"#.utf8)) }
                return (200, try directIntroductionFixture(remaining: 4))
            }
            if request.url?.path == "/v1/social/relationships/ids" {
                return (200, Data(#"{"followingIDs":[],"followingCount":0,"followerCount":0}"#.utf8))
            }
            if request.url?.path == "/v1/social/conversations" {
                return (200, Data(#"{"conversations":[],"nextCursor":null,"unreadCount":0}"#.utf8))
            }
            XCTAssertFalse(request.url?.path.hasPrefix("/v1/blocks") == true)
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        _ = try await store.socialDirectMessages(peer)
        store.updateDirectDraft("Unsent private draft", personID: peer)
        do { _ = try await store.sendDirectDraft(peer); XCTFail("The first write must remain uncertain") } catch { }
        XCTAssertNotNil(store.pendingDirectMessages[peer]); XCTAssertNotNil(store.directMessageAccess[peer])
        let revision = store.socialPrivacyRevision
        try await store.setSocialBlock(peer, enabled: true)
        XCTAssertEqual(store.socialPrivacyRevision, revision + 1)
        XCTAssertNil(store.directDrafts[peer]); XCTAssertNil(store.pendingDirectMessages[peer]); XCTAssertNil(store.directMessageAccess[peer])
        XCTAssertFalse(store.isFollowing(socialFixturePerson(following: true)))
        let rtc = KikiRTCService.shared
        let previous = rtc.socialStore; rtc.socialStore = store
        defer { rtc.socialStore = previous }
        try await rtc.setBlocked(peer, enabled: false)
        XCTAssertEqual(writes.values, ["PUT", "DELETE"])
        XCTAssertEqual(store.socialPrivacyRevision, revision + 2)
        XCTAssertFalse(store.isFollowing(socialFixturePerson(following: true)), "Unblocking must not recreate a removed follow")
        XCTAssertFalse(rtc.isUpdatingBlock)
        await store.logout()
    }

    /// Public UIButton target-actions exercise the production profile and the
    /// central native dismissal bridge. Fixtures are local; no message is sent.
    func testPublicProfileHalfSheetNativeActionsPushConversationIntoMessagesTab() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), peer = "kiki_fixture0002"
        let folder = URL(fileURLWithPath: "/tmp/kiki-public-profile-actions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        func nativeButtons(_ view: UIView) -> [UIButton] {
            ((view as? UIButton).map { [$0] } ?? []) + view.subviews.flatMap(nativeButtons)
        }
        func presentedChain(_ controller: UIViewController) -> [UIViewController] {
            guard let next = controller.presentedViewController else { return [] }
            return [next] + presentedChain(next)
        }
        func navigationControllers(_ controller: UIViewController) -> [UINavigationController] {
            ((controller as? UINavigationController).map { [$0] } ?? []) + controller.children.flatMap(navigationControllers)
        }
        var manifest: [[String: Any]] = []
        for (name, size, typeSize) in [("375", CGSize(width: 375, height: 812), DynamicTypeSize.large),
                                       ("375-large-text", CGSize(width: 375, height: 812), .accessibility2),
                                       ("ipad-width", CGSize(width: 1133, height: 744), .large)] {
            let writes = TestRequests(), directReads = TestRequests()
            let person = socialFixturePerson(following: false)
            var confirmed = person; confirmed.following = true
            let personData = try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(person))])
            let confirmedData = try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed))])
            let mock = KikiAPIMockServer { request in
                if request.url?.path == "/v1/social/people/" + peer { return (200, personData) }
                if request.url?.path == "/v1/social/follows/" + peer {
                    writes.append(request.httpMethod ?? ""); return (200, confirmedData)
                }
                if request.url?.path == "/v1/social/relationships/ids" {
                    return (200, try JSONSerialization.data(withJSONObject: ["followingIDs": writes.values.isEmpty ? [] : [peer], "followingCount": writes.values.isEmpty ? 0 : 1, "followerCount": 0]))
                }
                if request.url?.path == "/v1/social/conversations/" + peer + "/messages" {
                    XCTAssertEqual(request.httpMethod, "GET", "Profile routing validation must never send a DM")
                    directReads.append("page"); return (200, try directIntroductionFixture(remaining: 5))
                }
                return try p1VisualResponse(request, documents: docs)
            }
            let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
            try await withSocialWindow { window in
                let original = window.frame
                window.frame = CGRect(origin: original.origin, size: size)
                let tabs = KikiDirectNavigationFixtureTabs()
                let presenter = UIHostingController(rootView: KikiDirectNavigationFixture(store: store, tabs: tabs)
                    .environment(\.scenePhase, .active).preferredColorScheme(.light))
                window.rootViewController = presenter; window.makeKeyAndVisible()
                store.setAppForeground(true)
                try await self.waitUntil {
                    guard let controller = nativeMainTabController(in: presenter) else { return false }
                    return !navigationControllers(presenter).isEmpty && !nativeMainTabIsHidden(controller)
                }
                let tabController = try XCTUnwrap(nativeMainTabController(in: presenter))
                let initialTabs = nativeMainTabState(tabController)
                XCTAssertEqual(initialTabs.titles, ["语聊", "消息", "我"])
                XCTAssertEqual(initialTabs.selectedIndex, 0)
                let initialTabFrame = nativeMainTabVisibleFrame(tabController, in: window)
                let profile: UIViewController
                if name == "375" {
                    // Exercise SwiftUI's real presentation binding too: the
                    // central UIKit dismissal must reconcile that state.
                    tabs.profile = person
                    try await self.waitUntil {
                        guard let presented = presenter.presentedViewController else { return false }
                        return nativeButtons(presented.view).contains { $0.accessibilityIdentifier == "social.direct.open" }
                    }
                    profile = try XCTUnwrap(presenter.presentedViewController)
                    XCTAssertEqual(tabs.profile?.id, person.id)
                    XCTAssertEqual(tabs.profileDismissals, 0)
                } else {
                    let nativeProfile = UIHostingController(rootView: KikiPublicProfileView(userID: peer, store: store,
                        leadingAction: AnyView(KikiProfileSeatInviteButton(title: "邀请", isBusy: false, isEnabled: true,
                            action: { XCTFail("Rendering a room's profile action must not send an invitation") })))
                        .dynamicTypeSize(typeSize).environment(\.scenePhase, .active).preferredColorScheme(.light))
                    nativeProfile.modalPresentationStyle = .pageSheet
                    nativeProfile.sheetPresentationController?.detents = [.medium(), .large()]
                    nativeProfile.sheetPresentationController?.selectedDetentIdentifier = .medium
                    // Cover both nested sheets and a room-style full-screen
                    // presentation that removes the underlying host from window.
                    let intermediate = UIViewController()
                    intermediate.view.backgroundColor = UIColor(KikiPalette.background)
                    intermediate.modalPresentationStyle = name == "ipad-width" ? .fullScreen : .pageSheet
                    await withCheckedContinuation { continuation in presenter.present(intermediate, animated: false) { continuation.resume() } }
                    await withCheckedContinuation { continuation in intermediate.present(nativeProfile, animated: false) { continuation.resume() } }
                    profile = nativeProfile
                }
                try await self.waitUntil { nativeButtons(profile.view).filter { ["social.direct.open", "social.follow", "social.profile.more"].contains($0.accessibilityIdentifier ?? "") }.count == 3 }
                try await self.waitUntil { !profile.isBeingPresented && profile.transitionCoordinator == nil }
                try await Task.sleep(nanoseconds: 250_000_000)
                profile.view.layoutIfNeeded(); window.layoutIfNeeded()
                if name == "ipad-width" {
                    XCTAssertNil(presenter.viewIfLoaded?.window, "The full-screen fixture must remove the root host from its window")
                    XCTAssertTrue(profile.view.window === window, "The visible profile must still belong to this scene's window")
                }
                let buttons = nativeButtons(profile.view)
                let direct = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "social.direct.open" })
                let follow = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "social.follow" })
                let more = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "social.profile.more" })
                let frames = [direct, follow, more].map { $0.convert($0.bounds, to: profile.view) }
                XCTAssertTrue([direct, follow, more].allSatisfy(\.isEnabled))
                XCTAssertEqual(frames[0].midY, frames[1].midY, accuracy: 1)
                XCTAssertEqual(frames[1].midY, frames[2].midY, accuracy: 1)
                XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX)
                XCTAssertLessThanOrEqual(frames[1].maxX, frames[2].minX)
                XCTAssertTrue(frames.allSatisfy { $0.width >= 44 && $0.height >= 44 && $0.minX >= -1 && $0.maxX <= profile.view.bounds.width + 1 && $0.maxY <= profile.view.bounds.height + 1 })
                for button in [direct, follow] {
                    let label = try XCTUnwrap(button.titleLabel)
                    let titleFrame = label.convert(label.bounds, to: button)
                    // UIButton.Configuration may restore numberOfLines=0 while
                    // laying out a single fitted line. Check visible geometry,
                    // rather than UIKit's internal line-limit implementation.
                    XCTAssertGreaterThan(titleFrame.height, 0)
                    XCTAssertLessThanOrEqual(titleFrame.height, min(button.bounds.height, label.font.lineHeight * 1.25) + 1)
                    XCTAssertGreaterThanOrEqual(titleFrame.minX, -1)
                    XCTAssertLessThanOrEqual(titleFrame.maxX, button.bounds.width + 1)
                    XCTAssertGreaterThanOrEqual(titleFrame.minY, -1)
                    XCTAssertLessThanOrEqual(titleFrame.maxY, button.bounds.height + 1)
                }
                XCTAssertEqual(more.menu?.children.compactMap { ($0 as? UIAction)?.title }, ["举报用户", "拉黑用户"])
                func capture(_ suffix: String) throws {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + "-" + suffix + ".png"))
                    let attachment = XCTAttachment(image: image); attachment.name = device + "-" + name + "-" + suffix; attachment.lifetime = .keepAlways; self.add(attachment)
                }
                try capture("profile")
                follow.sendActions(for: .touchUpInside)
                try await self.waitUntil { writes.values == ["PUT"] && store.isFollowing(person) && follow.isEnabled && follow.configuration?.title == "已关注" }
                let depth = presentedChain(presenter).count
                XCTAssertEqual(depth, name == "375" ? 1 : 2)
                XCTAssertEqual(tabs.selectedTab, 0)
                direct.sendActions(for: .touchUpInside)
                do {
                    try await self.waitUntil {
                        presentedChain(presenter).isEmpty && tabs.selectedTab == 2
                            && store.directConversationPath.map(\.person.id) == [peer]
                            && !directReads.values.isEmpty && !self.socialEditableViews(window).isEmpty
                    }
                } catch {
                    func allControllers(_ value: UIViewController) -> [UIViewController] { [value] + value.children.flatMap(allControllers) }
                    let hosts = allControllers(presenter).compactMap { $0 as? KikiDirectConversationPresenter.Host }
                    print("Navigation fixture diagnostic", name, "pending", store.pendingDirectConversation != nil,
                          "path", store.directConversationPath.map(\.person.id), "tab", tabs.selectedTab,
                          "modalDepth", presentedChain(presenter).count, "reads", directReads.values.count,
                          "inputs", self.socialEditableViews(window).count, "hosts", hosts.count,
                          "hostWindows", hosts.map { $0.viewIfLoaded?.window != nil },
                          "cachedWindows", hosts.map { $0.hostingWindow != nil },
                          "parentDepths", hosts.map { host in var depth = 0; var current = host.parent; while let value = current { depth += 1; current = value.parent }; return depth })
                    try capture("route-failure")
                    throw error
                }
                var navigation = try XCTUnwrap(navigationControllers(presenter).first {
                    $0.viewControllers.count == 2 && $0.topViewController?.navigationItem.title == person.name
                }, "The real messages NavigationStack must push a conversation above its root")
                XCTAssertNil(presenter.presentedViewController, "A private conversation must not remain in a sheet")
                XCTAssertNil(store.pendingDirectConversation)
                if name == "375" {
                    try await self.waitUntil { tabs.profile?.id == nil && tabs.profileDismissals == 1 }
                    XCTAssertNil(tabs.profile, "Imperative dismissal must clear the parent SwiftUI sheet binding")
                    XCTAssertEqual(tabs.profileDismissals, 1, "SwiftUI must acknowledge the actual dismissal once")
                }
                try await self.waitUntil { store.foregroundNotificationContext.conversationPersonID == peer }
                try await self.waitUntil { navigation.transitionCoordinator == nil && navigation.topViewController?.viewIfLoaded?.window === window }
                try await self.waitUntil { nativeMainTabIsHidden(tabController) }
                let tabBarHiddenForConversation = nativeMainTabIsHidden(tabController)
                try capture("direct-pushed")

                store.requestDirectConversation(person)
                try await self.waitUntil { store.pendingDirectConversation?.id == nil }
                XCTAssertEqual(store.directConversationPath.map(\.person.id), [peer])
                XCTAssertEqual(navigation.viewControllers.count, 2, "Opening the same conversation cannot append a second chat")
                XCTAssertNil(presenter.presentedViewController)
                XCTAssertTrue(nativeMainTabIsHidden(tabController))

                // A preserved navigation path in another resident tab must not
                // suppress foreground notices for this conversation.
                tabs.selectedTab = 0
                try await self.waitUntil {
                    store.foregroundNotificationContext.conversationPersonID == nil && !nativeMainTabIsHidden(tabController)
                }
                XCTAssertEqual(store.directConversationPath.map(\.person.id), [peer])
                tabs.selectedTab = 2
                try await self.waitUntil {
                    store.foregroundNotificationContext.conversationPersonID == peer && nativeMainTabIsHidden(tabController)
                }
                navigation = try XCTUnwrap(navigationControllers(presenter).first {
                    $0.viewControllers.count == 2 && $0.topViewController?.navigationItem.title == person.name
                        && $0.topViewController?.viewIfLoaded?.window === window
                }, "The reselected native messages tab must show one pushed conversation")

                XCTAssertNotNil(navigation.popViewController(animated: false), "Use the real navigation controller's system back path")
                try await self.waitUntil {
                    store.directConversationPath.isEmpty && navigation.viewControllers.count == 1
                        && store.foregroundNotificationContext.conversationPersonID == nil
                        && navigation.transitionCoordinator == nil
                        && !nativeMainTabIsHidden(tabController)
                }
                XCTAssertEqual(tabs.selectedTab, 2, "Back returns to the messages list")
                let restoredTabs = nativeMainTabState(tabController)
                XCTAssertEqual(restoredTabs.titles, ["语聊", "消息", "我"])
                XCTAssertEqual(restoredTabs.selectedIndex, 1)
                XCTAssertNil(presenter.presentedViewController, "The old profile sheet must not revive after navigation and tab updates")
                if name == "375" { XCTAssertEqual(tabs.profileDismissals, 1) }
                try capture("messages-after-back")
                manifest.append(["layout": name, "viewportWidth": size.width,
                                 "buttonsStayInOneRow": true, "dismissedNativeSheetDepth": depth,
                                 "rootRemovedFromWindowBeforeRouting": name == "ipad-width",
                                 "swiftUISheetBindingExercised": name == "375", "swiftUISheetDismissals": tabs.profileDismissals,
                                 "messagesTabSelected": true, "nativeConversationPushed": true,
                                 "nativeTabBarHiddenForConversation": tabBarHiddenForConversation,
                                 "nativeTabBarRestoredAfterBack": true,
                                 "initialNativeTabFrame": initialTabFrame.map { NSCoder.string(for: $0) } ?? "System representation outside UITabBar",
                                 "restoredNativeTabFrame": nativeMainTabVisibleFrame(tabController, in: window).map { NSCoder.string(for: $0) } ?? "System representation outside UITabBar",
                                 "nativeTabItemIdentifiers": restoredTabs.identifiers,
                                 "nativeTabItemAccessibilityValues": restoredTabs.accessibilityValues,
                                 "nativeUnobscuredContentFrame": NSCoder.string(for: nativeMainTabContentFrame(tabController, in: window)),
                                 "inactiveTabClearedVisibility": true, "nativeBackReturnedToMessages": true,
                                 "confirmedFollowUpdatedButton": true])
                window.frame = original
            }
            await store.logout()
        }
        let result: [String: Any] = ["scope": "Offline fixtures; production half-sheet view and public UIButton target-actions; no real account or DM send", "device": device, "checks": manifest]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent(device + "-validation.json"))
    }

    func testDirectConversationRequestDeduplicationAndLateCompletionRespectPrivacyAndSession() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        for invalidatesSession in [false, true] {
            let mock = KikiAPIMockServer { try p1VisualResponse($0, documents: docs) }
            let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
            let person = socialFixturePerson(following: false)
            store.requestDirectConversation(person)
            let first = try XCTUnwrap(store.pendingDirectConversation)
            store.requestDirectConversation(person)
            XCTAssertEqual(store.pendingDirectConversation?.id, first.id, "Repeated taps share the in-flight native dismissal")
            XCTAssertTrue(store.isCurrentDirectConversationRequest(first.id))
            XCTAssertTrue(store.completeDirectConversationNavigation(first.id))
            XCTAssertFalse(store.completeDirectConversationNavigation(first.id), "A dismissal completion is consumed once")
            XCTAssertEqual(store.directConversationPath.map(\.person.id), [person.id])

            store.requestDirectConversation(person)
            let repeated = try XCTUnwrap(store.pendingDirectConversation)
            XCTAssertTrue(store.completeDirectConversationNavigation(repeated.id))
            XCTAssertEqual(store.directConversationPath.map(\.person.id), [person.id], "An existing chat is replaced without accumulating history")

            store.requestDirectConversation(person)
            let superseded = try XCTUnwrap(store.pendingDirectConversation)
            store.cancelPendingDirectConversation()
            XCTAssertFalse(store.completeDirectConversationNavigation(superseded.id), "A newer notification intent cancels the older direct handoff")
            XCTAssertEqual(store.directConversationPath.map(\.person.id), [person.id], "Cancelling a pending handoff preserves the current conversation")

            store.requestDirectConversation(person)
            let stale = try XCTUnwrap(store.pendingDirectConversation)
            if invalidatesSession { await store.logout() }
            else { store.socialPolicyChanged(userID: person.id, blocked: true) }
            XCTAssertNil(store.pendingDirectConversation)
            XCTAssertTrue(store.directConversationPath.isEmpty)
            XCTAssertFalse(store.isCurrentDirectConversationRequest(stale.id))
            XCTAssertFalse(store.completeDirectConversationNavigation(stale.id), "An old native completion cannot cross a session or privacy boundary")
            XCTAssertTrue(store.directConversationPath.isEmpty)
            if invalidatesSession {
                store.requestDirectConversation(person)
                XCTAssertNil(store.pendingDirectConversation, "A signed-out page cannot queue navigation")
            } else { await store.logout() }
        }
    }
}

@MainActor
private final class KikiDirectNavigationFixtureTabs: ObservableObject {
    @Published var selectedTab = 0
    @Published var profile: KikiPerson?
    @Published var profileDismissals = 0
}

/// The production inbox owns the NavigationStack and the production bridge
/// owns native dismissal and route consumption. Only tab selection is local.
@MainActor
private struct KikiDirectNavigationFixture: View {
    @ObservedObject var store: KikiAppStore
    @ObservedObject var tabs: KikiDirectNavigationFixtureTabs

    var body: some View {
        KikiMainTabs(selection: $tabs.selectedTab, unreadCount: store.unreadMessageCount,
                     hidesTabBar: tabs.selectedTab == 2 && !store.directConversationPath.isEmpty) {
            NavigationStack { Color.clear }
        } messages: {
            KikiMessagesView(store: store, isActive: tabs.selectedTab == 2)
        } profile: {
            Color.clear
        }
        .sheet(item: $tabs.profile, onDismiss: { tabs.profileDismissals += 1 }) { person in
            KikiPublicProfileView(userID: person.id, store: store).kikiRoomSheet()
        }
        .background(KikiDirectConversationPresenter(store: store, onOpen: { tabs.selectedTab = 2 },
                                                    onOpenRoom: { tabs.selectedTab = 0 }))
        .environmentObject(store)
    }
}

extension KikiConsentTests {
    func testSwitchingAwayFromProfileDuringItsActualRefreshDoesNotShowCancellationToast() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let started = expectation(description: "The visible profile starts its library refresh")
        let cancelled = expectation(description: "Switching tabs cancels the profile URLSession request")
        let requestGate = KikiProfileCancellationRequestGate(started: started, cancelled: cancelled)
        defer { requestGate.release() }
        let mock = KikiConcurrentConsentServer(beforeResponse: { request, id in
            requestGate.suspendProfileRequest(request, id: id)
        }, onStop: { _, id in requestGate.stopped(id) }) { request in
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        XCTAssertTrue(store.isAuthenticated)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let tabs = KikiProfileTabCancellationFixture()
        requestGate.arm()
        window.rootViewController = UIHostingController(rootView: KikiProfileTabCancellationView(tabs: tabs).environmentObject(store))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        await fulfillment(of: [started], timeout: 2)
        tabs.isProfileActive = false
        await fulfillment(of: [cancelled], timeout: 2)
        requestGate.release()
        // URLSession cancellation resumes the production .task, whose remaining
        // refresh calls must complete without publishing a user-facing error.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(store.toast)
        XCTAssertNil(store.loadingError)
        XCTAssertNil(store.libraryError)
        XCTAssertTrue(store.isAuthenticated)
        await store.logout()
    }


}

/// Correlates cancellation to the one library request deliberately suspended
/// after mounting the profile. Other completed/startup requests are irrelevant.
private final class KikiProfileCancellationRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let response = DispatchSemaphore(value: 0)
    private let started: XCTestExpectation
    private let cancelled: XCTestExpectation
    private var armed = false
    private var requestID: UUID?
    private var observedStop = false

    init(started: XCTestExpectation, cancelled: XCTestExpectation) {
        self.started = started; self.cancelled = cancelled
    }
    func arm() { lock.lock(); armed = true; lock.unlock() }
    func suspendProfileRequest(_ request: URLRequest, id: UUID) {
        lock.lock()
        guard armed, requestID == nil, request.url?.path == "/v1/library" else { lock.unlock(); return }
        requestID = id
        lock.unlock()
        started.fulfill()
        _ = response.wait(timeout: .now() + 5)
    }
    func stopped(_ id: UUID) {
        lock.lock()
        guard requestID == id, !observedStop else { lock.unlock(); return }
        observedStop = true
        lock.unlock()
        cancelled.fulfill()
    }
    func release() { response.signal() }
}

@MainActor
private final class KikiProfileTabCancellationFixture: ObservableObject {
    @Published var isProfileActive = true
}

private struct KikiProfileTabCancellationView: View {
    @ObservedObject var tabs: KikiProfileTabCancellationFixture
    var body: some View {
        KikiProfileView(isActive: tabs.isProfileActive)
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
    @Published var isLoggedIn = false
    @Published var isPresentingRoom = false
    var roomPresentationChanges: AnyPublisher<Bool, Never>? { $isPresentingRoom.eraseToAnyPublisher() }
    var currentSDKRoomID: String?
    var lastSessionToken: String?
    var loginCount = 0
    var logoutCount = 0
    var stopCount = 0
    var deferLogin = false
    var roomConnectError: Error?
    var lastRoomAttemptID: String?
    var presentedRoomIDs: [String] = []
    var onPresentRoom: ((String) -> Void)?
    var loginContinuation: CheckedContinuation<Void, Error>?
    func isCurrentRoom(_ roomID: String) -> Bool { currentSDKRoomID == roomID }
    func requireNoActiveRoom() throws { }
    func login(credentials: KikiSDKCredentials, sessionToken: String) async throws {
        lastSessionToken = sessionToken
        loginCount += 1
        if deferLogin { try await withCheckedThrowingContinuation { loginContinuation = $0 } }
        isLoggedIn = true
    }
    func logout() async { logoutCount += 1; isLoggedIn = false }
    func stopMediaForPrivacy() { stopCount += 1; isPresentingRoom = false; currentSDKRoomID = nil }
    func logoutForPrivacy() async throws { await logout() }
    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws { }
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws {
        lastRoomAttemptID = KikiIncidentContext.attempt?.id
        KikiIncidentContext.attempt?.enter(.mediaConnect)
        if let roomConnectError { throw roomConnectError }
    }
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws {
        lastRoomAttemptID = KikiIncidentContext.attempt?.id
        KikiIncidentContext.attempt?.enter(.mediaConnect)
        if let roomConnectError { throw roomConnectError }
        presentedRoomIDs.append(roomID)
        onPresentRoom?(roomID)
    }
}

private final class TestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func consentResponse(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data) {
    let user: [String: Any] = ["id": "legal_qa", "sdkUserID": "sdk_qa", "name": "测试昵称", "bio": "", "avatarIndex": 0, "notificationsEnabled": false, "needsNickname": false]
    let sdk: [String: Any] = ["provider": "livekit", "serverURL": "wss://furby.top", "userID": "sdk_qa", "expiresAt": 2_000_000_000]
    let body: [String: Any]
    switch request.url!.path {
    case "/v1/me/legal-consent":
        if request.httpMethod == "DELETE" { body = ["ok": true] }
        else { body = ["requiredVersions": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash], "requiresAcceptance": false, "legalConsent": ["privacyVersion": documents.privacyVersion, "termsVersion": documents.termsVersion, "documentHash": documents.documentHash, "acceptedAt": 1_792_180_000, "withdrawnAt": NSNull()]] }
    case "/v1/auth/refresh": body = ["user": user]
    case "/v1/voice/session": body = ["token": "voice-session", "expiresAt": 2_000_000_000, "user": user, "sdk": sdk]
    case "/v1/rooms": body = ["rooms": []]
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


extension KikiConsentTests {
    func testCreateReservationAndMediaConnectShareOneAttemptAndJoinStartsANewAttempt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var received: [KikiIncident] = []
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { event, _ in received.append(event) })
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let attempts = TestRequests()
        let roomID = "lk_" + String(repeating: "b", count: 32)
        let roomBody: [String: Any] = ["id": roomID, "title": "private-title", "host": "private-host", "hostID": "sdk_qa", "category": "随心聊", "audience": 0, "isLive": false, "theme": 0, "isCreatedByMe": true, "status": "draft", "createdAt": 1_800_000_000]
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/rooms", request.httpMethod == "POST" {
                attempts.append(request.value(forHTTPHeaderField: "X-Kiki-Attempt-ID") ?? "missing")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiki-Operation"), "create_room")
                return (200, try JSONSerialization.data(withJSONObject: roomBody))
            }
            if request.url?.path == "/v1/rooms/" + roomID { return (200, try JSONSerialization.data(withJSONObject: roomBody)) }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC(); rtc.roomConnectError = KikiTransportFailure(code: .requestTimeout)
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() }, incidents: outbox)
        await store.start()
        let reserved = try await store.reserveRoom(title: "private-title", category: "随心聊", isLive: false, theme: 0)
        do { try await store.startRoom(reserved); XCTFail("Media failure expected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("问题编号")) }
        XCTAssertEqual(rtc.lastRoomAttemptID, attempts.values.first)
        do { try await store.openRoom(reserved); XCTFail("Join failure expected") }
        catch { }
        XCTAssertNotEqual(rtc.lastRoomAttemptID, attempts.values.first)
        await outbox.flushNow()
        XCTAssertEqual(received.map(\.operation), [.createRoom, .joinRoom])
        XCTAssertEqual(received.map(\.stage), [.mediaConnect, .mediaConnect])
        XCTAssertEqual(received.map(\.code), [.requestTimeout, .requestTimeout])
        XCTAssertEqual(received.first?.attemptID, attempts.values.first)
        await store.logout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExpiredVoiceSessionExchangeIsReportedAtAccountAuthorizationStage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var received: [KikiIncident] = []
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { event, _ in received.append(event) })
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let exchanges = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/voice/session" {
                exchanges.append(request.value(forHTTPHeaderField: "X-Kiki-Attempt-ID") ?? "missing")
                if exchanges.values.count > 1 {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "X-Kiki-Operation"), "join_room")
                    throw URLError(.timedOut)
                }
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let rtc = TestRTC()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { rtc }, appleProvider: { TestApple() }, incidents: outbox)
        await store.start(); rtc.isLoggedIn = false
        let room = KikiRoom(id: "lk_" + String(repeating: "c", count: 32), title: "room", host: "host", hostID: "other", category: "随心聊", audience: 0, isLive: false, theme: 0, isCreatedByMe: false, status: "live", createdAt: 1_800_000_000)
        do { try await store.openRoom(room); XCTFail("Exchange timeout expected") }
        catch { }
        await outbox.flushNow()
        XCTAssertEqual(received.first?.operation, .joinRoom)
        XCTAssertEqual(received.first?.stage, .accountAuthorization)
        XCTAssertEqual(received.first?.code, .requestTimeout)
        XCTAssertEqual(received.first?.attemptID, exchanges.values.last)
        XCTAssertNil(rtc.lastRoomAttemptID, "The media SDK must never connect after authorization exchange failed")
        await store.logout()
    }
}


extension KikiConsentTests {
    func testSuccessfulMediaConnectionDoesNotDependOnRedundantLivePatchOrHistory() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("queue.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        var received: [KikiIncident] = []
        let outbox = KikiIncidentReporter(queueURL: file, automaticRetry: false, sender: { event, _ in received.append(event) })
        let identity = TestIdentity(values: ["sessionToken": "account-only", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let roomID = "lk_" + String(repeating: "d", count: 32)
        let roomBody: [String: Any] = ["id": roomID, "title": "room", "host": "host", "hostID": "sdk_qa", "category": "随心聊", "audience": 0, "isLive": false, "theme": 0, "isCreatedByMe": true, "status": "live", "createdAt": 1_800_000_000]
        let mock = KikiAPIMockServer { request in
            if request.httpMethod == "PATCH", request.url?.path == "/v1/rooms/" + roomID {
                XCTFail("POST already activates the room; an unnecessary live PATCH must not determine UI success")
                return (503, Data())
            }
            if request.url?.path == "/v1/rooms", request.httpMethod == "POST" { return (200, try JSONSerialization.data(withJSONObject: roomBody)) }
            if request.url?.path == "/v1/history/" + roomID { throw URLError(.timedOut) }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() }, incidents: outbox)
        await store.start()
        let room = try await store.reserveRoom(title: "room", category: "随心聊", isLive: false, theme: 0)
        try await store.startRoom(room)
        await outbox.flushNow()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.operation, .runtime)
        XCTAssertEqual(received.first?.severity, .warning)
        XCTAssertEqual(received.first?.code, .requestTimeout)
        XCTAssertTrue(store.toast?.contains("已创建房间") == true)
        await store.logout()
    }
}

extension KikiConsentTests {
    func testDirectMessageFailureKeepsDraftAndRetriesSameRequestBeforeClearing() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/kiki_target0000/messages" {
                let body = try requestBody(request)
                requests.append(try XCTUnwrap(body["requestID"] as? String))
                XCTAssertEqual(body["text"] as? String, "你好")
                if requests.values.count == 1 { return (503, Data(#"{"detail":"尚未确认"}"#.utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: ["message": ["id": UUID().uuidString, "seq": 1, "senderID": "legal_qa", "text": "你好", "createdAt": 1_792_400_000], "conversationID": UUID().uuidString]))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        store.updateDirectDraft("你好", personID: "kiki_target0000")
        do { _ = try await store.sendDirectDraft("kiki_target0000"); XCTFail("First attempt should fail") } catch { }
        XCTAssertEqual(store.directDrafts["kiki_target0000"], "你好")
        XCTAssertNotNil(store.pendingDirectMessages["kiki_target0000"])
        store.updateDirectDraft("changed", personID: "kiki_target0000")
        XCTAssertEqual(store.directDrafts["kiki_target0000"], "你好", "Unconfirmed retry body must remain immutable")
        _ = try await store.sendDirectDraft("kiki_target0000")
        XCTAssertEqual(requests.values.count, 2)
        XCTAssertEqual(Set(requests.values).count, 1)
        XCTAssertNil(store.pendingDirectMessages["kiki_target0000"])
        XCTAssertNil(store.directDrafts["kiki_target0000"])
        await store.logout()
    }

    func testLogoutClearsSocialDraftsAndDeniesUnauthenticatedSocialRequests() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try consentResponse($0, documents: docs) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        store.updateDirectDraft("仅当前账号可见", personID: "kiki_target0000")
        await store.logout()
        XCTAssertTrue(store.directDrafts.isEmpty)
        XCTAssertTrue(store.pendingDirectMessages.isEmpty)
        XCTAssertTrue(store.followingUserIDs.isEmpty)
        XCTAssertEqual(store.unreadMessageCount, 0)
        do { _ = try await store.socialPeople(); XCTFail("Logged out account cannot request social data") } catch { }
    }
}

extension KikiConsentTests {
    func testP1NativeScreenshotsWithAuthenticatedFixtures() async throws {
        let identity = TestIdentity(values: ["sessionToken": "fixture-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in try p1VisualResponse(request, documents: docs, expandsRoomList: true) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start(); await store.refreshRooms(); await store.refreshSocialSummary()
        XCTAssertTrue(store.isAuthenticated)
        let person = try await store.socialPerson("kiki_fixture0002")
        let inboxPage = try await store.socialInbox()
        XCTAssertEqual(inboxPage.entries.count, 2, "The main inbox fixture must contain a private conversation and an individual interaction")
        let screens: [(String, AnyView)] = [
            ("rooms-light", mainTabVisualScreen(AnyView(KikiDiscoverView().environmentObject(store).preferredColorScheme(.light)))),
            ("create-room-light", AnyView(KikiCreateRoomView(isLive: false, onCreate: { _ in XCTFail("Visual fixtures must not create a room") }).environmentObject(store).preferredColorScheme(.light))),
            ("messages-unified-light", mainTabVisualScreen(AnyView(KikiMessagesView(store: store).environment(\.scenePhase, .active).preferredColorScheme(.light)))),
            ("person-light", AnyView(KikiPublicProfileView(userID: person.id, store: store).preferredColorScheme(.light))),
            ("direct-light", AnyView(NavigationStack {
                KikiDirectConversationView(person: person, store: store)
            }.preferredColorScheme(.light))),
            ("profile-light", mainTabVisualScreen(AnyView(KikiProfileView().environmentObject(store).preferredColorScheme(.light)))),
            ("profile-dark", mainTabVisualScreen(AnyView(KikiProfileView().environmentObject(store).preferredColorScheme(.dark)))),
            ("create-room-dark", AnyView(KikiCreateRoomView(isLive: false, onCreate: { _ in XCTFail("Visual fixtures must not create a room") }).environmentObject(store).preferredColorScheme(.dark))),
            ("profile-large-text", mainTabVisualScreen(AnyView(KikiProfileView().environmentObject(store).preferredColorScheme(.light).dynamicTypeSize(.accessibility1))))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer { window.frame = originalFrame; window.isHidden = true; previous?.makeKeyAndVisible() }
        let folder = URL(fileURLWithPath: "/tmp/kiki-p1-screenshots", isDirectory: true)
        let layoutFolder = URL(fileURLWithPath: "/tmp/kiki-ipad-layout-screenshots", isDirectory: true)
        for output in [folder, layoutFolder] {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"

        func capture(_ name: String, screen: AnyView, size: CGSize? = nil, output: URL) async throws {
            defer { window.frame = originalFrame }
            window.rootViewController = UIHostingController(rootView: screen)
            window.makeKeyAndVisible()
            window.frame = size.map { CGRect(origin: originalFrame.origin, size: $0) } ?? originalFrame
            window.rootViewController?.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 650_000_000)
            window.layoutIfNeeded()
            XCTAssertGreaterThan(window.bounds.width, 300)
            if let size {
                XCTAssertEqual(window.frame.width, size.width, accuracy: 0.5, name)
                XCTAssertEqual(window.frame.height, size.height, accuracy: 0.5, name)
                XCTAssertEqual(window.rootViewController?.view.bounds.size, size, name)
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent(device + "-" + name + ".png"))
        }

        for (name, screen) in screens {
            try await capture(name, screen: screen, output: folder)
        }
        // Render the room without joining: the empty view has no startup task or connection action.
        let layoutScreens = screens.filter { ["rooms-light", "create-room-light", "direct-light"].contains($0.0) }
            + [("room-empty-dark", AnyView(KikiLiveKitRoomView(rtc: .shared)))]
        let sizes = [CGSize(width: 375, height: 812), CGSize(width: 744, height: 1133),
                     CGSize(width: 1133, height: 744), CGSize(width: 375, height: 600)]
        for size in sizes {
            for (name, screen) in layoutScreens {
                let name = "\(name)-\(Int(size.width))x\(Int(size.height))"
                try await capture(name, screen: screen, size: size, output: layoutFolder)
            }
        }
        await store.logout()
    }

    func testMainTabsUseNativeTabBarAndKeepLastContentReachableWhileScrolling() async throws {
        let identity = TestIdentity(values: ["sessionToken": "fixture-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            XCTAssertTrue(request.url?.host?.hasSuffix("example.invalid") == true,
                          "Top chrome fixtures must never use a real account or server")
            let (status, data) = try p1VisualResponse(request, documents: docs, expandsRoomList: true)
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch request.url?.path {
            case "/v1/rooms":
                let originals = try XCTUnwrap(body["rooms"] as? [[String: Any]])
                body["rooms"] = (0..<24).map { index -> [String: Any] in
                    var room = originals[index % originals.count]
                    room["id"] = "lk_" + String(format: "%032x", index + 1)
                    return room
                }
            case "/v1/social/inbox":
                let originals = try XCTUnwrap(body["entries"] as? [[String: Any]])
                body["entries"] = try (0..<24).map { index -> [String: Any] in
                    var entry = originals[index % originals.count]
                    let key = entry["kind"] as? String == "direct" ? "conversation" : "notification"
                    var item = try XCTUnwrap(entry[key] as? [String: Any])
                    item["id"] = String(format: "%08x-0000-4000-8000-%012x", index + 1, index + 1)
                    entry[key] = item
                    return entry
                }
                body["unreadDirectMessageCount"] = 12
                body["unreadNotificationCount"] = 12
            default: break
            }
            return (status, try JSONSerialization.data(withJSONObject: body))
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity,
                                       apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client },
                                 voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start(); await store.refreshRooms(); await store.refreshSocialSummary()
        XCTAssertTrue(store.isAuthenticated)
        let pages: [(String, AnyView)] = [
            ("rooms", AnyView(KikiDiscoverView().environmentObject(store))),
            ("messages", AnyView(KikiMessagesView(store: store).environment(\.scenePhase, .active))),
            ("profile", AnyView(KikiProfileView().environmentObject(store)))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let folder = URL(fileURLWithPath: "/tmp/kiki-native-tabs-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        var manifest: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent(device + "-geometry.json"))
            }
        }

        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        func visibleBar(in root: UIView) throws -> UINavigationBar {
            try XCTUnwrap(descendants(root).compactMap { $0 as? UINavigationBar }.first {
                !$0.isHidden && $0.alpha > 0.9 && $0.bounds.height > 20
            }, "The real page must retain its native navigation toolbar")
        }
        func checkTabItems(_ controller: UITabBarController) {
            let state = nativeMainTabState(controller)
            XCTAssertEqual(state.titles, ["语聊", "消息", "我"])
            XCTAssertEqual(state.selectedIndex, 0)
            guard state.badges.count == 3 else { XCTFail("The native tabs must expose all three badge values"); return }
            if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertEqual(state.badges[1], "", "Text-only iPad tabs retain an unread badge")
            } else {
                XCTAssertNil(state.badges[1], "Unread messages use the compact dot in the tab icon")
            }
            XCTAssertFalse(nativeMainTabIsHidden(controller), "Scrolling the main pages must retain the system tab interface")
        }
        @discardableResult
        func capture(_ name: String, topInset: CGFloat) throws -> UIImage {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
            // Retain a crop of the system status region and native toolbar.
            let top = UIGraphicsImageRenderer(size: CGSize(width: image.size.width, height: topInset + 44)).image { _ in
                image.draw(at: .zero)
            }
            let cropped = XCTAttachment(image: top); cropped.name = name + "-top"; cropped.lifetime = .keepAlways; add(cropped)
            try XCTUnwrap(top.pngData()).write(to: folder.appendingPathComponent(name + "-top.png"))
            return image
        }
        func clipAncestry(_ view: UIView) -> [[String: Any]] {
            var result: [[String: Any]] = [], ancestor: UIView? = view
            while let current = ancestor {
                result.append(["type": String(describing: type(of: current)), "clips": current.clipsToBounds,
                               "frame": NSCoder.string(for: current.convert(current.bounds, to: window))])
                ancestor = current.superview
            }
            return result
        }
        for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            for (name, page) in pages {
                let host = UIHostingController(rootView: mainTabVisualScreen(page).preferredColorScheme(scheme))
                host.safeAreaRegions = .all
                window.rootViewController = host
                // A compact real scene window keeps every production page,
                // including the shorter Profile, genuinely scrollable on both device idioms.
                window.frame = CGRect(origin: originalFrame.origin,
                                      size: CGSize(width: originalFrame.width, height: min(originalFrame.height, name == "profile" ? 320 : 640)))
                window.makeKeyAndVisible(); host.view.frame = window.bounds
                try await Task.sleep(nanoseconds: 750_000_000)
                window.layoutIfNeeded()
                let topInset = host.view.safeAreaInsets.top
                XCTAssertGreaterThan(topInset, 0, "The fixture must preserve the scene's real status safe area")
                XCTAssertFalse(descendants(host.view).contains { $0.accessibilityIdentifier == "main.statusBackdrop" },
                               "The native tab container must not restore a custom status-area blur")
                let tabController = try XCTUnwrap(nativeMainTabController(in: host), "The three destinations must use the system UITabBarController")
                checkTabItems(tabController)
                let tabFrame = nativeMainTabVisibleFrame(tabController, in: window)
                if let tabFrame { XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(tabFrame)) }
                let prefix = device + "-" + name + "-" + schemeName
                try capture(prefix + "-initial", topInset: topInset)
                do {
                    let scroll = try XCTUnwrap(socialScrollViews(host.view).filter {
                        !($0 is UITextView) && $0.bounds.height > 100
                            && $0.contentSize.height + $0.adjustedContentInset.top + $0.adjustedContentInset.bottom > $0.bounds.height + 100
                    }.max { $0.contentSize.height < $1.contentSize.height }, "\(name) must display real scrollable fixture content")
                    let beforeOffset = scroll.contentOffset.y
                    let bar = name == "rooms" ? nil : try visibleBar(in: host.view)
                    let beforeBar = bar.map { $0.convert($0.bounds, to: window) }
                    let end = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(end, beforeOffset + 160)), animated: false)
                    try await Task.sleep(nanoseconds: 250_000_000)
                    window.layoutIfNeeded()
                    XCTAssertGreaterThan(scroll.contentOffset.y, beforeOffset + 80, "\(name) must actually scroll before checking fixed controls")
                    XCTAssertEqual(host.view.safeAreaInsets.top, topInset, accuracy: 0.5)
                    if let bar, let beforeBar {
                        XCTAssertTrue(try visibleBar(in: host.view) === bar)
                        let afterBar = bar.convert(bar.bounds, to: window)
                        XCTAssertEqual(afterBar.minX, beforeBar.minX, accuracy: 1, name)
                        XCTAssertEqual(afterBar.minY, beforeBar.minY, accuracy: 1, name)
                        XCTAssertEqual(afterBar.width, beforeBar.width, accuracy: 1, name)
                        XCTAssertEqual(afterBar.height, beforeBar.height, accuracy: 1, name)
                    }
                    // iOS 26 can render SwiftUI toolbar actions in floating
                    // siblings outside UINavigationBar. The bar assertions do
                    // not verify those buttons' frames: compare each initial /
                    // scrolled screenshot pair, including profile.settings.
                    XCTAssertTrue(nativeMainTabController(in: host) === tabController)
                    checkTabItems(tabController)
                    try capture(prefix + "-scrolled", topInset: topInset)
                    for _ in 0..<3 {
                        let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: bottom), animated: false)
                        try await Task.sleep(nanoseconds: 80_000_000)
                        window.layoutIfNeeded()
                    }
                    let rawContentBottom = scroll.convert(CGPoint(x: 0, y: scroll.contentSize.height), to: window).y
                    let lastRowFrame: CGRect?
                    if let collection = scroll as? UICollectionView {
                        let section = try XCTUnwrap((0..<collection.numberOfSections).reversed().first {
                            collection.numberOfItems(inSection: $0) > 0
                        }, "The real List must expose its final populated section")
                        let indexPath = IndexPath(item: collection.numberOfItems(inSection: section) - 1, section: section)
                        let attributes = try XCTUnwrap(collection.collectionViewLayout.layoutAttributesForItem(at: indexPath),
                            "The final real List row must have public layout attributes")
                        lastRowFrame = collection.convert(attributes.frame, to: window)
                    } else if let table = scroll as? UITableView {
                        let section = try XCTUnwrap((0..<table.numberOfSections).reversed().first {
                            table.numberOfRows(inSection: $0) > 0
                        }, "The real List must expose its final populated section")
                        let indexPath = IndexPath(row: table.numberOfRows(inSection: section) - 1, section: section)
                        lastRowFrame = table.convert(table.rectForRow(at: indexPath), to: window)
                    } else {
                        lastRowFrame = nil
                        if name == "messages" { XCTFail("The native messages List must expose public collection/table row geometry") }
                    }
                    let contentBottom = lastRowFrame?.maxY ?? rawContentBottom
                    let finalTabFrame = nativeMainTabVisibleFrame(tabController, in: window)
                    let nativeContentFrame = nativeMainTabContentFrame(tabController, in: window)
                    let scrollFrame = scroll.convert(scroll.bounds, to: window)
                    XCTAssertGreaterThan(nativeContentFrame.height, 100, "The system must expose its unobscured content area")
                    XCTAssertLessThanOrEqual(contentBottom, min(nativeContentFrame.maxY, scrollFrame.maxY) + 2,
                                             "The final real content must remain reachable inside the system's unobscured content area")
                    if let finalTabFrame {
                        if finalTabFrame.midY >= window.bounds.midY {
                            XCTAssertLessThanOrEqual(contentBottom, finalTabFrame.minY + 2,
                                                     "The final real content must remain reachable above the native bottom tab bar")
                        } else {
                            XCTAssertGreaterThanOrEqual(scrollFrame.minY + scroll.adjustedContentInset.top, finalTabFrame.maxY - 2)
                        }
                    }
                    try capture(prefix + "-last-content", topInset: topInset)
                    manifest.append(["page": name, "scheme": schemeName, "statusHeight": topInset,
                                     "window": NSCoder.string(for: window.bounds), "scrollBefore": beforeOffset,
                                     "scrollAfter": scroll.contentOffset.y, "navigationBar": beforeBar.map { NSCoder.string(for: $0) } ?? "none",
                                     "scrollWindowFrame": NSCoder.string(for: scroll.convert(scroll.bounds, to: window)),
                                     "scrollClipAncestry": clipAncestry(scroll),
                                     "scrollContentInset": String(describing: scroll.adjustedContentInset),
                                     "tabContainer": tabFrame.map { NSCoder.string(for: $0) } ?? "System representation outside UITabBar", "contentBottomAtEnd": contentBottom,
                                     "nativeTabFrameAtEnd": finalTabFrame.map { NSCoder.string(for: $0) } ?? "System representation outside UITabBar",
                                     "nativeUnobscuredContentFrame": NSCoder.string(for: nativeContentFrame),
                                     "nativeTabBarHidden": nativeMainTabIsHidden(tabController),
                                     "nativeTabItemIdentifiers": nativeMainTabState(tabController).identifiers,
                                     "nativeTabItemAccessibilityValues": nativeMainTabState(tabController).accessibilityValues,
                                     "customStatusBackdropPresent": false,
                                     "rawContentBottomAtEnd": rawContentBottom,
                                     "actualLastRowFrame": lastRowFrame.map { NSCoder.string(for: $0) } ?? "non-List ScrollView",
                                     "trailingActionVerification": "Manual comparison of initial and scrolled screenshots; native bar frame is not the button frame"])
                } catch {
                    let hierarchy = descendants(host.view).map {
                        "\(type(of: $0)) frame=\($0.convert($0.bounds, to: window)) hidden=\($0.isHidden) alpha=\($0.alpha)"
                    }.joined(separator: "\n")
                    let attachment = XCTAttachment(string: hierarchy); attachment.name = prefix + "-native-hierarchy"; attachment.lifetime = .keepAlways; add(attachment)
                    throw error
                }
            }
        }
        await store.logout()
    }
}

@MainActor
private func nativeMainTabController(in root: UIViewController) -> UITabBarController? {
    if let controller = root as? UITabBarController { return controller }
    for child in root.children {
        if let controller = nativeMainTabController(in: child) { return controller }
    }
    return nil
}

private struct KikiNativeMainTabState {
    let titles: [String]
    let selectedIndex: Int?
    let badges: [String?]
    let identifiers: [String]
    let accessibilityValues: [String]
}

@MainActor
private func nativeMainTabState(_ controller: UITabBarController) -> KikiNativeMainTabState {
    // iPad's native top representation need not attach the legacy UITabBar.
    // Inspect the public controller models rather than a private rendered view.
    if #available(iOS 18.0, *), !controller.tabs.isEmpty {
        let tabs = controller.tabs
        return KikiNativeMainTabState(titles: tabs.map(\.title),
            selectedIndex: tabs.firstIndex { $0 === controller.selectedTab }, badges: tabs.map(\.badgeValue),
            identifiers: tabs.map { $0.accessibilityIdentifier ?? "nil" },
            accessibilityValues: tabs.map { $0.accessibilityValue ?? "nil" })
    }
    let items = controller.tabBar.items ?? []
    return KikiNativeMainTabState(titles: items.map { $0.title ?? "" },
        selectedIndex: items.firstIndex { $0 === controller.tabBar.selectedItem }, badges: items.map(\.badgeValue),
        identifiers: items.map { $0.accessibilityIdentifier ?? "nil" },
        accessibilityValues: items.map { $0.accessibilityValue ?? "nil" })
}

@MainActor
private func nativeMainTabIsHidden(_ controller: UITabBarController) -> Bool {
    if #available(iOS 18.0, *) { return controller.isTabBarHidden }
    return controller.tabBar.isHidden
}

@MainActor
private func nativeMainTabVisibleFrame(_ controller: UITabBarController, in window: UIWindow) -> CGRect? {
    let bar = controller.tabBar
    guard bar.window === window else { return nil }
    var ancestor: UIView? = bar
    while let current = ancestor {
        if current.isHidden || current.alpha < 0.01 { return nil }
        ancestor = current.superview
    }
    let frame = bar.convert(bar.bounds, to: window)
    return frame.intersection(window.bounds).height > 10 ? frame : nil
}

@MainActor
private func nativeMainTabContentFrame(_ controller: UITabBarController, in window: UIWindow) -> CGRect {
    let frame: CGRect
    if #available(iOS 26.0, *) { frame = controller.contentLayoutGuide.layoutFrame }
    else { frame = controller.view.safeAreaLayoutGuide.layoutFrame }
    return controller.view.convert(frame, to: window).intersection(window.bounds)
}

@MainActor
private func mainTabVisualScreen(_ page: AnyView) -> AnyView {
    AnyView(KikiMainTabs(selection: .constant(0), unreadCount: 3) {
        page
    } messages: {
        Color.clear
    } profile: {
        Color.clear
    })
}

private func p1VisualResponse(_ request: URLRequest, documents: KikiLegalBundle, expandsRoomList: Bool = false) throws -> (Int, Data) {
    let me = "kiki_fixture0001", other = "kiki_fixture0002"
    let person: [String: Any] = ["id": other, "name": "小岛", "bio": "喜欢散步和音乐，来聊聊今天的小事。", "avatarIndex": 4, "avatarURL": NSNull(), "following": true, "followsYou": true, "mutual": true, "followingCount": 12, "followerCount": 18, "currentRoomID": "lk_" + String(repeating: "a", count: 32)]
    var myself = person; myself["id"] = me; myself["name"] = "穷奇"; myself["bio"] = "听见，同频的你。"; myself["followingCount"] = 12; myself["followerCount"] = 18
    let time = Date().timeIntervalSince1970
    let room: [String: Any] = ["id": "lk_" + String(repeating: "a", count: 32), "title": "今晚聊点轻松的", "host": "小岛", "hostID": other, "category": "生活", "audience": 6, "isLive": false, "theme": 0, "isCreatedByMe": false, "status": "live", "createdAt": Int(time - 3600), "hostAvatarIndex": 4]
    let message: [String: Any] = ["id": "22222222-2222-4222-8222-222222222222", "seq": 1, "senderID": other, "text": "晚上好，刚刚房间里聊得很开心。", "createdAt": time - 120]
    let notice: [String: Any] = ["id": "44444444-4444-4444-8444-444444444444", "kind": "follow", "actor": person,
                                "text": "小岛关注了你", "createdAt": time - 500, "readAt": NSNull(), "roomID": NSNull()]
    let conversation: [String: Any] = ["id": "55555555-5555-4555-8555-555555555555", "person": person,
                                      "lastMessage": message, "unreadCount": 1, "canSend": true]
    let path = request.url!.path
    let body: [String: Any]
    switch path {
    case "/v1/rooms":
        var rooms = [room]
        if expandsRoomList {
            let titles = ["今晚一起聊聊生活里的小确幸和那些值得记住的瞬间", "戴上耳机听一首歌，再分享今天最想说的一句话",
                          "游戏结束后来复盘，认识一些同频的新朋友", "周末散步计划", "睡前晚安电台"]
            for (index, title) in titles.enumerated() {
                var additionalRoom = room
                additionalRoom["id"] = "lk_" + String(repeating: String(index + 1), count: 32)
                additionalRoom["title"] = title
                additionalRoom["theme"] = index + 1
                additionalRoom["audience"] = 12 + index * 3
                rooms.append(additionalRoom)
            }
        }
        body = ["rooms": rooms]
    case "/v1/library": body = ["favorites": [room], "recents": [room], "created": []]
    case "/v1/social/people/" + other: body = ["person": person]
    case "/v1/social/people/" + me: body = ["person": myself]
    case "/v1/social/people", "/v1/social/relationships": body = ["people": [person], "nextCursor": NSNull()]
    case "/v1/social/relationships/ids": body = ["followingIDs": [other], "followingCount": 12, "followerCount": 18]
    case "/v1/social/notifications": body = ["notifications": [notice], "unreadCount": 1, "nextCursor": NSNull(), "retentionDays": 30]
    case "/v1/social/conversations": body = ["conversations": [conversation], "nextCursor": NSNull(), "unreadCount": 1]
    case "/v1/social/inbox": body = ["entries": [["kind": "direct", "conversation": conversation], ["kind": "notification", "notification": notice]],
                                    "nextCursor": NSNull(), "unreadNotificationCount": 1, "unreadDirectMessageCount": 1]
    case "/v1/social/inbox/snapshot": body = ["snapshot": "visual-fixture-snapshot"]
    case "/v1/social/inbox/read", "/v1/social/inbox/clear": body = ["ok": true]
    case "/v1/social/conversations/" + other + "/messages": body = ["conversationID": "55555555-5555-4555-8555-555555555555", "messages": [message], "nextCursor": NSNull(), "canSend": true, "unreadCount": 1]
    case "/v1/social/conversations/" + other + "/read", "/v1/social/notifications/read": body = ["unreadCount": 0]
    default:
        let (status, raw) = try consentResponse(request, documents: documents)
        var fallback = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        if var user = fallback["user"] as? [String: Any] { user["id"] = me; user["sdkUserID"] = me; user["name"] = "穷奇"; fallback["user"] = user }
        if var sdk = fallback["sdk"] as? [String: Any] { sdk["userID"] = me; fallback["sdk"] = sdk }
        return (status, try JSONSerialization.data(withJSONObject: fallback))
    }
    return (200, try JSONSerialization.data(withJSONObject: body))
}

extension KikiConsentTests {
    func testExplicitDirectMessageRejectionKeepsEditableDraft() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/kiki_target0000/messages" { return (422, Data(#"{"detail":"请修改文字后重试"}"#.utf8)) }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        store.updateDirectDraft("原来的文字", personID: "kiki_target0000")
        do { _ = try await store.sendDirectDraft("kiki_target0000"); XCTFail("Expected rejection") } catch { }
        XCTAssertNil(store.pendingDirectMessages["kiki_target0000"])
        XCTAssertEqual(store.directDrafts["kiki_target0000"], "原来的文字")
        store.updateDirectDraft("修改后的文字", personID: "kiki_target0000")
        XCTAssertEqual(store.directDrafts["kiki_target0000"], "修改后的文字")
        await store.logout()
    }
}

extension KikiConsentTests {
    func testBlockPrivacyRevisionRejectsLateSocialResponse() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let arrived = expectation(description: "Social request is in flight")
        let gate = DispatchSemaphore(value: 0)
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/people" {
                arrived.fulfill(); _ = gate.wait(timeout: .now() + 5)
                return (200, Data(#"{"people":[],"nextCursor":null}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        let pending = Task { try await store.socialPeople() }
        await fulfillment(of: [arrived], timeout: 3)
        let epoch = store.socialPrivacyRevision
        store.socialPolicyChanged(userID: "kiki_target0000", blocked: true)
        XCTAssertGreaterThan(store.socialPrivacyRevision, epoch)
        gate.signal()
        do { _ = try await pending.value; XCTFail("A response requested before the block must not repopulate UI state") }
        catch { XCTAssertTrue(error is CancellationError) }
        await store.logout()
    }

}

extension KikiConsentTests {
    func testRoomAndSafetyBlockEntrypointUsesAccountRouteForBothDirections() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mutations = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/blocks/kiki_target0000" {
                XCTAssertFalse(request.url!.host!.hasPrefix("voice-"), "Production block must use the account route that removes follows")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
                let body = try requestBody(request)
                XCTAssertEqual(Set(body.keys), ["requestID"])
                XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(body["requestID"] as? String)))
                mutations.append(request.httpMethod ?? "")
                return (200, Data(#"{"ok":true,"blocked":true}"#.utf8))
            }
            XCTAssertFalse(request.url?.path.hasPrefix("/v1/blocks") == true, "Never bypass account follow cleanup through the old voice mutation")
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        let rtc = KikiRTCService.shared
        let previous = rtc.socialStore
        rtc.socialStore = store
        defer { rtc.socialStore = previous }
        let revision = store.socialPrivacyRevision
        try await rtc.setBlocked("kiki_target0000", enabled: true)
        try await rtc.setBlocked("kiki_target0000", enabled: false)
        XCTAssertEqual(mutations.values, ["PUT", "DELETE"])
        XCTAssertEqual(store.socialPrivacyRevision, revision + 2)
        XCTAssertFalse(rtc.isUpdatingBlock)
        await store.logout()
    }
}

@MainActor
private final class TestPushSystem: KikiPushSystem {
    var status = KikiPushPermission.authorized
    var requested = 0, registered = 0, unregistered = 0, cleared = 0, badge = 0
    var onRegister: (() -> Void)?
    func permission() async -> KikiPushPermission { status }
    func requestPermission() async throws { requested += 1; status = .authorized }
    func register() { registered += 1; onRegister?() }
    func unregister() { unregistered += 1 }
    func setBadge(_ count: Int) { badge = count }
    func clearNotifications() { cleared += 1; badge = 0 }
}

private final class TestPushServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled = true, _registered = false
    private var _puts: [Int64] = [], _deletes: [Int64] = [], _resolves = 0
    private var _routeType = "direct_message"
    var routeGate: DispatchSemaphore?
    var onResolve: (() -> Void)?
    var enabled: Bool { get { lock.lock(); defer { lock.unlock() }; return _enabled } set { lock.lock(); _enabled = newValue; lock.unlock() } }
    var registered: Bool { get { lock.lock(); defer { lock.unlock() }; return _registered } set { lock.lock(); _registered = newValue; lock.unlock() } }
    var puts: [Int64] { lock.lock(); defer { lock.unlock() }; return _puts }
    var deletes: [Int64] { lock.lock(); defer { lock.unlock() }; return _deletes }
    var resolves: Int { lock.lock(); defer { lock.unlock() }; return _resolves }
    var routeType: String { get { lock.lock(); defer { lock.unlock() }; return _routeType } set { lock.lock(); _routeType = newValue; lock.unlock() } }
    func response(_ request: URLRequest, docs: KikiLegalBundle) throws -> (Int, Data) {
        let path = request.url!.path
        var body: [String: Any]
        if path == "/v1/push/status" { body = ["enabled": enabled, "registered": registered, "badgeCount": 5, "accountTag": "fixture-account-tag"] }
        else if path.hasPrefix("/v1/push/devices/") {
            let input = try requestBody(request)
            let revision = try XCTUnwrap(input["revision"] as? Int64)
            XCTAssertNil(input["accountID"])
            lock.lock()
            if request.httpMethod == "PUT" { _puts.append(revision); _registered = true }
            else { _deletes.append(revision); _registered = false }
            lock.unlock()
            body = request.httpMethod == "PUT" ? ["ok": true, "registered": true, "accountTag": "fixture-account-tag"] : ["ok": true]
        } else if path.hasPrefix("/v1/push/destinations/") {
            lock.lock(); _resolves += 1; lock.unlock()
            onResolve?(); _ = routeGate?.wait(timeout: .now() + 5)
            body = ["type": routeType, "personID": "kiki_fixture0002"]
        } else if path == "/v1/me", request.httpMethod == "PATCH" {
            let input = try requestBody(request)
            enabled = input["notificationsEnabled"] as? Bool ?? false
            let (status, raw) = try p1VisualResponse(URLRequest(url: request.url!.deletingLastPathComponent().appendingPathComponent("auth/refresh")), documents: docs)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            var user = try XCTUnwrap(envelope["user"] as? [String: Any]); user["notificationsEnabled"] = enabled
            return (status, try JSONSerialization.data(withJSONObject: user))
        } else { return try p1VisualResponse(request, documents: docs) }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }
}

extension KikiConsentTests {
    private func pushFixture(_ state: TestPushServer, system: TestPushSystem? = nil) async throws -> (KikiAppStore, KikiPushController, TestIdentity) {
        let system = system ?? TestPushSystem()
        let identity = TestIdentity(values: ["sessionToken": "fixture-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in try state.response(request, docs: docs) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        let push = KikiPushController(system: system, identity: identity, environment: { "sandbox" })
        push.attach(store)
        return (store, push, identity)
    }
    private func waitForPush(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("Push state did not settle")
    }
    func testPushPermissionAndRegistrationNeverStartBeforeAuthenticatedConsent() async throws {
        let identity = TestIdentity()
        let system = TestPushSystem()
        let push = KikiPushController(system: system, identity: identity)
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { XCTFail("No API before consent"); return .shared }, rtcProvider: { XCTFail("No RTC before consent"); return TestRTC() })
        push.attach(store)
        await push.refresh(); await push.enable()
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertEqual(system.requested, 0); XCTAssertEqual(system.registered, 0)
    }
    func testPushRestoresExpiredBindingAndRevisionsSurviveLogout() async throws {
        let state = TestPushServer(), system = TestPushSystem()
        let (store, push, identity) = try await pushFixture(state, system: system)
        push.receivedToken(Data(repeating: 0xab, count: 40))
        await push.refresh()
        XCTAssertTrue(push.isRegistered); XCTAssertEqual(state.puts.count, 1)
        XCTAssertEqual(system.badge, 5)
        await push.refresh(); XCTAssertEqual(state.puts.count, 1, "Same active device does not rebind on every poll")
        state.registered = false
        await push.refresh()
        XCTAssertEqual(state.puts.count, 2, "APNs-invalidated or expired server registration must renew")
        XCTAssertGreaterThan(state.puts[1], state.puts[0])
        let installation = identity.read("pushInstallationID")
        await store.logout()
        XCTAssertFalse(push.isRegistered); XCTAssertEqual(system.badge, 0)
        XCTAssertEqual(identity.read("pushInstallationID"), installation)
        XCTAssertGreaterThan(Int64(identity.read("pushRegistrationRevision") ?? "0") ?? 0, state.puts.last ?? 0)
        XCTAssertNil(push.navigation)
    }
    func testPushExplicitPermissionAndDisabledAccountClearBadgeWithoutClearingInbox() async throws {
        let state = TestPushServer(), system = TestPushSystem(); state.enabled = false; system.status = .notDetermined
        let (store, push, _) = try await pushFixture(state, system: system)
        push.receivedToken(Data(repeating: 1, count: 32))
        await push.refresh()
        XCTAssertEqual(system.requested, 0); XCTAssertTrue(state.puts.isEmpty); XCTAssertEqual(system.badge, 0)
        await push.enable()
        XCTAssertEqual(system.requested, 1); XCTAssertTrue(store.notificationsEnabled); XCTAssertTrue(push.isRegistered)
        await store.refreshSocialSummary(); XCTAssertGreaterThan(store.unreadMessageCount, 0)
        await push.disable()
        XCTAssertFalse(store.notificationsEnabled); XCTAssertEqual(system.badge, 0); XCTAssertFalse(push.isRegistered)
        XCTAssertGreaterThan(store.unreadMessageCount, 0, "Account push preference must not disable the in-app inbox")
        await store.logout()
    }
    func testPushDeniedPermissionNeverRegistersAndDoesNotPromptAgain() async throws {
        let state = TestPushServer(), system = TestPushSystem(); system.status = .denied
        let (store, push, _) = try await pushFixture(state, system: system)
        push.receivedToken(Data(repeating: 1, count: 32)); await push.enable()
        XCTAssertTrue(state.puts.isEmpty); XCTAssertEqual(system.requested, 0); XCTAssertEqual(system.registered, 0); XCTAssertEqual(system.badge, 0)
        XCTAssertEqual(push.permission, .denied)
        await store.logout()
    }
    func testPushColdTapRejectsDifferentAccountTagAndIgnoresInjectedPeerID() async throws {
        let state = TestPushServer()
        let (store, push, _) = try await pushFixture(state)
        let tap = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "old-account-tag", "personID": "attacker-peer"]))
        push.receiveTap(tap)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(state.resolves, 0); XCTAssertNil(push.navigation)
        XCTAssertNil(KikiPushTap(payload: ["personID": "kiki_fixture0002"]))
        await store.logout()
    }
    func testPushTokenCallbackDoesNotCancelTapResolution() async throws {
        let state = TestPushServer(), system = TestPushSystem()
        let (store, push, _) = try await pushFixture(state, system: system)
        system.onRegister = { [weak push] in push?.receivedToken(Data(repeating: 2, count: 32)) }
        let tap = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "fixture-account-tag"]))
        push.receiveTap(tap)
        try await waitForPush { push.navigation != nil }
        XCTAssertEqual(state.resolves, 1); XCTAssertNotNil(push.navigation)
        await store.logout()
    }
    func testPushLateRouteCannotNavigateAfterLogoutOrBlock() async throws {
        for block in [false, true] {
            let state = TestPushServer(); let arrived = expectation(description: "route in flight")
            state.routeGate = DispatchSemaphore(value: 0); state.onResolve = { arrived.fulfill() }
            let (store, push, _) = try await pushFixture(state)
            let tap = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "fixture-account-tag"]))
            push.receiveTap(tap)
            await fulfillment(of: [arrived], timeout: 3)
            if block { store.socialPolicyChanged(userID: "kiki_fixture0002", blocked: true) }
            else { push.endSession() }
            state.routeGate?.signal()
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertNil(push.navigation)
            await store.logout()
        }
    }
    func testPushEnvironmentUsesProvisioningEntitlementRatherThanBuildConfiguration() throws {
        for (input, expected) in [("development", "sandbox"), ("production", "production")] {
            let profile = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["aps-environment": input]], format: .xml, options: 0)
            var cms = Data([0, 255, 1]); cms.append(profile); cms.append(Data([0, 254]))
            XCTAssertEqual(KikiPushEnvironment.fromProvisioningProfile(cms), expected)
        }
        XCTAssertNil(KikiPushEnvironment.fromProvisioningProfile(Data("invalid profile".utf8)))
    }
    func testPushPreferencesForegroundFixtureScreenshots() async throws {
        let state = TestPushServer(), system = TestPushSystem(); system.status = .denied
        let (store, push, _) = try await pushFixture(state, system: system)
        await push.refresh()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }; let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.rootViewController = UIHostingController(rootView: KikiPushPreferencesView(store: store, push: push).preferredColorScheme(.light))
        window.makeKeyAndVisible(); try await Task.sleep(nanoseconds: 500_000_000); window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        let folder = URL(fileURLWithPath: "/tmp/kiki-apns-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-notification-settings.png"))
        let attachment = XCTAttachment(image: image); attachment.name = device + "-notification-settings"; attachment.lifetime = .keepAlways; add(attachment)
        await store.logout()
    }
}

extension KikiConsentTests {
    func testPushColdTapSurvivesEmptyStartupUntilMatchingAccountLogin() async throws {
        let state = TestPushServer(), system = TestPushSystem(), identity = TestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in try state.response(request, docs: docs) }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { mock.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        let push = KikiPushController(system: system, identity: identity, environment: { "sandbox" })
        push.receiveTap(try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "fixture-account-tag"])))
        push.attach(store)
        await store.start()
        XCTAssertFalse(store.isAuthenticated); XCTAssertEqual(state.resolves, 0)
        try await store.loginWithApple()
        await push.refresh()
        XCTAssertTrue(store.isAuthenticated); XCTAssertEqual(state.resolves, 1); XCTAssertNotNil(push.navigation)
        await store.logout()
    }
}

extension KikiConsentTests {
    func testAppleFailureRetryAndLogoutPreserveSingleConsentDecision() async throws {
        let identity = TestIdentity()
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let logins = TestRequests()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/auth/apple" {
                logins.append("login")
                let body = try requestBody(request)
                let acceptance = try XCTUnwrap(body["legalConsent"] as? [String: Any])
                XCTAssertEqual(acceptance["documentHash"] as? String, docs.documentHash)
                XCTAssertEqual(acceptance["accepted"] as? Bool, true)
                XCTAssertEqual(acceptance["adultConfirmed"] as? Bool, true)
                if logins.values.count == 1 { return (503, Data(#"{"detail":"稍后重试"}"#.utf8)) }
            }
            return try consentResponse(request, documents: docs)
        }
        let preferences = defaults()
        let consent = KikiConsentStore(documents: docs, defaults: preferences, identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let accepted = try XCTUnwrap(consent.receipt)
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        do { try await store.loginWithApple(); XCTFail("Expected temporary Apple account API failure") }
        catch { }
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt, accepted)
        try await store.loginWithApple()
        XCTAssertTrue(store.isAuthenticated)
        await store.logout()
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt, accepted)
        let relaunched = KikiConsentStore(documents: docs, defaults: preferences, identity: identity, requiresRemoteDocuments: false)
        XCTAssertTrue(relaunched.hasCurrentConsent)
        XCTAssertEqual(relaunched.receipt, accepted)
        try await store.loginWithApple()
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(consent.receipt, accepted)
        await store.logout()
        XCTAssertEqual(logins.values.count, 3)
    }

    func testConsentPageAndMinimalLoginOfflineFixtureScreenshots() async throws {
        let identity = TestIdentity()
        let documents = try XCTUnwrap(KikiLegalBundle.bundled)
        let data = try XCTUnwrap(documents.validatedData)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            requests.append("GET /v1/legal/documents")
            return (200, data)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, apiProvider: { mock.client })
        await consent.refreshDocuments()
        XCTAssertTrue(consent.hasVerifiedRemoteDocuments)
        XCTAssertTrue(consent.canAccept)
        XCTAssertNil(consent.documentError)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let originalFrame = window.frame
        defer { window.frame = originalFrame; window.isHidden = true; previous?.makeKeyAndVisible() }
        let folder = URL(fileURLWithPath: "/tmp/kiki-onboarding-clean-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"

        func capture(_ name: String, screen: AnyView, size: CGSize? = nil) async throws {
            defer { window.frame = originalFrame }
            window.rootViewController = UIHostingController(rootView: screen.foregroundStyle(KikiPalette.text))
            window.makeKeyAndVisible()
            window.frame = size.map { CGRect(origin: originalFrame.origin, size: $0) } ?? originalFrame
            window.rootViewController?.view.frame = window.bounds
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + ".png"))
        }

        try await capture("silent-startup-light", screen: AnyView(KikiStartupView().preferredColorScheme(.light)))
        try await capture("silent-startup-dark", screen: AnyView(KikiStartupView().preferredColorScheme(.dark)))
        try await capture("startup-legal-error-light", screen: AnyView(KikiStartupView(errorMessage: "暂时无法获取最新协议，请检查网络后重试。", showsOfflineDocuments: true)
            .environmentObject(consent).preferredColorScheme(.light)))
        try await capture("startup-legal-error-short-320x568", screen: AnyView(KikiStartupView(errorMessage: "暂时无法获取最新协议，请检查网络后重试。", showsOfflineDocuments: true)
            .environmentObject(consent).preferredColorScheme(.light)), size: CGSize(width: 320, height: 568))
        try await capture("consent-page-light", screen: AnyView(KikiConsentGateView().environmentObject(consent).preferredColorScheme(.light)))
        try await capture("consent-page-dark", screen: AnyView(KikiConsentGateView().environmentObject(consent).preferredColorScheme(.dark)))
        try await capture("consent-page-large-text", screen: AnyView(KikiConsentGateView().environmentObject(consent).preferredColorScheme(.light).dynamicTypeSize(.accessibility2)))
        try await capture("consent-page-short-320x568", screen: AnyView(KikiConsentGateView().environmentObject(consent).preferredColorScheme(.light)), size: CGSize(width: 320, height: 568))
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertNil(consent.receipt)
        XCTAssertEqual(identity.readCount, 0)
        try consent.accept()
        let acceptedReceipt = consent.receipt
        try consent.accept()
        XCTAssertEqual(consent.receipt, acceptedReceipt, "Repeating an explicit action must preserve the original decision")
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: {
            XCTFail("Showing login must not contact the account API")
            return .shared
        }, rtcProvider: { XCTFail("Showing login must not create RTC"); return TestRTC() }, appleProvider: { XCTFail("Showing login must not begin Apple authorization"); return TestApple() })
        try await capture("minimal-login-light", screen: AnyView(KikiLoginView().environmentObject(store).environmentObject(consent).preferredColorScheme(.light)))
        try await capture("minimal-login-dark", screen: AnyView(KikiLoginView().environmentObject(store).environmentObject(consent).preferredColorScheme(.dark)))
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt, acceptedReceipt)
        XCTAssertEqual(identity.readCount, 0)

        func capturePendingPreparation(_ name: String, flow: KikiStartupPermissions,
                                       gate: KikiStartupTestGate, stage: KikiStartupPermissions.Stage) async throws {
            let pending = Task { await flow.begin(consent: consent) }
            do {
                for _ in 0..<100 {
                    if gate.isWaiting && flow.stage == stage { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                XCTAssertTrue(gate.isWaiting)
                XCTAssertEqual(flow.stage, stage)
                try await capture(name, screen: AnyView(KikiStartupPermissionsView(permissions: flow)
                    .environmentObject(consent).preferredColorScheme(.light)))
            } catch {
                gate.finish(); await pending.value
                throw error
            }
            gate.finish(); await pending.value
            XCTAssertTrue(flow.isReady(for: consent))
        }

        let networkEvents = KikiStartupEventLog(), networkGate = KikiStartupTestGate()
        let checkingNetwork = KikiStartupNetworkMock(events: networkEvents)
        let networkNotifications = KikiStartupNotificationMock(events: networkEvents)
        checkingNetwork.gate = networkGate; networkNotifications.status = .denied
        let networkFlow = KikiStartupPermissions(network: checkingNetwork, notifications: networkNotifications, waitForForeground: { })
        try await capturePendingPreparation("startup-network-check", flow: networkFlow, gate: networkGate, stage: .checkingNetwork)
        XCTAssertEqual(networkNotifications.requestCalls, 0)
        XCTAssertTrue(networkNotifications.pushSideEffects.isEmpty)

        let failedEvents = KikiStartupEventLog()
        let failedNetwork = KikiStartupNetworkMock(events: failedEvents)
        let failedNotifications = KikiStartupNotificationMock(events: failedEvents)
        failedNetwork.failure = URLError(.notConnectedToInternet)
        let failedFlow = KikiStartupPermissions(network: failedNetwork, notifications: failedNotifications, waitForForeground: { })
        await failedFlow.begin(consent: consent)
        XCTAssertEqual(failedFlow.stage, .failed)
        try await capture("startup-network-error-light", screen: AnyView(KikiStartupPermissionsView(permissions: failedFlow)
            .environmentObject(consent).preferredColorScheme(.light)))
        try await capture("startup-network-error-dark", screen: AnyView(KikiStartupPermissionsView(permissions: failedFlow)
            .environmentObject(consent).preferredColorScheme(.dark)))
        XCTAssertEqual(failedNotifications.statusCalls, 0)
        XCTAssertEqual(failedNotifications.requestCalls, 0)
        XCTAssertTrue(failedNotifications.pushSideEffects.isEmpty)

        let notificationEvents = KikiStartupEventLog(), notificationGate = KikiStartupTestGate()
        let notificationNetwork = KikiStartupNetworkMock(events: notificationEvents)
        let pendingNotifications = KikiStartupNotificationMock(events: notificationEvents)
        pendingNotifications.requestGate = notificationGate
        let notificationFlow = KikiStartupPermissions(network: notificationNetwork, notifications: pendingNotifications, waitForForeground: { })
        try await capturePendingPreparation("startup-notification", flow: notificationFlow, gate: notificationGate, stage: .requestingNotifications)
        XCTAssertEqual(pendingNotifications.requestCalls, 1)
        XCTAssertTrue(pendingNotifications.pushSideEffects.isEmpty)
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt, acceptedReceipt)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertEqual(requests.values, ["GET /v1/legal/documents"],
                       "The fixture permits only the anonymous manifest fetch before rendering the legal and login screens")
    }
}

extension KikiConsentTests {
    func testUnreadFetchRequestedBeforeReadCannotRestoreBadge() {
        var gate = KikiUnreadRequestGate()
        let oldFetch = gate.beginFetch()
        XCTAssertTrue(gate.accepts(oldFetch))
        let read = gate.beginMutation()
        XCTAssertFalse(gate.accepts(oldFetch))
        gate.finishMutation(read)
        XCTAssertFalse(gate.accepts(oldFetch), "A pre-read total remains stale after the read completes")
        let fresh = gate.beginFetch()
        XCTAssertTrue(gate.accepts(fresh))
    }

    func testUnreadFetchDuringReadCannotWriteAfterReadCompletes() {
        var gate = KikiUnreadRequestGate()
        let read = gate.beginMutation()
        let duringRead = gate.beginFetch()
        XCTAssertTrue(gate.hasPendingMutation)
        XCTAssertFalse(gate.accepts(duringRead))
        gate.finishMutation(read)
        XCTAssertFalse(gate.hasPendingMutation)
        XCTAssertFalse(gate.accepts(duringRead), "A response started before read acknowledgement is not authoritative")
        let fresh = gate.beginFetch()
        XCTAssertTrue(gate.accepts(fresh))
    }

    func testConcurrentUnreadReadsMustAllFinishBeforeNewTotalApplies() {
        var gate = KikiUnreadRequestGate()
        let first = gate.beginMutation(), second = gate.beginMutation()
        gate.finishMutation(second)
        let betweenReads = gate.beginFetch()
        XCTAssertTrue(gate.hasPendingMutation)
        XCTAssertFalse(gate.accepts(betweenReads))
        gate.finishMutation(first)
        XCTAssertFalse(gate.hasPendingMutation)
        XCTAssertFalse(gate.accepts(betweenReads))
        let fresh = gate.beginFetch()
        XCTAssertTrue(gate.accepts(fresh))
        gate.finishMutation(second)
        XCTAssertTrue(gate.accepts(fresh), "Duplicate cleanup cannot invalidate a newer authoritative result")
    }

    func testOnlyLatestUnreadFetchCanUpdateTheBadge() {
        var gate = KikiUnreadRequestGate()
        let first = gate.beginFetch(), second = gate.beginFetch()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))
        let third = gate.beginFetch()
        XCTAssertFalse(gate.accepts(second))
        XCTAssertTrue(gate.accepts(third))
    }

    func testIndependentInboxReadDoesNotInvalidateOtherInboxTotal() {
        var notifications = KikiUnreadRequestGate(), conversations = KikiUnreadRequestGate()
        let noticeFetch = notifications.beginFetch(), directFetch = conversations.beginFetch()
        let reading = notifications.beginMutation()
        XCTAssertFalse(notifications.accepts(noticeFetch))
        XCTAssertTrue(conversations.accepts(directFetch))
        notifications.finishMutation(reading)
        XCTAssertTrue(conversations.accepts(directFetch))
    }

    func testLateInboxFetchCannotRestoreUnreadAfterReadAcknowledgement() async throws {
        for direct in [false, true] {
            let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
            let docs = try XCTUnwrap(KikiLegalBundle.bundled)
            let arrived = expectation(description: direct ? "Old conversations total in flight" : "Old notifications total in flight")
            let responseGate = DispatchSemaphore(value: 0)
            defer { responseGate.signal() }
            let fetches = TestRequests()
            let path = direct ? "/v1/social/conversations" : "/v1/social/notifications"
            let readPath = direct ? "/v1/social/conversations/kiki_fixture0002/read" : "/v1/social/notifications/read"
            let mock = KikiConcurrentConsentServer { request in
                if request.url?.path == path {
                    fetches.append("fetch")
                    let old = fetches.values.count == 1
                    if old { arrived.fulfill(); _ = responseGate.wait(timeout: .now() + 5) }
                    let body: [String: Any] = direct
                        ? ["conversations": [], "nextCursor": NSNull(), "unreadCount": old ? 8 : 0]
                        : ["notifications": [], "nextCursor": NSNull(), "unreadCount": old ? 8 : 0, "retentionDays": 30]
                    return (200, try JSONSerialization.data(withJSONObject: body))
                }
                if request.url?.path == readPath {
                    // An out-of-order mutation total is deliberately misleading:
                    // only the subsequent authoritative GET may set the badge.
                    return (200, Data(#"{"unreadCount":99}"#.utf8))
                }
                return try consentResponse(request, documents: docs)
            }
            let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
            try consent.accept()
            let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
            await store.start()
            let oldFetch = Task {
                if direct { _ = try await store.socialConversations() }
                else { _ = try await store.socialNotifications() }
            }
            await fulfillment(of: [arrived], timeout: 3)
            if direct { try await store.readDirectMessages("kiki_fixture0002", throughMessageID: UUID().uuidString) }
            else { try await store.readNotifications(all: true) }
            XCTAssertEqual(direct ? store.unreadDirectMessageCount : store.unreadNotificationCount, 0)
            responseGate.signal()
            try await oldFetch.value
            XCTAssertEqual(direct ? store.unreadDirectMessageCount : store.unreadNotificationCount, 0, "A late pre-read response must not resurrect unread")
            XCTAssertEqual(fetches.values.count, 2)
            await store.logout()
        }
    }
}

extension KikiConsentTests {
    func testPushGenericRouteReplacesExistingDestinationAndCanBeConsumedImmediately() async throws {
        let state = TestPushServer()
        let (store, push, _) = try await pushFixture(state)
        func tap() throws -> KikiPushTap { try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "fixture-account-tag"])) }
        push.receiveTap(try tap())
        try await waitForPush { push.navigation != nil }
        XCTAssertNil(push.pendingInboxRequest)
        state.routeType = "notification"
        push.receiveTap(try tap())
        try await waitForPush { push.pendingInboxRequest != nil }
        XCTAssertNil(push.navigation, "A generic reminder must explicitly replace the prior APNs private-chat destination")
        let request = try XCTUnwrap(push.pendingInboxRequest)
        XCTAssertTrue(push.consumeInboxRequest(request))
        XCTAssertFalse(push.consumeInboxRequest(request), "One reminder is consumed once")
        await store.logout()
    }

    func testPushGenericRouteSurvivesFirstMessageViewConstructionAndDoesNotReplayAfterConsumption() async throws {
        let state = TestPushServer(); state.routeType = "notification"
        let (store, push, _) = try await pushFixture(state)
        push.receiveTap(try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "fixture-account-tag"])))
        try await waitForPush { push.pendingInboxRequest != nil }
        let request = try XCTUnwrap(push.pendingInboxRequest)
        _ = KikiMessagesView(store: store)
        XCTAssertEqual(push.pendingInboxRequest, request, "Constructing the message tab must not claim a cold-start reminder before its view handles it")
        XCTAssertTrue(push.consumeInboxRequest(request))
        _ = KikiMessagesView(store: store)
        XCTAssertNil(push.pendingInboxRequest, "Recreating the foreground view must not replay an already-opened reminder")
        await store.logout()
    }
}

/// Race fixtures must not block URLSession's protocol-loading queue. Responders
/// run independently, so two read operations are provably in flight together.
private final class KikiConcurrentConsentServer {
    let client: KikiAccountAPIClient
    let voiceClient: KikiAPIClient
    private let session: URLSession
    private let host = UUID().uuidString.lowercased() + ".consent.example.invalid"
    init(beforeResponse: ((URLRequest, UUID) -> Void)? = nil, onStop: ((URLRequest, UUID) -> Void)? = nil,
         responder: @escaping KikiConcurrentConsentProtocol.Responder) {
        KikiConcurrentConsentProtocol.install(responder, host: host, beforeResponse: beforeResponse, onStop: onStop)
        KikiConcurrentConsentProtocol.install(responder, host: "voice-" + host, beforeResponse: beforeResponse, onStop: onStop)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KikiConcurrentConsentProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAccountAPIClient(baseURL: URL(string: "https://" + host)!, session: session)
        voiceClient = KikiAPIClient(baseURL: URL(string: "https://voice-" + host)!, session: session)
    }
    deinit {
        session.invalidateAndCancel()
        KikiConcurrentConsentProtocol.remove(host: host)
        KikiConcurrentConsentProtocol.remove(host: "voice-" + host)
    }
}

private final class KikiConcurrentConsentProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = (URLRequest) throws -> (Int, Data)
    private static let handlersLock = NSLock()
    private static var handlers: [String: (responder: Responder, beforeResponse: ((URLRequest, UUID) -> Void)?, onStop: ((URLRequest, UUID) -> Void)?)] = [:]
    private let stateLock = NSLock()
    private var stopped = false
    private let requestID = UUID()
    static func install(_ responder: @escaping Responder, host: String, beforeResponse: ((URLRequest, UUID) -> Void)? = nil,
                        onStop: ((URLRequest, UUID) -> Void)? = nil) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers[host] = (responder, beforeResponse, onStop)
    }
    static func remove(host: String) {
        handlersLock.lock(); defer { handlersLock.unlock() }
        handlers.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handlersLock.lock()
        let handler = Self.handlers[request.url?.host ?? ""]
        Self.handlersLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                guard let handler, let url = request.url else { throw URLError(.badServerResponse) }
                handler.beforeResponse?(request, requestID)
                let (status, data) = try handler.responder(request)
                stateLock.lock(); let shouldReturn = !stopped; stateLock.unlock()
                guard shouldReturn else { return }
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { throw URLError(.badServerResponse) }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                stateLock.lock(); let shouldReturn = !stopped; stateLock.unlock()
                if shouldReturn { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
    }
    override func stopLoading() {
        stateLock.lock(); let wasStopped = stopped; stopped = true; stateLock.unlock()
        guard !wasStopped else { return }
        Self.handlersLock.lock()
        let onStop = Self.handlers[request.url?.host ?? ""]?.onStop
        Self.handlersLock.unlock()
        onStop?(request, requestID)
    }
}

extension KikiConsentTests {
    func testSuccessfulConcurrentReadStillRefreshesWhenLastReadFailsAndPreservesOriginalError() async throws {
        for direct in [false, true] {
            for refreshFails in [false, true] {
                let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
                let docs = try XCTUnwrap(KikiLegalBundle.bundled)
                let firstArrived = expectation(description: "First read is in flight")
                let secondArrived = expectation(description: "Second read is concurrently in flight")
                let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
                defer { releaseFirst.signal(); releaseSecond.signal() }
                let fetches = TestRequests()
                let firstMessage = "11111111-1111-4111-8111-111111111111"
                let secondMessage = "22222222-2222-4222-8222-222222222222"
                let path = direct ? "/v1/social/conversations" : "/v1/social/notifications"
                let readPath = direct ? "/v1/social/conversations/kiki_fixture0002/read" : "/v1/social/notifications/read"
                let mock = KikiConcurrentConsentServer { request in
                    if request.url?.path == path {
                        fetches.append("fetch")
                        let initial = fetches.values.count == 1
                        if !initial && refreshFails { return (503, Data(#"{"detail":"刷新失败不能覆盖原已读错误"}"#.utf8)) }
                        let count = initial ? 8 : 3
                        let body: [String: Any] = direct
                            ? ["conversations": [], "nextCursor": NSNull(), "unreadCount": count]
                            : ["notifications": [], "nextCursor": NSNull(), "unreadCount": count, "retentionDays": 30]
                        return (200, try JSONSerialization.data(withJSONObject: body))
                    }
                    if request.url?.path == readPath {
                        let body = try requestBody(request)
                        let first = direct ? body["throughMessageID"] as? String == firstMessage : body["all"] as? Bool == true
                        if first {
                            firstArrived.fulfill(); _ = releaseFirst.wait(timeout: .now() + 5)
                            return (200, Data(#"{"unreadCount":99}"#.utf8))
                        }
                        secondArrived.fulfill(); _ = releaseSecond.wait(timeout: .now() + 5)
                        return (503, Data(#"{"detail":"第二次已读失败"}"#.utf8))
                    }
                    return try consentResponse(request, documents: docs)
                }
                let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
                try consent.accept()
                let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
                await store.start()
                if direct { _ = try await store.socialConversations() }
                else { _ = try await store.socialNotifications() }
                XCTAssertEqual(direct ? store.unreadDirectMessageCount : store.unreadNotificationCount, 8)
                let firstRead = Task {
                    if direct { try await store.readDirectMessages("kiki_fixture0002", throughMessageID: firstMessage) }
                    else { try await store.readNotifications(all: true) }
                }
                await fulfillment(of: [firstArrived], timeout: 3)
                let secondRead = Task {
                    if direct { try await store.readDirectMessages("kiki_fixture0002", throughMessageID: secondMessage) }
                    else { try await store.readNotifications(ids: [secondMessage]) }
                }
                await fulfillment(of: [secondArrived], timeout: 3)
                releaseFirst.signal()
                try await firstRead.value
                XCTAssertEqual(fetches.values.count, 1, "The successful read must wait for the other pending mutation before reconciling totals")
                XCTAssertEqual(direct ? store.unreadDirectMessageCount : store.unreadNotificationCount, 8)
                releaseSecond.signal()
                do { try await secondRead.value; XCTFail("The failed read must retain its original error") }
                catch let error as KikiAPIError {
                    guard case .server(let status, let message) = error else { return XCTFail("Unexpected error: \(error)") }
                    XCTAssertEqual(status, 503)
                    XCTAssertEqual(message, "第二次已读失败")
                }
                XCTAssertEqual(fetches.values.count, 2, "The last failed mutation must still reconcile a prior successful read")
                XCTAssertEqual(direct ? store.unreadDirectMessageCount : store.unreadNotificationCount, refreshFails ? 8 : 3)
                XCTAssertTrue(store.isAuthenticated)
                await store.logout()
            }
        }
    }
}

@MainActor
private final class KikiStartupEventLog {
    var values: [String] = []
}

/// Deliberately ignores task cancellation until the test releases the callback,
/// so coordinator cancellation tests exercise genuinely late platform results.
@MainActor
private final class KikiStartupTestGate {
    private var pending: [CheckedContinuation<Void, Error>] = []
    private(set) var isWaiting = false
    func wait() async throws {
        try await withCheckedThrowingContinuation { pending.append($0); isWaiting = true }
    }
    func finish(_ error: Error? = nil) {
        let continuations = pending; pending = []; isWaiting = false
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}

@MainActor
private final class KikiStartupNetworkMock: KikiStartupNetworkProbing {
    private(set) var calls = 0
    let events: KikiStartupEventLog
    var failure: Error?
    var gate: KikiStartupTestGate?
    init(events: KikiStartupEventLog) { self.events = events }
    func check() async throws {
        calls += 1; events.values.append("network")
        let capturedFailure = failure
        if let gate { try await gate.wait() }
        if let capturedFailure { throw capturedFailure }
    }
}

@MainActor
private final class KikiStartupNotificationMock: KikiPushSystem {
    let events: KikiStartupEventLog
    var status = KikiPushPermission.notDetermined
    var decision = KikiPushPermission.authorized
    var requestError: Error?
    var requestGate: KikiStartupTestGate?
    private(set) var statusCalls = 0, requestCalls = 0
    private(set) var pushSideEffects: [String] = []
    init(events: KikiStartupEventLog) { self.events = events }
    func permission() async -> KikiPushPermission {
        statusCalls += 1; events.values.append("permission"); return status
    }
    func requestPermission() async throws {
        requestCalls += 1; events.values.append("request")
        if let requestGate { try await requestGate.wait() }
        if let requestError { throw requestError }
        status = decision
    }
    func register() { pushSideEffects.append("register") }
    func unregister() { pushSideEffects.append("unregister") }
    func setBadge(_ count: Int) { pushSideEffects.append("badge") }
    func clearNotifications() { pushSideEffects.append("clear") }
}

@MainActor
final class KikiStartupPermissionsTests: XCTestCase {
    private func consent(accepted: Bool = true) throws -> KikiConsentStore {
        let suite = "KikiStartupPermissionsTests." + UUID().uuidString
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let consent = KikiConsentStore(defaults: UserDefaults(suiteName: suite)!, identity: TestIdentity(), apiProvider: {
            XCTFail("Pre-login preparation must not create the authenticated account API"); return .shared
        }, requiresRemoteDocuments: false)
        if accepted { try consent.accept() }
        return consent
    }
    private func settle(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Preparation did not reach the expected asynchronous boundary")
    }
    func testNoConsentDoesNotProbeNetworkOrInspectOrRequestNotificationPermission() async throws {
        let consent = try consent(accepted: false), events = KikiStartupEventLog()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        await flow.begin(consent: consent)
        await flow.retry(consent: consent)
        XCTAssertTrue(events.values.isEmpty)
        XCTAssertFalse(flow.isReady); XCTAssertFalse(flow.isBusy)
        XCTAssertTrue(notifications.pushSideEffects.isEmpty)
    }
    func testNetworkCompletesBeforeNotificationAuthorizationAndPreparationBecomesReady() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), gate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        network.gate = gate
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let pending = Task { await flow.begin(consent: consent) }
        defer { gate.finish() }
        try await settle { gate.isWaiting }
        XCTAssertTrue(flow.isBusy); XCTAssertFalse(flow.isReady)
        XCTAssertEqual(events.values, ["network"], "The health probe must finish before touching the notification permission API")
        gate.finish(); await pending.value
        XCTAssertEqual(events.values, ["network", "permission", "request", "permission"])
        XCTAssertTrue(flow.isReady); XCTAssertFalse(flow.isBusy); XCTAssertNil(flow.errorMessage)
        XCTAssertTrue(notifications.pushSideEffects.isEmpty, "Permission preparation must not register APNs or mutate an account badge")
    }
    func testNetworkFailureBlocksLoginPreparationAndExplicitRetryCanRecover() async throws {
        let consent = try consent(), events = KikiStartupEventLog()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        network.failure = URLError(.notConnectedToInternet)
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        await flow.begin(consent: consent)
        XCTAssertFalse(flow.isReady); XCTAssertFalse(flow.isBusy); XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(events.values, ["network"])
        XCTAssertEqual(notifications.requestCalls, 0)
        network.failure = nil
        await flow.retry(consent: consent)
        XCTAssertEqual(network.calls, 2); XCTAssertTrue(flow.isReady); XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(notifications.requestCalls, 1)
    }
    func testDecliningTheSystemNotificationPromptDoesNotBlockAppleLoginPreparation() async throws {
        let consent = try consent(), events = KikiStartupEventLog()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        notifications.decision = .denied
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        await flow.begin(consent: consent)
        XCTAssertTrue(flow.isReady); XCTAssertFalse(flow.isBusy); XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(flow.notificationPermission, .denied)
        XCTAssertEqual(notifications.requestCalls, 1)
    }
    func testAlreadyDecidedNotificationPermissionNeverPromptsAgain() async throws {
        for permission in [KikiPushPermission.authorized, .denied, .provisional] {
            let consent = try consent(), events = KikiStartupEventLog()
            let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
            notifications.status = permission
            let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
            await flow.begin(consent: consent)
            await flow.begin(consent: consent)
            XCTAssertTrue(flow.isReady)
            XCTAssertEqual(flow.notificationPermission, permission)
            XCTAssertEqual(network.calls, 1, "A completed preparation does not restart on a duplicate view task")
            XCTAssertEqual(notifications.requestCalls, 0)
            XCTAssertTrue(notifications.pushSideEffects.isEmpty)
        }
    }
    func testNotificationAuthorizationFailureDoesNotBecomeANetworkLoginBlock() async throws {
        let consent = try consent(), events = KikiStartupEventLog()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        notifications.requestError = URLError(.unknown)
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        await flow.begin(consent: consent)
        XCTAssertTrue(flow.isReady); XCTAssertFalse(flow.isBusy); XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(notifications.requestCalls, 1)
    }
    func testConcurrentBeginAndRetryShareOneHealthProbeAndOneSystemPrompt() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), networkGate = KikiStartupTestGate(), promptGate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        network.gate = networkGate; notifications.requestGate = promptGate
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let first = Task { await flow.begin(consent: consent) }
        defer { networkGate.finish(); promptGate.finish() }
        try await settle { networkGate.isWaiting }
        let second = Task { await flow.begin(consent: consent) }
        let retry = Task { await flow.retry(consent: consent) }
        await Task.yield()
        XCTAssertEqual(network.calls, 1); XCTAssertEqual(notifications.requestCalls, 0)
        networkGate.finish()
        try await settle { promptGate.isWaiting }
        let third = Task { await flow.begin(consent: consent) }
        await Task.yield()
        XCTAssertEqual(network.calls, 1); XCTAssertEqual(notifications.requestCalls, 1)
        promptGate.finish()
        await first.value; await second.value; await retry.value; await third.value
        XCTAssertTrue(flow.isReady); XCTAssertEqual(network.calls, 1); XCTAssertEqual(notifications.requestCalls, 1)
    }
    func testCancelDuringHealthProbeRejectsItsLateSuccessBeforeTouchingNotifications() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), gate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        network.gate = gate
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let pending = Task { await flow.begin(consent: consent) }
        defer { gate.finish() }
        try await settle { gate.isWaiting }
        flow.cancel(); gate.finish(); await pending.value
        XCTAssertFalse(flow.isReady); XCTAssertFalse(flow.isBusy)
        XCTAssertEqual(events.values, ["network"])
    }
    func testWithdrawalDuringSystemPromptRejectsLateAuthorizationResult() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), gate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        notifications.requestGate = gate
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let pending = Task { await flow.begin(consent: consent) }
        defer { gate.finish() }
        try await settle { gate.isWaiting }
        await consent.withdraw { }
        XCTAssertFalse(consent.hasCurrentConsent)
        gate.finish(); await pending.value
        XCTAssertFalse(flow.isReady); XCTAssertFalse(flow.isBusy)
        XCTAssertEqual(notifications.requestCalls, 1)
        XCTAssertTrue(notifications.pushSideEffects.isEmpty)
    }
    func testCancelledOldProbeFailureCannotOverwriteANewerSuccessfulPreparation() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), oldGate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        network.gate = oldGate; network.failure = URLError(.timedOut); notifications.status = .denied
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let old = Task { await flow.begin(consent: consent) }
        defer { oldGate.finish() }
        try await settle { oldGate.isWaiting }
        flow.cancel()
        network.gate = nil; network.failure = nil
        await flow.begin(consent: consent)
        XCTAssertTrue(flow.isReady); XCTAssertNil(flow.errorMessage)
        oldGate.finish(); await old.value
        XCTAssertTrue(flow.isReady); XCTAssertNil(flow.errorMessage)
        XCTAssertEqual(network.calls, 2); XCTAssertEqual(notifications.requestCalls, 0)
    }
}

extension KikiStartupPermissionsTests {
    func testForegroundBarriersDelayNetworkAndTheSystemPromptUntilTheAppIsActive() async throws {
        let consent = try consent(), events = KikiStartupEventLog()
        let firstForeground = KikiStartupTestGate(), promptForeground = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        var foregroundCalls = 0
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: {
            foregroundCalls += 1
            if foregroundCalls == 1 { try await firstForeground.wait() }
            if foregroundCalls == 3 { try await promptForeground.wait() }
        })
        let pending = Task { await flow.begin(consent: consent) }
        defer { firstForeground.finish(); promptForeground.finish() }
        try await settle { firstForeground.isWaiting }
        XCTAssertTrue(events.values.isEmpty, "No network or notification API before the first foreground barrier")
        XCTAssertFalse(flow.isReady)
        firstForeground.finish()
        try await settle { promptForeground.isWaiting }
        XCTAssertEqual(events.values, ["network", "permission"])
        XCTAssertEqual(notifications.requestCalls, 0, "The app can become inactive after probing, so the system prompt needs its own foreground barrier")
        promptForeground.finish(); await pending.value
        XCTAssertTrue(flow.isReady)
        XCTAssertEqual(events.values, ["network", "permission", "request", "permission"])
    }
}

private struct KikiRoomHostScenePhaseProbe: View {
    @Environment(\.scenePhase) private var phase
    @State private var identity = UUID()
    let observe: @MainActor (ScenePhase, UUID) -> Void

    var body: some View {
        Text("Room host phase: \(String(describing: phase))")
            .task(id: phase) { observe(phase, identity) }
    }
}

extension KikiConsentTests {
    func testManuallyPresentedRoomHostScenePhaseMatchesForegroundWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let presenter = UIViewController()
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 250_000_000)
        let sceneNotifications = NotificationCenter()
        var observed: [ScenePhase] = []
        var identities: [UUID] = []
        let host = KikiRoomHostingController(rootView: KikiRoomHostScenePhaseProbe { phase, identity in
            observed.append(phase)
            identities.append(identity)
        }, notificationCenter: sceneNotifications)
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(host, animated: false) { continuation.resume() }
        }
        try await waitUntil { observed.last == .active }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        XCTAssertEqual(scene.activationState, .foregroundActive)
        XCTAssertTrue(host.view.window?.windowScene === scene)

        sceneNotifications.post(name: UIScene.willDeactivateNotification, object: scene)
        try await waitUntil { observed.last == .inactive }
        sceneNotifications.post(name: UIScene.didEnterBackgroundNotification, object: scene)
        try await waitUntil { observed.last == .background }
        sceneNotifications.post(name: UIScene.willEnterForegroundNotification, object: scene)
        try await waitUntil { observed.last == .inactive }
        sceneNotifications.post(name: UIScene.didActivateNotification, object: scene)
        try await waitUntil { observed.last == .active }

        let unrelatedSource = NSObject()
        let beforeUnrelated = observed
        sceneNotifications.post(name: UIScene.didEnterBackgroundNotification, object: unrelatedSource)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(observed, beforeUnrelated, "Only the hosting window's scene may change its phase")

        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
        try await waitUntil { observed.last == .background }
        sceneNotifications.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(observed.last, .background, "A dismissed room must not restart polling when its scene activates")
        await withCheckedContinuation { continuation in
            presenter.present(host, animated: false) { continuation.resume() }
        }
        try await waitUntil { observed.last == .active }
        XCTAssertEqual(Set(identities).count, 1, "Lifecycle updates and re-presentation must preserve SwiftUI view state")
        let report = """
        manually presented room host scenePhase: \(observed.map { String(describing: $0) }.joined(separator: ", "))
        UIApplication state: \(String(describing: UIApplication.shared.applicationState))
        UIWindowScene activation: \(String(describing: scene.activationState))
        host window belongs to tested scene: \(host.view.window?.windowScene === scene)
        SwiftUI state identity preserved: \(Set(identities).count == 1)
        """
        let attachment = XCTAttachment(string: report)
        attachment.name = "Manual room host scene lifecycle"
        attachment.lifetime = .keepAlways
        add(attachment)
        print(report)
        XCTAssertEqual(observed.last, .active, "The room's scenePhase must follow its actual visible window. " + report)
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
    }
}

extension KikiConsentTests {
    func testCoverInstallFetchesRequiredDocumentsAndPreservesExistingPreferencesUntilExplicitAcceptance() async throws {
        let preferences = defaults()
        let oldDocuments = try XCTUnwrap(KikiLegalBundle.bundled)
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        let current = try KikiLegalBundle.decodeValidated(data)
        let pending = KikiConsentStore.Receipt(versions: oldDocuments.versions,
            acceptedAt: Date(timeIntervalSince1970: 1_792_180_000), adultConfirmed: true,
            status: .updateRequired, requiredVersions: current.versions)
        preferences.set(try JSONEncoder().encode(pending), forKey: KikiConsentStore.storageKey)
        preferences.set("preserved-login-preference", forKey: "cover-install-marker")
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "deviceSecret": "existing-device"])
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            return (200, data)
        }
        let consent = KikiConsentStore(documents: oldDocuments, defaults: preferences,
            identity: identity, apiProvider: { mock.client })
        XCTAssertTrue(consent.requiresDocumentRefresh)
        XCTAssertFalse(consent.requiresAppUpdate)
        XCTAssertFalse(consent.canAccept)
        XCTAssertEqual(consent.presentation, .checking)
        XCTAssertThrowsError(try consent.accept())

        await consent.refreshDocuments()

        XCTAssertEqual(consent.documents?.versions, current.versions)
        XCTAssertTrue(consent.hasVerifiedRemoteDocuments)
        XCTAssertFalse(consent.requiresDocumentRefresh)
        XCTAssertTrue(consent.canAccept)
        XCTAssertFalse(consent.hasCurrentConsent, "Downloading a replacement agreement must not accept it")
        XCTAssertEqual(consent.presentation, .acceptanceRequired)
        XCTAssertEqual(consent.receipt, pending, "An update must preserve the prior decision until the user acts")
        XCTAssertEqual(preferences.string(forKey: "cover-install-marker"), "preserved-login-preference")
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertEqual(identity.values["sessionToken"], "existing-session")
        let cached = try XCTUnwrap(preferences.data(forKey: KikiConsentStore.documentsStorageKey))
        XCTAssertEqual(try KikiLegalBundle.decodeValidated(cached).versions, current.versions)

        try consent.accept()

        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt?.status, .accepted)
        XCTAssertEqual(consent.presentation, .accepted)
        XCTAssertEqual(try consent.acceptance().documentHash, current.documentHash)
        XCTAssertEqual(preferences.string(forKey: "cover-install-marker"), "preserved-login-preference")
    }

    func testColdLaunchVerifiesExistingAcceptedReceiptWithoutRequiringAnotherAcceptance() async throws {
        let preferences = defaults()
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        let server = try KikiLegalBundle.decodeValidated(data)
        let existing = KikiConsentStore.Receipt(versions: server.versions,
            acceptedAt: Date(timeIntervalSince1970: 1_792_180_000), adultConfirmed: true,
            status: .accepted)
        let persisted = try JSONEncoder().encode(existing)
        preferences.set(persisted, forKey: KikiConsentStore.storageKey)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            requests.append("GET /v1/legal/documents")
            return (200, data)
        }
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "deviceSecret": "existing-device"])
        let consent = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { mock.client })
        XCTAssertFalse(consent.hasVerifiedRemoteDocuments)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertEqual(consent.presentation, .checking, "Cold launch must keep the launch screen visible instead of flashing a signature page")
        XCTAssertEqual(consent.receipt, existing)

        await consent.refreshDocuments()

        XCTAssertTrue(consent.hasVerifiedRemoteDocuments)
        XCTAssertTrue(consent.hasCurrentConsent, "Verifying the same agreement must restore the user's existing decision without another button action")
        XCTAssertEqual(consent.presentation, .accepted, "A verified existing signature routes directly to account restoration")
        XCTAssertEqual(try consent.acceptance(), KikiLegalAcceptance(versions: server.versions,
            accepted: true, adultConfirmed: true))
        XCTAssertEqual(consent.receipt, existing)
        XCTAssertEqual(consent.receipt?.acceptedAt, existing.acceptedAt)
        XCTAssertEqual(preferences.data(forKey: KikiConsentStore.storageKey), persisted,
                       "Fetching the same revision must not rewrite the saved receipt")
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertEqual(identity.values["sessionToken"], "existing-session")
        XCTAssertEqual(requests.values, ["GET /v1/legal/documents"])
    }

    func testCurrentServerDocumentsAreAuthoritativeEvenWhenOlderThanTheApplicationBundle() async throws {
        let packaged = try XCTUnwrap(KikiLegalBundle.bundled)
        let data = try remoteLegalFixture(version: "2026-01-01-r1")
        let server = try KikiLegalBundle.decodeValidated(data)
        let preferences = defaults()
        let pending = KikiConsentStore.Receipt(versions: packaged.versions,
            acceptedAt: Date(timeIntervalSince1970: 1_792_180_000), adultConfirmed: true,
            status: .updateRequired, requiredVersions: packaged.versions)
        preferences.set(try JSONEncoder().encode(pending), forKey: KikiConsentStore.storageKey)
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            return (200, data)
        }
        let identity = TestIdentity()
        let consent = KikiConsentStore(documents: packaged, defaults: preferences, identity: identity,
            apiProvider: { mock.client })

        XCTAssertNotEqual(packaged.versions, server.versions)
        await consent.refreshDocuments()

        XCTAssertEqual(consent.documents?.versions, server.versions)
        XCTAssertTrue(consent.canAccept)
        XCTAssertFalse(consent.requiresAppUpdate)
        XCTAssertEqual(consent.receipt?.status, .updateRequired)
        XCTAssertEqual(consent.receipt?.requiredVersions, server.versions,
                       "A persisted requirement cannot pin the app to a superseded server revision")
        XCTAssertFalse(consent.hasCurrentConsent)
        try consent.accept()
        XCTAssertEqual(consent.receipt?.versions, server.versions)
        XCTAssertEqual(try consent.acceptance().privacyVersion, "2026-01-01-r1")
        XCTAssertEqual(identity.readCount, 0)
    }

    func testRemoteDocumentCacheRemainsReadableOfflineButCannotRestoreConsentBeforeServerVerification() async throws {
        let preferences = defaults()
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        let server = try KikiLegalBundle.decodeValidated(data)
        let identity = TestIdentity()
        let online = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            return (200, data)
        }
        let original = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { online.client })
        await original.refreshDocuments()
        try original.accept()
        let decision = original.receipt
        let offline = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            throw URLError(.notConnectedToInternet)
        }
        let restarted = KikiConsentStore(defaults: preferences, identity: identity, apiProvider: { offline.client })

        XCTAssertEqual(restarted.documents?.versions, server.versions, "Downloaded text must survive a cover install and cold launch")
        XCTAssertFalse(restarted.hasVerifiedRemoteDocuments)
        XCTAssertFalse(restarted.hasCurrentConsent)
        XCTAssertFalse(restarted.canAccept)
        XCTAssertEqual(restarted.presentation, .checking)
        XCTAssertThrowsError(try restarted.acceptance())
        await restarted.refreshDocuments()
        XCTAssertEqual(restarted.documents?.documents.first?.sections.first?.paragraphs,
                       server.documents.first?.sections.first?.paragraphs)
        XCTAssertEqual(restarted.receipt, decision)
        XCTAssertFalse(restarted.hasCurrentConsent)
        XCTAssertFalse(restarted.canAccept)
        XCTAssertNotNil(restarted.documentError)
        XCTAssertEqual(restarted.presentation, .checking, "A failed check offers retry without asking the user to sign again")
        XCTAssertEqual(identity.readCount, 0)
        let mock = KikiAPIMockServer { _ in XCTFail("An unverified cache must not activate account or room services"); return (500, Data()) }
        var sdkCreated = 0
        let store = KikiAppStore(consent: restarted, identity: identity,
            apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient },
            rtcProvider: { sdkCreated += 1; return TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertEqual(sdkCreated, 0)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertFalse(store.isAuthenticated)
    }

    func testMismatchedRemoteDocumentHashIsRejectedWithoutReplacingTheReadableBundleOrCache() async throws {
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["updatedAt"] = "2026-10-22"
        let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try KikiLegalBundle.decodeValidated(corrupt))
        let preferences = defaults()
        let packaged = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            return (200, corrupt)
        }
        let consent = KikiConsentStore(documents: packaged, defaults: preferences, identity: TestIdentity(),
            apiProvider: { mock.client })

        await consent.refreshDocuments()

        XCTAssertEqual(consent.documents?.versions, packaged.versions)
        XCTAssertFalse(consent.hasVerifiedRemoteDocuments)
        XCTAssertFalse(consent.canAccept)
        XCTAssertNotNil(consent.documentError)
        XCTAssertNil(preferences.data(forKey: KikiConsentStore.documentsStorageKey))
        XCTAssertNil(consent.receipt)
    }

    func testFailedPublicDocumentRequestCanRetryWithoutSendingAccountCredentials() async throws {
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        let requests = TestRequests()
        let identity = TestIdentity(values: ["sessionToken": "must-not-send", "deviceSecret": "must-not-read"])
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            requests.append("GET /v1/legal/documents")
            if requests.values.count == 1 {
                return (503, Data(#"{"detail":"协议服务暂不可用"}"#.utf8))
            }
            return (200, data)
        }
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, apiProvider: { mock.client })

        await consent.refreshDocuments()
        XCTAssertFalse(consent.canAccept)
        XCTAssertNotNil(consent.documentError)
        XCTAssertFalse(consent.isRefreshingDocuments)
        XCTAssertEqual(consent.presentation, .checking)
        XCTAssertThrowsError(try consent.accept())
        await consent.refreshDocuments()

        XCTAssertEqual(requests.values.count, 2)
        XCTAssertTrue(consent.hasVerifiedRemoteDocuments)
        XCTAssertTrue(consent.canAccept)
        XCTAssertNil(consent.documentError)
        XCTAssertEqual(consent.presentation, .acceptanceRequired, "Only a completed check with no current decision opens the signature page")
        XCTAssertFalse(consent.isRefreshingDocuments)
        XCTAssertNil(consent.receipt)
        XCTAssertEqual(identity.readCount, 0)
        XCTAssertEqual(identity.values["sessionToken"], "must-not-send")
    }

    func testASecondServerRevisionRequiresANewExplicitAcceptance() async throws {
        let firstData = try remoteLegalFixture(version: "2026-10-21-r10")
        let secondData = try remoteLegalFixture(version: "2026-10-22-r11")
        let second = try KikiLegalBundle.decodeValidated(secondData)
        let requests = TestRequests()
        let mock = KikiAPIMockServer { request in
            assertPublicLegalRequest(request)
            requests.append("documents")
            return (200, requests.values.count == 1 ? firstData : secondData)
        }
        let identity = TestIdentity()
        let consent = KikiConsentStore(defaults: defaults(), identity: identity, apiProvider: { mock.client })
        await consent.refreshDocuments()
        try consent.accept()
        let firstDecision = consent.receipt
        XCTAssertTrue(consent.hasCurrentConsent)

        await consent.refreshDocuments()

        XCTAssertEqual(consent.documents?.versions, second.versions)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertTrue(consent.canAccept)
        XCTAssertEqual(consent.receipt, firstDecision)
        XCTAssertThrowsError(try consent.acceptance())
        try consent.accept()
        XCTAssertTrue(consent.hasCurrentConsent)
        XCTAssertEqual(consent.receipt?.versions, second.versions)
        XCTAssertEqual(identity.readCount, 0)
    }

    func testInvalidCachedDocumentHashFallsBackToPackagedReadingWithoutEnablingAcceptance() async throws {
        let preferences = defaults()
        let data = try remoteLegalFixture(version: "2026-10-21-r10")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["updatedAt"] = "tampered-after-validation"
        preferences.set(try JSONSerialization.data(withJSONObject: object), forKey: KikiConsentStore.documentsStorageKey)
        let packaged = try XCTUnwrap(KikiLegalBundle.bundled)
        let identity = TestIdentity()
        let consent = KikiConsentStore(documents: packaged, defaults: preferences, identity: identity,
            apiProvider: { XCTFail("Initialization must not create a network client"); return .shared })

        XCTAssertEqual(consent.documents?.versions, packaged.versions)
        XCTAssertFalse(consent.hasVerifiedRemoteDocuments)
        XCTAssertFalse(consent.canAccept)
        XCTAssertFalse(consent.hasCurrentConsent)
        XCTAssertEqual(identity.readCount, 0)
    }
}

private func assertPublicLegalRequest(_ request: URLRequest, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(request.url?.path, "/v1/legal/documents", file: file, line: line)
    XCTAssertEqual(request.httpMethod, "GET", file: file, line: line)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), file: file, line: line)
    XCTAssertNil(request.httpBody, file: file, line: line)
    XCTAssertNil(request.httpBodyStream, file: file, line: line)
    XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
}

private func remoteLegalFixture(version: String) throws -> Data {
    let documents: [[String: Any]] = ["privacy", "terms", "sdk", "permissions"].map { id in
        ["id": id, "title": "服务器完整协议 \(id)", "version": version,
         "sections": [["title": "最新协议正文", "paragraphs": ["完整的 \(version) 正文，可以离线阅读。", "https://kiki.group/legal/\(id)"]]]]
    }
    var object: [String: Any] = [
        "schemaVersion": 1, "privacyVersion": version, "termsVersion": version,
        "updatedAt": "2026-10-21", "minimumAge": 18,
        "operator": ["name": "Kiki 开发者", "type": "个人开发者", "email": "support@kiki.group"],
        "documents": documents
    ]
    let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    object["documentHash"] = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

extension KikiStartupPermissionsTests {
    func testNewPreparationJoinsAnOutstandingSystemPromptInsteadOfRequestingTwice() async throws {
        let consent = try consent(), events = KikiStartupEventLog(), gate = KikiStartupTestGate()
        let network = KikiStartupNetworkMock(events: events), notifications = KikiStartupNotificationMock(events: events)
        notifications.requestGate = gate
        let flow = KikiStartupPermissions(network: network, notifications: notifications, waitForForeground: { })
        let old = Task { await flow.begin(consent: consent) }
        defer { gate.finish() }
        try await settle { gate.isWaiting }
        flow.cancel()
        XCTAssertFalse(flow.isReady)
        let current = Task { await flow.begin(consent: consent) }
        try await settle { network.calls == 2 && notifications.statusCalls >= 2 }
        XCTAssertEqual(notifications.requestCalls, 1, "Cancelling app preparation cannot dismiss an outstanding operating-system prompt")
        gate.finish()
        await old.value; await current.value
        XCTAssertTrue(flow.isReady)
        XCTAssertEqual(notifications.requestCalls, 1)
        XCTAssertEqual(flow.notificationPermission, .authorized)
    }
}

extension KikiConsentTests {
    func testInboxClearInvalidatesLateUnreadFetchAndClearsDraftOnlyAfterAcknowledgement() async throws {
        do {
            let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
            let docs = try XCTUnwrap(KikiLegalBundle.bundled)
            let arrived = expectation(description: "Pre-clear inbox snapshot")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let fetches = TestRequests()
            let requests = TestRequests()
            let listPath = "/v1/social/conversations"
            let clearPath = "/v1/social/conversations/kiki_fixture0002/clear"
            let nonce = UUID(), through = UUID().uuidString
            let mock = KikiConcurrentConsentServer { request in
                if request.url?.path == listPath {
                    fetches.append("fetch")
                    let old = fetches.values.count == 1
                    if old { arrived.fulfill(); _ = release.wait(timeout: .now() + 5) }
                    let body: [String: Any] = ["conversations": [], "nextCursor": NSNull(), "unreadCount": old ? 8 : 0]
                    return (200, try JSONSerialization.data(withJSONObject: body))
                }
                if request.url?.path == clearPath {
                    let body = try requestBody(request)
                    requests.append(try XCTUnwrap(body["requestID"] as? String))
                    XCTAssertEqual(UUID(uuidString: requests.values.last!), nonce)
                    XCTAssertEqual(body["throughMessageID"] as? String, through)
                    return (200, Data(#"{"ok":true}"#.utf8))
                }
                return try consentResponse(request, documents: docs)
            }
            let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
            try consent.accept()
            let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
            await store.start()
            store.updateDirectDraft("删除前的草稿", personID: "kiki_fixture0002")
            let snapshot = Task {
                _ = try await store.socialConversations()
            }
            await fulfillment(of: [arrived], timeout: 3)
            try await store.clearInboxEntry(inboxMutationEntry(), throughID: through, requestID: nonce)
            XCTAssertEqual(store.unreadDirectMessageCount, 0)
            XCTAssertNil(store.directDrafts["kiki_fixture0002"])
            XCTAssertEqual(store.directHistoryRevision["kiki_fixture0002"], 1)
            release.signal(); try await snapshot.value
            XCTAssertEqual(store.unreadDirectMessageCount, 0, "Pre-clear network responses cannot restore the badge")
            XCTAssertEqual(requests.values.count, 1)
            XCTAssertEqual(fetches.values.count, 2)
            await store.logout()
        }
    }

    func testFailedInboxClearPreservesDraftAndRetriesTheOriginalCutoffAndID() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let writes = TestRequests()
        let through = UUID().uuidString, nonce = UUID()
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/conversations/kiki_fixture0002/clear" {
                let body = try requestBody(request)
                XCTAssertEqual(body["throughMessageID"] as? String, through)
                writes.append(try XCTUnwrap(body["requestID"] as? String))
                return writes.values.count == 1 ? (503, Data(#"{"detail":"结果未确认"}"#.utf8)) : (200, Data(#"{"ok":true}"#.utf8))
            }
            if request.url?.path == "/v1/social/conversations" { return (200, Data(#"{"conversations":[],"nextCursor":null,"unreadCount":0}"#.utf8)) }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        store.updateDirectDraft("尚未发送", personID: "kiki_fixture0002")
        do { try await store.clearInboxEntry(inboxMutationEntry(), throughID: through, requestID: nonce); XCTFail("Unconfirmed clear must not succeed") } catch { }
        XCTAssertEqual(store.directDrafts["kiki_fixture0002"], "尚未发送")
        XCTAssertNil(store.directHistoryRevision["kiki_fixture0002"])
        try await store.clearInboxEntry(inboxMutationEntry(), throughID: through, requestID: nonce)
        XCTAssertNil(store.directDrafts["kiki_fixture0002"])
        XCTAssertEqual(store.directHistoryRevision["kiki_fixture0002"], 1)
        XCTAssertEqual(writes.values.count, 2); XCTAssertEqual(Set(writes.values).count, 1)
        await store.logout()
    }

    func testInboxClearSuccessAfterLogoutCannotTouchTheNextLocalSession() async throws {
        let identity = TestIdentity(values: ["sessionToken": "existing-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let arrived = expectation(description: "Clear request in flight")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let mock = KikiConcurrentConsentServer { request in
            if request.url?.path == "/v1/social/conversations/kiki_fixture0002/clear" {
                arrived.fulfill(); _ = release.wait(timeout: .now() + 5)
                return (200, Data(#"{"ok":true}"#.utf8))
            }
            return try consentResponse(request, documents: docs)
        }
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { mock.client }, voiceAPIProvider: { mock.voiceClient }, rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        let action = Task {
            try await store.clearInboxEntry(inboxMutationEntry(), throughID: UUID().uuidString, requestID: UUID())
        }
        await fulfillment(of: [arrived], timeout: 3)
        await store.logout(); let revision = store.notificationHistoryRevision
        release.signal()
        do { try await action.value; XCTFail("A stale session cannot acknowledge the clear") } catch { }
        XCTAssertTrue(store.directHistoryRevision.isEmpty)
        XCTAssertTrue(store.directDrafts.isEmpty)
        XCTAssertEqual(store.notificationHistoryRevision, revision)
        XCTAssertFalse(store.isAuthenticated)
    }

    private func inboxMutationEntry() -> KikiInboxEntry {
        let person = KikiPerson(id: "kiki_fixture0002", name: "朋友", bio: "", avatarIndex: 0, avatarURL: nil, following: true, followsYou: true, mutual: true, followingCount: 1, followerCount: 1, currentRoomID: nil)
        let conversation = KikiConversation(id: "test-conversation", person: person, lastMessage: nil, unreadCount: 8, canSend: true)
        return KikiInboxEntry(content: .direct(conversation), activityAt: nil, preview: "聊天", unreadCount: 8)
    }
}

extension KikiConsentTests {
    func testRelationshipFollowFallbackBecomesAuthoritativeAfterSummaryLoads() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            if request.url?.path == "/v1/social/relationships/ids" {
                return (200, Data(#"{"followingIDs":[],"followingCount":0,"followerCount":0}"#.utf8))
            }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        let followedSnapshot = socialFixturePerson(following: true)
        XCTAssertTrue(store.isFollowing(followedSnapshot), "The first profile render must use the author relationship before the summary finishes")
        XCTAssertFalse(store.isFollowing(socialFixturePerson(following: false)))
        await store.refreshSocialSummary()
        XCTAssertFalse(store.isFollowing(followedSnapshot), "A loaded authoritative ID set overrides stale person data")
        await store.logout()
    }

    func testRelationshipSuccessfulFollowOrUnfollowSurvivesSummaryFailureAndThenReconciles() async throws {
        for enabled in [true, false] {
            let docs = try XCTUnwrap(KikiLegalBundle.bundled)
            let mode = TestRequests(), mutations = TestRequests()
            let person = socialFixturePerson(following: !enabled)
            var confirmed = person; confirmed.following = enabled
            let response = try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmed))])
            let mock = KikiAPIMockServer { request in
                if request.url?.path == "/v1/social/follows/" + person.id {
                    XCTAssertEqual(request.httpMethod, enabled ? "PUT" : "DELETE")
                    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
                    XCTAssertNotNil(try requestBody(request)["requestID"])
                    mutations.append(request.httpMethod ?? "")
                    return (200, response)
                }
                if request.url?.path == "/v1/social/relationships/ids" {
                    if mode.values.isEmpty { return (503, Data(#"{"detail":"临时不可用"}"#.utf8)) }
                    let ids = enabled ? [] : [person.id]
                    return (200, try JSONSerialization.data(withJSONObject: ["followingIDs": ids, "followingCount": ids.count, "followerCount": 0]))
                }
                return try p1VisualResponse(request, documents: docs)
            }
            let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
            let result = try await store.setFollowing(person, enabled: enabled)
            XCTAssertEqual(result.following, enabled)
            XCTAssertEqual(store.isFollowing(person), enabled, "A confirmed mutation cannot revert merely because the subsequent summary fails")
            XCTAssertEqual(mutations.values.count, 1, "Metadata refresh must not repeat the follow mutation")
            XCTAssertTrue(store.isAuthenticated)
            mode.append("summary recovered")
            await store.refreshSocialSummary()
            XCTAssertEqual(store.isFollowing(person), !enabled, "A later successful summary reconciles the relationship across devices")
            await store.logout()
            XCTAssertFalse(store.isFollowing(socialFixturePerson(following: true)), "A logged-out view cannot retain a relationship from an old profile object")
            XCTAssertTrue(store.followingUserIDs.isEmpty)
        }
    }

    func testRelationshipBlockOverridesStaleAuthorFollowingWithoutChangingOtherPeople() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { try p1VisualResponse($0, documents: docs) }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        let author = socialFixturePerson(following: true)
        let unrelated = KikiPerson(id: "kiki_fixture0003", name: author.name, bio: author.bio,
            avatarIndex: author.avatarIndex, avatarURL: nil, following: true, followsYou: false, mutual: false,
            followingCount: 0, followerCount: 0, currentRoomID: nil)
        XCTAssertTrue(store.isFollowing(author)); XCTAssertTrue(store.isFollowing(unrelated))
        let revision = store.socialPrivacyRevision
        store.socialPolicyChanged(userID: author.id, blocked: true)
        XCTAssertGreaterThan(store.socialPrivacyRevision, revision)
        XCTAssertFalse(store.isFollowing(author), "The old author.following flag cannot resurrect a blocked relationship")
        XCTAssertTrue(store.isFollowing(unrelated))
        await store.logout()
        XCTAssertFalse(store.isFollowing(unrelated))
    }

    func testRelationshipLateFollowResponseCannotRestoreRelationshipAfterLogout() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let author = socialFixturePerson(following: false)
        var followed = author; followed.following = true
        let response = try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(followed))])
        let arrived = expectation(description: "Follow request has reached the local fixture")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let mock = KikiConcurrentConsentServer { request in
            if request.url?.path == "/v1/social/follows/" + author.id {
                arrived.fulfill(); _ = release.wait(timeout: .now() + 5)
                return (200, response)
            }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        let action = Task { try await store.setFollowing(author, enabled: true) }
        await fulfillment(of: [arrived], timeout: 3)
        await store.logout(); let revision = store.socialRevision
        release.signal()
        do { _ = try await action.value; XCTFail("The signed-out session cannot acknowledge this follow") } catch { }
        XCTAssertFalse(store.isAuthenticated)
        XCTAssertFalse(store.isFollowing(followed))
        XCTAssertTrue(store.followingUserIDs.isEmpty)
        XCTAssertEqual(store.socialRevision, revision, "An old account response cannot publish a relationship update after logout")
    }

    private func socialFixturePerson(following: Bool) -> KikiPerson {
        KikiPerson(id: "kiki_fixture0002", name: "小岛", bio: "喜欢散步和音乐。", avatarIndex: 4, avatarURL: nil,
                   following: following, followsYou: false, mutual: false, followingCount: 12, followerCount: 18, currentRoomID: nil)
    }

    private func socialFixtureStore(docs: KikiLegalBundle, api: KikiAccountAPIClient, voice: KikiAPIClient) async throws -> KikiAppStore {
        let identity = TestIdentity(values: ["sessionToken": "social-fixture-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let consent = KikiConsentStore(documents: docs, defaults: defaults(), identity: identity, apiProvider: { api }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { api }, voiceAPIProvider: { voice },
                                  rtcProvider: { TestRTC() }, appleProvider: { TestApple() })
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
        return store
    }
}

extension KikiConsentTests {
    func testInboxNotificationDeletionReloadsToCenteredEmptyStateWithNativeRefresh() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = InboxDeleteUIFixture(person: socialFixturePerson(following: false))
        let mock = KikiAPIMockServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let original = window.frame
            let host = UIHostingController(rootView: mainTabVisualScreen(AnyView(
                KikiMessagesView(store: store).environment(\.scenePhase, .active))).preferredColorScheme(.light))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { fixture.pageReads > 0 }
            try await Task.sleep(nanoseconds: 250_000_000)
            let initialPage = try await store.socialInbox()
            let entry = try XCTUnwrap(initialPage.entries.first)
            XCTAssertEqual(entry.preview, "关注了你")
            let before = fixture.pageReads
            try await store.clearInboxEntry(entry, throughID: fixture.notificationID, requestID: UUID())
            try await self.waitUntil { fixture.pageReads > before }
            XCTAssertEqual(fixture.deletes, 1)
            XCTAssertEqual(store.unreadNotificationCount, 0)
            let clearedPage = try await store.socialInbox()
            XCTAssertTrue(clearedPage.entries.isEmpty)
            let folder = URL(fileURLWithPath: "/tmp/kiki-inbox-empty-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            for (name, size, scheme) in [
                ("phone-light", CGSize(width: 375, height: 812), ColorScheme.light),
                ("phone-dark", CGSize(width: 375, height: 812), ColorScheme.dark),
                ("tablet-light", CGSize(width: 744, height: 1133), ColorScheme.light),
                ("tablet-dark", CGSize(width: 1133, height: 744), ColorScheme.dark)
            ] {
                window.rootViewController = UIHostingController(rootView: mainTabVisualScreen(AnyView(
                    KikiMessagesView(store: store).environment(\.scenePhase, .active))).preferredColorScheme(scheme))
                window.frame = CGRect(origin: original.origin, size: size)
                window.rootViewController?.view.frame = window.bounds; window.makeKeyAndVisible()
                try await Task.sleep(nanoseconds: 500_000_000)
                window.layoutIfNeeded()
                let scroll = try XCTUnwrap(self.socialScrollViews(window).first { $0.refreshControl != nil })
                XCTAssertNotNil(scroll.refreshControl, "Centering the empty overlay must preserve the native pull refresh control")
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image); attachment.name = "inbox-empty-" + device + "-" + name
                attachment.lifetime = .keepAlways; self.add(attachment)
                try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + ".png"))
            }
            window.frame = original
        }
        await store.logout()
    }

    private func withSocialWindow(_ action: (UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.endEditing(true); window.rootViewController = nil; window.isHidden = true; previous?.makeKeyAndVisible() }
        try await action(window)
    }
    private func socialEditableViews(_ view: UIView) -> [UIView] {
        let own: [UIView] = (view is UITextField || view is UITextView) ? [view] : []
        return own + view.subviews.flatMap(socialEditableViews)
    }
    private func socialScrollViews(_ view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap(socialScrollViews)
    }
}

private final class InboxDeleteUIFixture {
    let notificationID = "77777777-7777-4777-8777-777777777777"
    private let person: KikiPerson
    private let lock = NSLock()
    private var deleted = false
    private var reads = 0
    private var deleteCount = 0
    init(person: KikiPerson) { self.person = person }
    var pageReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var deletes: Int { lock.lock(); defer { lock.unlock() }; return deleteCount }
    func response(_ request: URLRequest) throws -> (Int, Data)? {
        lock.lock(); defer { lock.unlock() }
        let path = request.url?.path ?? ""
        let routes = ["/v1/social/inbox", "/v1/social/notifications", "/v1/social/notifications/" + notificationID]
        guard routes.contains(path) else { return nil }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer social-fixture-session")
        if path == routes[2] {
            XCTAssertEqual(request.httpMethod, "DELETE")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["requestID"])
            XCTAssertNotNil(UUID(uuidString: body["requestID"] as? String ?? ""))
            deleted = true; deleteCount += 1
            return (200, Data("{\"ok\":true}".utf8))
        }
        let actor = try JSONSerialization.jsonObject(with: JSONEncoder().encode(person))
        let notice: [String: Any] = ["id": notificationID, "seq": 1, "kind": "follow", "actor": actor,
            "text": "关注了你", "createdAt": Date().timeIntervalSince1970, "readAt": NSNull(), "roomID": NSNull()]
        let body: [String: Any]
        if path == "/v1/social/inbox" {
            reads += 1
            body = ["entries": deleted ? [] : [["kind": "notification", "notification": notice]],
                    "nextCursor": NSNull(), "unreadNotificationCount": deleted ? 0 : 1, "unreadDirectMessageCount": 0]
        } else {
            body = ["notifications": deleted ? [] : [notice], "unreadCount": deleted ? 0 : 1, "nextCursor": NSNull()]
        }
        return (200, try JSONSerialization.data(withJSONObject: body))
    }
}

extension KikiConsentTests {
    func testRoomNotificationNavigationResolvesTheAccountNoticeThenUsesFreshVoiceRoomAndConsumesOnce() async throws {
        let fixture = try await RoomNotificationNavigationFixture(defaults: defaults())
        let store = fixture.store, state = fixture.state
        let boundary = state.requests.count
        store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
        let request = try XCTUnwrap(store.pendingRoomNotification)
        store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
        XCTAssertEqual(store.pendingRoomNotification?.id, request.id, "Repeated taps share the current intent")
        let room = try await store.roomForNotificationNavigation(request.id)
        XCTAssertTrue(fixture.rtc.presentedRoomIDs.isEmpty, "Resolving permission and a fresh room must not present media yet")
        let reads = Array(state.requests.dropFirst(boundary))
        XCTAssertEqual(reads.map { $0.url!.path }, [state.destinationPath, "/v1/rooms"])
        XCTAssertEqual(reads.map(\.httpMethod), ["GET", "GET"])
        XCTAssertFalse(try XCTUnwrap(reads.first?.url?.host).hasPrefix("voice-"))
        XCTAssertEqual(reads.first?.value(forHTTPHeaderField: "Authorization"), "Bearer room-notification-session")
        XCTAssertTrue(try XCTUnwrap(reads.last?.url?.host).hasPrefix("voice-"))
        XCTAssertEqual(reads.last?.value(forHTTPHeaderField: "Authorization"), "Bearer voice-session")
        let completed = try await store.completeRoomNotificationNavigation(request.id, room: room)
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.rtc.presentedRoomIDs, [state.roomID])
        XCTAssertNil(store.pendingRoomNotification)
        do { _ = try await store.completeRoomNotificationNavigation(request.id, room: room); XCTFail("A consumed intent cannot present twice") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.rtc.presentedRoomIDs, [state.roomID])
        store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
        let unresolved = try XCTUnwrap(store.pendingRoomNotification)
        do { _ = try await store.completeRoomNotificationNavigation(unresolved.id, room: room); XCTFail("A previously resolved room cannot bypass this intent's account authorization and fresh lookup") }
        catch {
            guard case KikiAPIError.invalidResponse = error else { XCTFail("Expected rejection of an unresolved intent, received \(error)"); throw error }
        }
        XCTAssertEqual(fixture.rtc.presentedRoomIDs, [state.roomID])
        let beforeInvalid = state.requests.count
        do { _ = try await fixture.server.client.socialNotificationDestination("not-a-uuid", token: "room-notification-session"); XCTFail("Invalid notification UUID must be rejected locally") }
        catch { XCTAssertTrue(error is KikiAPIError) }
        XCTAssertEqual(state.requests.count, beforeInvalid)
        await store.logout()
    }

    func testRoomNotificationNavigationRejectsDeniedMismatchedEndedAndLiveStreamDestinationsBeforeRTC() async throws {
        for failure in RoomNotificationNavigationState.Failure.allCases {
            let fixture = try await RoomNotificationNavigationFixture(defaults: defaults())
            fixture.state.setFailure(failure)
            let state = fixture.state, store = fixture.store
            let boundary = state.requests.count
            store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
            let request = try XCTUnwrap(store.pendingRoomNotification)
            do {
                let room = try await store.roomForNotificationNavigation(request.id)
                _ = try await store.completeRoomNotificationNavigation(request.id, room: room)
                XCTFail("An unavailable or unauthorized room must not open: \(failure)")
            } catch { }
            XCTAssertTrue(fixture.rtc.presentedRoomIDs.isEmpty)
            if failure == .denied || failure == .mismatchedNotice {
                XCTAssertFalse(state.requests.dropFirst(boundary).contains { $0.url?.path == "/v1/rooms" },
                               "A rejected account destination cannot proceed to voice lookup")
            }
            await store.logout()
        }
    }

    func testLateRoomNotificationResolutionCannotPresentAfterPrivacySessionOrNewDirectIntent() async throws {
        for boundary in ["privacy-during-destination", "session-during-rooms", "direct-during-rooms"] {
            let fixture = try await RoomNotificationNavigationFixture(defaults: defaults())
            let store = fixture.store, state = fixture.state
            store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
            let request = try XCTUnwrap(store.pendingRoomNotification)
            let arrived = expectation(description: boundary)
            let gate = state.holdNext(path: boundary == "privacy-during-destination" ? state.destinationPath : "/v1/rooms") { arrived.fulfill() }
            defer { gate.signal() }
            let old = Task {
                let room = try await store.roomForNotificationNavigation(request.id)
                return try await store.completeRoomNotificationNavigation(request.id, room: room)
            }
            await fulfillment(of: [arrived], timeout: 3)
            if boundary == "privacy-during-destination" { store.socialPolicyChanged(userID: "kiki_fixture0002", blocked: true) }
            else if boundary == "session-during-rooms" { await store.logout(); try await store.loginWithApple() }
            else { store.requestDirectConversation(socialFixturePerson(following: true)) }
            let replacement = store.pendingDirectConversation?.id
            gate.signal()
            if case .success = await old.result { XCTFail("A superseded response must not finish the old room intent") }
            XCTAssertTrue(fixture.rtc.presentedRoomIDs.isEmpty)
            XCTAssertNil(store.pendingRoomNotification)
            XCTAssertEqual(store.pendingDirectConversation?.id, replacement, "A late room response cannot replace the newer direct intent")
            await store.logout()
        }
    }

    func testRoomNotificationReusesPresentedRoomAndResumesMinimizedRoomThroughExistingRTCPath() async throws {
        let fixture = try await RoomNotificationNavigationFixture(defaults: defaults())
        let store = fixture.store, state = fixture.state
        fixture.rtc.currentSDKRoomID = state.roomID
        fixture.rtc.isPresentingRoom = true
        store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
        let first = try XCTUnwrap(store.pendingRoomNotification)
        let room = try await store.roomForNotificationNavigation(first.id)
        let reused = try await store.completeRoomNotificationNavigation(first.id, room: room)
        XCTAssertTrue(reused)
        XCTAssertTrue(fixture.rtc.presentedRoomIDs.isEmpty, "The already presented room must retain its native controller")
        fixture.rtc.isPresentingRoom = false
        store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
        let resumed = try XCTUnwrap(store.pendingRoomNotification)
        let refreshedRoom = try await store.roomForNotificationNavigation(resumed.id)
        let completed = try await store.completeRoomNotificationNavigation(resumed.id, room: refreshedRoom)
        XCTAssertTrue(completed)
        XCTAssertEqual(fixture.rtc.presentedRoomIDs, [state.roomID], "A minimized same-room intent uses presentRoom's existing resume path once")
        await store.logout()
    }

    func testRoomNotificationColdPushResolvesOnlyTheMatchingAccountAndIgnoresInjectedRoomPayload() async throws {
        let deliveryID = UUID().uuidString
        let tap = try XCTUnwrap(KikiPushTap(payload: ["deliveryID": deliveryID, "accountTag": "room-fixture-account",
            "roomID": "lk_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "notificationID": UUID().uuidString, "body": "forged opening"]))
        XCTAssertEqual(tap, KikiPushTap(payload: ["deliveryID": deliveryID, "accountTag": "room-fixture-account"]))
        let fixture = try await RoomNotificationNavigationFixture(defaults: defaults(), coldTap: tap)
        let push = try XCTUnwrap(fixture.push)
        await push.refresh()
        try await waitForPush { push.navigation != nil }
        let navigation = try XCTUnwrap(push.navigation)
        guard case .room(let roomID, let notificationID) = navigation.content else {
            XCTFail("The authenticated destination must produce a room navigation intent"); await fixture.store.logout(); return
        }
        XCTAssertEqual(roomID, fixture.state.roomID)
        XCTAssertEqual(notificationID, fixture.state.notificationID)
        XCTAssertEqual(fixture.store.pendingRoomNotification?.roomID, roomID,
                       "A cold tap must publish the intent even if a full-screen room prevents Root from redrawing")
        XCTAssertEqual(fixture.store.pendingRoomNotification?.notificationID, notificationID)
        XCTAssertTrue(fixture.rtc.presentedRoomIDs.isEmpty, "APNs resolution publishes an intent; the native presenter owns media presentation")
        let resolves = fixture.state.requests.filter { $0.url?.path.hasPrefix("/v1/push/destinations/") == true }
        XCTAssertEqual(resolves.count, 1)
        XCTAssertEqual(resolves.first?.url?.lastPathComponent, deliveryID)
        XCTAssertEqual(resolves.first?.value(forHTTPHeaderField: "Authorization"), "Bearer room-notification-session")
        push.receiveTap(try XCTUnwrap(KikiPushTap(payload: ["deliveryID": UUID().uuidString, "accountTag": "another-account",
                                                         "roomID": fixture.state.roomID])))
        await push.refresh()
        XCTAssertEqual(fixture.state.requests.filter { $0.url?.path.hasPrefix("/v1/push/destinations/") == true }.count, 1,
                       "A different account tag must be rejected before resolving its destination")
        XCTAssertEqual(fixture.store.pendingRoomNotification?.notificationID, notificationID,
                       "An unrelated account's push cannot cancel the current account's room intent")
        await fixture.store.logout()
    }

    func testRoomNotificationNativePresenterDismissesProfileThenSelectsVoiceTabBeforeRTC() async throws {
        let fixture = try await RoomNotificationNavigationFixture(defaults: defaults())
        let store = fixture.store, state = fixture.state
        try await withSocialWindow { window in
            let tabs = KikiDirectNavigationFixtureTabs()
            let root = UIHostingController(rootView: KikiDirectNavigationFixture(store: store, tabs: tabs)
                .environment(\.scenePhase, .active))
            window.rootViewController = root; window.makeKeyAndVisible()
            try await self.waitUntil { nativeMainTabController(in: root) != nil }
            tabs.profile = self.socialFixturePerson(following: true)
            try await self.waitUntil { root.presentedViewController != nil }
            let profile = try XCTUnwrap(root.presentedViewController)
            try await self.waitUntil { !profile.isBeingPresented && profile.transitionCoordinator == nil }
            XCTAssertEqual(tabs.selectedTab, 0)
            var verifiedPresentation = false
            fixture.rtc.onPresentRoom = { roomID in
                XCTAssertEqual(roomID, state.roomID)
                XCTAssertNil(root.presentedViewController, "The actual profile sheet must finish dismissing before RTC opens")
                XCTAssertEqual(tabs.selectedTab, 0, "The native routing bridge selects the voice tab before opening media")
                verifiedPresentation = true
            }
            defer { fixture.rtc.onPresentRoom = nil }
            store.requestRoomNotification(roomID: state.roomID, notificationID: state.notificationID)
            try await self.waitUntil { verifiedPresentation && store.pendingRoomNotification == nil && tabs.profile == nil }
            XCTAssertEqual(fixture.rtc.presentedRoomIDs, [state.roomID])
            XCTAssertEqual(tabs.profileDismissals, 1, "Native dismissal must reconcile the real SwiftUI sheet binding once")
            XCTAssertNil(root.presentedViewController)
            XCTAssertTrue(store.directConversationPath.isEmpty)
        }
        await store.logout()
    }
}

@MainActor
private final class RoomNotificationNavigationFixture {
    let state = RoomNotificationNavigationState()
    let server: KikiConcurrentConsentServer
    let store: KikiAppStore
    let rtc = TestRTC()
    let push: KikiPushController?

    init(defaults: UserDefaults, coldTap: KikiPushTap? = nil) async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled), state = self.state
        server = KikiConcurrentConsentServer { try state.response($0, documents: docs) }
        let server = self.server, rtc = self.rtc
        let identity = TestIdentity(values: ["sessionToken": "room-notification-session", "appleSubject": "apple-subject", "appleSessionVersion": "2"])
        let consent = KikiConsentStore(documents: docs, defaults: defaults, identity: identity, apiProvider: { server.client }, requiresRemoteDocuments: false)
        try consent.accept()
        let store = KikiAppStore(consent: consent, identity: identity, apiProvider: { server.client }, voiceAPIProvider: { server.voiceClient },
                                 rtcProvider: { rtc }, appleProvider: { TestApple() })
        self.store = store
        if let coldTap {
            let system = TestPushSystem(); system.status = .denied
            let push = KikiPushController(system: system, identity: identity, environment: { nil })
            push.receiveTap(coldTap)
            push.attach(store)
            self.push = push
        } else { push = nil }
        await store.start()
        XCTAssertTrue(store.isAuthenticated)
    }
}

private final class RoomNotificationNavigationState: @unchecked Sendable {
    enum Failure: CaseIterable { case denied, mismatchedNotice, ended, liveStream }
    let roomID = "lk_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let notificationID = "66666666-6666-4666-8666-666666666666"
    var destinationPath: String { "/v1/social/notifications/" + notificationID + "/destination" }
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var failure: Failure?
    private var held: (path: String, gate: DispatchSemaphore, arrived: () -> Void)?
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return capturedRequests }
    func setFailure(_ value: Failure) { lock.lock(); defer { lock.unlock() }; failure = value }
    func holdNext(path: String, arrived: @escaping () -> Void) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); defer { lock.unlock() }; held = (path, gate, arrived)
        return gate
    }
    func response(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data) {
        let path = try XCTUnwrap(request.url?.path)
        lock.lock()
        capturedRequests.append(request)
        let failure = self.failure
        let waiting = held?.path == path ? held : nil
        if waiting != nil { held = nil }
        lock.unlock()
        waiting?.arrived(); _ = waiting?.gate.wait(timeout: .now() + 5)
        if path == destinationPath || path.hasPrefix("/v1/push/destinations/") {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse(request.url!.host!.hasPrefix("voice-"))
            if failure == .denied { return (403, Data(#"{"detail":"当前账号无法查看这条提醒"}"#.utf8)) }
            let body: [String: Any] = ["type": "notification", "roomID": roomID,
                                      "notificationID": failure == .mismatchedNotice ? "77777777-7777-4777-8777-777777777777" : notificationID]
            return (200, try JSONSerialization.data(withJSONObject: body))
        }
        if path == "/v1/rooms", request.httpMethod == "GET" {
            let room: [String: Any] = ["id": roomID, "title": "开房提醒测试", "host": "小岛", "hostID": "kiki_fixture0002",
                "category": "生活", "audience": 3, "isLive": failure == .liveStream, "theme": 0, "isCreatedByMe": false,
                "status": failure == .ended ? "ended" : "live", "createdAt": 1_800_000_000, "hostAvatarIndex": 4]
            return (200, try JSONSerialization.data(withJSONObject: ["rooms": [room]]))
        }
        if path == "/v1/history/" + roomID { return (200, Data(#"{"ok":true}"#.utf8)) }
        if path == "/v1/push/status" {
            return (200, Data(#"{"enabled":true,"registered":false,"badgeCount":1,"accountTag":"room-fixture-account"}"#.utf8))
        }
        if path.hasPrefix("/v1/push/devices/") { return (200, Data(#"{"ok":true}"#.utf8)) }
        return try p1VisualResponse(request, documents: documents)
    }
}

extension KikiConsentTests {
    func testMutualRelationshipActionRequestsChatWithoutConfirmationOrFollowMutation() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .mutual))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.mutualID) != nil }
            let button = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.mutualID))
            XCTAssertEqual(button.titleLabel?.text, "聊天")
            button.sendActions(for: .touchUpInside)
            try await self.waitUntil { store.pendingDirectConversation?.person.id == fixture.mutualID }
            XCTAssertEqual(fixture.mutations.count, 0, "Chat must only emit the existing direct-conversation intent")
            XCTAssertFalse(self.relationshipHasAlert(host), "Chat opens directly without a confirmation sheet")
        }
        await store.logout()
    }

    func testFollowingRelationshipButtonsKeepBothUnfollowedRowsAndAllowImmediateRefollow() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
            let initialReads = fixture.readCount(for: .following)
            for (userID, label) in [(fixture.followingID, "已关注"), (fixture.mutualID, "互相关注")] {
                let button = try XCTUnwrap(self.relationshipButton(in: window, userID: userID))
                XCTAssertEqual(button.titleLabel?.text, label)
                button.sendActions(for: .touchUpInside)
                try await self.waitUntil {
                    guard let current = self.relationshipButton(in: window, userID: userID) else { return false }
                    return fixture.mutations.contains { $0.personID == userID && $0.method == "DELETE" }
                        && current.isEnabled && current.titleLabel?.text == "关注"
                }
                XCTAssertFalse(self.relationshipHasAlert(host), "DELETE takes effect without an unfollow dialog")
            }
            XCTAssertFalse(store.isFollowing(fixture.initialFollowing))
            XCTAssertFalse(store.isFollowing(fixture.initialMutual))
            for (userID, label) in [(fixture.followingID, "已关注"), (fixture.mutualID, "互相关注")] {
                let refollow = try XCTUnwrap(self.relationshipButton(in: window, userID: userID))
                refollow.sendActions(for: .touchUpInside)
                try await self.waitUntil {
                    guard let current = self.relationshipButton(in: window, userID: userID) else { return false }
                    return current.isEnabled && current.titleLabel?.text == label
                }
            }
            XCTAssertEqual(fixture.mutations.map(\.method), ["DELETE", "DELETE", "PUT", "PUT"])
            XCTAssertEqual(fixture.readCount(for: .following), initialReads,
                           "Successful mutations update the buttons without refreshing the session's following membership")
            XCTAssertTrue(store.isFollowing(fixture.initialFollowing))
            XCTAssertTrue(store.isFollowing(fixture.initialMutual))
            XCTAssertFalse(self.relationshipHasAlert(host))
        }
        await store.logout()
    }

    func testFollowingUnfollowedRowSurvivesRelationshipTabSwitches() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
            let initialReads = fixture.readCount(for: .following)
            try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "关注" }
            for kind in [KikiRelationshipKind.mutual, .followers, .following] {
                let control = try XCTUnwrap(self.relationshipSegmentedControls(window).first)
                control.selectedSegmentIndex = try XCTUnwrap(KikiRelationshipKind.allCases.firstIndex(of: kind))
                control.sendActions(for: .valueChanged)
                if kind == .following {
                    try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "关注" }
                } else {
                    try await self.waitUntil {
                        fixture.readCount(for: kind) > 0
                            && self.relationshipButton(in: window, userID: fixture.followingID) == nil
                            && self.relationshipButton(in: window, userID: fixture.mutualID) != nil
                    }
                }
            }
            XCTAssertEqual(fixture.readCount(for: .following), initialReads,
                           "Switching tabs remains within the same following/fans module session")
            let refollow = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID))
            refollow.sendActions(for: .touchUpInside)
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "已关注" }
            XCTAssertEqual(fixture.mutations.map(\.method), ["DELETE", "PUT"])
        }
        await store.logout()
    }

    func testFollowingUnfollowedRowSurvivesViewingAndDismissingPublicProfile() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        do {
            try await withSocialWindow { window in
                let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
                window.rootViewController = host; window.makeKeyAndVisible()
                try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
                try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
                try await self.waitUntil {
                    guard let current = self.relationshipButton(in: window, userID: fixture.followingID) else { return false }
                    return current.isEnabled && current.titleLabel?.text == "关注"
                }
                let readsBeforeProfile = fixture.readCount(for: .following)
                guard let row = self.relationshipAccessibilityNodes(in: host.view).first(where: {
                    ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier == "relationships.person." + fixture.followingID
                }) else {
                    throw XCTSkip("This runtime does not expose the SwiftUI person row through public in-process accessibility containers.")
                }
                guard row.accessibilityActivate() else {
                    throw XCTSkip("This runtime does not support public accessibility activation of the SwiftUI person row.")
                }
                try await self.waitUntil {
                    guard let profile = host.presentedViewController else { return false }
                    return self.relationshipNativeButtons(profile.view).contains { $0.accessibilityIdentifier == "social.follow" }
                }
                let profile = try XCTUnwrap(host.presentedViewController)
                XCTAssertEqual(self.relationshipNativeButtons(profile.view).first { $0.accessibilityIdentifier == "social.follow" }?.titleLabel?.text,
                               "关注", "The retained row must open the current unfollowed profile")
                try await self.waitUntil { !profile.isBeingPresented && profile.transitionCoordinator == nil }
                await withCheckedContinuation { continuation in
                    profile.dismiss(animated: false) { continuation.resume() }
                }
                try await self.waitUntil {
                    host.presentedViewController == nil
                        && self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "关注"
                }
                XCTAssertEqual(fixture.readCount(for: .following), readsBeforeProfile,
                               "Returning from a profile sheet must retain this module session's following membership")
                try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
                try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "已关注" }
                XCTAssertEqual(fixture.mutations.map(\.method), ["DELETE", "PUT"])
            }
        } catch {
            await store.logout()
            throw error
        }
        await store.logout()
    }

    func testFollowingListFetchesAuthoritativeMembershipAfterLeavingAndReenteringModule() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            window.rootViewController = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
            try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followingID) else { return false }
                return current.isEnabled && current.titleLabel?.text == "关注"
            }
            let readsBeforeExit = fixture.readCount(for: .following)
            window.rootViewController = UIViewController()
            try await Task.sleep(nanoseconds: 100_000_000)
            window.rootViewController = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.makeKeyAndVisible()
            try await self.waitUntil {
                fixture.readCount(for: .following) > readsBeforeExit
                    && self.relationshipButton(in: window, userID: fixture.mutualID) != nil
            }
            XCTAssertNil(self.relationshipButton(in: window, userID: fixture.followingID),
                         "Reentering the module must discard the old membership snapshot")
            XCTAssertEqual(fixture.mutations.map(\.method), ["DELETE"])
        }
        await store.logout()
    }

    func testFollowingSessionSnapshotIsClearedImmediatelyAfterPrivacyChange() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            window.rootViewController = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
            try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID)?.titleLabel?.text == "关注" }
            let readsBeforePrivacyChange = fixture.readCount(for: .following)
            store.socialPolicyChanged(userID: fixture.followingID, blocked: true)
            try await self.waitUntil {
                fixture.readCount(for: .following) > readsBeforePrivacyChange
                    && self.relationshipButton(in: window, userID: fixture.followingID) == nil
                    && self.relationshipButton(in: window, userID: fixture.mutualID) != nil
            }
            XCTAssertFalse(store.isFollowing(fixture.initialFollowing))
        }
        await store.logout()
    }

    func testFollowerRelationshipActionFollowsDirectlyAndRefreshesToMutualLabel() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .followers))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil {
                self.relationshipButton(in: window, userID: fixture.followerID) != nil
                    && self.relationshipButton(in: window, userID: fixture.mutualID) != nil
            }
            XCTAssertEqual(self.relationshipButton(in: window, userID: fixture.mutualID)?.titleLabel?.text, "互相关注")
            let button = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followerID))
            XCTAssertEqual(button.titleLabel?.text, "关注")
            button.sendActions(for: .touchUpInside)
            try await self.waitUntil {
                self.relationshipButton(in: window, userID: fixture.followerID)?.titleLabel?.text == "互相关注"
            }
            XCTAssertEqual(fixture.mutations.map(\.method), ["PUT"])
            XCTAssertEqual(fixture.mutations.first?.personID, fixture.followerID)
            XCTAssertTrue(store.isFollowing(fixture.initialFollower))
            XCTAssertFalse(self.relationshipHasAlert(host), "Following must take effect without a confirmation dialog")
        }
        await store.logout()
    }

    func testRelationshipMutationFailureKeepsRowAndAllowsOneRetryAfterDuplicateTaps() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let gate = fixture.holdNextMutation(status: 503)
        defer { gate.signal() }
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .followers))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followerID) != nil }
            let button = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followerID))
            button.sendActions(for: .touchUpInside)
            button.sendActions(for: .touchUpInside)
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followerID) else { return false }
                return fixture.mutations.count == 1 && !current.isEnabled
                    && current.configuration?.showsActivityIndicator == true
            }
            let busyButton = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followerID))
            busyButton.sendActions(for: .touchUpInside)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fixture.mutations.count, 1, "Rapid and disabled-button taps cannot duplicate an in-flight follow")
            XCTAssertFalse(self.relationshipHasAlert(host), "An in-flight follow never requires confirmation")
            gate.signal()
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followerID) else { return false }
                return current.isEnabled && current.titleLabel?.text == "关注"
            }
            XCTAssertFalse(store.isFollowing(fixture.initialFollower), "A failed write must not create a local following override")
            let retry = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followerID))
            retry.sendActions(for: .touchUpInside)
            try await self.waitUntil {
                self.relationshipButton(in: window, userID: fixture.followerID)?.titleLabel?.text == "互相关注"
            }
            XCTAssertEqual(fixture.mutations.map(\.method), ["PUT", "PUT"])
            XCTAssertEqual(Set(fixture.mutations.map(\.requestID)).count, 2,
                           "A new user retry after an explicit rejection is a separate mutation")
            XCTAssertTrue(store.isFollowing(fixture.initialFollower))
            XCTAssertFalse(self.relationshipHasAlert(host))
        }
        await store.logout()
    }

    func testFollowingUnfollowFailureRetainsOriginalLabelAndBlocksDuplicateTaps() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let gate = fixture.holdNextMutation(status: 503)
        defer { gate.signal() }
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: .following))
            window.rootViewController = host; window.makeKeyAndVisible()
            try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.followingID) != nil }
            let button = try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID))
            button.sendActions(for: .touchUpInside); button.sendActions(for: .touchUpInside)
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followingID) else { return false }
                return fixture.mutations.count == 1 && !current.isEnabled
                    && current.configuration?.showsActivityIndicator == true
            }
            try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(fixture.mutations.count, 1)
            gate.signal()
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followingID) else { return false }
                return current.isEnabled && current.titleLabel?.text == "已关注"
            }
            XCTAssertTrue(store.isFollowing(fixture.initialFollowing), "A failed DELETE cannot mark a person unfollowed")
            XCTAssertFalse(self.relationshipHasAlert(host))
            try XCTUnwrap(self.relationshipButton(in: window, userID: fixture.followingID)).sendActions(for: .touchUpInside)
            try await self.waitUntil {
                guard let current = self.relationshipButton(in: window, userID: fixture.followingID) else { return false }
                return current.isEnabled && current.titleLabel?.text == "关注"
            }
            XCTAssertEqual(fixture.mutations.map(\.method), ["DELETE", "DELETE"])
            XCTAssertEqual(Set(fixture.mutations.map(\.requestID)).count, 2)
            XCTAssertFalse(store.isFollowing(fixture.initialFollowing))
        }
        await store.logout()
    }

    func testRelationshipListsNativeOrderAndLightDarkLargeTextScreenshots() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let fixture = KikiRelationshipActionFixture()
        let mock = KikiConcurrentConsentServer { request in
            if let response = try fixture.response(request) { return response }
            return try p1VisualResponse(request, documents: docs)
        }
        let store = try await socialFixtureStore(docs: docs, api: mock.client, voice: mock.voiceClient)
        try await withSocialWindow { window in
            let folder = URL(fileURLWithPath: "/tmp/kiki-relationships-screenshots", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            for kind in KikiRelationshipKind.allCases {
                for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                             ("dark", ColorScheme.dark, .large),
                                             ("large-text", ColorScheme.light, .accessibility1)] {
                    let host = UIHostingController(rootView: KikiRelationshipsView(store: store, initialKind: kind)
                        .preferredColorScheme(scheme).dynamicTypeSize(size))
                    window.rootViewController = host; window.makeKeyAndVisible()
                    try await self.waitUntil { self.relationshipButton(in: window, userID: fixture.mutualID) != nil }
                    try await Task.sleep(nanoseconds: 180_000_000)
                    window.layoutIfNeeded()
                    let control = try XCTUnwrap(self.relationshipSegmentedControls(window).first)
                    XCTAssertEqual((0..<control.numberOfSegments).compactMap { control.titleForSegment(at: $0) },
                                   ["互相关注", "正在关注", "粉丝"])
                    XCTAssertEqual(control.selectedSegmentIndex, KikiRelationshipKind.allCases.firstIndex(of: kind))
                    let buttons = self.relationshipNativeButtons(window).filter {
                        $0.accessibilityIdentifier?.hasPrefix("relationships.action.") == true
                    }
                    XCTAssertFalse(buttons.isEmpty)
                    for button in buttons {
                        let frame = button.convert(button.bounds, to: window)
                        XCTAssertGreaterThanOrEqual(frame.width, 44)
                        XCTAssertGreaterThanOrEqual(frame.height, 44)
                        XCTAssertTrue(window.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                                      "Native relationship actions must remain on screen in large text")
                        XCTAssertFalse(button.titleLabel?.text?.isEmpty ?? true)
                    }
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                    }
                    let filename = device + "-" + kind.rawValue + "-" + name
                    let attachment = XCTAttachment(image: image); attachment.name = filename; attachment.lifetime = .keepAlways
                    self.add(attachment)
                    try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(filename + ".png"))
                }
            }
        }
        await store.logout()
    }

    private func relationshipNativeButtons(_ view: UIView) -> [UIButton] {
        (view as? UIButton).map { [$0] } ?? view.subviews.flatMap(relationshipNativeButtons)
    }
    private func relationshipButton(in view: UIView, userID: String) -> UIButton? {
        relationshipNativeButtons(view).first { $0.accessibilityIdentifier == "relationships.action." + userID }
    }
    private func relationshipSegmentedControls(_ view: UIView) -> [UISegmentedControl] {
        (view as? UISegmentedControl).map { [$0] } ?? view.subviews.flatMap(relationshipSegmentedControls)
    }
    private func relationshipAccessibilityNodes(in root: UIView) -> [NSObject] {
        var nodes: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard nodes.count < 2_000, visited.insert(ObjectIdentifier(object)).inserted else { return }
            nodes.append(object)
            if let view = object as? UIView { view.subviews.forEach(visit) }
            if let elements = object.accessibilityElements {
                for case let element as NSObject in elements { visit(element) }
            }
            let count = object.accessibilityElementCount()
            if count > 0, count < 500 {
                for index in 0..<count {
                    if let element = object.accessibilityElement(at: index) as? NSObject { visit(element) }
                }
            }
        }
        visit(root)
        return nodes
    }
    private func relationshipHasAlert(_ controller: UIViewController) -> Bool {
        if controller is UIAlertController { return true }
        if let presented = controller.presentedViewController, relationshipHasAlert(presented) { return true }
        return controller.children.contains(where: relationshipHasAlert)
    }
}

private final class KikiRelationshipActionFixture: @unchecked Sendable {
    struct Mutation { let personID: String; let method: String; let requestID: String }
    let mutualID = "kiki_fixture0002", followingID = "kiki_fixture0003", followerID = "kiki_fixture0004"
    private let lock = NSLock()
    private var writes: [Mutation] = []
    private var relationshipReads: [String: Int] = [:]
    private var people: [KikiPerson]
    private var nextMutation: (status: Int, gate: DispatchSemaphore)?
    var mutations: [Mutation] { lock.lock(); defer { lock.unlock() }; return writes }
    func readCount(for kind: KikiRelationshipKind) -> Int {
        lock.lock(); defer { lock.unlock() }; return relationshipReads[kind.rawValue, default: 0]
    }
    var initialMutual: KikiPerson { Self.person(id: mutualID, name: "同频小岛", following: true, followsYou: true) }
    var initialFollowing: KikiPerson { Self.person(id: followingID, name: "正在关注的朋友", following: true, followsYou: false) }
    var initialFollower: KikiPerson { Self.person(id: followerID, name: "等你关注的小星星", following: false, followsYou: true) }
    init() {
        people = [Self.person(id: "kiki_fixture0002", name: "同频小岛", following: true, followsYou: true),
                  Self.person(id: "kiki_fixture0003", name: "正在关注的朋友", following: true, followsYou: false),
                  Self.person(id: "kiki_fixture0004", name: "等你关注的小星星", following: false, followsYou: true)]
    }
    func holdNextMutation(status: Int) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock(); nextMutation = (status, gate); lock.unlock()
        return gate
    }
    func response(_ request: URLRequest) throws -> (Int, Data)? {
        let path = request.url?.path ?? ""
        if path.hasPrefix("/v1/social/people/") {
            lock.lock(); let person = people.first { $0.id == request.url?.lastPathComponent }; lock.unlock()
            guard let person else { return nil }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer social-fixture-session")
            return (200, try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(person))]))
        }
        guard path == "/v1/social/relationships" || path == "/v1/social/relationships/ids"
                || path.hasPrefix("/v1/social/follows/") else { return nil }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer social-fixture-session")
        if path.hasPrefix("/v1/social/follows/") {
            let body = try requestBody(request)
            let method = try XCTUnwrap(request.httpMethod)
            let requestID = try XCTUnwrap(body["requestID"] as? String)
            XCTAssertNotNil(UUID(uuidString: requestID)); XCTAssertEqual(Set(body.keys), ["requestID"])
            XCTAssertTrue(["PUT", "DELETE"].contains(method))
            let personID = request.url!.lastPathComponent
            lock.lock()
            writes.append(.init(personID: personID, method: method, requestID: requestID))
            let held = nextMutation; nextMutation = nil
            lock.unlock()
            if let held { _ = held.gate.wait(timeout: .now() + 5) }
            if let held, held.status != 200 {
                return (held.status, Data(#"{"detail":"关注操作暂时不可用，请重试。"}"#.utf8))
            }
            lock.lock()
            let index = try XCTUnwrap(people.firstIndex { $0.id == personID })
            people[index].following = method == "PUT"
            people[index].mutual = people[index].following && people[index].followsYou
            let person = people[index]
            lock.unlock()
            return (200, try JSONSerialization.data(withJSONObject: ["person": JSONSerialization.jsonObject(with: JSONEncoder().encode(person))]))
        }
        lock.lock(); let snapshot = people; lock.unlock()
        if path == "/v1/social/relationships/ids" {
            let ids = snapshot.filter(\.following).map(\.id)
            return (200, try JSONSerialization.data(withJSONObject: ["followingIDs": ids, "followingCount": ids.count,
                                                                    "followerCount": snapshot.filter(\.followsYou).count]))
        }
        let kind = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value
        lock.lock(); relationshipReads[kind ?? "", default: 0] += 1; lock.unlock()
        let visible = snapshot.filter { person in
            switch kind { case "mutual": return person.mutual; case "following": return person.following; case "followers": return person.followsYou; default: return false }
        }
        return (200, try JSONSerialization.data(withJSONObject: ["people": JSONSerialization.jsonObject(with: JSONEncoder().encode(visible)), "nextCursor": NSNull()]))
    }
    private static func person(id: String, name: String, following: Bool, followsYou: Bool) -> KikiPerson {
        KikiPerson(id: id, name: name, bio: "喜欢散步和音乐，一起分享生活中的小事。", avatarIndex: following ? 4 : 2,
                   avatarURL: nil, following: following, followsYou: followsYou, mutual: following && followsYou,
                   followingCount: 12, followerCount: 18, currentRoomID: nil)
    }
}

extension KikiConsentTests {
    /// Renders the real DM view against URLProtocol fixtures. No account, photo
    /// URL, or outgoing message is read from or written to the live service.
    func testDirectSenderIdentityProductionLayoutAndOfflineProfileRouting() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let peer = "kiki_identity0002", me = "legal_qa"
        let peerName = "小岛 · 一个很长很长的昵称用来检查消息旁边名称是否会正确截断 🌊"
        let myName = "离线验收 · 我自己的很长昵称也需要保持一行显示 ✨"
        let person = KikiPerson(id: peer, name: peerName, bio: "离线资料验收", avatarIndex: 4, avatarURL: nil,
                                following: true, followsYou: true, mutual: true,
                                followingCount: 12, followerCount: 18, currentRoomID: nil)
        let myself = KikiPerson(id: me, name: myName, bio: "离线自己的资料", avatarIndex: 1, avatarURL: nil,
                               following: false, followsYou: false, mutual: false,
                               followingCount: 12, followerCount: 18, currentRoomID: nil)
        let people = [peer: person, me: myself]
        let pages = TestRequests(), writes = TestRequests(), profileReads = TestRequests()
        let messages: [[String: Any]] = [
            ["id": "identity-peer", "seq": 1, "senderID": peer,
             "text": "晚风很舒服，刚刚的房间里聊得很开心。长消息也应该保持自然换行，头像和昵称都要清晰。", "createdAt": 1_792_600_000],
            ["id": "identity-mine", "seq": 2, "senderID": me,
             "text": "收到啦 😀\n" + String(repeating: "Kiki", count: 16), "createdAt": 1_792_600_030]
        ]
        let mock = KikiAPIMockServer { request in
            let path = request.url?.path ?? ""
            if path == "/v1/social/conversations/" + peer + "/messages" {
                if request.httpMethod != "GET" {
                    writes.append(request.httpMethod ?? "unknown")
                    XCTFail("Identity layout validation must never send a message")
                    return (405, Data())
                }
                pages.append("page")
                return (200, try JSONSerialization.data(withJSONObject: [
                    "conversationID": "11111111-1111-4111-8111-111111111111", "messages": messages,
                    "nextCursor": NSNull(), "canSend": true, "replyEstablished": true, "unreadCount": 0
                ]))
            }
            if path == "/v1/social/conversations/" + peer + "/read" {
                return (200, Data(#"{"unreadCount":0}"#.utf8))
            }
            if path == "/v1/social/conversations" {
                return (200, Data(#"{"conversations":[],"nextCursor":null,"unreadCount":0}"#.utf8))
            }
            if path.hasPrefix("/v1/social/people/"), let id = request.url?.lastPathComponent, let target = people[id] {
                XCTAssertEqual(request.httpMethod, "GET")
                profileReads.append(id)
                return (200, try JSONSerialization.data(withJSONObject: [
                    "person": JSONSerialization.jsonObject(with: JSONEncoder().encode(target))
                ]))
            }
            let (status, raw) = try consentResponse(request, documents: docs)
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
            if var user = body["user"] as? [String: Any] {
                user["name"] = myName; user["avatarIndex"] = 1; body["user"] = user
            }
            return (status, try JSONSerialization.data(withJSONObject: body))
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        XCTAssertEqual(store.userID, me); XCTAssertEqual(store.profileName, myName)
        store.updateDirectDraft("离线验收草稿，不发送", personID: peer)
        let folder = URL(fileURLWithPath: "/tmp/kiki-direct-identity-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        var checks: [[String: Any]] = []
        try await withSocialWindow { window in
            for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                          ("dark", ColorScheme.dark, .large),
                                          ("large-text", ColorScheme.light, .accessibility1)] {
                let baseline = pages.values.count
                let host = UIHostingController(rootView: NavigationStack {
                    KikiDirectConversationView(person: person, store: store)
                }.environment(\.scenePhase, .active).preferredColorScheme(scheme).dynamicTypeSize(size))
                window.rootViewController = host; window.makeKeyAndVisible()
                try await self.waitUntil { pages.values.count > baseline && !self.socialEditableViews(window).isEmpty }
                try await Task.sleep(nanoseconds: 300_000_000)
                window.layoutIfNeeded()
                let input = try XCTUnwrap(self.socialEditableViews(window).first {
                    !$0.isHidden && $0.bounds.width > 100 && $0.bounds.height > 15
                })
                var enabled = true, ancestor: UIView? = input
                while let view = ancestor { enabled = enabled && view.isUserInteractionEnabled; ancestor = view.superview }
                if let field = input as? UITextField { enabled = enabled && field.isEnabled }
                if let text = input as? UITextView { enabled = enabled && text.isEditable }
                XCTAssertTrue(enabled, "Identity rows must preserve composer admission")
                let inputFrame = input.convert(input.bounds, to: window)
                XCTAssertGreaterThan(inputFrame.width, 100)
                XCTAssertGreaterThanOrEqual(inputFrame.minX, -1)
                XCTAssertLessThanOrEqual(inputFrame.maxX, window.bounds.width + 1)
                let nodes = self.relationshipAccessibilityNodes(in: window)
                let exposed = nodes.filter { (self.directSenderIdentifier($0) ?? "").hasPrefix("social.direct.") }
                let identifiers = Set(exposed.compactMap { self.directSenderIdentifier($0) })
                let hasSenderNodes = identifiers.contains("social.direct.sender.avatar.identity-peer")
                if hasSenderNodes {
                    for id in ["identity-peer", "identity-mine"] {
                        for kind in ["sender.avatar.", "sender.name.", "message."] {
                            XCTAssertTrue(identifiers.contains("social.direct." + kind + id))
                        }
                        if let avatar = exposed.first(where: { self.directSenderIdentifier($0) == "social.direct.sender.avatar." + id }) {
                            XCTAssertGreaterThanOrEqual(avatar.accessibilityFrame.width, 44)
                            XCTAssertGreaterThanOrEqual(avatar.accessibilityFrame.height, 44)
                            XCTAssertEqual(avatar.accessibilityLabel,
                                           id == "identity-mine" ? "查看我的个人主页" : "查看\(peerName)的个人主页")
                        }
                        if let name = exposed.first(where: { self.directSenderIdentifier($0) == "social.direct.sender.name." + id }) {
                            XCTAssertEqual(name.accessibilityLabel, id == "identity-mine" ? myName : peerName)
                        }
                    }
                    XCTAssertTrue(identifiers.contains("social.direct.profile"))
                }
                checks.append(["state": name, "nativeInputEnabled": enabled, "inputWidth": inputFrame.width,
                               "viewportWidth": window.bounds.width, "senderAccessibilityInspected": hasSenderNodes,
                               "exposedDirectIdentifiers": identifiers.sorted()])
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image); attachment.name = "direct-identity-" + device + "-" + name
                attachment.lifetime = .keepAlways; self.add(attachment)
                try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(device + "-" + name + ".png"))
                XCTAssertTrue(input.becomeFirstResponder(), "The native composer remains focusable")
                XCTAssertTrue(input.isFirstResponder)
                window.endEditing(true); window.rootViewController = nil
            }
            for (identifier, expectedID) in [("social.direct.profile", peer),
                                             ("social.direct.sender.avatar.identity-peer", peer),
                                             ("social.direct.sender.avatar.identity-mine", me)] {
                let baseline = pages.values.count
                let host = UIHostingController(rootView: NavigationStack {
                    KikiDirectConversationView(person: person, store: store)
                }.environment(\.scenePhase, .active))
                window.rootViewController = host; window.makeKeyAndVisible()
                try await self.waitUntil { pages.values.count > baseline }
                try await Task.sleep(nanoseconds: 250_000_000)
                let node = self.relationshipAccessibilityNodes(in: window).first { self.directSenderIdentifier($0) == identifier }
                let before = profileReads.values.count
                let activated: Bool
                if node?.accessibilityActivate() == true { activated = true }
                else if let control = node as? UIControl, !control.allTargets.isEmpty {
                    control.sendActions(for: .touchUpInside); activated = true
                } else { activated = false }
                if activated {
                    try await self.waitUntil { profileReads.values.count > before }
                    XCTAssertEqual(profileReads.values.last, expectedID, "Every avatar must open its own identity")
                }
                checks.append(["action": identifier, "activationSupported": activated,
                               "expectedProfileID": expectedID, "profileRouteVerified": activated && profileReads.values.last == expectedID])
                host.presentedViewController?.dismiss(animated: false)
                window.rootViewController = nil
            }
        }
        XCTAssertTrue(writes.values.isEmpty)
        XCTAssertEqual(store.directDrafts[peer], "离线验收草稿，不发送")
        let manifest: [String: Any] = ["device": device, "checks": checks, "messageWrites": writes.values.count,
            "scope": "Production DM view with offline API fixtures and seeded avatars; no outgoing DM, real identity, photo download, or live account"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(device + "-validation.json"))
        await store.logout()
    }
    private func directSenderIdentifier(_ object: NSObject) -> String? {
        (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
    }

}

extension KikiConsentTests {
    /// A paused first GET separates the mounted, loading, and confirmed states
    /// of the real conversation view without sending a message or adding a
    /// production-only testing hook.
    func testDirectEntryDefersEmptyStateUntilConfirmedResponse() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let peer = "kiki_entry0002"
        let person = KikiPerson(id: peer, name: "小岛 · 离线进入验收", bio: "", avatarIndex: 4, avatarURL: nil,
                                following: true, followsYou: true, mutual: true,
                                followingCount: 12, followerCount: 18, currentRoomID: nil)
        let folder = URL(fileURLWithPath: "/tmp/kiki-direct-entry-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        var checks: [[String: Any]] = []
        for populated in [false, true] {
            let name = populated ? "existing-chat" : "new-chat"
            let arrived = expectation(description: name + " first page is loading")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let pages = TestRequests(), writes = TestRequests()
            let mock = KikiConcurrentConsentServer { request in
                let path = request.url?.path ?? ""
                if path == "/v1/social/conversations/" + peer + "/messages" {
                    guard request.httpMethod == "GET" else {
                        writes.append(request.httpMethod ?? "unknown")
                        return (405, Data())
                    }
                    pages.append("page")
                    if pages.values.count == 1 {
                        arrived.fulfill()
                        _ = release.wait(timeout: .now() + 5)
                    }
                    let messages: [[String: Any]] = populated ? [[
                        "id": "entry-message", "seq": 1, "senderID": peer,
                        "text": "已有的聊天消息应该直接显示。", "createdAt": 1_792_600_000
                    ]] : []
                    return (200, try JSONSerialization.data(withJSONObject: [
                        "conversationID": "11111111-1111-4111-8111-111111111111", "messages": messages,
                        "nextCursor": NSNull(), "canSend": true, "replyEstablished": true, "unreadCount": 0
                    ]))
                }
                if path == "/v1/social/conversations/" + peer + "/read" {
                    return (200, Data(#"{"unreadCount":0}"#.utf8))
                }
                if path == "/v1/social/conversations" {
                    return (200, Data(#"{"conversations":[],"nextCursor":null,"unreadCount":0}"#.utf8))
                }
                return try consentResponse(request, documents: docs)
            }
            let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
            let activation = DirectEntryActivation()
            try await withSocialWindow { window in
                window.rootViewController = UIHostingController(rootView:
                    DirectEntryView(person: person, store: store, activation: activation)
                        .environment(\.scenePhase, .active).preferredColorScheme(.dark))
                window.makeKeyAndVisible()
                try await self.waitUntil {
                    self.directEntryScroll(window) != nil && !self.socialEditableViews(window).isEmpty
                }
                try await Task.sleep(nanoseconds: 150_000_000)
                let unloaded = try self.directEntrySnapshot(window, folder: folder, name: device + "-" + name + "-unloaded")
                XCTAssertEqual(pages.values.count, 0, "An inactive destination must not start a request")
                XCTAssertLessThan(unloaded, 80, "An unconfirmed conversation must not contain the tall empty-state placeholder")
                checks.append(["chat": name, "phase": "unloaded", "contentHeight": unloaded])

                activation.isActive = true
                await self.fulfillment(of: [arrived], timeout: 2)
                try await Task.sleep(nanoseconds: 100_000_000)
                let loading = try self.directEntrySnapshot(window, folder: folder, name: device + "-" + name + "-loading")
                XCTAssertLessThan(loading, 190, "Loading must not display the confirmed-empty illustration")
                XCTAssertNil(store.directMessageAccess[peer], "The first response remains paused while loading is captured")
                checks.append(["chat": name, "phase": "loading", "contentHeight": loading])

                release.signal()
                try await self.waitUntil { store.directMessageAccess[peer]?.canSend == true }
                try await Task.sleep(nanoseconds: 200_000_000)
                let phase = populated ? "loaded-messages" : "confirmed-empty"
                let confirmed = try self.directEntrySnapshot(window, folder: folder, name: device + "-" + name + "-" + phase)
                XCTAssertGreaterThan(confirmed, populated ? 80 : 180, "The confirmed production content must now render")
                let input = try XCTUnwrap(self.socialEditableViews(window).first {
                    !$0.isHidden && $0.bounds.width > 100 && $0.bounds.height > 15
                })
                var enabled = true, ancestor: UIView? = input
                while let view = ancestor { enabled = enabled && view.isUserInteractionEnabled; ancestor = view.superview }
                if let field = input as? UITextField { enabled = enabled && field.isEnabled }
                if let text = input as? UITextView { enabled = enabled && text.isEditable }
                XCTAssertTrue(enabled, "A completed initial load must enable the native composer")
                checks.append(["chat": name, "phase": phase, "contentHeight": confirmed, "nativeInputEnabled": enabled])
            }
            XCTAssertTrue(writes.values.isEmpty, "This regression only loads offline messages")
            await store.logout()
        }
        try JSONSerialization.data(withJSONObject: ["device": device, "checks": checks], options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent(device + "-validation.json"))
    }

    private func directEntryScroll(_ window: UIWindow) -> UIScrollView? {
        socialScrollViews(window).first { !($0 is UITextView) && $0.bounds.width > 200 && $0.bounds.height > 200 }
    }
    private func directEntrySnapshot(_ window: UIWindow, folder: URL, name: String) throws -> CGFloat {
        window.layoutIfNeeded()
        let scroll = try XCTUnwrap(directEntryScroll(window))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
        return scroll.contentSize.height
    }
    @MainActor private final class DirectEntryActivation: ObservableObject {
        @Published var isActive = false
    }
    @MainActor private struct DirectEntryView: View {
        let person: KikiPerson
        @ObservedObject var store: KikiAppStore
        @ObservedObject var activation: DirectEntryActivation
        var body: some View {
            NavigationStack { KikiDirectConversationView(person: person, store: store, isActive: activation.isActive) }
        }
    }
}

extension KikiConsentTests {
    func testPublicAccountNumberIsDisplayedWithoutChangingSessionIdentityAndClearsAtLogout() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let mock = KikiAPIMockServer { request in
            let (status, data) = try consentResponse(request, documents: docs)
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            if var user = body["user"] as? [String: Any] {
                user["displayID"] = "kiki_000001"; body["user"] = user
            }
            return (status, try JSONSerialization.data(withJSONObject: body))
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        XCTAssertEqual(store.userID, "legal_qa")
        XCTAssertEqual(store.displayID, "kiki_000001")
        XCTAssertTrue(store.pushSessionKey?.hasSuffix(":legal_qa") == true)
        await store.logout()
        XCTAssertTrue(store.userID.isEmpty)
        XCTAssertTrue(store.displayID.isEmpty)
    }
}

extension KikiConsentTests {
    func testProfileTextSaveKeepsUploadedPhotoAndOnlyANewUploadReplacesIt() async throws {
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let state = KikiProfileUploadFixture()
        let mock = KikiAPIMockServer { request in
            if let response = try state.response(request, documents: docs) { return response }
            return try consentResponse(request, documents: docs)
        }
        let store = try await directIntroductionStore(documents: docs, api: mock.client, voice: mock.voiceClient)
        XCTAssertTrue(store.isAuthenticated)
        XCTAssertEqual(store.customAvatarURL, KikiProfileUploadFixture.originalURL)

        try await store.updateProfile(name: "新昵称", bio: "新的自我介绍")
        XCTAssertEqual(store.profileName, "新昵称")
        XCTAssertEqual(store.bio, "新的自我介绍")
        XCTAssertEqual(store.customAvatarURL, KikiProfileUploadFixture.originalURL)
        XCTAssertEqual(state.mutations, ["text"])

        try await store.updateProfile(name: "新昵称", bio: "新的自我介绍", jpegData: state.jpeg)
        XCTAssertEqual(store.customAvatarURL, KikiProfileUploadFixture.uploadedURL)
        XCTAssertEqual(state.mutations, ["text", "text", "photo"])
        await store.logout()
    }
}

/// Models the account server retaining an uploaded photo across text edits and
/// returning the latest photo when the app renews its authenticated voice card.
private final class KikiProfileUploadFixture: @unchecked Sendable {
    static let originalURL = "https://kiki.group/v1/avatars/original.jpg"
    static let uploadedURL = "https://kiki.group/v1/avatars/uploaded.jpg"
    let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
    private let lock = NSLock()
    private var recordedMutations: [String] = []
    private var user: [String: Any] = [
        "id": "legal_qa", "sdkUserID": "sdk_qa", "name": "测试昵称", "bio": "",
        "avatarIndex": 5, "avatarURL": KikiProfileUploadFixture.originalURL, "notificationsEnabled": false, "needsNickname": false
    ]
    var mutations: [String] { lock.lock(); defer { lock.unlock() }; return recordedMutations }

    private func uploadedPhotoData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func response(_ request: URLRequest, documents: KikiLegalBundle) throws -> (Int, Data)? {
        lock.lock(); defer { lock.unlock() }
        switch (request.url?.path, request.httpMethod) {
        case ("/v1/me", "PATCH"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), ["name", "bio"])
            user["name"] = try XCTUnwrap(body["name"] as? String)
            user["bio"] = try XCTUnwrap(body["bio"] as? String)
            recordedMutations.append("text")
            return (200, try JSONSerialization.data(withJSONObject: user))
        case ("/v1/me/avatar", "POST"):
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer existing-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(try uploadedPhotoData(request), jpeg)
            user["avatarURL"] = Self.uploadedURL
            recordedMutations.append("photo")
            return (200, try JSONSerialization.data(withJSONObject: user))
        case ("/v1/auth/refresh", _), ("/v1/voice/session", _):
            let (status, data) = try consentResponse(request, documents: documents)
            var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            body["user"] = user
            return (status, try JSONSerialization.data(withJSONObject: body))
        default:
            return nil
        }
    }
}
