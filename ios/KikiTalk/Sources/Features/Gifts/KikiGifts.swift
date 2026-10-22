import Foundation
import Combine

struct KikiGiftItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let price: Int
    let animationAsset: String
    let posterAsset: String
}

enum KikiDecorationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case avatarFrame, micEffect, chatBubble, roomBackground
    var id: String { rawValue }
    var title: String {
        switch self {
        case .avatarFrame: return "头像框"
        case .micEffect: return "麦位特效"
        case .chatBubble: return "聊天气泡"
        case .roomBackground: return "房间背景"
        }
    }
}

struct KikiDecorationItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let style: String
    let kind: KikiDecorationKind
    let price: Int
    var symbol: String {
        switch kind {
        case .avatarFrame: return "person.crop.circle"
        case .micEffect: return "waveform"
        case .chatBubble: return "bubble.left.and.bubble.right.fill"
        case .roomBackground: return "photo"
        }
    }
}

struct KikiEquippedDecorations: Codable, Equatable, Sendable {
    let avatarFrame: String?
    let micEffect: String?
    let chatBubble: String?
    let roomBackground: String?
    static let empty = Self(avatarFrame: nil, micEffect: nil, chatBubble: nil, roomBackground: nil)
    func id(for kind: KikiDecorationKind) -> String? {
        switch kind {
        case .avatarFrame: return avatarFrame
        case .micEffect: return micEffect
        case .chatBubble: return chatBubble
        case .roomBackground: return roomBackground
        }
    }
}

struct KikiDecorationInventory: Codable, Equatable, Sendable {
    let ownedIDs: [String]
    let equipped: KikiEquippedDecorations
    static let empty = Self(ownedIDs: [], equipped: .empty)
}

struct KikiGiftWallet: Codable, Equatable, Sendable {
    let balance: Int
    let initialGrant: Int
    let currency: String
}

struct KikiGiftInventoryItem: Codable, Equatable, Sendable {
    let giftID: String
    let quantity: Int
}

struct KikiWalletEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let amount: Int
    let balanceAfter: Int
    let createdAt: Int
}

struct KikiGiftEvent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let roomID: String
    let batchID: String
    let senderUserID: String
    let senderName: String
    let recipientUserID: String
    let recipientName: String
    let giftID: String
    let giftName: String
    let seq: Int
    let quantity: Int
    let unitPrice: Int
    let batchRecipientCount: Int
    let createdAt: Int
}

struct KikiExperienceCatalog: Codable, Equatable, Sendable {
    let gifts: [KikiGiftItem]
    let decorations: [KikiDecorationItem]
    let initialGrant: Int
}

struct KikiExperienceSnapshot: Codable, Equatable, Sendable {
    let wallet: KikiGiftWallet
    let inventory: KikiDecorationInventory
    let entries: [KikiWalletEntry]
    let giftInventory: [KikiGiftInventoryItem]

    init(wallet: KikiGiftWallet, inventory: KikiDecorationInventory, entries: [KikiWalletEntry],
         giftInventory: [KikiGiftInventoryItem] = []) {
        self.wallet = wallet; self.inventory = inventory; self.entries = entries
        self.giftInventory = giftInventory
    }
    private enum CodingKeys: String, CodingKey { case wallet, inventory, entries, giftInventory }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        wallet = try values.decode(KikiGiftWallet.self, forKey: .wallet)
        inventory = try values.decode(KikiDecorationInventory.self, forKey: .inventory)
        entries = try values.decode([KikiWalletEntry].self, forKey: .entries)
        giftInventory = try values.decodeIfPresent([KikiGiftInventoryItem].self, forKey: .giftInventory) ?? []
    }
}

struct KikiGiftSendResult: Codable, Equatable, Sendable {
    let events: [KikiGiftEvent]
    let wallet: KikiGiftWallet
    let totalCost: Int
    let giftInventory: [KikiGiftInventoryItem]
    let inventoryUsed: Int
    let diamondQuantity: Int
    let totalQuantity: Int

    init(events: [KikiGiftEvent], wallet: KikiGiftWallet, totalCost: Int,
         giftInventory: [KikiGiftInventoryItem] = [], inventoryUsed: Int = 0,
         diamondQuantity: Int = 0, totalQuantity: Int = 0) {
        self.events = events; self.wallet = wallet; self.totalCost = totalCost
        self.giftInventory = giftInventory; self.inventoryUsed = inventoryUsed
        self.diamondQuantity = diamondQuantity; self.totalQuantity = totalQuantity
    }
    private enum CodingKeys: String, CodingKey {
        case events, wallet, totalCost, giftInventory, inventoryUsed, diamondQuantity, totalQuantity
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        events = try values.decode([KikiGiftEvent].self, forKey: .events)
        wallet = try values.decode(KikiGiftWallet.self, forKey: .wallet)
        totalCost = try values.decode(Int.self, forKey: .totalCost)
        giftInventory = try values.decodeIfPresent([KikiGiftInventoryItem].self, forKey: .giftInventory) ?? []
        inventoryUsed = try values.decodeIfPresent(Int.self, forKey: .inventoryUsed) ?? 0
        diamondQuantity = try values.decodeIfPresent(Int.self, forKey: .diamondQuantity) ?? 0
        totalQuantity = try values.decodeIfPresent(Int.self, forKey: .totalQuantity) ?? 0
    }
}

struct KikiGiftEventPage: Codable, Equatable, Sendable {
    let events: [KikiGiftEvent]
    let cursor: Int
    let hasMore: Bool
}

struct KikiDecorationPurchaseResult: Codable, Equatable, Sendable {
    let wallet: KikiGiftWallet
    let inventory: KikiDecorationInventory
}

struct KikiPublicDecoration: Codable, Equatable, Sendable {
    let userID: String
    let equipped: KikiEquippedDecorations
}

struct KikiPublicDecorationPage: Codable, Equatable, Sendable {
    let users: [KikiPublicDecoration]
}

/// Experience diamonds are issued and persisted by the voice service. This
/// store has no payment, local grant or polling timer; the room lifecycle drives it.
@MainActor
final class KikiGiftStore: ObservableObject {
    @Published private(set) var wallet: KikiGiftWallet?
    @Published private(set) var inventory: KikiDecorationInventory = .empty
    @Published private(set) var catalog: KikiExperienceCatalog?
    @Published private(set) var entries: [KikiWalletEntry] = []
    @Published private(set) var giftInventory: [KikiGiftInventoryItem] = []
    @Published private(set) var events: [KikiGiftEvent] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var publicDecorations: [String: KikiEquippedDecorations] = [:]

    private var api: KikiAPIClient?
    private var token: String?
    private(set) var userID: String?
    private var epoch: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    private var activeMutations = 0
    private var mutationTail: Task<Void, Never>?
    private var refreshTask: Task<Bool, Never>?
    private var refreshID: UUID?
    private var decorationRefreshID: UUID?
    private var roomID: String?
    private var roomGeneration: UInt64 = 0
    fileprivate var roomPresentationGeneration: UInt64 { roomGeneration }
    private(set) var roomCursor: Int?
    private var pollTask: Task<Void, Never>?
    private var pollID: UUID?
    private let now: () -> Date
    private(set) var nextAllowedRoomPollAt = Date.distantPast
    private(set) var roomPollFailureCount = 0
    private(set) var hasPendingRoomInvalidation = false
    private var roomInvalidationRevision: UInt64 = 0
    private var seenEventIDs: Set<String> = []
    private var seenEventOrder: [String] = []
    private var sendQueues: [String: KikiGiftSendQueue] = [:]
    private var completedGiftRequests: Set<UUID> = []
    private var completedGiftOrder: [UUID] = []
    /// Called only after a server-confirmed send, to invalidate the room's
    /// gift-event feed through the existing RTC connection.
    var onRoomGiftCommitted: ((String) -> Void)?

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    var isAvailable: Bool { api != nil && token?.isEmpty == false && userID?.isEmpty == false }
    var giftItems: [KikiGiftItem] { catalog?.gifts ?? [] }
    var decorationItems: [KikiDecorationItem] { catalog?.decorations ?? [] }
    var balanceText: String { wallet.map { $0.balance.formatted(.number) } ?? "—" }
    func giftCount(_ giftID: String) -> Int { giftInventory.first { $0.giftID == giftID }?.quantity ?? 0 }
    var orderedGiftItems: [KikiGiftItem] {
        giftItems.enumerated().sorted {
            let left = giftCount($0.element.id) > 0, right = giftCount($1.element.id) > 0
            return left == right ? $0.offset < $1.offset : left
        }.map(\.element)
    }
    func sendQueue(for roomID: String) -> KikiGiftSendQueue {
        if let queue = sendQueues[roomID] { return queue }
        // Retain unresolved requests while a sheet is closed, but bound room caches.
        if sendQueues.count >= 8 {
            for key in Array(sendQueues.keys) where sendQueues[key]?.pendingCount == 0 {
                sendQueues.removeValue(forKey: key)
            }
        }
        let queue = KikiGiftSendQueue(gifts: self, roomID: roomID)
        sendQueues[roomID] = queue
        return queue
    }
    fileprivate func didCompleteGift(_ requestID: UUID) -> Bool { completedGiftRequests.contains(requestID) }

    func configure(api: KikiAPIClient, token: String, userID: String) {
        guard !token.isEmpty, !userID.isEmpty else { reset(); return }
        if self.userID != userID || self.api !== api { reset() }
        self.api = api
        self.token = token
        self.userID = userID
    }

    func reset() {
        epoch &+= 1
        sendQueues.values.forEach { $0.invalidate() }
        sendQueues = [:]
        completedGiftRequests = []; completedGiftOrder = []
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        mutationTail = nil
        mutationRevision = 0
        activeMutations = 0
        decorationRefreshID = nil
        stopRoom()
        api = nil
        token = nil
        userID = nil
        wallet = nil
        inventory = .empty
        catalog = nil
        entries = []
        giftInventory = []
        isLoading = false
        errorMessage = nil
        publicDecorations = [:]
    }

    /// Coalesce readers. If a mutation overtakes a snapshot, fetch once more
    /// after it settles instead of putting an older balance back on screen.
    func refresh() async {
        let expectedEpoch = epoch
        for _ in 0..<2 {
            guard isCurrent(expectedEpoch), let api, let token else { return }
            let task: Task<Bool, Never>
            if let current = refreshTask {
                task = current
            } else {
                let id = UUID()
                let revision = mutationRevision
                let startedDuringMutation = activeMutations > 0
                refreshID = id
                // A background revalidation must not replace usable content
                // with a loading state or dim its controls on every tick.
                let showsInitialLoading = catalog == nil || wallet == nil
                if showsInitialLoading { isLoading = true }
                task = Task { @MainActor [weak self] in
                    guard let self else { return false }
                    defer {
                        if self.refreshID == id {
                            self.refreshTask = nil
                            self.refreshID = nil
                            if self.isLoading { self.isLoading = false }
                        }
                    }
                    do {
                        async let catalog = api.experienceCatalog(token: token)
                        async let snapshot = api.experience(token: token)
                        let (newCatalog, newSnapshot) = try await (catalog, snapshot)
                        try Task.checkCancellation()
                        guard self.isCurrent(expectedEpoch) else { return false }
                        if self.catalog != newCatalog { self.catalog = newCatalog }
                        guard self.mutationRevision == revision, !startedDuringMutation,
                              self.activeMutations == 0 else { return true }
                        if self.wallet != newSnapshot.wallet { self.wallet = newSnapshot.wallet }
                        if self.giftInventory != newSnapshot.giftInventory { self.giftInventory = newSnapshot.giftInventory }
                        self.applyInventory(newSnapshot.inventory)
                        let entries = Array(newSnapshot.entries.prefix(50))
                        if self.entries != entries { self.entries = entries }
                        if self.errorMessage != nil { self.errorMessage = nil }
                    } catch {
                        if self.isCurrent(expectedEpoch), self.mutationRevision == revision,
                           !(error is CancellationError) { self.errorMessage = error.localizedDescription }
                    }
                    return false
                }
                refreshTask = task
            }
            let superseded = await task.value
            guard superseded, isCurrent(expectedEpoch), activeMutations == 0 else { return }
        }
    }

    func appearance(for userID: String) -> KikiEquippedDecorations {
        userID == self.userID ? inventory.equipped : (publicDecorations[userID] ?? .empty)
    }

    func refreshDecorations(userIDs: [String]) async {
        guard !Task.isCancelled, let api, let token, isAvailable else { return }
        let ids = Array(Set(userIDs.filter { !$0.isEmpty })).sorted().prefix(100)
        guard !ids.isEmpty else { return }
        let requested = Set(ids)
        let expectedEpoch = epoch
        let id = UUID()
        decorationRefreshID = id
        do {
            let page = try await api.userDecorations(userIDs: Array(ids), token: token)
            guard isCurrent(expectedEpoch), decorationRefreshID == id, !Task.isCancelled else { return }
            var refreshed = publicDecorations
            if refreshed.count > 500 {
                refreshed = refreshed.filter { requested.contains($0.key) || $0.key == userID }
            }
            // Missing users may have been deleted or hidden by a block. Remove
            // their previous public appearance instead of retaining stale gear.
            for requestedID in requested where requestedID != userID {
                refreshed.removeValue(forKey: requestedID)
            }
            for user in page.users where requested.contains(user.userID) && user.userID != self.userID {
                refreshed[user.userID] = user.equipped
            }
            if let userID { refreshed[userID] = inventory.equipped }
            if publicDecorations != refreshed { publicDecorations = refreshed }
        } catch {
            if isCurrent(expectedEpoch), decorationRefreshID == id, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
    }

    func purchase(_ item: KikiDecorationItem, requestID: UUID) async throws {
        try await mutate(operation: { api, token in
            try await api.purchaseDecoration(decorationID: item.id, requestID: requestID, token: token)
        }, apply: { result in
            self.wallet = result.wallet
            self.applyInventory(result.inventory)
        })
        await refresh()
    }

    func equip(kind: KikiDecorationKind, decorationID: String?) async throws {
        try await mutate(operation: { api, token in
            try await api.equipDecoration(kind: kind, decorationID: decorationID, token: token)
        }, apply: { self.applyInventory($0) })
    }

    @discardableResult
    func send(roomID: String, gift: KikiGiftItem, quantity: Int,
              recipientIDs: [String], requestID: UUID,
              reportErrors: Bool = true,
              presentationGeneration: UInt64? = nil,
              beforeSend: @escaping @MainActor @Sendable () throws -> Void = {}) async throws -> KikiGiftSendResult {
        if let userID, recipientIDs.contains(userID) {
            throw KikiAPIError.server(422, "礼物只能赠送给其他成员，请重新选择收礼人。")
        }
        // A user may confirm the gift panel before the room driver's first
        // poll. Keep that confirmation visible without inventing a poll cursor.
        let expectedRoomGeneration = presentationGeneration ?? roomGeneration
        if isAvailable, self.roomID == nil, roomGeneration == expectedRoomGeneration { self.roomID = roomID }
        return try await mutate(reportErrors: reportErrors, operation: { api, token in
            // Other experience writes may precede this one. Authorize the
            // frozen intent only when it is actually about to reach the API.
            try await beforeSend()
            return try await api.sendGift(roomID: roomID, giftID: gift.id, quantity: quantity,
                                          recipientIDs: recipientIDs, requestID: requestID, token: token)
        }, apply: { result in
            // Drop this reservation before publishing the new inventory, even
            // if the queue worker has not resumed to remove its head yet.
            if self.completedGiftRequests.insert(requestID).inserted { self.completedGiftOrder.append(requestID) }
            if self.completedGiftOrder.count > 2_000 {
                self.completedGiftRequests.remove(self.completedGiftOrder.removeFirst())
            }
            self.wallet = result.wallet
            self.giftInventory = result.giftInventory
            if self.roomID == roomID, self.roomGeneration == expectedRoomGeneration {
                // A baseline poll can already include the accepted send while
                // its HTTP response is still in flight. That must not suppress
                // this device's confirmation; event IDs deduplicate later polls.
                self.appendEvents(result.events, roomID: roomID)
                self.onRoomGiftCommitted?(roomID)
            }
        })
    }

    func stopRoom() {
        if let roomID { sendQueues[roomID]?.cancelWaiting() }
        roomGeneration &+= 1
        pollTask?.cancel()
        pollTask = nil
        pollID = nil
        roomID = nil
        roomCursor = nil
        nextAllowedRoomPollAt = .distantPast
        roomPollFailureCount = 0
        hasPendingRoomInvalidation = false
        roomInvalidationRevision = 0
        events = []
        seenEventIDs = []
        seenEventOrder = []
    }

    func pollRoom(roomID: String, invalidated: Bool = false) async {
        guard !Task.isCancelled, let api, let token, isAvailable else { return }
        if self.roomID != roomID {
            stopRoom()
            self.roomID = roomID
        }
        if invalidated {
            roomInvalidationRevision &+= 1
            hasPendingRoomInvalidation = true
        }
        if let task = pollTask { await task.value; return }
        // Incoming hints are retained, but never shorten server Retry-After or
        // failure backoff. The room driver retries this pending read when due.
        guard now() >= nextAllowedRoomPollAt else { return }
        let expectedEpoch = epoch
        let generation = roomGeneration
        let id = UUID()
        pollID = id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.pollID == id { self.pollTask = nil; self.pollID = nil } }
            do {
                // Keep the original four-page budget even if invalidations
                // arrive during a GET. A trailing read uses the cursor committed
                // by the older response; it never establishes a new baseline.
                var pagesRemaining = 4
                repeat {
                    let readingRevision = self.roomInvalidationRevision
                    var hasMore = false
                    repeat {
                        try Task.checkCancellation()
                        let after = self.roomCursor
                        let page = try await api.giftEvents(roomID: roomID, after: after, token: token)
                        pagesRemaining -= 1
                        try Task.checkCancellation()
                        guard self.isCurrent(expectedEpoch), self.roomID == roomID,
                              self.roomGeneration == generation else { return }
                        guard page.cursor >= (after ?? 0), !page.hasMore || after == nil || page.cursor > after! else {
                            throw KikiAPIError.invalidResponse
                        }
                        self.roomCursor = page.cursor
                        // Initial history establishes only a live cursor.
                        if let after {
                            self.appendEvents(page.events.filter { $0.seq > after && $0.seq <= page.cursor }, roomID: roomID)
                            hasMore = page.hasMore
                        } else { hasMore = false }
                    } while hasMore && pagesRemaining > 0
                    self.roomPollFailureCount = 0
                    self.nextAllowedRoomPollAt = .distantPast
                    self.hasPendingRoomInvalidation = hasMore || self.roomInvalidationRevision != readingRevision
                    // A hint received after the preceding snapshot began needs
                    // one later GET. Joining the old pollTask alone is stale.
                } while self.hasPendingRoomInvalidation && pagesRemaining > 0
            } catch {
                if self.isCurrent(expectedEpoch), self.roomID == roomID,
                   self.roomGeneration == generation, !(error is CancellationError), !Task.isCancelled {
                    self.hasPendingRoomInvalidation = true
                    // An in-flight read can use a lease rotated in the meantime.
                    // Retry its replacement without declaring the account lost.
                    if (error as? KikiAPIError)?.isUnauthorized == true, token != self.token { return }
                    self.roomPollFailureCount += 1
                    let delay: TimeInterval
                    if case .rateLimited(let seconds, _) = error as? KikiAPIError { delay = Double(seconds) }
                    else { delay = min(30, pow(2, Double(min(self.roomPollFailureCount, 5)))) }
                    self.nextAllowedRoomPollAt = self.now().addingTimeInterval(delay)
                    if self.errorMessage != error.localizedDescription { self.errorMessage = error.localizedDescription }
                }
            }
        }
        pollTask = task
        await task.value
    }

    private func isCurrent(_ expectedEpoch: UInt64) -> Bool { epoch == expectedEpoch && isAvailable }

    private func applyInventory(_ inventory: KikiDecorationInventory) {
        if self.inventory != inventory { self.inventory = inventory }
        if let userID, publicDecorations[userID] != inventory.equipped { publicDecorations[userID] = inventory.equipped }
    }

    private func appendEvents(_ incoming: [KikiGiftEvent], roomID: String) {
        let fresh = incoming.filter { $0.roomID == roomID }.sorted { $0.seq < $1.seq }.filter {
            guard seenEventIDs.insert($0.id).inserted else { return false }
            seenEventOrder.append($0.id)
            return true
        }
        guard !fresh.isEmpty else { return }
        events = Array((events + fresh).sorted { $0.seq < $1.seq }.suffix(200))
        if seenEventOrder.count > 2_000 {
            let removed = seenEventOrder.prefix(seenEventOrder.count - 2_000)
            removed.forEach { seenEventIDs.remove($0) }
            seenEventOrder = Array(seenEventOrder.suffix(2_000))
        }
    }

    /// All writes share a queue, so a slower earlier response cannot overwrite
    /// the wallet or equipped state returned by a later write.
    @discardableResult
    private func mutate<Response: Sendable>(
        reportErrors: Bool = true,
        operation: @escaping @Sendable (KikiAPIClient, String) async throws -> Response,
        apply: @escaping @MainActor (Response) -> Void
    ) async throws -> Response {
        guard let api, isAvailable else { throw KikiAPIError.security("请先登录后使用体验钻石。") }
        let expectedEpoch = epoch
        let predecessor = mutationTail
        let task = Task { @MainActor in
            await predecessor?.value
            try Task.checkCancellation()
            guard self.isCurrent(expectedEpoch), let token = self.token else { throw CancellationError() }
            self.mutationRevision &+= 1
            self.activeMutations += 1
            defer {
                if self.isCurrent(expectedEpoch) {
                    self.activeMutations -= 1
                    self.mutationRevision &+= 1
                }
            }
            do {
                let response = try await operation(api, token)
                try Task.checkCancellation()
                guard self.isCurrent(expectedEpoch) else { throw CancellationError() }
                apply(response)
                self.errorMessage = nil
                return response
            } catch {
                if reportErrors, self.isCurrent(expectedEpoch), !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription
                }
                throw error
            }
        }
        mutationTail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

struct KikiGiftSendQuote: Equatable {
    let inventoryUsed: Int
    let diamondQuantity: Int
    let totalQuantity: Int
    let totalCost: Int
    let isAffordable: Bool
}

struct KikiGiftCombo: Equatable {
    let giftID: String
    let recipientIDs: [String]
    let count: Int
    let totalCost: Int
    let inventoryUsed: Int
    let lastConfirmedAt: Date
}

/// One tap is one immutable, server-confirmed request. The account store retains
/// this FIFO across sheet dismissals, so an uncertain result keeps its retry UUID.
@MainActor
final class KikiGiftSendQueue: ObservableObject {
    @Published private(set) var pendingCount = 0
    @Published private(set) var isSending = false
    @Published private(set) var isPaused = false
    @Published private(set) var isRetrying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastCombo: KikiGiftCombo?
    private struct Intent: Sendable {
        let id: UUID
        let gift: KikiGiftItem
        let recipientIDs: [String]
        let comboID: UUID
        // Local presentation scope is captured on the first attempt, then
        // retained with the immutable wire request across receipt recovery.
        var presentationGeneration: UInt64? = nil
    }
    private weak var gifts: KikiGiftStore?
    private let roomID: String
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var accountID: String?
    private var intents: [Intent] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var invalidated = false
    private var eligibleRecipientIDs: Set<String>?
    private var submittedIntentID: UUID?
    private var uncertainIntentID: UUID?
    private var automaticFailures = 0
    private var nextAllowedSendAt = Date.distantPast
    private var latestTap: (giftID: String, recipients: [String], at: Date, comboID: UUID)?
    private var confirmedComboID: UUID?
    init(gifts: KikiGiftStore, roomID: String,
         now: @escaping @MainActor () -> Date = { Date() },
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
         }) {
        self.gifts = gifts; self.roomID = roomID; self.accountID = gifts.userID
        self.now = now; self.sleep = sleep
    }

    func nextQuote(gift: KikiGiftItem, recipientIDs: [String]) -> KikiGiftSendQuote? {
        guard let gifts, !invalidated, gifts.isAvailable, let wallet = gifts.wallet,
              let senderID = gifts.userID, !recipientIDs.contains(senderID),
              !recipientIDs.isEmpty, recipientIDs.count <= 50,
              Set(recipientIDs).count == recipientIDs.count, gift.price >= 0,
              eligibleRecipientIDs.map({ Set(recipientIDs).isSubset(of: $0) }) ?? true else { return nil }
        var quantities = Dictionary(gifts.giftInventory.map { ($0.giftID, max(0, $0.quantity)) }, uniquingKeysWith: max)
        var available = wallet.balance
        for intent in intents where !gifts.didCompleteGift(intent.id) {
            let used = min(quantities[intent.gift.id] ?? 0, intent.recipientIDs.count)
            quantities[intent.gift.id, default: 0] -= used
            let cost = intent.gift.price.multipliedReportingOverflow(by: intent.recipientIDs.count - used)
            guard !cost.overflow else { return nil }
            available = max(-1, available - cost.partialValue)
        }
        let used = min(quantities[gift.id] ?? 0, recipientIDs.count)
        let paid = recipientIDs.count - used
        let cost = gift.price.multipliedReportingOverflow(by: paid)
        guard !cost.overflow else { return nil }
        return KikiGiftSendQuote(inventoryUsed: used, diamondQuantity: paid, totalQuantity: recipientIDs.count,
                                 totalCost: cost.partialValue, isAffordable: cost.partialValue <= available)
    }

    @discardableResult
    func enqueue(gift: KikiGiftItem, recipientIDs: [String]) -> Bool {
        guard !invalidated, !isPaused, pendingCount < 20, let gifts, gifts.isAvailable,
              let quote = nextQuote(gift: gift, recipientIDs: recipientIDs), quote.isAffordable else { return false }
        if let accountID { guard accountID == gifts.userID else { return false } }
        else { accountID = gifts.userID }
        let sortedRecipients = recipientIDs.sorted(), now = now()
        let continues = latestTap?.giftID == gift.id && latestTap?.recipients == sortedRecipients
            && now.timeIntervalSince(latestTap?.at ?? .distantPast) <= 4
        let comboID = continues ? latestTap!.comboID : UUID()
        latestTap = (gift.id, sortedRecipients, now, comboID)
        intents.append(Intent(id: UUID(), gift: gift, recipientIDs: sortedRecipients, comboID: comboID))
        pendingCount = intents.count
        errorMessage = nil
        start()
        return true
    }

    func retry() {
        guard isPaused, !intents.isEmpty, !invalidated else { return }
        isPaused = false; errorMessage = nil; automaticFailures = 0
        start()
    }

    /// Drop whole, immutable waiting taps when a selected member leaves a
    /// seat. A submitted/uncertain tap retains its UUID to resolve its receipt.
    @discardableResult
    func updateEligibleRecipients(_ recipientIDs: Set<String>) -> Int {
        eligibleRecipientIDs = recipientIDs
        let previousCount = intents.count
        intents.removeAll { intent in
            intent.id != submittedIntentID && intent.id != uncertainIntentID
                && !Set(intent.recipientIDs).isSubset(of: recipientIDs)
        }
        pendingCount = intents.count
        stopEmptyWorker()
        return previousCount - intents.count
    }

    func cancelWaiting() {
        intents.removeAll { $0.id != submittedIntentID && $0.id != uncertainIntentID }
        pendingCount = intents.count
        stopEmptyWorker()
    }

    func resetCombo() { lastCombo = nil; confirmedComboID = nil; latestTap = nil }

    fileprivate func invalidate() {
        generation += 1; invalidated = true
        worker?.cancel(); worker = nil
        intents = []; pendingCount = 0
        isSending = false; isPaused = false; isRetrying = false; errorMessage = nil; lastCombo = nil
        submittedIntentID = nil; uncertainIntentID = nil; automaticFailures = 0
        latestTap = nil; confirmedComboID = nil
    }

    private func stopEmptyWorker() {
        guard intents.isEmpty else { return }
        generation += 1
        worker?.cancel(); worker = nil
        isSending = false; isPaused = false; isRetrying = false
        automaticFailures = 0
    }

    private func start() {
        guard worker == nil, !intents.isEmpty, !isPaused, !invalidated else { return }
        let expectedGeneration = generation
        isSending = true
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            var refreshed = false
            defer {
                if self.generation == expectedGeneration {
                    self.worker = nil; self.isSending = false; self.isRetrying = false
                    if refreshed, let gifts = self.gifts { Task { await gifts.refresh() } }
                }
            }
            while !Task.isCancelled, self.generation == expectedGeneration, !self.isPaused,
                  let intent = self.intents.first {
                guard let gifts = self.gifts, gifts.isAvailable, gifts.userID == self.accountID else {
                    self.invalidate(); return
                }
                if self.uncertainIntentID != intent.id, let eligible = self.eligibleRecipientIDs,
                   !Set(intent.recipientIDs).isSubset(of: eligible) {
                    self.intents.removeFirst(); self.pendingCount = self.intents.count
                    continue
                }
                do {
                    let delay = self.nextAllowedSendAt.timeIntervalSince(self.now())
                    if delay > 0 { try await self.sleep(delay) }
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    guard self.intents.first?.id == intent.id else { continue }
                    let presentationGeneration = intent.presentationGeneration ?? gifts.roomPresentationGeneration
                    self.intents[0].presentationGeneration = presentationGeneration
                    let receipt = try await gifts.send(roomID: self.roomID, gift: intent.gift, quantity: 1,
                        recipientIDs: intent.recipientIDs, requestID: intent.id, reportErrors: false,
                        presentationGeneration: presentationGeneration, beforeSend: { [weak self] in
                            guard let self, self.generation == expectedGeneration, !self.invalidated,
                                  self.intents.first?.id == intent.id else { throw CancellationError() }
                            self.submittedIntentID = intent.id
                            // 100 taps/minute stays below the server's gift
                            // limits; a server cooldown can extend this delay.
                            self.nextAllowedSendAt = self.now().addingTimeInterval(0.6)
                        })
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    self.intents.removeFirst(); self.pendingCount = self.intents.count
                    self.submittedIntentID = nil; self.uncertainIntentID = nil
                    self.automaticFailures = 0; self.isRetrying = false
                    let now = self.now()
                    let previous = self.lastCombo
                    // A slow response must not split a burst whose taps were
                    // consecutive; only acknowledged taps increase its count.
                    let continues = previous != nil && self.confirmedComboID == intent.comboID
                    self.confirmedComboID = intent.comboID
                    self.lastCombo = KikiGiftCombo(giftID: intent.gift.id, recipientIDs: intent.recipientIDs,
                        count: continues ? (previous?.count ?? 0) + 1 : 1,
                        totalCost: (continues ? previous?.totalCost ?? 0 : 0) + receipt.totalCost,
                        inventoryUsed: (continues ? previous?.inventoryUsed ?? 0 : 0) + receipt.inventoryUsed,
                        lastConfirmedAt: now)
                    self.errorMessage = nil
                    refreshed = true
                } catch {
                    guard self.generation == expectedGeneration, !Task.isCancelled else { return }
                    guard self.intents.first?.id == intent.id else { continue }
                    self.submittedIntentID = nil
                    if let error = error as? KikiAPIError, case .rateLimited(let delay, _) = error {
                        self.nextAllowedSendAt = max(self.nextAllowedSendAt, self.now().addingTimeInterval(TimeInterval(delay)))
                        self.isRetrying = true; self.errorMessage = nil
                        continue
                    }
                    if let error = error as? KikiAPIError, case .server(let status, _) = error,
                       (400..<500).contains(status), status != 408, status != 429 {
                        if self.uncertainIntentID == intent.id {
                            self.intents = [intent]; self.pendingCount = 1; self.isPaused = true
                        } else {
                            self.intents = []; self.pendingCount = 0
                        }
                        self.errorMessage = error.localizedDescription
                    } else {
                        self.uncertainIntentID = intent.id
                        self.automaticFailures += 1
                        if Self.canAutomaticallyRetry(error), self.automaticFailures <= 3 {
                            let backoff = 0.6 * pow(2, Double(self.automaticFailures - 1))
                            self.nextAllowedSendAt = max(self.nextAllowedSendAt, self.now().addingTimeInterval(backoff))
                            self.isRetrying = true; self.errorMessage = nil
                            continue
                        }
                        self.isPaused = true
                        self.errorMessage = Self.canAutomaticallyRetry(error) ? "网络暂不可用，请重试。" : error.localizedDescription
                    }
                    return
                }
            }
        }
    }

    private static func canAutomaticallyRetry(_ error: Error) -> Bool {
        if let failure = error as? KikiTransportFailure { return failure.code != .networkTLSFailed }
        if let error = error as? KikiAPIError {
            switch error {
            case .server(let status, _): return status == 408 || (500..<600).contains(status)
            case .invalidResponse: return true
            default: return false
            }
        }
        return false
    }
}

/// A bounded, value-only projection of confirmed room events. Keeping it apart
/// from SwiftUI makes batch deduplication and combo timing deterministic.
struct KikiGiftPresentationState: Equatable {
    struct Presentation: Equatable, Identifiable {
        /// The first batch owns the animation identity throughout a combo.
        let id: String
        let event: KikiGiftEvent
        fileprivate(set) var quantity: Int
        fileprivate(set) var batchCount: Int
        let recipientIDs: [String]
        fileprivate(set) var revision: Int
        fileprivate(set) var expiresAt: Date
        fileprivate let hasCompleteRecipients: Bool
        fileprivate var lastServerTime: Int
        fileprivate var lastSequence: Int
        fileprivate var lastReceivedAt: Date
        fileprivate var startedAt: Date?

        fileprivate mutating func merge(_ batch: Batch, at now: Date) {
            let total = quantity.addingReportingOverflow(batch.event.quantity)
            quantity = total.overflow ? Int.max : total.partialValue
            batchCount += 1
            lastServerTime = batch.event.createdAt
            lastSequence = batch.lastSequence
            lastReceivedAt = now
            revision += 1
        }
    }

    fileprivate struct Batch {
        let key: String
        let event: KikiGiftEvent
        let recipientIDs: [String]
        let complete: Bool
        let firstSequence: Int
        let lastSequence: Int
    }

    private(set) var active: Presentation?
    private(set) var queue: [Presentation] = []
    var seenBatchCount: Int { seen.count }
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var highestSequence = 0
    private let displayDuration: TimeInterval
    private let maximumDisplayDuration: TimeInterval
    private let comboInterval: TimeInterval = 4

    init(displayDuration: TimeInterval = 4, maximumDisplayDuration: TimeInterval = 12) {
        self.displayDuration = min(12, max(0.1, displayDuration))
        self.maximumDisplayDuration = min(12, max(self.displayDuration, maximumDisplayDuration))
    }

    /// A room mount/resume establishes a baseline, never a history replay.
    mutating func reset(baseline: [KikiGiftEvent] = []) {
        active = nil
        queue = []
        seen = []
        seenOrder = []
        highestSequence = max(0, baseline.map(\.seq).max() ?? 0)
        for batch in batches(from: baseline) { remember(batch.key) }
    }

    /// Accept the store's entire bounded event window, including repeated HTTP
    /// receipts, poll pages and incomplete recipient batches.
    mutating func ingest(_ events: [KikiGiftEvent], at now: Date = Date()) {
        if let active, now > active.expiresAt { advance(at: now) }
        let previousSequence = highestSequence
        let incoming = batches(from: events)
        highestSequence = max(highestSequence, events.map(\.seq).max() ?? 0)
        for batch in incoming {
            guard !seen.contains(batch.key) else { continue }
            remember(batch.key)
            // Older batches can arrive after a send receipt has moved ahead of
            // polling. They remain in chat, but must not grow a newer combo.
            guard batch.lastSequence > previousSequence else { continue }
            if var current = active, canMerge(current, with: batch, at: now) {
                current.merge(batch, at: now)
                let limit = (current.startedAt ?? now).addingTimeInterval(maximumDisplayDuration)
                current.expiresAt = min(limit, max(current.expiresAt, now.addingTimeInterval(displayDuration)))
                active = current
            } else if let index = queue.indices.last, canMerge(queue[index], with: batch, at: now) {
                queue[index].merge(batch, at: now)
            } else {
                let presentation = Presentation(id: batch.key, event: batch.event, quantity: batch.event.quantity,
                    batchCount: 1, recipientIDs: batch.recipientIDs, revision: 0, expiresAt: now,
                    hasCompleteRecipients: batch.complete, lastServerTime: batch.event.createdAt,
                    lastSequence: batch.lastSequence, lastReceivedAt: now, startedAt: nil)
                if active == nil {
                    activate(presentation, at: now)
                } else {
                    if queue.count == 8 { queue.removeFirst() }
                    queue.append(presentation)
                }
            }
        }
    }

    /// Timer callers pass their captured deadline if the wall clock moved back.
    mutating func advance(at now: Date = Date()) {
        guard let current = active, now >= current.expiresAt else { return }
        active = nil
        if !queue.isEmpty {
            let next = queue.removeFirst()
            activate(next, at: now)
        }
    }

    private mutating func activate(_ presentation: Presentation, at now: Date) {
        var value = presentation
        value.startedAt = now
        value.expiresAt = now.addingTimeInterval(displayDuration)
        value.revision += 1
        active = value
    }

    private func canMerge(_ current: Presentation, with batch: Batch, at now: Date) -> Bool {
        let localGap = now.timeIntervalSince(current.lastReceivedAt)
        let serverGap = TimeInterval(batch.event.createdAt) - TimeInterval(current.lastServerTime)
        return current.hasCompleteRecipients && batch.complete
            && current.event.roomID == batch.event.roomID
            && current.event.senderUserID == batch.event.senderUserID
            && current.event.giftID == batch.event.giftID
            && current.recipientIDs == batch.recipientIDs
            && batch.firstSequence > current.lastSequence
            && localGap >= 0 && localGap <= comboInterval
            && serverGap >= 0 && serverGap <= comboInterval
    }

    private mutating func remember(_ key: String) {
        guard seen.insert(key).inserted else { return }
        seenOrder.append(key)
        if seenOrder.count > 256 { seen.remove(seenOrder.removeFirst()) }
    }

    private func batches(from events: [KikiGiftEvent]) -> [Batch] {
        let grouped = Dictionary(grouping: events) { event in
            event.roomID + ":" + (event.batchID.isEmpty ? event.id : event.batchID)
        }
        return grouped.compactMap { key, rows in
            let unique = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
                .sorted { $0.seq < $1.seq }
            guard let first = unique.first, first.quantity > 0 else { return nil }
            let recipients = Set(unique.map(\.recipientUserID))
            let complete = first.batchRecipientCount > 0 && !recipients.contains("")
                && recipients.count == first.batchRecipientCount && unique.count == recipients.count
                && unique.allSatisfy {
                    $0.roomID == first.roomID && $0.senderUserID == first.senderUserID
                        && $0.giftID == first.giftID && $0.quantity == first.quantity
                        && $0.batchRecipientCount == first.batchRecipientCount && $0.createdAt == first.createdAt
                }
            // A partially visible/page-split batch still plays once. Without a
            // complete target set it stays separate, including after later pages.
            return Batch(key: key, event: first, recipientIDs: complete ? recipients.sorted() : [], complete: complete,
                         firstSequence: first.seq, lastSequence: unique.last?.seq ?? first.seq)
        }.sorted { left, right in
            left.firstSequence == right.firstSequence ? left.key < right.key : left.firstSequence < right.firstSequence
        }
    }
}
