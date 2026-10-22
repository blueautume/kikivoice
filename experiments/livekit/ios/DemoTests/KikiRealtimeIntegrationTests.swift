import Foundation
import XCTest
@testable import KikiLiveKitLab

/// Opt-in integration uses an externally supplied code and deletes its temporary account.
final class KikiRealtimeIntegrationTests: XCTestCase {
    func testRealLabSessionAndRoomGrant() async throws {
        guard let code = ProcessInfo.processInfo.environment["KIKI_LAB_ACCESS_CODE"], !code.isEmpty else {
            throw XCTSkip("设置 KIKI_LAB_ACCESS_CODE 后验证独立实验登录、房间令牌与注销。邀请码不得写入 scheme 或源码。")
        }
        let docs = try XCTUnwrap(KikiLegalBundle.bundled)
        let api = KikiAPIClient.shared
        let response = try await api.loginForLab(name: "iOS 集成验证", accessCode: code,
            legalConsent: KikiLegalAcceptance(versions: docs.versions, accepted: true, adultConfirmed: true))
        do {
            XCTAssertEqual(response.sdk.provider, "livekit")
            XCTAssertEqual(response.sdk.serverURL, "wss://furby.top")
            let room = try await api.reserveRoom(title: "iOS 基础验证", category: "随心聊", isLive: false, theme: 0, token: response.token)
            let connection = try await api.rtcJoin(roomID: room.id, token: response.token)
            XCTAssertFalse(connection.participantToken.isEmpty)
            XCTAssertEqual(connection.room.id, room.id)
            XCTAssertFalse(connection.room.isLive)
            _ = try await api.setRoomStatus(room.id, status: "ended", token: response.token)
            try await api.deleteAccount(token: response.token)
        } catch {
            try? await api.deleteAccount(token: response.token)
            throw error
        }
    }
}
