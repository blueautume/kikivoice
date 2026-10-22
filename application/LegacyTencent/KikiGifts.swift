import Combine
import Foundation
import SDWebImage
import SwiftUI
import UIKit

struct KikiGift: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let price: Int
    let animationAsset: String
    let effectTier: Int
    let durationMilliseconds: Int

    var assetURL: URL? {
        // Catalog entries select packaged assets, never arbitrary remote content.
        guard Self.knownIDs.contains(id), animationAsset == "\(id).gif" else { return nil }
        return Bundle.main.url(forResource: id, withExtension: "gif", subdirectory: "Gifts")
    }
    var poster: UIImage? {
        Self.poster(for: id)
    }
    static func poster(for id: String) -> UIImage? {
        guard knownIDs.contains(id),
              let url = Bundle.main.url(forResource: id, withExtension: "png", subdirectory: "Gifts") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    static let knownIDs: Set<String> = ["heart", "flower_rain", "aurora_car", "galaxy_rocket", "cosmic_heart"]
}

struct KikiGiftNotice: Decodable, Equatable {
    let version: String
    let title: String
    let text: String
    let url: String
}

struct KikiGiftCatalog: Decodable {
    let gifts: [KikiGift]
    let currency: String
    let initialBalance: Int
    let notice: KikiGiftNotice
}

struct KikiGiftWallet: Decodable, Equatable {
    let balance: Int
    let currency: String
    let initialGrant: Int
}

struct KikiGiftEvent: Decodable, Equatable, Identifiable {
    let sequence: Int64
    let id: String
    let giftID: String
    let giftName: String
    let unitPrice: Int
    let quantity: Int
    let totalCost: Int
    let senderID: String
    let senderName: String
    let senderAvatarIndex: Int
    let senderAvatarURL: String?
    let recipientID: String
    let recipientName: String
    let createdAt: Int
    let batchID: String?
    let batchRecipientCount: Int?
}

struct KikiGiftSendResponse: Decodable { let event: KikiGiftEvent; let wallet: KikiGiftWallet }
struct KikiGiftBatchSendResponse: Decodable {
    let events: [KikiGiftEvent]
    let wallet: KikiGiftWallet
    let totalCost: Int
    let recipientCount: Int
    let quantityPerRecipient: Int
}
struct KikiGiftEventPage: Decodable { let events: [KikiGiftEvent]; let nextCursor: Int64; let hasMore: Bool }

struct KikiGiftRecipient: Identifiable, Equatable {
    let id: String
    let name: String
    let avatarURL: String?
    let isHost: Bool
    let isOnSeat: Bool
}

@MainActor
final class KikiGiftRecipientSource: ObservableObject {
    @Published var members: [KikiGiftRecipient] = []
    @Published var isLoading = false
    var refresh: (() -> Void)?
}

/// Selection is a snapshot, including when "all" was tapped. Later arrivals
/// must never silently increase the number of recipients or the total cost.
struct KikiGiftRecipientSelection {
    private(set) var selectedIDs: Set<String> = []
    private var initialized = false
    mutating func reconcile(_ members: [KikiGiftRecipient]) {
        selectedIDs.formIntersection(Set(members.map(\.id)))
        if !initialized, let host = members.first(where: \.isHost) {
            selectedIDs = [host.id]; initialized = true
        }
    }
    @discardableResult
    mutating func toggle(_ id: String) -> Bool {
        initialized = true
        if selectedIDs.contains(id) { selectedIDs.remove(id); return true }
        guard selectedIDs.count < 50 else { return false }
        selectedIDs.insert(id); return true
    }
    mutating func selectAll(_ members: [KikiGiftRecipient]) {
        initialized = true
        var ids: [String] = []; var seen: Set<String> = []
        for member in members where seen.insert(member.id).inserted {
            ids.append(member.id)
            if ids.count == 50 { break }
        }
        selectedIDs = Set(ids)
    }
    mutating func clear() { initialized = true; selectedIDs.removeAll() }
    var recipientIDs: [String] { selectedIDs.sorted() }
    func totalCost(price: Int, quantity: Int) -> Int? {
        guard price >= 0, quantity > 0 else { return nil }
        let perPerson = price.multipliedReportingOverflow(by: quantity)
        let total = perPerson.partialValue.multipliedReportingOverflow(by: selectedIDs.count)
        return perPerson.overflow || total.overflow ? nil : total.partialValue
    }
}

/// A bounded queue prevents a busy room from retaining unlimited animations or
/// replaying a sender's locally acknowledged event on the next poll.
struct KikiGiftEventQueue {
    private(set) var pending: [KikiGiftEvent] = []
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var seenBatches: Set<String> = []
    private var batchOrder: [String] = []
    let capacity: Int
    init(capacity: Int = 12) { self.capacity = max(1, capacity) }
    @discardableResult
    mutating func append(_ event: KikiGiftEvent) -> Bool {
        guard seen.insert(event.id).inserted else { return false }
        seenOrder.append(event.id)
        if seenOrder.count > 256 { seen.remove(seenOrder.removeFirst()) }
        // Every child event still acknowledges its recipient in chat. Only the
        // first child schedules a shared animation, including across poll pages.
        if let batchID = event.batchID, !batchID.isEmpty {
            guard seenBatches.insert(batchID).inserted else { return true }
            batchOrder.append(batchID)
            if batchOrder.count > 256 { seenBatches.remove(batchOrder.removeFirst()) }
        }
        if pending.count == capacity { pending.removeFirst() }
        pending.append(event)
        return true
    }
    mutating func next() -> KikiGiftEvent? { pending.isEmpty ? nil : pending.removeFirst() }
    mutating func clear() {
        pending.removeAll(); seen.removeAll(); seenOrder.removeAll()
        seenBatches.removeAll(); batchOrder.removeAll()
    }
}

@MainActor
final class KikiGiftStore: ObservableObject {
    struct PendingSend: Equatable {
        let roomID: String; let giftID: String; let quantity: Int; let requestID: String; let noticeVersion: String
        var recipientIDs: [String]? = nil
    }
    @Published private(set) var catalog: KikiGiftCatalog?
    @Published private(set) var wallet: KikiGiftWallet?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingSend: PendingSend?
    @Published private(set) var lastSent: KikiGiftEvent?
    var onConfirmedGift: ((String, KikiGiftEvent) -> Void)?
    private var api: KikiAPIClient?
    private var token: String?
    private var generation = 0
    private var walletRevision = 0
    private var loadTask: Task<Void, Never>?

    func configure(api: KikiAPIClient, token: String) {
        guard self.token != token else { return }
        reset()
        self.api = api; self.token = token
    }
    func reset() {
        loadTask?.cancel(); loadTask = nil
        generation += 1; walletRevision = 0; api = nil; token = nil; catalog = nil; wallet = nil
        isLoading = false; isSending = false; pendingSend = nil; errorMessage = nil; lastSent = nil
        onConfirmedGift = nil
    }
    func load() async {
        if let loadTask { await loadTask.value; return }
        let expected = generation
        let task = Task { @MainActor [weak self] in
            guard let self, self.generation == expected else { return }
            await self.fetchCatalogAndWallet()
        }
        loadTask = task
        await task.value
        if generation == expected { loadTask = nil }
    }
    private func fetchCatalogAndWallet() async {
        guard !isLoading, let api, let token else { return }
        let expected = generation
        let expectedWalletRevision = walletRevision
        isLoading = true; errorMessage = nil
        defer { if generation == expected { isLoading = false } }
        do {
            async let nextCatalog = api.giftCatalog(token: token)
            async let nextWallet = api.giftWallet(token: token)
            let result = try await (nextCatalog, nextWallet)
            try Task.checkCancellation()
            guard generation == expected else { return }
            catalog = result.0
            if walletRevision == expectedWalletRevision { wallet = result.1 }
        } catch {
            guard generation == expected, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }
    func events(roomID: String, after cursor: Int64?) async throws -> KikiGiftEventPage {
        guard let api, let token else { throw CancellationError() }
        let expected = generation
        let result = try await api.giftEvents(roomID: roomID, after: cursor, token: token)
        guard generation == expected else { throw CancellationError() }
        return result
    }
    /// An ambiguous network failure retains the entire request, including its
    /// recipients. Changing room or selection cannot accidentally charge again.
    func send(roomID: String, giftID: String, quantity: Int) async {
        guard !isSending, api != nil, token != nil, let catalog,
              catalog.gifts.contains(where: { $0.id == giftID }), [1, 10, 99].contains(quantity) else { return }
        if let pendingSend, pendingSend.roomID != roomID || pendingSend.giftID != giftID || pendingSend.quantity != quantity || pendingSend.recipientIDs != nil {
            errorMessage = "上一笔赠送结果尚待确认，请先确认上一笔赠送。"; return
        }
        let pending = pendingSend ?? PendingSend(roomID: roomID, giftID: giftID, quantity: quantity,
                                                 requestID: UUID().uuidString, noticeVersion: catalog.notice.version)
        await perform(pending)
    }
    func sendBatch(roomID: String, giftID: String, quantity: Int, recipientIDs: [String]) async {
        guard !isSending, api != nil, token != nil, let catalog,
              catalog.gifts.contains(where: { $0.id == giftID }), [1, 10, 99].contains(quantity) else { return }
        let recipients = Set(recipientIDs).sorted()
        guard !recipients.isEmpty else { errorMessage = "请至少选择一位收礼人。"; return }
        guard recipients.count <= 50, recipients.allSatisfy({ !$0.isEmpty }) else {
            errorMessage = "每次最多选择50位收礼人，请检查选择。"; return
        }
        if let pendingSend, pendingSend.roomID != roomID || pendingSend.giftID != giftID || pendingSend.quantity != quantity || pendingSend.recipientIDs != recipients {
            errorMessage = "上一笔赠送结果尚待确认，请先确认上一笔赠送。"; return
        }
        let pending = pendingSend ?? PendingSend(roomID: roomID, giftID: giftID, quantity: quantity,
                                                 requestID: UUID().uuidString, noticeVersion: catalog.notice.version,
                                                 recipientIDs: recipients)
        await perform(pending)
    }
    func retryPending() async {
        guard !isSending, let pendingSend else { return }
        await perform(pendingSend)
    }
    private func perform(_ pending: PendingSend) async {
        guard !isSending, let api, let token else { return }
        pendingSend = pending; isSending = true; errorMessage = nil
        let expected = generation
        defer { if generation == expected { isSending = false } }
        do {
            let events: [KikiGiftEvent]
            let confirmedWallet: KikiGiftWallet
            if let recipients = pending.recipientIDs {
                let response = try await api.sendGiftBatch(roomID: pending.roomID, giftID: pending.giftID, quantity: pending.quantity,
                                                          recipientIDs: recipients, requestID: pending.requestID,
                                                          noticeVersion: pending.noticeVersion, token: token)
                events = response.events; confirmedWallet = response.wallet
            } else {
                let response = try await api.sendGift(roomID: pending.roomID, giftID: pending.giftID, quantity: pending.quantity,
                                                     requestID: pending.requestID, noticeVersion: pending.noticeVersion, token: token)
                events = [response.event]; confirmedWallet = response.wallet
            }
            guard generation == expected else { return }
            walletRevision += 1
            wallet = confirmedWallet; pendingSend = nil; lastSent = events.last
            for event in events { onConfirmedGift?(pending.roomID, event) }
        } catch {
            guard generation == expected else { return }
            if let apiError = error as? KikiAPIError, case .server(let status, _) = apiError,
               [400, 402, 404, 409, 412, 422].contains(status) {
                pendingSend = nil
                if status == 412 { self.catalog = nil }
            }
            if !(error is CancellationError) { errorMessage = error.localizedDescription }
        }
    }

}

@MainActor
@available(iOS 16.0, *)
struct KikiGiftPanel: View {
    @ObservedObject var gifts: KikiGiftStore
    let roomID: String
    let hostName: String
    @ObservedObject var recipientSource: KikiGiftRecipientSource
    @State private var selectedID = "heart"
    @State private var quantity = 1
    @State private var recipients = KikiGiftRecipientSelection()
    @State private var successMessage: String?
    @State private var selectionMessage: String?
    @Environment(\.dismiss) private var dismiss

    private var selection: KikiGift? { gifts.catalog?.gifts.first { $0.id == (unresolved?.giftID ?? selectedID) } }
    private var unresolved: KikiGiftStore.PendingSend? { gifts.pendingSend }
    private var members: [KikiGiftRecipient] {
        var seen: Set<String> = []
        return recipientSource.members.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }
    private var recipientCount: Int { unresolved.map { $0.recipientIDs?.count ?? 1 } ?? recipients.selectedIDs.count }
    private var selectedQuantity: Int { unresolved?.quantity ?? quantity }
    private var totalCost: Int? {
        guard let selection else { return nil }
        if unresolved != nil { return selection.price * selectedQuantity * recipientCount }
        return recipients.totalCost(price: selection.price, quantity: quantity)
    }
    private var insufficientBalance: Bool {
        guard let totalCost, let wallet = gifts.wallet else { return false }
        return wallet.balance < totalCost
    }
    private var locked: Bool { gifts.isSending || unresolved != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("心意礼物").font(.system(size: 21, weight: .bold))
                    HStack(spacing: 5) {
                        Image(systemName: "diamond.fill").foregroundStyle(.cyan)
                        Text(gifts.wallet.map { $0.balance.formatted() } ?? "读取余额…")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                        Text("免费钻石").font(.system(size: 10)).foregroundStyle(KikiPalette.secondary)
                    }.accessibilityIdentifier("gift.wallet")
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 25)).foregroundStyle(KikiPalette.secondary)
                }.accessibilityLabel("关闭礼物面板")
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    recipientPicker
                    if let catalog = gifts.catalog {
                        HStack {
                            Text("礼物").font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text("5款心意 · 不支持充值").font(.system(size: 11)).foregroundStyle(KikiPalette.muted)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(catalog.gifts) { gift in
                                Button { selectedID = gift.id; successMessage = nil } label: {
                                    VStack(spacing: 6) {
                                        Group {
                                            if let image = gift.poster { Image(uiImage: image).resizable().scaledToFit() }
                                            else { Image(systemName: "gift.fill").resizable().scaledToFit().padding(18) }
                                        }.frame(height: 78)
                                        Text(gift.name).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                                        Text("♦ \(gift.price.formatted())").font(.system(size: 11, weight: .semibold)).foregroundStyle(.cyan)
                                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                                        .background(selectedID == gift.id ? KikiPalette.purple.opacity(0.23) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(selectedID == gift.id ? KikiPalette.purple : .clear, lineWidth: 2))
                                }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier("gift.select.\(gift.id)")
                            }
                        }
                        HStack(spacing: 0) {
                            Text("赠送即同意 ")
                            Link("《礼物体验说明》", destination: URL(string: "https://kiki.group/gifts/notice/")!)
                        }.font(.system(size: 11)).foregroundStyle(KikiPalette.secondary)
                        Text(catalog.notice.text).font(.system(size: 11)).foregroundStyle(KikiPalette.muted).fixedSize(horizontal: false, vertical: true)
                    } else if gifts.isLoading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                    } else {
                        Button("重新加载礼物") { Task { await gifts.load() } }.frame(maxWidth: .infinity, minHeight: 150)
                    }
                    if let error = gifts.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(.orange).accessibilityIdentifier("gift.error")
                    } else if let successMessage {
                        Text(successMessage).font(.system(size: 12)).foregroundStyle(KikiPalette.mint).accessibilityIdentifier("gift.success")
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }
            sendControls
        }
        .background(KikiPalette.surface.ignoresSafeArea()).foregroundStyle(KikiPalette.text)
        .preferredColorScheme(.dark).tint(KikiPalette.lavender)
        .task {
            if let pending = gifts.pendingSend { selectedID = pending.giftID; quantity = pending.quantity }
            recipients.reconcile(members)
            recipientSource.refresh?()
            await gifts.load()
        }
        .onChange(of: recipientSource.members) { _ in
            let previous = recipients.selectedIDs
            recipients.reconcile(members)
            if previous.subtracting(recipients.selectedIDs).isEmpty == false, unresolved == nil {
                selectionMessage = "已移除离开房间的收礼人，请确认选择。"
            }
        }
    }

    private var recipientPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("送给").font(.system(size: 14, weight: .semibold))
                Text("已选\(recipientCount)人").font(.system(size: 12)).foregroundStyle(KikiPalette.lavender)
                Spacer(minLength: 0)
                if recipientSource.isLoading { ProgressView().scaleEffect(0.7).frame(width: 16, height: 16) }
                else {
                    Button { recipientSource.refresh?() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 12)) }
                        .accessibilityLabel("刷新房间成员")
                }
                Button(members.count > 50 ? "全选前50人" : "全选") {
                    recipients.selectAll(members); selectionMessage = members.count > 50 ? "已选当前列表前50人，每次最多赠送50人。" : nil
                    successMessage = nil
                }.disabled(locked || members.isEmpty).accessibilityIdentifier("gift.recipients.all")
                Button("清空") { recipients.clear(); selectionMessage = nil; successMessage = nil }
                    .disabled(locked || recipients.selectedIDs.isEmpty).accessibilityIdentifier("gift.recipients.clear")
            }.font(.system(size: 12)).buttonStyle(.plain)
            if members.isEmpty {
                Text(recipientSource.isLoading ? "正在获取房间成员…" : "暂无可选成员，请刷新后再试。")
                    .font(.system(size: 12)).foregroundStyle(KikiPalette.secondary).frame(maxWidth: .infinity, minHeight: 90)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(members) { member in
                            let isSelected = unresolved?.recipientIDs?.contains(member.id) ?? recipients.selectedIDs.contains(member.id)
                            Button {
                                selectionMessage = recipients.toggle(member.id) ? nil : "每次最多选择50位收礼人。"
                                successMessage = nil
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack(alignment: .bottomTrailing) {
                                        AsyncImage(url: member.avatarURL.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() } placeholder: {
                                            ZStack {
                                                Circle().fill(KikiPalette.purple.opacity(0.25))
                                                Text(String(member.name.prefix(1))).font(.system(size: 22, weight: .semibold))
                                            }
                                        }.frame(width: 51, height: 51).clipShape(Circle()).padding(3)
                                            .overlay(Circle().stroke(isSelected ? KikiPalette.purple : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1))
                                        if isSelected {
                                            Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white, KikiPalette.purple)
                                                .background(Circle().fill(KikiPalette.purple))
                                        }
                                    }
                                    Text(member.name.isEmpty ? "房间用户" : member.name).font(.system(size: 11)).lineLimit(1).frame(width: 62)
                                    Text(member.isHost ? "房主" : (member.isOnSeat ? "麦上" : "在听"))
                                        .font(.system(size: 9, weight: .medium)).foregroundStyle(member.isHost ? KikiPalette.lavender : KikiPalette.muted)
                                }.frame(width: 62)
                            }.buttonStyle(.plain).disabled(locked)
                                .accessibilityLabel("\(member.name)，\(member.isHost ? "房主" : (member.isOnSeat ? "麦上" : "在听"))，\(isSelected ? "已选择" : "未选择")")
                                .accessibilityIdentifier("gift.recipient.\(member.id)")
                        }
                    }.padding(.vertical, 2)
                }
            }
            if let selectionMessage {
                Text(selectionMessage).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }.padding(13).background(KikiPalette.purple.opacity(0.075), in: RoundedRectangle(cornerRadius: 18))
    }

    private var sendControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("每人").font(.system(size: 12)).foregroundStyle(KikiPalette.secondary)
                ForEach([1, 10, 99], id: \.self) { count in
                    Button { quantity = count; successMessage = nil } label: {
                        Text("×\(count)").font(.system(size: 13, weight: .semibold)).frame(width: 45, height: 32)
                            .background(selectedQuantity == count ? KikiPalette.purple.opacity(0.4) : .white.opacity(0.06), in: Capsule())
                    }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier("gift.quantity.\(count)")
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("合计 \(totalCost?.formatted() ?? "—") 钻").font(.system(size: 12, weight: .semibold)).foregroundStyle(insufficientBalance ? .orange : KikiPalette.text)
                    Text("每人\(selectedQuantity)个 × \(recipientCount)人").font(.system(size: 10)).foregroundStyle(KikiPalette.secondary)
                }.accessibilityIdentifier("gift.total")
            }
            Button {
                let targetIDs = recipients.recipientIDs
                let giftID = selectedID
                let count = quantity
                Task {
                    if gifts.pendingSend != nil { await gifts.retryPending() }
                    else { await gifts.sendBatch(roomID: roomID, giftID: giftID, quantity: count, recipientIDs: targetIDs) }
                    if gifts.errorMessage == nil, gifts.pendingSend == nil { successMessage = "已送出，心意已送达" }
                }
            } label: {
                HStack {
                    if gifts.isSending { ProgressView().tint(.white) }
                    Text(gifts.isSending ? "正在确认赠送…" : (unresolved != nil ? "重试并确认上一笔赠送" : (recipientCount == 0 ? "请选择收礼人" : (insufficientBalance ? "钻石余额不足" : "赠送给已选\(recipientCount)人"))))
                }.font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 45)
                    .background(KikiPalette.purple, in: Capsule())
            }.buttonStyle(.plain)
                .disabled(gifts.isSending || (unresolved == nil && (recipientCount == 0 || selection == nil || gifts.wallet == nil || totalCost == nil || insufficientBalance)))
                .accessibilityIdentifier("gift.send")
            if let unresolved {
                Text(unresolved.roomID == roomID ? "待确认赠送已锁定原收礼人和数量，重试不会重复扣款。" : "点击重试将确认上一房间的赠送，保留原收礼人和数量。")
                    .font(.system(size: 10)).foregroundStyle(KikiPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
            .background(KikiPalette.surface.shadow(color: .black.opacity(0.15), radius: 8, y: -4))
    }
}

@MainActor
@available(iOS 16.0, *)
struct KikiGiftWalletCard: View {
    @ObservedObject var gifts: KikiGiftStore
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "diamond.fill").font(.system(size: 25)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 5) {
                Text("我的钻石").font(.system(size: 12)).foregroundStyle(KikiPalette.secondary)
                Text(gifts.wallet.map { $0.balance.formatted() } ?? "—").font(.system(size: 23, weight: .semibold, design: .rounded))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text("免费体验礼物").font(.system(size: 12)).foregroundStyle(KikiPalette.lavender)
                Text("不支持充值或提现").font(.system(size: 10)).foregroundStyle(KikiPalette.muted)
            }
        }.padding(18).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .accessibilityIdentifier("profile.giftWallet").task { await gifts.load() }
    }
}

/// A short receipt stays at the safe-area top, independently of long GIF loops.
@MainActor
final class KikiGiftTopBanner: UIView {
    let thumbnailView = UIImageView()
    let senderLabel = UILabel()
    let recipientLabel = UILabel()
    let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "room.gift.receipt"
        isUserInteractionEnabled = false
        backgroundColor = UIColor(red: 0.19, green: 0.10, blue: 0.35, alpha: 0.96)
        layer.cornerRadius = 16
        layer.borderWidth = 1
        layer.borderColor = UIColor(red: 0.65, green: 0.47, blue: 1, alpha: 0.45).cgColor
        thumbnailView.contentMode = .scaleAspectFit
        thumbnailView.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        thumbnailView.layer.cornerRadius = 10; thumbnailView.clipsToBounds = true
        thumbnailView.accessibilityIdentifier = "room.gift.receipt.thumbnail"
        for label in [senderLabel, recipientLabel] {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white; label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let destination = UILabel()
        destination.text = "送给"; destination.font = .systemFont(ofSize: 12)
        destination.textColor = UIColor.white.withAlphaComponent(0.7)
        destination.setContentHuggingPriority(.required, for: .horizontal)
        destination.setContentCompressionResistancePriority(.required, for: .horizontal)
        let participants = UIStackView(arrangedSubviews: [senderLabel, destination, recipientLabel])
        participants.spacing = 6
        senderLabel.widthAnchor.constraint(equalTo: recipientLabel.widthAnchor).isActive = true
        detailLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        detailLabel.textColor = UIColor(red: 0.69, green: 0.84, blue: 1, alpha: 1)
        detailLabel.adjustsFontSizeToFitWidth = true; detailLabel.minimumScaleFactor = 0.8
        let text = UIStackView(arrangedSubviews: [participants, detailLabel])
        text.axis = .vertical; text.spacing = 4
        for view in [thumbnailView, text] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            thumbnailView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailView.widthAnchor.constraint(equalToConstant: 44), thumbnailView.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(event: KikiGiftEvent) {
        senderLabel.text = event.senderName
        recipientLabel.text = event.recipientName
        let perPerson = event.batchRecipientCount.flatMap { $0 > 1 ? "\($0)人 · 每人 " : nil } ?? ""
        detailLabel.text = "\(perPerson)\(event.giftName) ×\(event.quantity)"
        thumbnailView.image = KikiGift.poster(for: event.giftID) ?? UIImage(systemName: "gift.fill")
    }
}

/// This overlay never receives touches: seats, chat and room controls remain
/// available even when a large gift is being displayed.
@MainActor
final class KikiRoomGiftPresenter {
    private weak var controller: UIViewController?
    private let gifts: KikiGiftStore
    private let roomID: String
    private let hostName: () -> String
    private let recipientSource: KikiGiftRecipientSource
    private let overlay = UIView()
    private let imageView = SDAnimatedImageView()
    private let banner = KikiGiftTopBanner()
    private var bannerDismissal: Task<Void, Never>?
    private var bannerGeneration = 0
    private var announcedBatches = Set<String>()
    private var announcedBatchOrder: [String] = []
    private var polling: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var cursor: Int64?
    private var queue = KikiGiftEventQueue()
    private var visible = false
    private var activityGeneration = 0
    private var foreground = UIApplication.shared.applicationState == .active
    private var observers: [NSObjectProtocol] = []
    private weak var panel: UIViewController?

    init(controller: UIViewController, roomID: String, gifts: KikiGiftStore, hostName: @escaping () -> String, recipientSource: KikiGiftRecipientSource? = nil) {
        self.controller = controller; self.roomID = roomID; self.gifts = gifts; self.hostName = hostName
        self.recipientSource = recipientSource ?? KikiGiftRecipientSource()
        overlay.isUserInteractionEnabled = false; overlay.accessibilityElementsHidden = true
        overlay.backgroundColor = .clear
        imageView.contentMode = .scaleAspectFit; imageView.maxBufferSize = 8 * 1024 * 1024
        imageView.clearBufferWhenStopped = true; imageView.shouldCustomLoopCount = true; imageView.animationRepeatCount = 1
        banner.isHidden = true
        overlay.addSubview(imageView); overlay.addSubview(banner); overlay.isHidden = true
        overlay.frame = controller.view.bounds; overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(overlay)
        banner.translatesAutoresizingMaskIntoConstraints = false
        let preferredWidth = banner.widthAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            banner.widthAnchor.constraint(lessThanOrEqualToConstant: 480), preferredWidth,
            banner.heightAnchor.constraint(equalToConstant: 64)
        ])
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foreground = false; self?.updateActivity() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.foreground = true; self?.updateActivity() }
        })
        observers.append(center.addObserver(forName: Notification.Name("KikiGiftPanelRequested"), object: nil, queue: .main) { [weak self] notification in
            let id = notification.userInfo?["roomID"] as? String
            Task { @MainActor in if id == self?.roomID { self?.showPanel() } }
        })
        gifts.onConfirmedGift = { [weak self] id, event in
            guard let self, id == self.roomID, self.visible, self.foreground else { return }
            self.enqueue(event)
        }
    }

    deinit {
        polling?.cancel(); playback?.cancel(); bannerDismissal?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    func setVisible(_ visible: Bool) { self.visible = visible; updateActivity() }
    func stop() {
        visible = false; updateActivity(); overlay.removeFromSuperview()
        panel?.dismiss(animated: false)
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
    }
    private func updateActivity() {
        guard visible && foreground else {
            activityGeneration += 1
            polling?.cancel(); polling = nil; playback?.cancel(); playback = nil
            bannerGeneration += 1; bannerDismissal?.cancel(); bannerDismissal = nil
            banner.isHidden = true; banner.thumbnailView.image = nil
            announcedBatches.removeAll(); announcedBatchOrder.removeAll()
            cursor = nil; queue.clear(); imageView.stopAnimating(); imageView.image = nil; overlay.isHidden = true
            overlay.backgroundColor = .clear
            return
        }
        guard polling == nil else { return }
        let expected = activityGeneration
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let page = try await self.gifts.events(roomID: self.roomID, after: self.cursor)
                    try Task.checkCancellation()
                    guard self.visible && self.foreground, self.activityGeneration == expected else { return }
                    self.cursor = page.nextCursor
                    page.events.forEach(self.enqueue)
                    // Catch up with bounded pages; normal operation uses one lightweight poll.
                    try await Task.sleep(nanoseconds: page.hasMore ? 150_000_000 : 1_500_000_000)
                } catch is CancellationError { return }
                catch { do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return } }
            }
        }
    }
    func showPanel() {
        guard #available(iOS 16.0, *) else { return }
        guard visible, foreground, let controller, controller.presentedViewController == nil else { return }
        let host = UIHostingController(rootView: KikiGiftPanel(gifts: gifts, roomID: roomID, hostName: hostName(), recipientSource: recipientSource))
        host.modalPresentationStyle = .pageSheet
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.custom(identifier: .init("kikiGifts")) { context in min(680, context.maximumDetentValue) }, .large()]
            sheet.prefersGrabberVisible = true
        }
        panel = host; controller.present(host, animated: true)
    }
    private func enqueue(_ event: KikiGiftEvent) {
        guard visible, foreground else { return }
        guard queue.append(event) else { return }
        // Chat acknowledges the whole transaction immediately, even when an
        // earlier multi-gift animation is still playing. Never send an IM copy.
        var message: [String: Any] = [
            "roomID": roomID, "eventID": event.id, "senderID": event.senderID,
            "senderName": event.senderName, "recipientName": event.recipientName,
            "giftName": event.giftName, "quantity": event.quantity
        ]
        if let avatar = event.senderAvatarURL { message["senderAvatarURL"] = avatar }
        NotificationCenter.default.post(name: Notification.Name("KikiGiftEventConfirmed"), object: nil, userInfo: message)
        showReceipt(event)
        playNext()
    }
    private func showReceipt(_ event: KikiGiftEvent) {
        if let batchID = event.batchID {
            guard announcedBatches.insert(batchID).inserted else { return }
            announcedBatchOrder.append(batchID)
            if announcedBatchOrder.count > 256 { announcedBatches.remove(announcedBatchOrder.removeFirst()) }
        }
        bannerGeneration += 1
        let expected = bannerGeneration
        bannerDismissal?.cancel()
        banner.configure(event: event); banner.isHidden = false; overlay.isHidden = false
        bannerDismissal = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, !Task.isCancelled, self.bannerGeneration == expected else { return }
            self.banner.isHidden = true; self.banner.thumbnailView.image = nil
            self.bannerDismissal = nil; self.updateOverlayVisibility()
        }
    }
    private func updateOverlayVisibility() {
        overlay.isHidden = imageView.image == nil && banner.isHidden
    }
    private func playNext() {
        guard playback == nil, let event = queue.next() else { return }
        let expected = activityGeneration
        playback = Task { [weak self] in
            guard let self else { return }
            if self.gifts.catalog == nil { await self.gifts.load() }
            // A suspended load may finish after minimize/background and a new
            // player has started. The old task cannot clear that new handle.
            guard self.activityGeneration == expected else { return }
            guard !Task.isCancelled, self.visible, self.foreground,
                  let gift = self.gifts.catalog?.gifts.first(where: { $0.id == event.giftID }) else {
                self.playback = nil; self.playNext(); return
            }
            let size = self.overlay.bounds.size
            let tier = min(5, max(1, gift.effectTier))
            let width: CGFloat = tier == 1 ? 150 : (tier == 2 ? 220 : min(size.width - 20, 360))
            let height: CGFloat = tier >= 4 ? min(size.height * 0.7, 540) : (tier == 3 ? 260 : 230)
            self.imageView.frame = tier == 5 ? self.overlay.bounds : CGRect(x: (size.width - width) / 2, y: tier >= 4 ? (size.height - height) / 2 : max(170, size.height * 0.44 - height / 2), width: width, height: height)
            self.imageView.contentMode = .scaleAspectFit
            self.overlay.backgroundColor = tier == 5 ? UIColor(red: 0.12, green: 0.03, blue: 0.23, alpha: 0.38) : .clear
            self.imageView.accessibilityIdentifier = "gift.animation.\(event.id)"
            self.overlay.isHidden = false
            do {
                if !UIAccessibility.isReduceMotionEnabled,
                   let url = gift.assetURL, let animated = SDAnimatedImage(contentsOfFile: url.path) {
                    self.imageView.animationRepeatCount = max(1, event.quantity)
                    self.imageView.image = animated
                    self.imageView.startAnimating()
                    // Wait for actual completed loops rather than estimating
                    // duration: decoding or slow frames must not cut off gifts.
                    while self.imageView.currentLoopCount < UInt(self.imageView.animationRepeatCount) {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } else {
                    self.imageView.image = gift.poster
                    try await Task.sleep(nanoseconds: 1_800_000_000)
                }
            }
            catch { return }
            guard !Task.isCancelled, self.activityGeneration == expected else { return }
            self.imageView.stopAnimating(); self.imageView.image = nil; self.overlay.backgroundColor = .clear
            self.updateOverlayVisibility()
            self.playback = nil; self.playNext()
        }
    }
}
