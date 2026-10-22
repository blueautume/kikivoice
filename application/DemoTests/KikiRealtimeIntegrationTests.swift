import Foundation
import XCTest
@testable import KikiTalk

/// Public infrastructure checks never fabricate an Apple identity or create a test user.
/// Actual Apple authorization, first nickname and cross-device RTC need a signed-in device.
final class KikiRealtimeIntegrationTests: XCTestCase {
    func testRealAppleChallengeIsAvailable() async throws {
        guard ProcessInfo.processInfo.environment["KIKI_TEST_APPLE_CHALLENGE"] == "1" else {
            throw XCTSkip("设置 KIKI_TEST_APPLE_CHALLENGE=1 后验证真实 Apple 登录 challenge；不会创建账号。")
        }
        let api = KikiAccountAPIClient.shared
        let first = try await api.appleChallenge()
        let second = try await api.appleChallenge()
        XCTAssertFalse(first.challengeID.isEmpty)
        XCTAssertFalse(first.nonce.isEmpty)
        XCTAssertNotEqual(first.challengeID, second.challengeID)
        XCTAssertNotEqual(first.nonce, second.nonce)
        XCTAssertGreaterThan(first.expiresAt, Int(Date().timeIntervalSince1970))
    }
}
