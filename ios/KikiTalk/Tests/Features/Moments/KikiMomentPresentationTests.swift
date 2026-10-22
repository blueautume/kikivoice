import Foundation
import XCTest
@testable import KikiTalk

@MainActor
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

    func testPullDuringOlderReadCoalescesInvalidationsAndAwaitsATrailingFreshPage() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        var pullStarted = false, pullFinished = false
        let pull = Task { pullStarted = true; await feed.reload(); pullFinished = true }
        try await waitForFeed { pullStarted }
        feed.invalidate(); feed.invalidate()
        XCTAssertEqual(reads.pages.count, 1, "Notification bursts must share the current worker")
        reads.respondPage(0, moments: [try feedMoment(comments: 1)])
        try await waitForFeed { reads.pages.count == 2 }
        XCTAssertTrue(feed.moments.isEmpty, "A pre-pull snapshot must not be published")
        XCTAssertFalse(pullFinished, "The native refresh action must await the fresh request")
        reads.respondPage(1, moments: [try feedMoment(comments: 4)])
        await pull.value
        XCTAssertTrue(pullFinished)
        XCTAssertEqual(feed.moments.first?.commentCount, 4)
        XCTAssertEqual(feed.moments.first?.commentPreview.first?.text, "评论 4")
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
        XCTAssertEqual(reads.pages.count, 2)
    }

    func testDetailRefreshAndLikeValueCannotBeOverwrittenByAnOlderFeedSnapshot() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        let original = try feedMoment(comments: 1)
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: [original])
        try await waitForFeed { !feed.isLoading }
        let older = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 2 }
        var detailStarted = false
        let detail = Task { detailStarted = true; await feed.refreshMoment(original.id) }
        try await waitForFeed { detailStarted }
        reads.respondPage(1, moments: [original])
        try await waitForFeed { reads.details.count == 1 }
        reads.respondDetail(0, moment: try feedMoment(comments: 6))
        await older.value; await detail.value
        XCTAssertEqual(feed.moments.first?.commentCount, 6)
        XCTAssertEqual(feed.moments.first?.commentPreview.first?.text, "评论 6")

        let stalePage = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 3 }
        let committed = try feedMoment(comments: 7, likes: 9)
        feed.update(committed)
        reads.respondPage(2, moments: [original])
        try await waitForFeed { reads.pages.count == 4 }
        XCTAssertEqual(feed.moments.first, committed, "An old page cannot erase a confirmed mutation")
        reads.respondPage(3, moments: [committed])
        await stalePage.value
        XCTAssertEqual(feed.moments.first, committed)
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
    }

    func testHiddenInvalidationsWaitAndReactivationDiscardsCancelledReadBeforeCatchingUp() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: [try feedMoment(comments: 1)])
        try await waitForFeed { !feed.isLoading }
        feed.setActive(false); feed.invalidate(); feed.invalidate()
        XCTAssertEqual(reads.pages.count, 1, "A sheet, hidden tab or inactive scene must defer reads")
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 2 }
        feed.setActive(false); feed.setActive(true)
        XCTAssertEqual(reads.pages.count, 2, "Even a cancelled transport must finish before its successor starts")
        reads.respondPage(1, moments: [try feedMoment(comments: 99)])
        try await waitForFeed { reads.pages.count == 3 }
        XCTAssertEqual(feed.moments.first?.commentCount, 1)
        reads.respondPage(2, moments: [try feedMoment(comments: 5)])
        try await waitForFeed { !feed.isLoading }
        XCTAssertEqual(feed.moments.first?.commentCount, 5)
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
    }

    func testPrivacyOrAccountResetRejectsLateReadAndClearsPreviousAccountContent() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: [try feedMoment(comments: 1)])
        try await waitForFeed { !feed.isLoading }
        let older = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 2 }
        feed.reset(); feed.setActive(true)
        XCTAssertTrue(feed.moments.isEmpty)
        XCTAssertNil(feed.nextCursor)
        reads.respondPage(1, moments: [try feedMoment(comments: 99)])
        try await waitForFeed { reads.pages.count == 3 }
        XCTAssertTrue(feed.moments.isEmpty, "The old account must not repopulate the cleared feed")
        let current = try feedMoment(comments: 2, id: "22222222-2222-4222-8222-222222222222")
        reads.respondPage(2, moments: [current])
        await older.value
        XCTAssertEqual(feed.moments, [current])
    }

    func testPullSupersedesInFlightPaginationAndKeepsTheFreshCursor() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: [try feedMoment(comments: 1)], nextCursor: "after-first")
        try await waitForFeed { !feed.isLoading }
        let more = Task { await feed.loadMore() }
        try await waitForFeed { reads.pages.count == 2 }
        XCTAssertEqual(reads.pages[1], "after-first")
        var pullStarted = false
        let pull = Task { pullStarted = true; await feed.reload() }
        try await waitForFeed { pullStarted }
        reads.respondPage(1, moments: [try feedMoment(comments: 99)], nextCursor: "stale-cursor")
        try await waitForFeed { reads.pages.count == 3 }
        XCTAssertNil(reads.pages[2])
        reads.respondPage(2, moments: [try feedMoment(comments: 8)])
        await more.value; await pull.value
        XCTAssertEqual(feed.moments.map(\.commentCount), [8])
        XCTAssertNil(feed.nextCursor)
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
    }

    func testRefreshFailureKeepsCommentsAndPreviewAndCanBeRetried() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        let original = try feedMoment(comments: 2)
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: [original], nextCursor: "preserved-cursor")
        try await waitForFeed { !feed.isLoading }
        let failing = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 2 }
        reads.failPage(1)
        await failing.value
        XCTAssertEqual(feed.moments, [original])
        XCTAssertEqual(feed.nextCursor, "preserved-cursor")
        XCTAssertNotNil(feed.error)
        let retry = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 3 }
        reads.respondPage(2, moments: [try feedMoment(comments: 9)])
        await retry.value
        XCTAssertEqual(feed.moments.first?.commentCount, 9)
        XCTAssertNil(feed.error)
    }

    func testTemporaryDetailOverlayKeepsFortyLoadedMomentsAndRefreshesOnlyTheThirtieth() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        let original = try await loadFortyMoments(feed, reads: reads)
        let target = original[29]
        feed.setActive(false, refreshOnResume: false)
        await feed.refreshMoment(target.id)
        feed.setActive(true, refreshOnResume: false)
        try await waitForFeed { reads.details.count == 1 }
        XCTAssertEqual(reads.pages.count, 2, "Closing an unchanged overlay must not replace the loaded head")
        XCTAssertEqual(reads.details, [target.id])
        let updated = try feedMoment(comments: 5, id: target.id)
        reads.respondDetail(0, moment: updated)
        try await waitForFeed { !feed.isLoading }
        XCTAssertEqual(feed.moments.count, 40)
        XCTAssertEqual(feed.moments.map(\.id), original.map(\.id))
        XCTAssertEqual(feed.moments[29], updated)
        XCTAssertEqual(feed.nextCursor, "after-forty")
        XCTAssertEqual(reads.pages.count, 2)
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
    }

    func testDirtyOverlayRefreshesTheLoadedRangeAtomicallyAndKeepsItOnALaterPageFailure() async throws {
        let reads = MomentFeedReads(), feed = feedModel(reads)
        defer { feed.setActive(false); reads.finishRemaining() }
        let original = try await loadFortyMoments(feed, reads: reads)
        feed.setActive(false, refreshOnResume: false)
        feed.invalidate()
        feed.setActive(true, refreshOnResume: false)
        try await waitForFeed { reads.pages.count == 3 }
        let freshHead = try original.prefix(20).map { try feedMoment(comments: 3, id: $0.id) }
        reads.respondPage(2, moments: freshHead, nextCursor: "fresh-second")
        try await waitForFeed { reads.pages.count == 4 }
        XCTAssertEqual(reads.pages[3], "fresh-second")
        XCTAssertEqual(feed.moments, original, "An incomplete refresh cannot truncate or partially replace forty rows")
        reads.failPage(3)
        try await waitForFeed { !feed.isLoading }
        XCTAssertEqual(feed.moments, original)
        XCTAssertEqual(feed.nextCursor, "after-forty")
        XCTAssertNotNil(feed.error)

        let retry = Task { await feed.reload() }
        try await waitForFeed { reads.pages.count == 5 }
        reads.respondPage(4, moments: freshHead, nextCursor: "fresh-second")
        try await waitForFeed { reads.pages.count == 6 }
        let freshTail = try original.suffix(20).map { try feedMoment(comments: 6, id: $0.id) }
        reads.respondPage(5, moments: freshTail, nextCursor: "fresh-after-forty")
        await retry.value
        XCTAssertEqual(feed.moments.count, 40)
        XCTAssertEqual(feed.moments.map(\.id), original.map(\.id))
        XCTAssertEqual(feed.moments[29].commentCount, 6)
        XCTAssertEqual(feed.nextCursor, "fresh-after-forty")
        XCTAssertNil(feed.error)
        XCTAssertEqual(reads.maximumConcurrentReads, 1)
    }

    private func loadFortyMoments(_ feed: KikiMomentFeedModel, reads: MomentFeedReads) async throws -> [KikiMoment] {
        let values = try (1...40).map { try feedMoment(comments: 0, id: String(format: "00000000-0000-4000-8000-%012d", $0)) }
        feed.setActive(true)
        try await waitForFeed { reads.pages.count == 1 }
        reads.respondPage(0, moments: Array(values.prefix(20)), nextCursor: "after-twenty")
        try await waitForFeed { !feed.isLoading }
        let more = Task { await feed.loadMore() }
        try await waitForFeed { reads.pages.count == 2 }
        reads.respondPage(1, moments: Array(values.suffix(20)), nextCursor: "after-forty")
        await more.value
        XCTAssertEqual(feed.moments.count, 40)
        return values
    }

    private func feedModel(_ reads: MomentFeedReads) -> KikiMomentFeedModel {
        KikiMomentFeedModel(fetchPage: { try await reads.page($0) }, fetchMoment: { try await reads.detail($0) })
    }
    private func feedMoment(comments: Int, likes: Int = 8,
                            id: String = "11111111-1111-4111-8111-111111111111") throws -> KikiMoment {
        var object = momentJSON(); object["id"] = id; object["commentCount"] = comments; object["likeCount"] = likes
        object["commentPreview"] = comments > 0 ? [commentJSON(comments, momentID: id)] : []
        return try decode(object)
    }
    private func waitForFeed(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Controlled feed request did not settle", file: file, line: line)
        throw CancellationError()
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

@MainActor
private final class MomentFeedReads {
    private(set) var pages: [String?] = []
    private(set) var details: [String] = []
    private(set) var maximumConcurrentReads = 0
    private var activeReads = 0
    private var pageContinuations: [Int: CheckedContinuation<KikiMomentsPage, Error>] = [:]
    private var detailContinuations: [Int: CheckedContinuation<KikiMoment, Error>] = [:]

    func page(_ cursor: String?) async throws -> KikiMomentsPage {
        activeReads += 1; maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            let index = pages.count; pages.append(cursor); pageContinuations[index] = continuation
        }
    }
    func detail(_ id: String) async throws -> KikiMoment {
        activeReads += 1; maximumConcurrentReads = max(maximumConcurrentReads, activeReads)
        defer { activeReads -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            let index = details.count; details.append(id); detailContinuations[index] = continuation
        }
    }
    func respondPage(_ index: Int, moments: [KikiMoment], nextCursor: String? = nil) {
        pageContinuations.removeValue(forKey: index)?.resume(returning: .init(moments: moments, nextCursor: nextCursor))
    }
    func respondDetail(_ index: Int, moment: KikiMoment) {
        detailContinuations.removeValue(forKey: index)?.resume(returning: moment)
    }
    func failPage(_ index: Int) {
        pageContinuations.removeValue(forKey: index)?.resume(throwing: KikiAPIError.server(503, "暂时无法刷新，请重试。"))
    }
    func finishRemaining() {
        let pages = pageContinuations.values, details = detailContinuations.values
        pageContinuations = [:]; detailContinuations = [:]
        for continuation in pages { continuation.resume(throwing: CancellationError()) }
        for continuation in details { continuation.resume(throwing: CancellationError()) }
    }
}
