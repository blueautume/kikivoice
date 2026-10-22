import Foundation
import Security
import XCTest
@testable import KikiVoiceOps

final class VoiceOpsTests: XCTestCase {
    func testCentralEndpointAllowlistRejectsOldAndCrossServiceHosts() throws {
        for (path, methods) in OpsIdentityEndpoint.allowedMethods {
            for method in methods.split(separator: ",") {
                var request = URLRequest(url: URL(string: "https://kiki.group" + path)!); request.httpMethod = String(method)
                XCTAssertTrue(OpsIdentityEndpoint.permits(request))
            }
        }
        for url in ["https://furby.top/admin/v2/me", "https://kiki.group/admin/v1/dashboard", "https://kiki.group/v1/me",
                    "http://kiki.group/admin/v2/me", "https://kiki.group:8443/admin/v2/me", "https://user@kiki.group/admin/v2/me",
                    "https://kiki.group/admin/v2/me?token=x", "https://kiki.group/admin/v2/me#x", "https://kiki.group/admin/v2/%6de",
                    "https://kiki.group/admin/v2/../me", "https://other.invalid/admin/v2/me"] {
            XCTAssertFalse(OpsIdentityEndpoint.permits(URLRequest(url: URL(string: url)!)))
        }
        var wrong = URLRequest(url: URL(string: "https://kiki.group/admin/v2/me")!); wrong.httpMethod = "DELETE"
        XCTAssertFalse(OpsIdentityEndpoint.permits(wrong))
    }
    func testSessionIsVersionedCentralAndBoundedToEightHours() {
        let now = Date()
        XCTAssertTrue(testSession().isValid(now: now))
        XCTAssertFalse(OpsSession(token: "fixture", expiresAt: now.addingTimeInterval(3600), host: "furby.top").isValid(now: now))
        XCTAssertFalse(OpsSession(token: "fixture", expiresAt: now.addingTimeInterval(3600), version: 1).isValid(now: now))
        XCTAssertFalse(OpsSession(token: "fixture", expiresAt: now.addingTimeInterval(9 * 3600)).isValid(now: now))
        XCTAssertFalse(OpsSession(token: "fixture", expiresAt: now.addingTimeInterval(-1)).isValid(now: now))
    }
    func testCanonicalBase64URLRoundTripAndMalformedInputs() throws {
        let bytes = Data([0, 255, 254, 12, 64, 33])
        let encoded = OpsBase64URL.encode(bytes)
        XCTAssertFalse(encoded.contains("=")); XCTAssertFalse(encoded.contains("+")); XCTAssertFalse(encoded.contains("/"))
        XCTAssertEqual(try OpsBase64URL.decode(encoded), bytes)
        for bad in ["", "a", "YWJj=", "Y WJj", "a+b/", "Zh", "你好"] { XCTAssertThrowsError(try OpsBase64URL.decode(bad)) }
        XCTAssertThrowsError(try OpsBase64URL.decode("Zg", minimum: 16))
    }
    func testRegistrationRequiresCorrectRPDiscoverableUVAndES256() throws {
        try registrationOptions().validate()
        for mutation in ["rp", "uv", "resident", "algorithm", "challenge"] {
            var root = try registrationDictionary()
            var key = root["publicKey"] as! [String: Any]
            if mutation == "rp" { key["rp"] = ["id": "evil.invalid", "name": "Kiki"] }
            if mutation == "uv" { key["authenticatorSelection"] = ["residentKey": "required", "userVerification": "preferred"] }
            if mutation == "resident" { key["authenticatorSelection"] = ["residentKey": "preferred", "userVerification": "required"] }
            if mutation == "algorithm" { key["pubKeyCredParams"] = [["type": "public-key", "alg": -257]] }
            if mutation == "challenge" { key["challenge"] = "invalid=padding" }
            root["publicKey"] = key
            let options = try JSONDecoder().decode(OpsRegistrationOptions.self, from: JSONSerialization.data(withJSONObject: root))
            XCTAssertThrowsError(try options.validate())
        }
    }
    func testDiscoverableAuthenticationRejectsIdentifyingAllowList() throws {
        try authenticationOptions().validate()
        let value: [String: Any] = ["transactionID": "fixture-transaction", "publicKey": ["challenge": challenge,
            "rpId": "kiki.group", "userVerification": "required", "allowCredentials": [["id": "YQ", "type": "public-key"]]]]
        let options = try JSONDecoder().decode(OpsAuthenticationOptions.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try options.validate())
    }
    func testRegistrationAndAssertionSerializeAllRawWebAuthnFields() throws {
        let registration = try registrationCredential()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, object["rawId"] as? String)
        XCTAssertEqual(object["type"] as? String, "public-key")
        let response = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertNotNil(response["clientDataJSON"]); XCTAssertNotNil(response["attestationObject"])
        XCTAssertNil(response["signature"]); XCTAssertNil(response["userHandle"])
        let assertion = try assertionCredential()
        XCTAssertNotNil(assertion.response.authenticatorData); XCTAssertNotNil(assertion.response.signature)
        XCTAssertNotNil(assertion.response.userHandle); XCTAssertNil(assertion.response.attestationObject)
        XCTAssertEqual(try OpsBase64URL.decode(assertion.response.userHandle!), Data(repeating: 7, count: 32))
    }
    func testNameValidationAllowsDuplicatesAndRejectsEmptyLongOrControlNames() {
        XCTAssertEqual(OpsAccount.validName("  同名测试  "), "同名测试")
        XCTAssertEqual(OpsAccount.validName("e\u{0301}"), "é")
        XCTAssertEqual(OpsAccount.validName("同名测试"), OpsAccount.validName("同名测试"))
        XCTAssertNil(OpsAccount.validName("  ")); XCTAssertNil(OpsAccount.validName(String(repeating: "名", count: 33)))
        XCTAssertNil(OpsAccount.validName("a\nb")); XCTAssertNil(OpsAccount.validName("a\u{0000}b"))
    }
    func testPasswordEraSessionsArePurgedWithoutImportAndFreshVaultIsUnified() throws {
        let namespace = ".fixture." + UUID().uuidString
        let vault = KeychainSessionVault(namespace: namespace)
        defer { try? vault.remove() }
        for service in ["voice", "account"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.kikitalk.voiceops.admin.\(service).v1" + namespace,
                kSecAttrAccount as String: "admin-session", kSecValueData as String: Data("obsolete-fixture".utf8)]
            XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        }
        try vault.purgeLegacySessions()
        for service in ["voice", "account"] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.kikitalk.voiceops.admin.\(service).v1" + namespace,
                kSecAttrAccount as String: "admin-session"]
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        }
        try vault.save(testSession())
        XCTAssertTrue(try vault.load()?.isValid() == true)
        try vault.remove(); XCTAssertNil(try vault.load())
        XCTAssertEqual(OpsIdentityEndpoint.keychainService, "com.kikitalk.voiceops.identity.v2")
    }
    func testNetworkOptionsAndVerifyCarryNoExistingBearer() async throws {
        let transport = ScriptedTransport { request in
            XCTAssertEqual(request.url?.host, "kiki.group")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url!.path.hasSuffix("/options") { return (200, try JSONSerialization.data(withJSONObject: registrationDictionary())) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["transactionID", "credential"])
            return (200, try sessionJSON(account: testAccount(name: nil, voice: false, account: false)))
        }
        let api = OpsIdentityAPI(transport: transport)
        _ = try await api.registrationOptions()
        let result = try await api.finishRegistration(transactionID: "fixture-transaction", credential: registrationCredential())
        XCTAssertTrue(result.account.needsName); XCTAssertFalse(result.account.permissions.voice); XCTAssertFalse(result.account.permissions.account)
    }
    func testMeAndBothDashboardRequestsStayOnCentralHost() async throws {
        let transport = ScriptedTransport { request in
            XCTAssertEqual(request.url?.host, "kiki.group")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-ops-session")
            if request.url!.path == "/admin/v2/me" { return (200, try meJSON(testAccount())) }
            return (200, try dashboardData(request.url!.path.contains("/voice/") ? "dashboard-fixture" : "account-dashboard-fixture"))
        }
        let api = OpsIdentityAPI(transport: transport)
        _ = try await api.me(session: testSession())
        let voice = try await api.dashboard(session: testSession())
        let account = try await api.accountDashboard(session: testSession())
        XCTAssertEqual(voice.service.host, "furby.top")
        XCTAssertEqual(account.service.host, "kiki.group")
        let paths = await transport.paths
        XCTAssertEqual(paths, ["/admin/v2/me", "/admin/v2/services/voice/dashboard", "/admin/v2/services/account/dashboard"])
    }
    func testWrongSessionScopeAndMissingPermissionsFailClosed() async throws {
        for (serviceID, role) in [("voice-lab", "viewer"), ("ops-identity", "admin")] {
            let transport = ScriptedTransport { _ in (200, try sessionJSON(account: testAccount(), serviceID: serviceID, role: role)) }
            do { _ = try await OpsIdentityAPI(transport: transport).finishAuthentication(transactionID: "fixture", credential: assertionCredential()); XCTFail("wrong scope") }
            catch { XCTAssertEqual(error as? OpsError, .invalidResponse) }
        }
        let transport = ScriptedTransport { _ in (200, Data(#"{"schemaVersion":1,"account":{"id":"ops_fixture","name":"名字","needsName":false}}"#.utf8)) }
        do { _ = try await OpsIdentityAPI(transport: transport).me(session: testSession()); XCTFail("No implicit grants") }
        catch { XCTAssertEqual(error as? OpsError, .invalidResponse) }
    }
    func testRedirectsExpiredSessionAndUnsafePathAreRejected() async throws {
        let transport = ScriptedTransport { _ in (302, Data()) }
        let api = OpsIdentityAPI(transport: transport)
        do { _ = try await api.me(session: testSession()); XCTFail("redirect") } catch { XCTAssertEqual(error as? OpsError, .redirected) }
        XCTAssertThrowsError(try api.request(path: "/admin/v1/dashboard", method: "GET"))
        XCTAssertThrowsError(try api.request(path: "https://furby.top/admin/v2/me", method: "GET"))
        XCTAssertThrowsError(try api.request(path: "/admin/v2/me", method: "GET", session: OpsSession(token: "fixture", expiresAt: .distantPast)))
        let blocker = RedirectBlocker(); let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let url = URL(string: "https://kiki.group/admin/v2/me")!, task = session.dataTask(with: URL(string: "https://kiki.group")!)
        blocker.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                           newRequest: URLRequest(url: URL(string: "https://furby.top")!)) { XCTAssertNil($0) }
    }
    func test403RemainsDistinctFrom401AndDoesNotExposeServerText() async throws {
        for status in [401, 403, 409, 429, 503] {
            let transport = ScriptedTransport { _ in (status, Data(#"{"detail":"do not show internal details"}"#.utf8)) }
            do { _ = try await OpsIdentityAPI(transport: transport).me(session: testSession()); XCTFail("reject") }
            catch {
                let expected: OpsError = switch status { case 401: .unauthenticated; case 403: .forbidden; case 409: .ceremonyExpired; case 429: .rateLimited; default: .server(status: 503) }
                XCTAssertEqual(error as? OpsError, expected)
                XCTAssertFalse(error.localizedDescription.contains("internal details"))
            }
        }
    }
}

let challenge = OpsBase64URL.encode(Data(repeating: 3, count: 32))
func testSession() -> OpsSession { OpsSession(token: "fixture-ops-session", expiresAt: Date().addingTimeInterval(3600)) }
func testAccount(name: String? = "同名管理员", voice: Bool = true, account: Bool = true) -> OpsAccount {
    OpsAccount(id: "ops_fixture_account", name: name, needsName: name == nil, permissions: OpsPermissions(voice: voice, account: account))
}
func registrationDictionary() throws -> [String: Any] {
    ["transactionID": "fixture-transaction", "publicKey": ["rp": ["id": "kiki.group", "name": "Kiki 运维"],
        "user": ["id": OpsBase64URL.encode(Data(repeating: 7, count: 32)), "name": "ops_fixture_account", "displayName": "运维账户"],
        "challenge": challenge, "pubKeyCredParams": [["type": "public-key", "alg": -7]], "attestation": "none",
        "authenticatorSelection": ["residentKey": "required", "userVerification": "required"]]]
}
func registrationOptions() throws -> OpsRegistrationOptions { try JSONDecoder().decode(OpsRegistrationOptions.self, from: JSONSerialization.data(withJSONObject: registrationDictionary())) }
func authenticationOptions() throws -> OpsAuthenticationOptions {
    try JSONDecoder().decode(OpsAuthenticationOptions.self, from: JSONSerialization.data(withJSONObject: ["transactionID":"fixture-transaction", "publicKey":["challenge":challenge,"rpId":"kiki.group","userVerification":"required"]]))
}
func registrationCredential() throws -> OpsPasskeyCredential { try .registration(id: Data([1,2,3]), clientData: Data("fixture-client-data".utf8), attestation: Data([0xa1, 0x61])) }
func assertionCredential() throws -> OpsPasskeyCredential { try .assertion(id: Data([1,2,3]), clientData: Data("fixture-client-data".utf8), authenticatorData: Data(repeating: 1, count: 37), signature: Data([2,3,4]), userHandle: Data(repeating: 7, count: 32)) }
func sessionJSON(account: OpsAccount, serviceID: String = "ops-identity", role: String = "member") throws -> Data {
    let data = try JSONEncoder().encode(account), object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: ["token":"fixture-ops-session","expiresAt":Date().addingTimeInterval(3600).timeIntervalSince1970,"serviceID":serviceID,"role":role,"account":object])
}
func meJSON(_ account: OpsAccount) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schemaVersion":1,"account":JSONSerialization.jsonObject(with: JSONEncoder().encode(account))])
}
func dashboardData(_ name: String) throws -> Data { try Data(contentsOf: XCTUnwrap(Bundle(for: VoiceOpsTests.self).url(forResource: name, withExtension: "json"))) }
actor ScriptedTransport: OpsTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, Data)
    private let handler: Handler
    var paths = [String]()
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        paths.append(request.url!.path)
        let (status, data) = try handler(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
