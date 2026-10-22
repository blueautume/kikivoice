import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct KikiDiscoverView: View {
    var isActive: Bool = true
    var onSearchFocusChange: (Bool) -> Void = { _ in }
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var query = ""
    @State private var followingOnly = false
    @State private var sortByHeat = false
    @State private var showsCreate = false
    @State private var showsPeople = false
    @State private var pendingRoom: KikiRoom?
    @FocusState private var isSearching: Bool

    private var filteredRooms: [KikiRoom] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rooms = store.rooms.filter {
            !$0.isLive && (!followingOnly || store.followingUserIDs.contains($0.hostID))
                && (term.isEmpty || "\($0.title) \($0.host)".localizedCaseInsensitiveContains(term))
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
            KikiCreateRoomView(isLive: false) { pendingRoom = $0; query = ""; followingOnly = false }.environmentObject(store)
        }
        .sheet(isPresented: $showsPeople) { KikiPeopleDirectoryView(store: store) }
        .overlay {
            if store.isJoiningRoom {
                VStack(spacing: 14) { ProgressView(); Text("正在连接房间…").font(.subheadline) }
                    .padding(28).background(KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .background(KikiRoomKeyboardDismissal(isEnabled: isActive && isSearching, onDismiss: endSearch))
        .onChange(of: isSearching) { focused in onSearchFocusChange(isActive && focused) }
        .onChange(of: isActive) { active in if !active { endSearch() } }
        .onDisappear(perform: endSearch)
    }

    private func discoverContent(columns: [GridItem]) -> some View {
        VStack(spacing: 0) {
            KikiDiscoverToolbar {
                KikiDiscoverSearchField(query: $query, isSearching: $isSearching, onSubmit: endSearch)
            } people: {
                KikiFindPeopleButton(isVisible: isActive) { endSearch(); showsPeople = true }
            } create: {
                KikiCreateRoomButton(isVisible: isActive, action: presentCreate)
                    .disabled(store.isJoiningRoom)
            }.padding(.horizontal, 20).padding(.top, 12)
            HStack(spacing: 20) {
                filterButton("全部", selected: !followingOnly) { followingOnly = false }
                filterButton("关注", selected: followingOnly) { followingOnly = true }
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Menu {
                    Button("最近创建") { sortByHeat = false }
                    Button("人数优先") { sortByHeat = true }
                } label: { Label(sortByHeat ? "人数" : "最新", systemImage: "line.3.horizontal.decrease").font(.subheadline).foregroundStyle(KikiPalette.secondary) }
            }.padding(.horizontal, 22).padding(.vertical, 16)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let error = store.loadingError { KikiInlineError(message: error) { Task { await store.refreshRooms() } } }
                    if filteredRooms.isEmpty {
                        KikiEmptyState(symbol: followingOnly ? "person.2.wave.2" : "waveform", title: followingOnly ? "关注的人还没有开房" : "此刻，等一个声音",
                            message: followingOnly ? "去找朋友，或切换「全部」认识更多人。" : "可以换个关键词，或创建一个自己的中文语聊房。")
                        Button(followingOnly ? "找朋友" : "创建语聊房") { endSearch(); if followingOnly { showsPeople = true } else { presentCreate() } }
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
            }.scrollDismissesKeyboard(.interactively)
                .kikiMainTabScrollInsets()
                .kikiTransparentTopScrollEdge()
                .refreshable { await store.refreshRooms(); await store.refreshSocialSummary() }
        }
    }
    private func filterButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { endSearch(); action() } label: { Text(title).font(.headline).foregroundStyle(selected ? KikiPalette.text : KikiPalette.muted)
            .padding(.bottom, 6).overlay(alignment: .bottom) { if selected { Capsule().fill(KikiPalette.purple).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func presentCreate() {
        guard !store.isJoiningRoom else { return }
        endSearch()
        guard !KikiRTCService.shared.isVoiceRoomMinimized else { store.notify("你仍在语聊房中，请先返回并离开房间。"); return }
        showsCreate = true
    }
    private func open(_ room: KikiRoom) async {
        endSearch()
        do { try await store.openRoom(room) } catch { store.notify(error.localizedDescription) }
    }
    private func endSearch() {
        isSearching = false
        onSearchFocusChange(false)
    }
    private func openPendingRoom() {
        guard let room = pendingRoom else { return }; pendingRoom = nil
        Task { do { try await store.startRoom(room) } catch { store.notify(error.localizedDescription); await store.refreshLibrary() } }
    }
}

/// The search field receives all remaining width; the two action capsules keep
/// their native touch dimensions even with accessibility text or a long query.
struct KikiDiscoverToolbar<Search: View, People: View, Create: View>: View {
    @ViewBuilder var search: () -> Search
    @ViewBuilder var people: () -> People
    @ViewBuilder var create: () -> Create

    var body: some View {
        HStack(spacing: 8) {
            search().frame(minWidth: 0, maxWidth: .infinity)
            people().fixedSize()
            create().fixedSize()
        }
    }
}

struct KikiDiscoverSearchField: View {
    @Binding var query: String
    var isSearching: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 17))
                .foregroundStyle(KikiPalette.muted)
            TextField("搜索房间或房主", text: $query).font(.body).autocorrectionDisabled().submitLabel(.search)
                .focused(isSearching).onSubmit(onSubmit)
                .accessibilityIdentifier("roomSearchField")
                .frame(minWidth: 0, maxWidth: .infinity)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                        .foregroundStyle(KikiPalette.muted).frame(width: 24, height: 28)
                }.accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
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
    @EnvironmentObject private var store: KikiAppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let room: KikiRoom

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
            if room.isCreatedByMe || store.favoriteIDs.contains(room.id) {
                HStack(spacing: 8) {
                    if room.isCreatedByMe {
                        Text("我的房间").font(.caption).foregroundStyle(KikiPalette.secondary)
                    }
                    Spacer(minLength: 4)
                    if store.favoriteIDs.contains(room.id) {
                        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(KikiPalette.lavender)
                    }
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
        .accessibilityLabel("\(room.title)，房主\(hostName)，\(statusText)")
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
