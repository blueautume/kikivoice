import Foundation
import XCTest
@testable import KikiTalk

final class KikiMomentPresentationTests: XCTestCase {
    func testOlderMomentResponsesWithoutPreviewRemainReadable() throws {
        for preview in [nil, NSNull()] as [Any?] {
            var object = momentJSON()
            if let preview { object["commentPreview"] = preview }
            let moment = try decode(object)
            XCTAssertTrue(moment.commentPreview.isEmpty)
            XCTAssertEqual(moment.commentCount, 36, "An older response still carries the total comment count")
        }
    }

    func testPreviewIncludesAtMostThreeCommentsFromThisMomentAndPreservesTotal() throws {
        var object = momentJSON()
        object["commentPreview"] = [commentJSON(0, momentID: "another-moment")]
            + (1...6).map { commentJSON($0) }
        let moment = try decode(object)
        XCTAssertEqual(moment.commentPreview.map(\.id), ["comment-1", "comment-2", "comment-3"])
        XCTAssertTrue(moment.commentPreview.allSatisfy { $0.momentID == moment.id })
        XCTAssertEqual(moment.commentCount, 36, "The feed preview limit must not replace the server's total")
    }

    func testProgrammaticallyCreatedMomentUsesTheSamePreviewBoundary() throws {
        let original = try decode(momentJSON())
        let comments = try (0...4).map {
            try JSONDecoder().decode(KikiMomentComment.self, from: json(commentJSON($0, momentID: $0 == 0 ? "other" : original.id)))
        }
        let moment = KikiMoment(id: original.id, author: original.author, text: original.text, media: original.media,
                                createdAt: original.createdAt, likeCount: original.likeCount, commentCount: original.commentCount,
                                liked: original.liked, canDelete: original.canDelete, commentPreview: comments)
        XCTAssertEqual(moment.commentPreview.map(\.id), ["comment-1", "comment-2", "comment-3"])
        let noPreview = KikiMoment(id: original.id, author: original.author, text: "", media: [], createdAt: 0,
                                   likeCount: 0, commentCount: 0, liked: false, canDelete: false)
        XCTAssertTrue(noPreview.commentPreview.isEmpty)
    }

    func testMalformedPreviewDoesNotSilentlyInventDisplayableComments() throws {
        var object = momentJSON()
        object["commentPreview"] = [["id": "missing-required-comment-fields"]]
        XCTAssertThrowsError(try decode(object))
    }

    func testDetailAndLikeResponsesRetainPreviewAndAuthenticatedAccountRoute() async throws {
        let nonce = UUID(), momentID = "11111111-1111-4111-8111-111111111111"
        var object = momentJSON()
        object["commentPreview"] = (1...3).map { commentJSON($0) }
        let response = try json(["moment": object])
        let server = KikiAPIMockServer { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer moment-fixture-only")
            XCTAssertTrue(request.url?.host?.hasSuffix("example.invalid") == true)
            let isLike = request.url?.path.hasSuffix("/like") == true
            XCTAssertEqual(request.url?.path, "/v1/social/moments/" + momentID + (isLike ? "/like" : ""))
            XCTAssertEqual(request.httpMethod, isLike ? "PUT" : "GET")
            if isLike {
                let body = try requestBody(request)
                XCTAssertEqual(Set(body.keys), ["requestID"])
                XCTAssertEqual(UUID(uuidString: body["requestID"] as? String ?? ""), nonce)
            }
            return (200, response)
        }
        let detail = try await server.client.socialMoment(momentID, token: "moment-fixture-only")
        let liked = try await server.client.socialLike(momentID, enabled: true, requestID: nonce, token: "moment-fixture-only")
        XCTAssertEqual(detail.commentPreview.count, 3)
        XCTAssertEqual(liked.commentPreview, detail.commentPreview)
        XCTAssertEqual(liked.commentCount, 36)
    }

    private func decode(_ object: [String: Any]) throws -> KikiMoment {
        try JSONDecoder().decode(KikiMoment.self, from: json(object))
    }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func personJSON() -> [String: Any] {
        ["id": "kiki_fixture0002", "name": "小岛", "bio": "", "avatarIndex": 4, "avatarURL": NSNull(),
         "following": false, "followsYou": false, "mutual": false, "followingCount": 0, "followerCount": 0, "currentRoomID": NSNull()]
    }
    private func momentJSON() -> [String: Any] {
        ["id": "11111111-1111-4111-8111-111111111111", "author": personJSON(), "text": "今天的海边很漂亮 😀", "media": [],
         "createdAt": 1_792_422_000, "likeCount": 8, "commentCount": 36, "liked": false, "canDelete": false]
    }
    private func commentJSON(_ index: Int, momentID: String = "11111111-1111-4111-8111-111111111111") -> [String: Any] {
        ["id": "comment-\(index)", "momentID": momentID, "author": personJSON(), "text": "评论 \(index)",
         "createdAt": 1_792_422_000 + index, "canDelete": false]
    }
}
