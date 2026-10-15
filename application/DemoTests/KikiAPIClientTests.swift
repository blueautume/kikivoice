import XCTest
@testable import KikiTalk

final class KikiAPIClientTests: XCTestCase {
    func testLoginSendsAccountAndDeviceBindingWithoutAnExistingSession() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/id")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), Set(["userID", "deviceSecret"]))
            XCTAssertEqual(body["userID"] as? String, "island_23")
            XCTAssertEqual(body["deviceSecret"] as? String, String(repeating: "a", count: 64))
            return (200, try jsonData([
                "token": "test-access-token", "user": userFixture,
                "sdk": ["sdkAppID": 12345, "userID": "sdk-island", "userSig": "test-signature", "expiresAt": 1_900_000_000]
            ]))
        }

        let response = try await server.client.login(userID: "island_23", deviceSecret: String(repeating: "a", count: 64))

        XCTAssertEqual(response.token, "test-access-token")
        XCTAssertEqual(response.user.id, "island_23")
        XCTAssertEqual(response.user.sdkUserID, "sdk-island")
        XCTAssertFalse(response.user.needsNickname)
        XCTAssertNil(response.user.avatarURL)
        XCTAssertEqual(response.sdk.userID, "sdk-island")
        XCTAssertEqual(response.sdk.expiresAt, 1_900_000_000)
    }

    func testDecodesFirstNicknameRequirementAndCustomAvatar() async throws {
        let server = KikiAPIMockServer { _ in
            var user = userFixture
            user["needsNickname"] = true
            user["avatarURL"] = "https://43.138.219.160/v1/avatars/abc123.jpg"
            return (200, try jsonData([
                "token": "test-access-token", "user": user,
                "sdk": ["sdkAppID": 12345, "userID": "sdk-island", "userSig": "test-signature", "expiresAt": 1_900_000_000]
            ]))
        }

        let response = try await server.client.login(userID: "island_23", deviceSecret: String(repeating: "a", count: 64))

        XCTAssertTrue(response.user.needsNickname)
        XCTAssertEqual(response.user.avatarURL, "https://43.138.219.160/v1/avatars/abc123.jpg")
    }

    func testNicknameEditPreservesCustomAvatarByOmittingPresetIndex() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/me")
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            let body = try requestBody(request)
            XCTAssertEqual(body["name"] as? String, "海边小岛")
            XCTAssertEqual(body["bio"] as? String, "一起听歌")
            XCTAssertNil(body["avatarIndex"])
            XCTAssertNil(body["avatarURL"])
            var user = userFixture
            user["name"] = "海边小岛"
            user["needsNickname"] = false
            user["avatarURL"] = "https://43.138.219.160/v1/avatars/abc123.jpg"
            return (200, try jsonData(user))
        }

        let user = try await server.client.updateProfile(name: "海边小岛", bio: "一起听歌", token: "test-access-token")

        XCTAssertFalse(user.needsNickname)
        XCTAssertNotNil(user.avatarURL)
    }

    func testSelectingPresetSendsIndexToReplaceCustomPhoto() async throws {
        let server = KikiAPIMockServer { request in
            let body = try requestBody(request)
            XCTAssertEqual(body["avatarIndex"] as? Int, 5)
            var user = userFixture
            user["avatarIndex"] = 5
            user["avatarURL"] = NSNull()
            return (200, try jsonData(user))
        }

        let user = try await server.client.updateProfile(name: "小岛", bio: "", avatarIndex: 5, token: "test-access-token")

        XCTAssertEqual(user.avatarIndex, 5)
        XCTAssertNil(user.avatarURL)
    }

    func testPhotoUploadUsesAuthenticatedRawJPEGBody() async throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/me/avatar")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            XCTAssertEqual(try requestData(request), jpeg)
            var user = userFixture
            user["avatarURL"] = "https://43.138.219.160/v1/avatars/abc123.jpg"
            return (200, try jsonData(user))
        }

        let user = try await server.client.uploadAvatar(jpegData: jpeg, token: "test-access-token")

        XCTAssertNotNil(user.avatarURL)
    }

    func testInvalidPhotoUploadAndForeignAvatarNeverMakeRequests() async throws {
        let server = KikiAPIMockServer { _ in
            XCTFail("Invalid images and foreign avatar URLs must be rejected before a request")
            return (500, Data())
        }
        for data in [Data(), Data(repeating: 0, count: 2 * 1024 * 1024 + 1)] {
            do {
                _ = try await server.client.uploadAvatar(jpegData: data, token: "test-access-token")
                XCTFail("Invalid avatar size should fail")
            } catch let error as KikiAPIError {
                guard case .server(422, _) = error else { return XCTFail("Expected avatar size validation") }
            }
        }
        do {
            _ = try await server.client.loadAvatar("https://example.com/v1/avatars/abc123.jpg")
            XCTFail("Foreign avatar host should fail")
        } catch let error as KikiAPIError {
            guard case .security = error else { return XCTFail("Expected endpoint validation") }
        }
    }

    func testLibraryDecodesServerRoomsWithoutTheRemovedLanguageField() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/library")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            var endedRoom = roomFixture
            endedRoom["status"] = "ended"
            return (200, try jsonData(["favorites": [endedRoom], "recents": [endedRoom], "created": [roomFixture]]))
        }

        let library = try await server.client.library(token: "test-access-token")

        XCTAssertEqual(library.favorites.first?.id, "room-123")
        XCTAssertEqual(library.favorites.first?.status, "ended")
        XCTAssertEqual(library.recents.first?.hostID, "sdk-island")
        XCTAssertEqual(library.created.first?.title, "今晚一起听歌 🌙")
        XCTAssertEqual(library.created.first?.audience, 0)
        XCTAssertEqual(library.created.first?.status, "draft")
        XCTAssertEqual(library.created.first?.isCreatedByMe, true)
    }

    func testRoomReservationPreservesChineseTitleAndDoesNotSendLanguageOrInventAudience() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            let body = try requestBody(request)
            XCTAssertEqual(Set(body.keys), Set(["title", "category", "isLive", "theme"]))
            XCTAssertEqual(body["title"] as? String, "今晚一起听歌 🌙")
            XCTAssertEqual(body["category"] as? String, "音乐")
            XCTAssertEqual(body["isLive"] as? Bool, true)
            XCTAssertEqual(body["theme"] as? Int, 3)
            return (200, try jsonData(roomFixture))
        }

        let room = try await server.client.reserveRoom(title: "今晚一起听歌 🌙", category: "音乐", isLive: true, theme: 3, token: "test-access-token")

        XCTAssertEqual(room.id, "room-123")
        XCTAssertEqual(room.status, "draft")
        XCTAssertTrue(room.isLive)
    }

    func testOnlineRoomMetadataIsLookedUpByIDInsteadOfTheRecentHistoryWindow() async throws {
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/rooms/lookup")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            let body = try requestBody(request)
            XCTAssertEqual(body["ids"] as? [String], ["room-123"])
            return (200, try jsonData(["rooms": [roomFixture]]))
        }

        let rooms = try await server.client.roomMetadata(ids: ["room-123", "room-123"], token: "test-access-token")

        XCTAssertEqual(rooms.map(\.id), ["room-123"])
    }

    func testOnlineRoomMetadataUsesBoundedBatchesAndSkipsEmptyLists() async throws {
        let batchSizes = KikiRequestMethods()
        let server = KikiAPIMockServer { request in
            let ids = try XCTUnwrap(try requestBody(request)["ids"] as? [String])
            XCTAssertLessThanOrEqual(ids.count, 100)
            batchSizes.append(String(ids.count))
            return (200, try jsonData(["rooms": []]))
        }

        _ = try await server.client.roomMetadata(ids: [], token: "test-access-token")
        XCTAssertTrue(batchSizes.values.isEmpty)
        _ = try await server.client.roomMetadata(ids: (0..<201).map { "room-\($0)" }, token: "test-access-token")
        XCTAssertEqual(batchSizes.values, ["100", "100", "1"])
    }

    func testUnauthorizedResponseKeepsServerMessageAndRequiresRelogin() async throws {
        let server = KikiAPIMockServer { _ in
            (401, try jsonData(["detail": "登录已失效，请重新登录"]))
        }

        do {
            _ = try await server.client.library(token: "expired-test-token")
            XCTFail("过期会话不应被当作成功响应")
        } catch let error as KikiAPIError {
            XCTAssertTrue(error.isUnauthorized)
            XCTAssertEqual(error.localizedDescription, "登录已失效，请重新登录")
        }
    }

    func testNonJSONServerFailureDoesNotSurfaceHTMLAsAnError() async throws {
        let server = KikiAPIMockServer { _ in
            (502, Data("<html>upstream unavailable</html>".utf8))
        }

        do {
            _ = try await server.client.me(token: "test-access-token")
            XCTFail("网关错误不应被当作用户资料")
        } catch let error as KikiAPIError {
            XCTAssertFalse(error.isUnauthorized)
            XCTAssertEqual(error.localizedDescription, "请求未完成，请检查输入后重试。")
        }
    }

    func testMalformedSuccessPayloadProducesRecoverableError() async throws {
        let server = KikiAPIMockServer { _ in
            (200, try jsonData(["favorites": "invalid", "recents": [], "created": []]))
        }

        do {
            _ = try await server.client.library(token: "test-access-token")
            XCTFail("损坏的资料不应变成空收藏记录")
        } catch let error as KikiAPIError {
            guard case .invalidResponse = error else { return XCTFail("应报告数据格式错误") }
            XCTAssertFalse(error.isUnauthorized)
        }
    }

    func testFavoriteMutationsUseAuthenticatedIdempotentEndpoints() async throws {
        let methods = KikiRequestMethods()
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.url?.path, "/v1/favorites/room-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
            methods.append(request.httpMethod ?? "")
            return (200, try jsonData(["ok": true]))
        }

        try await server.client.favorite("room-123", enabled: true, token: "test-access-token")
        try await server.client.favorite("room-123", enabled: false, token: "test-access-token")
        XCTAssertEqual(methods.values, ["PUT", "DELETE"])
    }
}

private let userFixture: [String: Any] = [
    "id": "island_23", "sdkUserID": "sdk-island", "name": "小岛", "bio": "一起听见世界。",
    "avatarIndex": 3, "notificationsEnabled": false
]

private let roomFixture: [String: Any] = [
    "id": "room-123", "title": "今晚一起听歌 🌙", "host": "小岛", "hostID": "sdk-island",
    "audience": 0, "isLive": true, "theme": 3, "category": "音乐", "isCreatedByMe": true,
    "status": "draft", "createdAt": 1_800_000_000
]

private func jsonData(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object)
}

private func requestData(_ request: URLRequest) throws -> Data {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    return data
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: requestData(request)) as? [String: Any])
}

/// Each mock has a unique host so concurrent test sessions cannot share stubs.
private final class KikiAPIMockServer {
    let client: KikiAPIClient
    private let host: String
    private let session: URLSession

    init(responder: @escaping KikiMockURLProtocol.Responder) {
        host = "\(UUID().uuidString.lowercased()).example.invalid"
        KikiMockURLProtocol.install(responder, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KikiMockURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = KikiAPIClient(baseURL: URL(string: "https://\(host)")!, session: session)
    }

    deinit {
        session.invalidateAndCancel()
        KikiMockURLProtocol.remove(host: host)
    }
}

private final class KikiMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Responder = (URLRequest) throws -> (Int, Data)
    private static let lock = NSLock()
    private static var responders: [String: Responder] = [:]

    static func install(_ responder: @escaping Responder, host: String) {
        lock.lock()
        defer { lock.unlock() }
        responders[host] = responder
    }

    static func remove(host: String) {
        lock.lock()
        defer { lock.unlock() }
        responders.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responder = Self.responders[request.url?.host ?? ""]
        Self.lock.unlock()
        do {
            let handler = try XCTUnwrap(responder)
            let (status, data) = try handler(request)
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class KikiRequestMethods {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ method: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(method)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
