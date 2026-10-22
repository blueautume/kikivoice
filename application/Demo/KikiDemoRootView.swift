import AuthenticationServices
import SwiftUI
import UIKit

@available(iOS 16.0, *)
@MainActor
struct KikiDemoRootView: View {
    @StateObject private var consent = KikiConsentStore.shared
    @StateObject private var startupPermissions = KikiStartupPermissions()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if consent.isWithdrawalPending { KikiWithdrawalPendingView() }
            else if consent.hasCurrentConsent {
                if startupPermissions.isReady(for: consent) { KikiAuthorizedRootView(consent: consent) }
                else { KikiStartupPermissionsView(permissions: startupPermissions) }
            }
            else { KikiConsentGateView() }
        }
        .environmentObject(consent)
        .foregroundStyle(KikiPalette.text).tint(KikiPalette.lavender)
        .task(id: consent.hasCurrentConsent) {
            if consent.hasCurrentConsent { await startupPermissions.begin(consent: consent) }
            else { startupPermissions.cancel() }
        }
        .task(id: shouldRefreshDocuments) {
            guard shouldRefreshDocuments else { return }
            await consent.refreshDocuments()
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, shouldRefreshDocuments else { return }
            Task {
                guard shouldRefreshDocuments else { return }
                await consent.refreshDocuments()
            }
        }
    }

    private var shouldRefreshDocuments: Bool {
        !consent.hasCurrentConsent && !consent.isWithdrawalPending && !consent.serviceTransitionInProgress
    }
}

@available(iOS 16.0, *)
struct KikiStartupPermissionsView: View {
    @ObservedObject var permissions: KikiStartupPermissions
    @EnvironmentObject private var consent: KikiConsentStore

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 48)
                    Image("KikiLaunchMark").resizable().scaledToFit()
                        .frame(width: 84, height: 84).accessibilityHidden(true)
                    VStack(spacing: 14) {
                        Text(permissions.stage == .failed ? "暂时无法连接" : "准备开始")
                            .font(.title.weight(.semibold)).foregroundStyle(KikiPalette.text)
                        Text(statusText).font(.subheadline).lineSpacing(5)
                            .foregroundStyle(KikiPalette.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if permissions.stage == .failed {
                        VStack(spacing: 14) {
                            Button("重试连接") { Task { await permissions.retry(consent: consent) } }
                                .font(.body.weight(.semibold)).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 17)
                                .background(KikiPalette.action, in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityIdentifier("startup.retryNetwork")
                            Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                                .font(.footnote).foregroundStyle(KikiPalette.lavender)
                        }
                    } else {
                        ProgressView().tint(KikiPalette.lavender)
                            .accessibilityLabel(statusText)
                    }
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: 420)
                .padding(.horizontal, 28).padding(.vertical, 32)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
        }
        .background(KikiPalette.background.ignoresSafeArea())
        .accessibilityIdentifier("startup.permissions")
    }

    private var statusText: String {
        switch permissions.stage {
        case .failed:
            return permissions.errorMessage ?? "请允许 Kiki 使用无线数据，或连接可用网络后重试。"
        case .waitingForForeground:
            return "请完成系统确认，返回后会继续。"
        case .requestingNotifications:
            return "允许通知，及时收到新的消息。\n暂不允许也可以继续登录。"
        case .idle, .checkingNetwork:
            return "正在检查网络连接。\n如系统询问网络访问，请选择允许。"
        case .ready:
            return "准备就绪"
        }
    }
}

/// Constructing this child is conditional on current, explicit local consent.
@available(iOS 16.0, *)
@MainActor
private struct KikiAuthorizedRootView: View {
    @StateObject private var store: KikiDemoStore
    @ObservedObject private var push = KikiPushController.shared
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

    init(consent: KikiConsentStore) {
        _store = StateObject(wrappedValue: KikiDemoStore(consent: consent))
    }

    private var foregroundSessionKey: String? {
        guard scenePhase == .active, store.isAuthenticated, !store.needsNickname else { return nil }
        return store.pushSessionKey
    }

    private var roomCatalogKey: String? {
        guard selectedTab == 0, !store.isPresentingRoom else { return nil }
        return foregroundSessionKey
    }

    var body: some View {
        ZStack {
            KikiPalette.background.ignoresSafeArea()
            if !store.startupFinished {
                KikiStartupView()
            } else if store.isAuthenticated && store.needsNickname {
                KikiNicknameOnboardingView()
            } else if store.isAuthenticated {
                VStack(spacing: 0) {
                    ZStack {
                        KikiDiscoverView(isActive: selectedTab == 0).opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0).accessibilityHidden(selectedTab != 0)
                        KikiMomentsView(store: store, isActive: selectedTab == 1).opacity(selectedTab == 1 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 1).accessibilityHidden(selectedTab != 1)
                        KikiMessagesView(store: store, isActive: selectedTab == 2).opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2).accessibilityHidden(selectedTab != 2)
                        KikiProfileView(isActive: selectedTab == 3).opacity(selectedTab == 3 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 3).accessibilityHidden(selectedTab != 3)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    tabBar
                }
            } else { KikiLoginView() }
        }
        .foregroundStyle(KikiPalette.text).environmentObject(store)
        .tint(KikiPalette.purple)
        .task { push.attach(store); await store.start(); await push.refresh() }
        .task(id: store.pushSessionKey) { if store.pushSessionKey != nil { await push.refresh() } }
        .onChange(of: push.inboxRequest) { _ in if store.isAuthenticated { selectedTab = 2 } }
        .sheet(item: $push.navigation, onDismiss: { push.navigationDidDismiss() }) { route in
            switch route.content {
            case .direct(let person): KikiDirectConversationView(person: person, store: store)
            case .moment(let moment): KikiMomentCommentsView(moment: moment, store: store)
            }
        }
        .task(id: roomCatalogKey) {
            guard roomCatalogKey != nil else { return }
            await store.watchRoomCatalog()
        }
        .task(id: foregroundSessionKey) {
            guard foregroundSessionKey != nil else { return }
            await store.recordForegroundActivity()
            await store.refreshSafety()
            await store.refreshSocialSummary()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
                if scenePhase == .active && !store.needsNickname {
                    await store.refreshSocialSummary()
                    await push.refresh()
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task {
                    await store.checkAppleCredentialState()
                    if store.isAuthenticated {
                        await store.refreshLibrary()
                        await push.refresh()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await store.appleCredentialRevoked() }
        }
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Text(toast).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 13)
                    .background(KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                    .padding(.horizontal, 20).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity)).allowsHitTesting(false)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            tab(icon: "waveform", title: "语聊", index: 0)
            tab(icon: "square.text.square", title: "动态", index: 1)
            tab(icon: "bubble.left.and.bubble.right", title: "消息", index: 2)
            tab(icon: "person.crop.circle", title: "我", index: 3)
        }
            .frame(maxWidth: 720)
            .padding(.top, 11).padding(.bottom, 5)
            .frame(maxWidth: .infinity)
            .background(KikiPalette.background)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) }
    }

    private func tab(icon: String, title: String, index: Int) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation(.easeInOut(duration: 0.16)) { selectedTab = index }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 22, weight: selectedTab == index ? .semibold : .regular))
                    .overlay(alignment: .topTrailing) {
                        if index == 2, store.unreadMessageCount > 0 {
                            Text(store.unreadMessageCount > 99 ? "99+" : "\(store.unreadMessageCount)")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(KikiPalette.action, in: Capsule()).offset(x: 16, y: -8)
                        }
                    }
                Text(title).font(.system(size: 10, weight: .medium))
            }.foregroundStyle(selectedTab == index ? KikiPalette.lavender : KikiPalette.muted)
                .frame(maxWidth: .infinity).frame(height: 43).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(index == 0 ? "discoverTab" : (index == 1 ? "momentsTab" : (index == 2 ? "messagesTab" : "profileTab")))
            .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }
}

@available(iOS 16.0, *)
private struct KikiStartupView: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color("KikiLaunchBackground").ignoresSafeArea()

                // Match the native launch screen while the account restores.
                VStack(spacing: 0) {
                    Image("KikiLaunchMark")
                        .resizable().scaledToFit().frame(width: 128, height: 128)
                        .accessibilityHidden(true)
                    Text("Kiki语聊")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(KikiPalette.text).frame(height: 34)
                        .padding(.top, 24)
                    Text("听见，同频的你")
                        .font(.system(size: 13))
                        .foregroundStyle(KikiPalette.secondary).frame(height: 16)
                        .padding(.top, 10)
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 28)

                ProgressView()
                    .tint(KikiPalette.lavender)
                    .accessibilityLabel("正在恢复账号")
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2 + 120)

                Text("让每一种声音，都有回响")
                    .font(.system(size: 11)).foregroundStyle(KikiPalette.muted)
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 24)
            }
            .dynamicTypeSize(.medium)
        }
    }
}

@available(iOS 16.0, *)
struct KikiDiscoverView: View {
    var isActive: Bool = true
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var category = "全部"
    @State private var query = ""
    @State private var followingOnly = false
    @State private var sortByHeat = false
    @State private var showsCreate = false
    @State private var showsPeople = false
    @State private var pendingRoom: DemoRoom?

    private var filteredRooms: [DemoRoom] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rooms = store.rooms.filter {
            !$0.isLive && (category == "全部" || $0.category == category)
                && (!followingOnly || store.followingUserIDs.contains($0.hostID))
                && (term.isEmpty || "\($0.title) \($0.host) \($0.category)".localizedCaseInsensitiveContains(term))
        }
        return sortByHeat ? rooms.sorted { $0.audience > $1.audience } : rooms
    }

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, 1120)
            let columnCount = KikiRoomListLayout.columnCount(availableWidth: width, accessibilitySize: dynamicTypeSize.isAccessibilitySize)
            discoverContent(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12, alignment: .top), count: columnCount))
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsCreate, onDismiss: openPendingRoom) {
            KikiCreateRoomView(isLive: false) { pendingRoom = $0; category = "全部"; query = ""; followingOnly = false }.environmentObject(store)
        }
        .sheet(isPresented: $showsPeople) { KikiPeopleDirectoryView(store: store) }
        .overlay {
            if store.isJoiningRoom {
                VStack(spacing: 14) { ProgressView(); Text("正在连接房间…").font(.subheadline) }
                    .padding(28).background(KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func discoverContent(columns: [GridItem]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("语聊").font(.largeTitle.weight(.bold))
                Spacer()
                Button { showsPeople = true } label: {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: KikiCreateRoomButton.symbolSize, weight: .semibold))
                        .frame(width: 44, height: KikiCreateRoomButton.touchHeight)
                }
                    .accessibilityLabel("找朋友").accessibilityIdentifier("social.people")
                KikiCreateRoomButton(isVisible: isActive, action: presentCreate)
                    .disabled(store.isJoiningRoom)
            }.padding(.horizontal, 22).padding(.top, 15).padding(.bottom, 16)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(KikiPalette.muted)
                TextField("搜索房间、房主或话题", text: $query).font(.body).autocorrectionDisabled().submitLabel(.search)
                    .accessibilityIdentifier("roomSearchField")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(KikiPalette.muted) }.accessibilityLabel("清空搜索") }
            }.padding(13).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 20)
            HStack(spacing: 20) {
                filterButton("全部", selected: !followingOnly) { followingOnly = false }
                filterButton("关注", selected: followingOnly) { followingOnly = true }
                Spacer()
                Menu {
                    Button("最近创建") { sortByHeat = false }
                    Button("人数优先") { sortByHeat = true }
                } label: { Label(sortByHeat ? "人数" : "最新", systemImage: "line.3.horizontal.decrease").font(.subheadline).foregroundStyle(KikiPalette.secondary) }
            }.padding(.horizontal, 22).padding(.vertical, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["全部", "随心聊", "音乐", "生活", "游戏", "情感"], id: \.self) { item in
                        Button { category = item } label: {
                            Text(item).font(.subheadline).foregroundStyle(category == item ? KikiPalette.lavender : KikiPalette.secondary)
                                .padding(.horizontal, 13).padding(.vertical, 8)
                                .background(category == item ? KikiPalette.elevated : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20)
            }.padding(.bottom, 10)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let error = store.loadingError { KikiInlineError(message: error) { Task { await store.refreshRooms() } } }
                    HStack {
                        Text(query.isEmpty ? "正在语聊" : "搜索结果").font(.subheadline.weight(.medium)).foregroundStyle(KikiPalette.secondary)
                        Text("\(filteredRooms.count)").font(.caption).foregroundStyle(KikiPalette.muted)
                        Spacer()
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                    }
                    if filteredRooms.isEmpty {
                        KikiEmptyState(symbol: followingOnly ? "person.2.wave.2" : "waveform", title: followingOnly ? "关注的人还没有开房" : "此刻，等一个声音",
                            message: followingOnly ? "去找朋友，或切换「全部」认识更多人。" : "可以换个关键词，或创建一个自己的中文语聊房。")
                        Button(followingOnly ? "找朋友" : "创建语聊房") { if followingOnly { showsPeople = true } else { presentCreate() } }
                            .font(.body.weight(.semibold)).padding(.bottom, 25)
                    }
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(filteredRooms) { room in
                            Button { Task { await open(room) } } label: { KikiRoomCard(room: room) }
                                .buttonStyle(KikiPressStyle()).disabled(store.isJoiningRoom).accessibilityIdentifier("room-\(room.id)")
                                .contextMenu {
                                    Button { store.toggleFavorite(room) } label: { Label(store.favoriteIDs.contains(room.id) ? "取消收藏" : "收藏房间", systemImage: store.favoriteIDs.contains(room.id) ? "bookmark.slash" : "bookmark") }
                                }
                        }
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.refreshable { await store.refreshRooms(); await store.refreshSocialSummary() }
        }
    }
    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.headline).foregroundStyle(selected ? KikiPalette.text : KikiPalette.muted)
            .padding(.bottom, 6).overlay(alignment: .bottom) { if selected { Capsule().fill(KikiPalette.purple).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func presentCreate() {
        guard !store.isJoiningRoom else { return }
        guard !KikiRTCService.shared.isVoiceRoomMinimized else { store.notify("你仍在语聊房中，请先返回并离开房间。"); return }
        showsCreate = true
    }
    private func open(_ room: DemoRoom) async {
        do { try await store.openRoom(room) } catch { store.notify(error.localizedDescription) }
    }
    private func openPendingRoom() {
        guard let room = pendingRoom else { return }; pendingRoom = nil
        Task { do { try await store.startRoom(room) } catch { store.notify(error.localizedDescription); await store.refreshLibrary() } }
    }
}

/// Keep room cards wide enough for the host and the real member preview, even
/// on an iPad. Accessibility text uses the full available width in one column.
enum KikiRoomListLayout {
    static func columnCount(availableWidth: CGFloat, accessibilitySize: Bool) -> Int {
        accessibilitySize || availableWidth < 700 ? 1 : 2
    }
}

@available(iOS 16.0, *)
struct KikiRoomCard: View {
    @EnvironmentObject private var store: KikiDemoStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let room: DemoRoom

    private var usesCurrentProfile: Bool { room.isCreatedByMe && !store.userID.isEmpty }
    private var hostName: String { usesCurrentProfile ? store.profileName : room.host }
    private var statusText: String {
        room.status == "live" ? "\(max(0, room.audience)) 人在线" : (room.status == "draft" ? "未开始" : "已结束")
    }
    private var members: [KikiRoomMemberPreview] {
        var seen = Set<String>()
        return Array(room.memberPreview.filter {
            !$0.userID.isEmpty && $0.userID != room.hostID && seen.insert($0.userID).inserted
        }.prefix(3))
    }
    private var cardBackground: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.15, green: 0.13, blue: 0.21, alpha: 1)
                : UIColor(red: 0.95, green: 0.93, blue: 0.99, alpha: 1)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Text(room.category).font(.caption.weight(.semibold))
                    .foregroundStyle(KikiPalette.lavender)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(KikiPalette.purple.opacity(0.09), in: Capsule())
                if room.isCreatedByMe {
                    Text("我的房间").font(.caption).foregroundStyle(KikiPalette.secondary)
                }
                Spacer(minLength: 4)
                if store.favoriteIDs.contains(room.id) {
                    Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(KikiPalette.lavender)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.subheadline.weight(.medium))
                    .foregroundStyle(KikiPalette.purple).accessibilityHidden(true)
                Text(room.title).font(.headline.weight(.semibold))
                    .foregroundStyle(KikiPalette.text)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                HStack(spacing: 9) {
                    KikiAvatar(index: usesCurrentProfile ? store.avatarIndex : room.hostAvatarIndex, size: 36,
                               customURL: usesCurrentProfile ? store.customAvatarURL : room.hostAvatarURL)
                    Text(hostName).font(.subheadline)
                        .foregroundStyle(KikiPalette.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if room.status == "live" {
                    HStack(spacing: 7) {
                        if !members.isEmpty {
                            HStack(spacing: -9) {
                                ForEach(members) { member in
                                    KikiAvatar(index: member.avatarIndex, size: 27, customURL: member.avatarURL)
                                        .overlay(Circle().stroke(cardBackground, lineWidth: 2))
                                }
                            }.accessibilityHidden(true)
                        }
                        Label("\(max(0, room.audience))", systemImage: "person.2.fill")
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(KikiPalette.secondary)
                    }.fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
                } else {
                    Text(statusText).font(.caption).foregroundStyle(KikiPalette.muted)
                }
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(KikiPalette.purple.opacity(0.10), lineWidth: 0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(room.category)，\(room.title)，房主\(hostName)，\(statusText)")
        .accessibilityIdentifier("roomCard-\(room.id)")
    }
}

@available(iOS 16.0, *)
struct KikiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
