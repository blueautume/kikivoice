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

    func testRoomBackgroundSurvivesSavingAndEditingAllFiveStyles() throws {
        var room = KikiRoom(id: "voice_theme", title: "房间", host: "房主", hostID: "host", category: "随心聊",
                            audience: 0, isLive: false, theme: 0, isCreatedByMe: true, status: "draft")
        for theme in 0..<5 {
            room.theme = theme
            let restored = try JSONDecoder().decode(KikiRoom.self, from: JSONEncoder().encode(room))
            XCTAssertEqual(restored.theme, theme)
            XCTAssertEqual(restored.id, room.id)
        }
    }

    func testUnknownRoomBackgroundFallsBackToSystemStyle() throws {
        let room = KikiRoom(id: "voice_theme", title: "房间", host: "房主", hostID: "host", category: "随心聊",
                            audience: 0, isLive: false, theme: -1, isCreatedByMe: true, status: "draft")
        XCTAssertEqual(room.theme, 0)
        let data = Data(#"{"id":"voice_theme","title":"房间","host":"房主","hostID":"host","category":"随心聊","audience":0,"isLive":false,"theme":5,"isCreatedByMe":true,"status":"draft"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(KikiRoom.self, from: data).theme, 0)
    }

    func testRoomWithoutOptionalAvatarUsesDefaultWithoutFakeMembers() throws {
        let data = Data(#"{"id":"voice_kiki_b","title":"真实房间","host":"kiki_001","hostID":"kiki_owner","category":"生活","audience":0,"isLive":false,"theme":0,"isCreatedByMe":true,"status":"draft"}"#.utf8)
        let room = try JSONDecoder().decode(KikiRoom.self, from: data)
        XCTAssertEqual(room.hostAvatarIndex, 0)
        XCTAssertEqual(room.audience, 0)
        XCTAssertEqual(room.status, "draft")
        XCTAssertTrue(room.isCreatedByMe)
    }

    func testSeatInviteRequiresModeratorAndCurrentOnlineListener() {
        let owner = roomMember("owner", role: .owner, seat: 1)
        let listener = roomMember("listener")
        let offline = roomMember("offline", online: false)
        let speaker = roomMember("speaker", seat: 2)
        let state = invitationRoomState(me: owner, members: [listener, offline, speaker])

        XCTAssertEqual(state.seatInviteState(for: listener.userID, at: 1_000), .available)
        XCTAssertNil(state.seatInviteState(for: owner.userID, at: 1_000), "The user must use their own seat controls")
        XCTAssertNil(state.seatInviteState(for: offline.userID, at: 1_000))
        XCTAssertNil(state.seatInviteState(for: speaker.userID, at: 1_000))
        XCTAssertNil(state.seatInviteState(for: "departed", at: 1_000), "Old profile data is not current room membership")

        let ordinary = invitationRoomState(me: listener, members: [roomMember("other-listener")])
        XCTAssertNil(ordinary.seatInviteState(for: "other-listener", at: 1_000), "Listeners cannot invite other listeners")
    }

    func testSeatInviteAllowsPeerAdministratorEvenWhenAllSeatsAreOccupied() {
        let admin = roomMember("admin", role: .admin, seat: 2)
        let peerAdmin = roomMember("peer-admin", role: .admin)
        let seats = (1...8).map { KikiRoomSeat(index: $0, userID: $0 == 2 ? admin.userID : "speaker-\($0)", locked: false, audioLocked: false) }
        let state = invitationRoomState(me: admin, members: [peerAdmin], seats: seats)

        XCTAssertFalse(admin.canModerate(peerAdmin), "Punishment permissions deliberately exclude peers")
        XCTAssertTrue(state.availableSeats.isEmpty)
        XCTAssertEqual(state.seatInviteState(for: peerAdmin.userID, at: 1_000), .available,
                       "An invitation can authorize waiting for the next ordered seat")
    }

    func testSeatInvitePendingExpiresAtDeadlineAndOnlyAppliesToItsTarget() {
        let owner = roomMember("owner", role: .owner, seat: 1)
        let listener = roomMember("listener")
        let invitation = KikiSeatInvitation(userID: listener.userID, name: listener.name, seatIndex: 2, expiresAt: 1_120)
        let state = invitationRoomState(me: owner, members: [listener, roomMember("other")], invitations: [invitation])

        XCTAssertEqual(state.seatInviteState(for: listener.userID, at: 1_119), .pending)
        XCTAssertEqual(state.seatInviteState(for: listener.userID, at: 1_120), .available)
        XCTAssertEqual(state.seatInviteState(for: listener.userID, at: 1_121), .available)
        XCTAssertEqual(state.seatInviteState(for: "other", at: 1_119), .available)
    }

    func testActiveInviteCannotKeepDepartedOrSeatedTargetInvitable() {
        let owner = roomMember("owner", role: .owner, seat: 1)
        let invitation = KikiSeatInvitation(userID: "listener", name: "listener", seatIndex: 2, expiresAt: 1_120)

        for target in [roomMember("listener", online: false), roomMember("listener", seat: 2)] {
            let state = invitationRoomState(me: owner, members: [target], invitations: [invitation])
            XCTAssertNil(state.seatInviteState(for: target.userID, at: 1_000))
        }
        XCTAssertNil(invitationRoomState(me: owner, invitations: [invitation]).seatInviteState(for: "listener", at: 1_000))
    }

    func testIncomingInviteMustBeForCurrentUserAndStillValid() {
        let listener = roomMember("listener")
        let invitation = KikiSeatInvitation(userID: listener.userID, name: listener.name, seatIndex: 2, expiresAt: 1_120)
        let other = KikiSeatInvitation(userID: "other", name: "other", seatIndex: 3, expiresAt: 1_200)
        let state = invitationRoomState(me: listener, invitations: [other, invitation])

        XCTAssertEqual(state.pendingIncomingInvitation(at: 1_119), invitation)
        XCTAssertNil(state.pendingIncomingInvitation(at: 1_120), "The exact expiration second is already expired")
        XCTAssertNil(state.pendingIncomingInvitation(at: 1_121), "Another user's invitation must never be offered instead")
        XCTAssertNil(invitationRoomState(me: listener, invitations: [other]).pendingIncomingInvitation(at: 1_000))
    }

    func testIncomingInviteDisappearsAfterTakingSeatOrLosingOnlinePresence() {
        let invitation = KikiSeatInvitation(userID: "listener", name: "listener", seatIndex: 2, expiresAt: 2_000_000_000)

        for me in [roomMember("listener", seat: 2), roomMember("listener", online: false)] {
            let state = invitationRoomState(me: me, invitations: [invitation])
            XCTAssertNil(state.pendingIncomingInvitation(at: 1_000), "A stale invitation must not offer another seat transition")
            XCTAssertNil(state.myInvitation)
        }
        XCTAssertEqual(invitationRoomState(me: roomMember("listener"), invitations: [invitation]).myInvitation, invitation)
    }

    private func roomMember(_ userID: String, role: KikiRoomRole = .member,
                            seat: Int? = nil, online: Bool = true) -> KikiRoomMember {
        KikiRoomMember(userID: userID, name: userID, avatarIndex: 0, avatarURL: nil,
                       role: role, seatIndex: seat, audioMuted: false, chatMuted: false,
                       online: online, canPublishAudio: seat != nil, canPublishData: true)
    }

    private func invitationRoomState(me: KikiRoomMember, members: [KikiRoomMember] = [],
                                     seats: [KikiRoomSeat] = [], invitations: [KikiSeatInvitation] = []) -> KikiRoomState {
        let room = KikiRoom(id: "voice_invite", title: "房间", host: "房主", hostID: "owner", category: "随心聊",
                            audience: members.count + 1, isLive: false, theme: 0, isCreatedByMe: me.role == .owner, status: "live")
        return KikiRoomState(room: room, revision: 1, me: me, seats: seats, members: [me] + members,
                             queue: [], invitations: invitations, bans: [])
    }
}
