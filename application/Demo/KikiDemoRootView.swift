import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct KikiDemoRootView: View {
    @StateObject private var store = KikiDemoStore()
    @State private var selectedTab = 0
    @Environment(\.scenePhase) private var scenePhase

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
                        KikiDiscoverView().opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0).accessibilityHidden(selectedTab != 0)
                        KikiProfileView().opacity(selectedTab == 1 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 1).accessibilityHidden(selectedTab != 1)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    tabBar
                }
            } else { KikiLoginView() }
        }
        .foregroundStyle(KikiPalette.text).environmentObject(store)
        .preferredColorScheme(.dark).tint(KikiPalette.purple)
        .task { await store.start() }
        .task(id: store.isAuthenticated) {
            guard store.isAuthenticated else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 20_000_000_000) }
                catch { return }
                if scenePhase == .active && !store.needsNickname && !KikiRTCService.shared.isPresentingRoom { await store.refreshRooms() }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && store.isAuthenticated { Task { await store.refreshRooms(); await store.refreshLibrary() } }
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
            tab(icon: "waveform", title: "语聊 / 直播", index: 0)
            tab(icon: "person.crop.circle", title: "我", index: 1)
        }.padding(.top, 11).padding(.bottom, 5).background(KikiPalette.background)
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) }
    }

    private func tab(icon: String, title: String, index: Int) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation(.easeInOut(duration: 0.16)) { selectedTab = index }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 23, weight: selectedTab == index ? .semibold : .regular))
                Text(title).font(.system(size: 10, weight: .medium))
            }.foregroundStyle(selectedTab == index ? KikiPalette.lavender : KikiPalette.muted)
                .frame(maxWidth: .infinity).frame(height: 43).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(index == 0 ? "discoverTab" : "profileTab")
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
private struct KikiDiscoverView: View {
    @EnvironmentObject private var store: KikiDemoStore
    @State private var isLive = false
    @State private var category = "全部"
    @State private var query = ""
    @State private var searching = false
    @State private var sortByHeat = false
    @State private var showCreate = false
    @State private var pendingRoom: DemoRoom?

    private var filteredRooms: [DemoRoom] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rooms = store.rooms.filter { room in
            room.isLive == isLive && (category == "全部" || room.category == category)
                && (query.isEmpty || "\(room.title) \(room.host) \(room.category)".localizedCaseInsensitiveContains(query))
        }
        return sortByHeat ? rooms.sorted { $0.audience > $1.audience } : rooms
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if searching { searchBar.padding(.horizontal, 20).padding(.bottom, 12) }
            modeSelector
            topicSelector
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    if query.isEmpty && category == "全部" { banner }
                    if let error = store.loadingError {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "wifi.exclamationmark")
                            Text(error).font(.system(size: 12)).lineSpacing(4)
                            Spacer(minLength: 0)
                            Button("重试") { Task { await store.refreshRooms() } }.font(.system(size: 12, weight: .semibold))
                        }.foregroundStyle(KikiPalette.lavender).padding(14)
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    sectionHeading
                    if filteredRooms.isEmpty { emptyState }
                    LazyVStack(spacing: 12) {
                        ForEach(filteredRooms) { room in
                            Button { open(room) } label: { KikiRoomCard(room: room) }
                                .buttonStyle(KikiPressStyle()).disabled(store.isJoiningRoom)
                                .accessibilityIdentifier("room-\(room.id)")
                                .contextMenu {
                                    Button { store.toggleFavorite(room) } label: {
                                        Label(store.favoriteIDs.contains(room.id) ? "取消收藏" : "收藏房间", systemImage: store.favoriteIDs.contains(room.id) ? "bookmark.slash" : "bookmark")
                                    }
                                }
                        }
                    }
                    if !filteredRooms.isEmpty {
                        Text("长按房间可收藏 · 下拉刷新在线列表").font(.system(size: 11)).foregroundStyle(KikiPalette.muted).padding(.vertical, 14)
                    }
                }.padding(.horizontal, 20).padding(.top, 7).padding(.bottom, 20)
            }.refreshable { await store.refreshRooms() }
        }
        .sheet(isPresented: $showCreate, onDismiss: openPendingRoom) {
            KikiCreateRoomView(initialIsLive: isLive) { room in
                isLive = room.isLive; category = "全部"; query = ""; pendingRoom = room
            }.environmentObject(store)
        }
        .overlay {
            if store.isJoiningRoom {
                VStack(spacing: 14) { ProgressView().tint(KikiPalette.lavender); Text("正在连接房间…").font(.system(size: 13)) }
                    .padding(28).background(KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(KikiPalette.purple.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: "waveform").font(.system(size: 20, weight: .bold)).foregroundStyle(KikiPalette.lavender)
            }
            Text("kiki").font(.system(size: 30, weight: .heavy, design: .rounded)).tracking(-1.5)
            Text("听见，同频的你").font(.system(size: 11)).foregroundStyle(KikiPalette.muted)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { searching.toggle(); if !searching { query = "" } }
            } label: {
                Image(systemName: searching ? "xmark" : "magnifyingglass").font(.system(size: 19))
                    .foregroundStyle(KikiPalette.secondary).frame(width: 40, height: 44)
            }.accessibilityLabel(searching ? "关闭搜索" : "搜索房间").accessibilityIdentifier("searchRooms")
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 17)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(KikiPalette.muted)
            TextField("搜索房间、主播或话题", text: $query).font(.system(size: 14))
                .autocorrectionDisabled().submitLabel(.search).accessibilityIdentifier("roomSearchField")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(KikiPalette.muted) }.accessibilityLabel("清空搜索")
            }
        }.padding(13).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var modeSelector: some View {
        HStack(alignment: .center, spacing: 26) {
            modeButton("语聊", live: false); modeButton("直播", live: true)
            Spacer()
            Button { showCreate = true } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("创建房间").font(.system(size: 12, weight: .semibold))
                }.foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 10)
                    .background(KikiPalette.purple, in: Capsule())
            }.accessibilityIdentifier("createRoom").disabled(store.isJoiningRoom)
        }.padding(.horizontal, 23).padding(.bottom, 15)
    }

    private func modeButton(_ title: String, live: Bool) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.2)) { isLive = live } } label: {
            VStack(spacing: 8) {
                Text(title).font(.system(size: 23, weight: isLive == live ? .bold : .medium))
                    .foregroundStyle(isLive == live ? KikiPalette.text : KikiPalette.muted)
                Capsule().fill(isLive == live ? KikiPalette.purple : .clear).frame(width: 19, height: 3)
            }
        }.buttonStyle(.plain).accessibilityIdentifier(live ? "liveMode" : "voiceMode")
            .accessibilityAddTraits(isLive == live ? .isSelected : [])
    }

    private var topicSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(["全部", "随心聊", "音乐", "生活", "游戏", "情感"], id: \.self) { item in
                    Button { category = item } label: {
                        Text(item).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(category == item ? KikiPalette.text : KikiPalette.secondary)
                            .padding(.horizontal, 15).padding(.vertical, 9)
                            .background(category == item ? KikiPalette.elevated : .clear, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 20)
        }.padding(.bottom, 11)
    }

    private var banner: some View {
        Button { showCreate = true } label: {
            ZStack(alignment: .leading) {
                LinearGradient(colors: [Color(hex: 0x322350), Color(hex: 0x5E4484), Color(hex: 0x8370A3)], startPoint: .leading, endPoint: .trailing)
                GeometryReader { geo in
                    ZStack {
                        Circle().stroke(.white.opacity(0.12), lineWidth: 1).frame(width: 210, height: 210)
                        Circle().stroke(.white.opacity(0.16), lineWidth: 1).frame(width: 160, height: 160)
                        Circle().fill(LinearGradient(colors: [Color(hex: 0xC6B2F0), Color(hex: 0x7255B2), Color(hex: 0x4C3478)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 105, height: 105)
                        Image(systemName: "waveform").font(.system(size: 45, weight: .light)).foregroundStyle(.white.opacity(0.88))
                        Image(systemName: "sparkle").font(.system(size: 23)).offset(x: -68, y: -40)
                    }.foregroundStyle(Color(hex: 0xE3D4FF)).position(x: geo.size.width * 0.79, y: geo.size.height * 0.54)
                }
                VStack(alignment: .leading, spacing: 11) {
                    Text("此刻，听见彼此").font(.system(size: 10, weight: .medium)).foregroundStyle(KikiPalette.lavender)
                    Text("让每一种声音\n都有回响").font(.system(size: 24, weight: .semibold)).lineSpacing(2)
                    Label("开启你的房间", systemImage: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Color(hex: 0xD4C4EA))
                }.padding(.leading, 20).padding(.vertical, 19)
            }.frame(height: 157).clipShape(RoundedRectangle(cornerRadius: 21))
        }.buttonStyle(KikiPressStyle()).accessibilityLabel("开启你的房间")
    }

    private var sectionHeading: some View {
        HStack(spacing: 7) {
            Text(query.isEmpty ? (isLive ? "正在直播" : "正在语聊") : "搜索结果").font(.system(size: 16, weight: .semibold))
            Text("\(filteredRooms.count)").font(.system(size: 10)).foregroundStyle(KikiPalette.muted)
            if store.isRefreshing { ProgressView().scaleEffect(0.65).tint(KikiPalette.lavender) }
            Spacer()
            Menu {
                Button("最近开播") { sortByHeat = false }
                Button("人气优先") { sortByHeat = true }
            } label: {
                Label(sortByHeat ? "人气" : "最新", systemImage: "chevron.down").font(.system(size: 11)).foregroundStyle(KikiPalette.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: query.isEmpty ? (isLive ? "video" : "mic.badge.plus") : "magnifyingglass")
                .font(.system(size: 38, weight: .light)).foregroundStyle(KikiPalette.lavender)
            Text(query.isEmpty && category == "全部" ? "第一个声音，等你开启" : "没有找到匹配的房间").font(.system(size: 17, weight: .semibold))
            Text(query.isEmpty && category == "全部" ? "此刻还没有在线房间，创建一个，邀请朋友加入吧。" : "换个话题或关键词试试。")
                .font(.system(size: 12)).lineSpacing(5).multilineTextAlignment(.center).foregroundStyle(KikiPalette.secondary)
            Button(query.isEmpty && category == "全部" ? "创建房间" : "重置筛选") {
                if query.isEmpty && category == "全部" { showCreate = true }
                else { query = ""; category = "全部" }
            }.font(.system(size: 13, weight: .semibold)).foregroundStyle(KikiPalette.lavender)
                .padding(.horizontal, 20).padding(.vertical, 11).background(KikiPalette.purple.opacity(0.15), in: Capsule())
        }.frame(maxWidth: .infinity).padding(.vertical, 54)
    }

    private func open(_ room: DemoRoom) {
        Task { do { try await store.openRoom(room) } catch { store.notify(error.localizedDescription) } }
    }

    private func openPendingRoom() {
        guard let room = pendingRoom else { return }
        pendingRoom = nil
        Task { do { try await store.startRoom(room) } catch { store.notify(error.localizedDescription); await store.refreshLibrary() } }
    }
}

@available(iOS 16.0, *)
struct KikiRoomCard: View {
    @EnvironmentObject private var store: KikiDemoStore
    let room: DemoRoom
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 6) {
                Text(room.isLive ? "直播" : "语聊").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.24), in: Capsule())
                Text("# \(room.category)").font(.system(size: 10, weight: .medium)).foregroundStyle(KikiPalette.lavender)
                    .padding(.horizontal, 8).padding(.vertical, 5).background(.black.opacity(0.17), in: Capsule())
                Spacer()
                if store.favoriteIDs.contains(room.id) { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(KikiPalette.lavender) }
                Circle().fill(room.status == "live" ? KikiPalette.mint : KikiPalette.muted).frame(width: 5, height: 5)
                Text(room.status == "live" ? "进行中" : room.status == "draft" ? "未开播" : "已结束").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                KikiWave(color: .white.opacity(0.9))
                Text(room.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                KikiAvatar(index: room.isCreatedByMe ? store.avatarIndex : room.hostAvatarIndex, size: 30, customURL: room.isCreatedByMe ? store.customAvatarURL : room.hostAvatarURL)
                Text(room.isCreatedByMe ? store.profileName : room.host).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                if room.isCreatedByMe { Text("我的").font(.system(size: 8)).padding(4).background(.white.opacity(0.12), in: Capsule()) }
                Spacer()
                if room.status == "live" { Label("\(room.audience) 人次", systemImage: "eye").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)) }
            }
        }.padding(17).background(KikiCover(theme: room.theme)).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.06), lineWidth: 0.5)).foregroundStyle(KikiPalette.text)
            .accessibilityElement(children: .combine)
    }
}

@available(iOS 16.0, *)
struct KikiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.98 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
