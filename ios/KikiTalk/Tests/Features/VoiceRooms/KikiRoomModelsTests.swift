import XCTest
@testable import KikiTalk

final class KikiRoomModelsTests: XCTestCase {
    func testServerRoomDoesNotRequireLegacyLanguageField() throws {
        let data = Data(#"{"id":"voice_kiki_a","title":"周末聊聊🌙","host":"小岛","hostID":"kiki_host","category":"随心聊","audience":2,"isLive":false,"theme":1,"isCreatedByMe":false,"status":"live","createdAt":1792100000,"hostAvatarIndex":4}"#.utf8)
        let room = try JSONDecoder().decode(KikiRoom.self, from: data)
        XCTAssertEqual(room.title, "周末聊聊🌙")
        XCTAssertEqual(room.hostAvatarIndex, 4)
        XCTAssertEqual(room.status, "live")
        XCTAssertEqual(room.audience, 2)
        XCTAssertEqual(room.language, "中文")
    }

    func testClosedRoomRemainsARecordWithoutOnlineViewers() throws {
        let room = KikiRoom(id: "live_kiki_ended", title: "昨天的音乐", host: "主播", hostID: "kiki_owner", category: "音乐", audience: 0, isLive: true, theme: 2, isCreatedByMe: true, status: "ended", createdAt: 1792100000, hostAvatarIndex: 2)
        let restored = try JSONDecoder().decode(KikiRoom.self, from: JSONEncoder().encode(room))
        XCTAssertEqual(restored, room)
        XCTAssertEqual(restored.audience, 0)
        XCTAssertEqual(restored.status, "ended")
    }

    func testRoomWithoutOptionalAvatarUsesDefaultWithoutFakeMembers() throws {
        let data = Data(#"{"id":"voice_kiki_b","title":"真实房间","host":"kiki_001","hostID":"kiki_owner","category":"生活","audience":0,"isLive":false,"theme":0,"isCreatedByMe":true,"status":"draft"}"#.utf8)
        let room = try JSONDecoder().decode(KikiRoom.self, from: data)
        XCTAssertEqual(room.hostAvatarIndex, 0)
        XCTAssertEqual(room.audience, 0)
        XCTAssertEqual(room.status, "draft")
        XCTAssertTrue(room.isCreatedByMe)
    }
}
