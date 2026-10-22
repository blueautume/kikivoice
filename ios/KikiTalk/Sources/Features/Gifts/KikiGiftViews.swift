import ImageIO
import SwiftUI
import UIKit

/// The wallet only displays the voice service's persisted experience balance.
struct KikiGiftWalletCard: View {
    @ObservedObject var gifts: KikiGiftStore
    @State private var showsCenter = false

    var body: some View {
        Button { showsCenter = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "diamond.fill")
                    .font(.title2).foregroundStyle(KikiPalette.purple)
                    .frame(width: 46, height: 46)
                    .background(KikiPalette.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text("我的钻石与装扮").font(.headline).foregroundStyle(KikiPalette.text)
                    Text(gifts.wallet == nil ? "查看体验钻石、礼物与永久装扮" : "\(gifts.balanceText) 体验钻石")
                        .font(.subheadline).foregroundStyle(KikiPalette.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(KikiPalette.muted)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 21))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("profile.experienceWallet")
        .sheet(isPresented: $showsCenter) { KikiExperienceCenterView(gifts: gifts).kikiRoomSheet() }
    }
}

struct KikiExperienceCenterView: View {
    @ObservedObject var gifts: KikiGiftStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab: ExperienceTab = .shop
    @State private var category: KikiDecorationKind = .avatarFrame
    @State private var preview: KikiDecorationItem?
    private enum ExperienceTab: String, CaseIterable, Identifiable {
        case shop = "装扮商店", owned = "我的装扮", ledger = "钻石明细"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    balanceCard
                    Picker("体验中心内容", selection: $tab) {
                        ForEach(ExperienceTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if tab == .ledger { ledger } else { decorations }
                    if let error = gifts.errorMessage {
                        KikiExperienceMessage(text: error, isError: true)
                        Button("重新同步") { Task { await gifts.refresh() } }.buttonStyle(.bordered)
                    }
                }
                .padding(20).frame(maxWidth: 840).frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background)
            .foregroundStyle(KikiPalette.text)
            .navigationTitle("钻石与装扮").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .refreshable { await gifts.refresh() }
            .task { await gifts.refresh() }
            .sheet(item: $preview) { item in KikiDecorationDetail(gifts: gifts, item: item).kikiRoomSheet() }
            .overlay {
                if gifts.isLoading && gifts.catalog == nil {
                    ProgressView("正在同步体验账户…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .tint(KikiPalette.purple)
        .accessibilityIdentifier("experience.center")
    }

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("体验钻石", systemImage: "diamond.fill").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.82))
            Text(gifts.wallet == nil ? "等待同步" : gifts.balanceText)
                .font(.system(.largeTitle, design: .rounded).weight(.bold)).monospacedDigit()
                .contentTransition(.numericText()).foregroundStyle(.white)
                .minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityIdentifier("experience.balance")
            Text("首次赠送 1 亿体验钻石，用于赠送礼物和解锁装扮。")
                .font(.footnote).foregroundStyle(.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                Text("账号保存 · 装扮永久拥有")
            }.font(.caption).foregroundStyle(.white.opacity(0.72))
        }
        .padding(23).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 25)
                .fill(LinearGradient(colors: [Color(hex: 0x7150B8), Color(hex: 0x4F388B), Color(hex: 0x353052)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "diamond.fill").font(.system(size: 105)).rotationEffect(.degrees(18))
                        .foregroundStyle(.white.opacity(0.055)).padding(.trailing, 14).accessibilityHidden(true)
                }
        }
    }

    private var decorations: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(KikiDecorationKind.allCases) { kind in
                        Button { category = kind } label: {
                            Text(kind.title).font(.subheadline.weight(.medium)).fixedSize()
                                .padding(.horizontal, 15).padding(.vertical, 10)
                                .foregroundStyle(category == kind ? .white : KikiPalette.secondary)
                                .background(category == kind ? KikiPalette.action : KikiPalette.surface, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(category == kind ? .isSelected : [])
                    }
                }
            }
            let items = gifts.decorationItems.filter { $0.kind == category && (tab != .owned || gifts.inventory.ownedIDs.contains($0.id)) }
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: tab == .owned ? "sparkles" : "shippingbox").font(.largeTitle).foregroundStyle(KikiPalette.lavender)
                    Text(tab == .owned ? "还没有这类装扮" : "正在准备装扮").font(.headline)
                    Text(tab == .owned ? "到商店挑选一件，解锁后就能永久使用。" : "下拉刷新，获取最新的体验装扮。")
                        .font(.subheadline).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center)
                    if tab == .owned { Button("逛逛商店") { tab = .shop }.buttonStyle(.bordered) }
                }.frame(maxWidth: .infinity).padding(.vertical, 40)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 142, maximum: 260), spacing: 13)], spacing: 13) {
                    ForEach(items) { item in
                        Button { preview = item } label: {
                            KikiDecorationShopCard(item: item,
                                                   owned: gifts.inventory.ownedIDs.contains(item.id),
                                                   equipped: gifts.inventory.equipped.id(for: item.kind) == item.id)
                        }.buttonStyle(.plain).accessibilityIdentifier("decoration.item.\(item.id)")
                    }
                }
            }
        }
    }

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近 50 笔收支").font(.headline)
            if gifts.entries.isEmpty {
                Text("暂无收支记录，首次赠送将在账号同步后显示。")
                    .font(.subheadline).foregroundStyle(KikiPalette.secondary).padding(.vertical, 20)
            }
            ForEach(gifts.entries) { entry in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: entry.kind == "initial_grant" ? "diamond.fill" : (entry.kind == "gift" ? "gift.fill" : "sparkles"))
                        .foregroundStyle(KikiPalette.purple).frame(width: 24).padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.title).font(.subheadline.weight(.medium))
                        Text(Date(timeIntervalSince1970: TimeInterval(entry.createdAt)), format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(KikiPalette.secondary)
                        Text("余额 \(KikiExperienceFormat.diamonds(entry.balanceAfter))")
                            .font(.caption).foregroundStyle(KikiPalette.muted)
                    }
                    Spacer(minLength: 4)
                    Text("\(entry.amount > 0 ? "+" : "")\(KikiExperienceFormat.diamonds(entry.amount))")
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(entry.amount > 0 ? KikiPalette.mint : KikiPalette.text)
                        .multilineTextAlignment(.trailing)
                }
                .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            }
        }
    }
}

private struct KikiDecorationShopCard: View {
    let item: KikiDecorationItem
    let owned: Bool
    let equipped: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            KikiDecorationPreview(item: item).frame(height: 116).frame(maxWidth: .infinity)
                .background(KikiPalette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
            Text(equipped ? "正在使用" : (owned ? "已永久拥有" : "永久解锁"))
                .font(.caption).foregroundStyle(equipped ? KikiPalette.purple : KikiPalette.secondary)
            if !owned {
                Label(KikiExperienceFormat.diamonds(item.price), systemImage: "diamond.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(KikiPalette.purple)
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(equipped ? KikiPalette.purple.opacity(0.65) : .clear, lineWidth: 1.5))
    }
}

private struct KikiDecorationDetail: View {
    @ObservedObject var gifts: KikiGiftStore
    let item: KikiDecorationItem
    @Environment(\.dismiss) private var dismiss
    @State private var requestID = UUID()
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var confirmation: String?
    private var owned: Bool { gifts.inventory.ownedIDs.contains(item.id) }
    private var equipped: Bool { gifts.inventory.equipped.id(for: item.kind) == item.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KikiDecorationPreview(item: item).frame(height: 220).frame(maxWidth: .infinity)
                        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 24))
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.name).font(.title2.bold())
                        Spacer(minLength: 4)
                        Text(item.kind.title).font(.caption.weight(.medium)).foregroundStyle(KikiPalette.purple)
                    }
                    Text(item.summary).font(.body).foregroundStyle(KikiPalette.secondary)
                    Label("一次解锁，永久拥有", systemImage: "checkmark.seal.fill").font(.subheadline).foregroundStyle(KikiPalette.mint)
                    if !owned {
                        HStack {
                            Label(KikiExperienceFormat.diamonds(item.price), systemImage: "diamond.fill").font(.title3.weight(.semibold))
                            Spacer()
                            Text("余额 \(gifts.balanceText)").font(.caption).foregroundStyle(KikiPalette.secondary)
                        }
                    }
                    if let errorMessage { KikiExperienceMessage(text: errorMessage, isError: true) }
                    if let confirmation { KikiExperienceMessage(text: confirmation, isError: false) }
                    Button { performAction() } label: {
                        HStack {
                            Spacer()
                            if isWorking { ProgressView().tint(.white) }
                            Text(owned ? (equipped ? "卸下装扮" : "立即使用") : "使用体验钻石解锁").font(.headline)
                            Spacer()
                        }.padding(.vertical, 15).foregroundStyle(.white)
                            .background(KikiPalette.action, in: RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain).disabled(isWorking || !gifts.isAvailable || (!owned && (gifts.wallet?.balance ?? -1) < item.price))
                    .opacity(isWorking ? 0.7 : 1)
                    .accessibilityIdentifier("decoration.action.\(item.id)")
                    if !owned, let wallet = gifts.wallet, wallet.balance < item.price {
                        Text("体验钻石余额不足。").font(.footnote).foregroundStyle(KikiPalette.secondary)
                    }
                }.padding(22).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background).foregroundStyle(KikiPalette.text)
            .navigationTitle("装扮预览").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.disabled(isWorking) } }
        }
        .tint(KikiPalette.purple).interactiveDismissDisabled(isWorking)
    }

    private func performAction() {
        guard !isWorking else { return }
        isWorking = true; errorMessage = nil; confirmation = nil
        Task { @MainActor in
            defer { isWorking = false }
            do {
                if owned {
                    let removing = equipped
                    try await gifts.equip(kind: item.kind, decorationID: removing ? nil : item.id)
                    confirmation = removing ? "已卸下，仍可在“我的装扮”中再次使用。" : "装扮已生效。"
                } else {
                    try await gifts.purchase(item, requestID: requestID)
                    requestID = UUID()
                    confirmation = "已永久解锁，点击“立即使用”即可装备。"
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct KikiDecorationPreview: View {
    let item: KikiDecorationItem
    var body: some View {
        Group {
            switch item.kind {
            case .avatarFrame:
                KikiAvatar(index: 0, size: 65).overlay { KikiAvatarDecoration(decorationID: item.id, size: 75) }
            case .micEffect:
                KikiAvatar(index: 0, size: 54).overlay { KikiMicDecoration(decorationID: item.id, isSpeaking: false, size: 92) }
                    .overlay(alignment: .bottom) {
                        Image(systemName: "waveform").font(.caption.bold()).foregroundStyle(KikiDecorationPaint(id: item.id).colors[0]).offset(y: 15)
                    }
            case .chatBubble:
                Text("你好，很高兴认识你 ✨").font(.caption).foregroundStyle(KikiPalette.text)
                    .padding(12).background { KikiChatDecorationBackground(decorationID: item.id) }.padding(10)
            case .roomBackground:
                ZStack {
                    KikiRoomDecorationBackground(decorationID: item.id)
                    VStack(spacing: 12) {
                        Text("Kiki 的语聊空间").font(.caption.weight(.semibold)).foregroundStyle(KikiPalette.text)
                        HStack(spacing: 9) { ForEach(0..<4) { index in KikiAvatar(index: index, size: 22) } }
                    }.padding(12)
                }.clipShape(RoundedRectangle(cornerRadius: 14)).padding(7)
            }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel("\(item.name)效果预览")
    }
}

enum KikiGiftRecipientPolicy {
    static func eligibleMembers(_ members: [KikiRoomMember], senderID: String?, hostID: String?) -> [KikiRoomMember] {
        guard let senderID, !senderID.isEmpty else { return [] }
        var seen: Set<String> = []
        return members.filter { $0.online && ($0.seatIndex ?? 0) > 0 && !$0.userID.isEmpty && $0.userID != senderID && seen.insert($0.userID).inserted }
            .sorted { left, right in
                if (left.userID == hostID) != (right.userID == hostID) { return left.userID == hostID }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }
}

/// Each Send enqueues one server-confirmed gift per selected recipient.
@MainActor
struct KikiGiftPanel: View {
    @ObservedObject var gifts: KikiGiftStore
    @ObservedObject private var sendQueue: KikiGiftSendQueue
    let roomID: String
    let members: [KikiRoomMember]
    let hostID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedIDs: Set<String> = []
    @State private var selectedGiftID: String?
    @State private var initializedRecipients = false
    @State private var tab: GiftTab = .all
    @State private var showsCenter = false
    @State private var contentWidth: CGFloat = 343
    @State private var selectionError: String?

    init(gifts: KikiGiftStore, roomID: String, members: [KikiRoomMember], hostID: String?) {
        self.gifts = gifts
        self.roomID = roomID
        self.members = members
        self.hostID = hostID
        _sendQueue = ObservedObject(wrappedValue: gifts.sendQueue(for: roomID))
    }

    private enum GiftTab: String, CaseIterable { case all = "礼物", backpack = "背包" }
    private struct ContentWidth: PreferenceKey {
        static var defaultValue: CGFloat { 343 }
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
    private var recipients: [KikiRoomMember] {
        KikiGiftRecipientPolicy.eligibleMembers(members, senderID: gifts.userID, hostID: hostID)
    }
    private var selection: KikiGiftItem? { gifts.giftItems.first { $0.id == selectedGiftID } }
    private var selectedGiftStock: Int { selection.map { gifts.giftCount($0.id) } ?? 0 }
    private var orderedGifts: [KikiGiftItem] {
        gifts.orderedGiftItems.filter { tab == .all || ownedCount($0) > 0 }
    }
    private var quote: KikiGiftSendQuote? {
        guard let selection else { return nil }
        return sendQueue.nextQuote(gift: selection, recipientIDs: selectedIDs.sorted())
    }
    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize
            ? max(2, min(4, Int((contentWidth + 10) / 150)))
            : max(3, min(6, Int((contentWidth + 10) / 84)))
        return Array(repeating: GridItem(.flexible(minimum: 0), spacing: 9), count: count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recipientPicker
                    giftPicker
                    sendError
                    if let selectionError { KikiExperienceMessage(text: selectionError, isError: true) }
                }
                .background {
                    GeometryReader { geometry in Color.clear.preference(key: ContentWidth.self, value: geometry.size.width) }
                }
                .padding(16).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            .onPreferenceChange(ContentWidth.self) { contentWidth = $0 }
            .background(KikiPalette.background).foregroundStyle(KikiPalette.text)
            .navigationTitle("送礼物").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { balanceButton }
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } }
            }
            .task {
                reconcileRecipients()
                if selectedGiftID == nil { selectedGiftID = orderedGifts.first?.id }
                await gifts.refresh()
                if selectedGiftID == nil { selectedGiftID = orderedGifts.first?.id }
            }
            .onChange(of: members) { reconcileRecipients() }
            .onChange(of: selectedGiftStock) { oldValue, newValue in
                // Reservations affect the next quote immediately; only confirmed
                // inventory exhaustion moves the selected card out of the backpack.
                if tab == .backpack, oldValue > 0, newValue == 0 {
                    tab = .all
                }
            }
            .onChange(of: gifts.userID) { selectedIDs = []; dismiss() }
            .sheet(isPresented: $showsCenter) { KikiExperienceCenterView(gifts: gifts).kikiRoomSheet() }
        }
        .tint(KikiPalette.purple)
        .accessibilityIdentifier("gift.panel")
    }

    private var balanceButton: some View {
        Button { showsCenter = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "diamond.fill").font(.system(size: 13))
                    .frame(width: 13, height: 16).fixedSize()
                Text(gifts.wallet == nil ? "—" : gifts.balanceText)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit().contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 96, height: 24)
        }
        .accessibilityLabel(gifts.wallet == nil ? "钻石余额同步中，查看钻石与装扮" : "钻石余额 \(gifts.balanceText)，查看钻石与装扮")
        .accessibilityIdentifier("gift.wallet")
    }

    private var recipientPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("赠送给").font(.subheadline.weight(.semibold))
                Text("已选 \(selectedIDs.count) 人").font(.caption).foregroundStyle(KikiPalette.secondary)
                Spacer(minLength: 4)
                Button(allRecipientsSelected ? "取消全选" : "全部") {
                    selectedIDs = allRecipientsSelected ? [] : Set(recipients.prefix(32).map(\.userID))
                    initializedRecipients = true; selectionError = nil
                }.font(.caption.weight(.medium)).disabled(recipients.isEmpty)
            }
            if recipients.isEmpty {
                Text(gifts.isAvailable ? "暂无可收礼的麦上成员" : "正在同步麦上成员…")
                    .font(.subheadline).foregroundStyle(KikiPalette.secondary).padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 11) {
                        ForEach(recipients) { member in recipientButton(member) }
                    }.padding(.vertical, 4)
                }
            }
        }
    }
    private var allRecipientsSelected: Bool {
        !recipients.isEmpty && Set(recipients.prefix(32).map(\.userID)).isSubset(of: selectedIDs)
    }

    private func recipientButton(_ member: KikiRoomMember) -> some View {
        let selected = selectedIDs.contains(member.userID)
        return Button {
            selectionError = nil
            if selected { selectedIDs.remove(member.userID) }
            else if selectedIDs.count < 32 { selectedIDs.insert(member.userID) }
            else { selectionError = "每次最多选择 32 人。" }
            initializedRecipients = true
        } label: {
            VStack(spacing: 6) {
                KikiAvatar(index: member.avatarIndex, size: 45, customURL: member.avatarURL)
                    .overlay { KikiAvatarDecoration(decorationID: gifts.appearance(for: member.userID).avatarFrame, size: 51) }
                    .padding(5)
                    .overlay { Circle().stroke(selected ? KikiPalette.purple : .clear, lineWidth: 2) }
                    .overlay(alignment: .bottomTrailing) {
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, KikiPalette.action).font(.body) }
                    }
                Text(member.name)
                    .font(.caption).foregroundStyle(selected ? KikiPalette.purple : KikiPalette.text).lineLimit(1)
                if member.userID == hostID { Text("房主").font(.caption2).foregroundStyle(KikiPalette.secondary) }
            }.frame(width: 65)
        }.buttonStyle(.plain)
            .accessibilityLabel("\(member.name)\(member.userID == hostID ? "，房主" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("gift.recipient.\(member.userID)")
    }

    private var giftPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 21) {
                ForEach(GiftTab.allCases, id: \.self) { value in
                    Button { selectTab(value) } label: {
                        VStack(spacing: 7) {
                            Text(value.rawValue).font(.headline).foregroundStyle(tab == value ? KikiPalette.text : KikiPalette.muted)
                            Capsule().fill(tab == value ? KikiPalette.action : .clear).frame(height: 3)
                        }.fixedSize(horizontal: true, vertical: false)
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == value ? .isSelected : [])
                        .accessibilityIdentifier(value == .all ? "gift.tab.all" : "gift.tab.backpack")
                }
                Spacer(minLength: 0)
            }
            if gifts.giftItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { ProgressView(); Text("正在获取礼物…").font(.subheadline).foregroundStyle(KikiPalette.secondary) }
                    if let error = gifts.errorMessage {
                        KikiExperienceMessage(text: error, isError: true)
                        Button("重新加载") { Task { await gifts.refresh(); if selectedGiftID == nil { selectedGiftID = orderedGifts.first?.id } } }
                    }
                }.padding(.vertical, 20)
            } else if orderedGifts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "shippingbox").font(.title).foregroundStyle(KikiPalette.lavender)
                    Text("背包里的礼物已送完").font(.subheadline.weight(.medium))
                    Button("查看礼物") { tab = .all }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(orderedGifts) { gift in giftCard(gift) }
                }
            }
        }
    }

    private func giftCard(_ gift: KikiGiftItem) -> some View {
        let selected = selection?.id == gift.id
        let count = ownedCount(gift)
        return VStack(spacing: 0) {
            Button { selectedGiftID = gift.id; selectionError = nil } label: {
                VStack(spacing: 6) {
                    KikiGiftPoster(giftID: gift.id).frame(height: dynamicTypeSize.isAccessibilitySize ? 80 : 68)
                    Text(gift.name).font(.caption.weight(.medium)).foregroundStyle(KikiPalette.text)
                        .lineLimit(2).frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 42 : 29)
                    Group {
                        if count > 0 {
                            Text("拥有 ×\(count)").foregroundStyle(KikiPalette.mint)
                        } else {
                            Label(KikiExperienceFormat.diamonds(gift.price), systemImage: "diamond.fill")
                                .foregroundStyle(KikiPalette.purple)
                        }
                    }.font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
                }
                .padding(.horizontal, 5).padding(.top, 10).padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("gift.item.\(gift.id)")

            // Selection and Send are siblings: tapping Send never changes selection or sends twice.
            Button { enqueue(gift) } label: {
                HStack(spacing: 5) {
                    Spacer(minLength: 0)
                    Text("Send").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9).foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .background(KikiPalette.action)
            }
            .buttonStyle(.plain).disabled(!selected || !canSend)
            .opacity(selected ? (canSend ? 1 : 0.45) : 0)
            .allowsHitTesting(selected)
            .accessibilityHidden(!selected)
            .accessibilityLabel("赠送\(gift.name)，每人一份")
            .accessibilityIdentifier(selected ? "gift.send" : "gift.send.inactive.\(gift.id)")
        }
        .frame(maxWidth: .infinity)
        .background(selected ? KikiPalette.purple.opacity(0.09) : KikiPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? KikiPalette.purple : .clear, lineWidth: 2) }
    }

    private func ownedCount(_ gift: KikiGiftItem) -> Int { gifts.giftCount(gift.id) }
    private var canSend: Bool {
        gifts.isAvailable && !sendQueue.isPaused && sendQueue.pendingCount < 20 &&
        !selectedIDs.isEmpty && selectedIDs.count <= 32 && quote?.isAffordable == true
    }
    private func enqueue(_ gift: KikiGiftItem) {
        reconcileRecipients()
        guard canSend else { return }
        if sendQueue.enqueue(gift: gift, recipientIDs: selectedIDs.sorted()) { selectionError = nil }
    }

    @ViewBuilder private var sendError: some View {
        if let error = sendQueue.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(error)
                    .font(.footnote).foregroundStyle(KikiPalette.lavender)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if sendQueue.isPaused {
                    Button("重试") { sendQueue.retry() }
                        .font(.footnote.weight(.semibold)).accessibilityIdentifier("gift.retry")
                }
            }
            .padding(.vertical, 8).accessibilityIdentifier("gift.sendError")
        } else if let error = gifts.errorMessage, !gifts.giftItems.isEmpty {
            KikiInlineError(message: error) { Task { await gifts.refresh() } }
        } else if let quote, !quote.isAffordable {
            Text("钻石不足，请更换礼物或减少收礼人。")
                .font(.footnote).foregroundStyle(KikiPalette.secondary)
        }
    }

    private func selectTab(_ value: GiftTab) {
        tab = value; selectionError = nil
        if value == .backpack, selectedGiftStock == 0,
           let firstOwned = gifts.orderedGiftItems.first(where: { gifts.giftCount($0.id) > 0 }) {
            selectedGiftID = firstOwned.id
        }
    }

    private func reconcileRecipients() {
        let eligibleIDs = Set(recipients.map(\.userID))
        sendQueue.updateEligibleRecipients(eligibleIDs)
        selectedIDs.formIntersection(eligibleIDs)
        if !initializedRecipients, let target = recipients.first(where: { $0.userID == hostID }) ?? recipients.first {
            selectedIDs = [target.userID]; initializedRecipients = true
        }
    }
}

/// Confirmed batches share a stable animation while their live combo grows.
struct KikiGiftPresentationOverlay: View {
    @ObservedObject var gifts: KikiGiftStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presentation = KikiGiftPresentationState()
    @State private var appeared = false

    var body: some View {
        GeometryReader { geometry in
            if let item = presentation.active {
                let event = item.event
                VStack(spacing: 14) {
                    HStack(spacing: 11) {
                        KikiGiftPoster(giftID: event.giftID).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.senderName).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(event.batchRecipientCount > 1 ? "赠予 \(event.batchRecipientCount) 位成员" : "赠予 \(event.recipientName)")
                                .font(.caption).foregroundStyle(.white.opacity(0.78)).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Text("×\(item.quantity)").font(.title3.bold()).monospacedDigit()
                            .contentTransition(.numericText(value: Double(item.quantity)))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: item.quantity)
                            .id(item.id)
                    }
                    .padding(13).frame(maxWidth: 430).foregroundStyle(.white)
                    .background(LinearGradient(colors: [Color(hex: 0x7656AD).opacity(0.95), Color(hex: 0x3D315C).opacity(0.94)], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
                    Spacer(minLength: 0)
                    KikiGiftAnimatedImage(giftID: event.giftID, animated: !reduceMotion)
                        .id(item.id)
                        .frame(width: min(max(0, geometry.size.width - 32), 370), height: min(max(0, geometry.size.height * 0.52), 440))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16).padding(.top, 84).padding(.bottom, 70)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(event.senderName)赠送\(event.giftName) ×\(item.quantity)，给\(event.batchRecipientCount > 1 ? "\(event.batchRecipientCount)位成员" : event.recipientName)")
                .accessibilityIdentifier("giftPresentationCombo")
                .task(id: "\(item.id):\(item.revision)") {
                    let remaining = min(12, max(0, item.expiresAt.timeIntervalSinceNow))
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                    guard !Task.isCancelled, presentation.active?.id == item.id,
                          presentation.active?.revision == item.revision else { return }
                    presentation.advance(at: max(Date(), item.expiresAt))
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            presentation = KikiGiftPresentationState(displayDuration: reduceMotion ? 1.8 : 4,
                                                     maximumDisplayDuration: reduceMotion ? 5.4 : 12)
            presentation.reset(baseline: gifts.events)
            appeared = true
        }
        .onChange(of: gifts.events) { _, events in
            guard appeared else { return }
            if events.isEmpty { presentation.reset(); return }
            presentation.ingest(events)
        }
        .onChange(of: gifts.userID) { presentation.reset(baseline: gifts.events) }
        .onDisappear { appeared = false; presentation.reset() }
    }
}

struct KikiAvatarDecoration: View {
    let decorationID: String?
    let size: CGFloat
    var body: some View {
        let side = min(240, max(0, size))
        let paint = KikiDecorationPaint(id: decorationID)
        ZStack {
            if decorationID?.hasPrefix("frame_") == true {
                Circle().stroke(paint.gradient, lineWidth: max(2, side * 0.045)).padding(side * 0.055)
                Circle().stroke(paint.colors[0].opacity(0.4), lineWidth: 1).padding(side * 0.005)
                ForEach(0..<4) { index in
                    Image(systemName: index == 0 && paint.style == "gold" ? "crown.fill" : "sparkle")
                        .font(.system(size: max(8, side * (index == 0 ? 0.19 : 0.12)), weight: .bold))
                        .foregroundStyle(paint.colors[index % paint.colors.count])
                        .offset(x: index % 2 == 0 ? 0 : (index == 1 ? side * 0.44 : -side * 0.44),
                                y: index % 2 == 0 ? (index == 0 ? -side * 0.43 : side * 0.43) : 0)
                }
            }
        }.frame(width: side, height: side).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct KikiMicDecoration: View {
    let decorationID: String?
    let isSpeaking: Bool
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let side = min(240, max(0, size))
        let paint = KikiDecorationPaint(id: decorationID)
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: reduceMotion || !isSpeaking || decorationID == nil)) { timeline in
            let phase = reduceMotion || !isSpeaking ? 0 : (sin(timeline.date.timeIntervalSinceReferenceDate * 4) + 1) / 2
            ZStack {
                if decorationID?.hasPrefix("mic_") == true {
                    Circle().stroke(paint.gradient, lineWidth: isSpeaking ? 2.5 : 1.3)
                        .padding(side * (0.11 - 0.035 * phase)).opacity(isSpeaking ? 0.8 : 0.42)
                    Circle().stroke(paint.colors[0].opacity(isSpeaking ? 0.5 : 0.2), style: StrokeStyle(lineWidth: 1.4, dash: paint.style == "aurora" ? [4, 5] : []))
                        .padding(side * (0.03 + 0.035 * phase))
                    if paint.style == "gold" {
                        ForEach(0..<4) { index in
                            Circle().fill(paint.colors[0]).frame(width: 3.5, height: 3.5)
                                .offset(x: index % 2 == 0 ? 0 : (index == 1 ? side * 0.44 : -side * 0.44),
                                        y: index % 2 == 0 ? (index == 0 ? -side * 0.44 : side * 0.44) : 0)
                        }
                    }
                }
            }
        }.frame(width: side, height: side).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct KikiChatDecorationBackground: View {
    let decorationID: String?
    var body: some View {
        let paint = KikiDecorationPaint(id: decorationID)
        RoundedRectangle(cornerRadius: 15)
            .fill(decorationID?.hasPrefix("bubble_") == true ? AnyShapeStyle(LinearGradient(colors: paint.colors.map { $0.opacity(0.19) }, startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(KikiPalette.surface.opacity(0.85)))
            .overlay {
                if decorationID?.hasPrefix("bubble_") == true {
                    RoundedRectangle(cornerRadius: 15).stroke(paint.gradient.opacity(0.6), lineWidth: 0.8)
                }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct KikiRoomDecorationBackground: View {
    let decorationID: String?
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let paint = KikiDecorationPaint(id: decorationID)
        GeometryReader { geometry in
            ZStack {
                KikiPalette.background
                LinearGradient(colors: colorScheme == .dark ? paint.roomColors
                               : (paint.decorated ? paint.colors.map { $0.opacity(0.16) }
                                  : [KikiPalette.background, KikiPalette.surface]),
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if decorationID?.hasPrefix("background_") == true {
                    Ellipse().fill(RadialGradient(colors: [paint.colors[0].opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: max(1, min(geometry.size.width, 700) * 0.6)))
                        .frame(width: min(geometry.size.width * 1.3, 900), height: min(geometry.size.height * 0.8, 700))
                        .rotationEffect(.degrees(-25)).offset(x: geometry.size.width * 0.2, y: -geometry.size.height * 0.2)
                    ForEach(0..<14) { index in
                        Circle().fill(paint.colors[index % 3].opacity(index % 3 == 0 ? 0.3 : 0.12))
                            .frame(width: index % 3 == 0 ? 3 : 2, height: index % 3 == 0 ? 3 : 2)
                            .position(x: geometry.size.width * CGFloat((index * 37 + 13) % 100) / 100,
                                      y: geometry.size.height * CGFloat((index * 23 + 7) % 100) / 100)
                    }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct KikiDecorationPaint {
    let style: String
    let decorated: Bool
    init(id: String?) {
        style = id?.split(separator: "_").last.map(String.init) ?? "violet"
        decorated = id?.hasPrefix("background_") == true
    }
    var colors: [Color] {
        switch style {
        case "aurora": return [Color(hex: 0x7CE5D4), Color(hex: 0x8FAEFF), Color(hex: 0xD9ADFF)]
        case "gold": return [Color(hex: 0xFFE8AB), Color(hex: 0xDDA34B), Color(hex: 0xFFF3D9)]
        default: return [Color(hex: 0xC8A9FF), Color(hex: 0x8161DE), Color(hex: 0xEABEFF)]
        }
    }
    var gradient: AngularGradient { AngularGradient(colors: colors + [colors[0]], center: .center) }
    var roomColors: [Color] {
        guard decorated else { return [Color(hex: 0x25232F), Color(hex: 0x1C1A24), Color(hex: 0x14131A)] }
        switch style {
        case "aurora": return [Color(hex: 0x19333D), Color(hex: 0x26253F), Color(hex: 0x141824)]
        case "gold": return [Color(hex: 0x3D3028), Color(hex: 0x28232C), Color(hex: 0x17151D)]
        default: return [Color(hex: 0x382749), Color(hex: 0x242037), Color(hex: 0x171420)]
        }
    }
}

private struct KikiExperienceMessage: View {
    let text: String
    let isError: Bool
    var body: some View {
        Label(text, systemImage: isError ? "exclamationmark.circle" : "checkmark.circle.fill")
            .font(.footnote).foregroundStyle(isError ? Color.orange : KikiPalette.mint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((isError ? Color.orange : KikiPalette.mint).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum KikiExperienceFormat {
    static func diamonds(_ amount: Int) -> String { amount.formatted(.number.locale(Locale(identifier: "zh_CN"))) }
}

private struct KikiGiftPoster: View {
    let giftID: String
    var body: some View {
        Group {
            if let image = KikiGiftAssets.poster(giftID) { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "gift.fill").resizable().scaledToFit().foregroundStyle(KikiPalette.lavender).padding(12) }
        }.accessibilityHidden(true)
    }
}

private enum KikiGiftAssets {
    static let knownIDs: Set<String> = ["heart", "flower_rain", "aurora_car", "galaxy_rocket", "cosmic_heart"]
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 10; cache.totalCostLimit = 45_000_000; return cache
    }()
    static func url(_ id: String, extension ext: String) -> URL? {
        guard knownIDs.contains(id) else { return nil }
        return Bundle.main.url(forResource: id, withExtension: ext, subdirectory: "Gifts") ?? Bundle.main.url(forResource: id, withExtension: ext)
    }
    static func poster(_ id: String) -> UIImage? {
        let key = "poster_\(id)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let url = url(id, extension: "png"), let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4)); return image
    }
    /// Decode only the finite, packaged catalogue, off the main thread and with a memory cap.
    static func animation(_ id: String) -> UIImage? {
        let key = "animation_\(id)" as NSString
        if let image = images.object(forKey: key) { return image }
        guard let url = url(id, extension: "gif"), let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return poster(id) }
        let count = min(80, CGImageSourceGetCount(source))
        guard count > 0 else { return poster(id) }
        var frames: [UIImage] = []; var duration: Double = 0; var memoryCost = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 440, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { continue }
            let cost = frame.bytesPerRow * frame.height
            guard memoryCost + cost <= 40_000_000 else { break }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.065
            duration += max(0.02, delay); memoryCost += cost; frames.append(UIImage(cgImage: frame))
        }
        guard !frames.isEmpty, let image = UIImage.animatedImage(with: frames, duration: max(0.1, duration)) else { return poster(id) }
        images.setObject(image, forKey: key, cost: memoryCost); return image
    }
}

private struct KikiGiftAnimatedImage: UIViewRepresentable {
    let giftID: String
    let animated: Bool
    final class Coordinator { var key = ""; var generation = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(); view.contentMode = .scaleAspectFit; view.isUserInteractionEnabled = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal); view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }
    func updateUIView(_ view: UIImageView, context: Context) {
        let key = "\(giftID)_\(animated)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key; context.coordinator.generation += 1
        let generation = context.coordinator.generation
        view.stopAnimating(); view.image = KikiGiftAssets.poster(giftID)
        guard animated else { return }
        let id = giftID; let coordinator = context.coordinator
        DispatchQueue.global(qos: .userInitiated).async { [weak view] in
            let image = KikiGiftAssets.animation(id)
            DispatchQueue.main.async {
                guard coordinator.generation == generation, let view else { return }
                view.image = image; view.startAnimating()
            }
        }
    }
    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.generation += 1; view.stopAnimating(); view.image = nil
    }
}
