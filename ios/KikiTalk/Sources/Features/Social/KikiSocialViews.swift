import SwiftUI

struct KikiEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(KikiPalette.lavender)
            Text(title).font(.headline).foregroundStyle(KikiPalette.text)
            Text(message).font(.subheadline).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.horizontal, 28).padding(.vertical, 48)
    }
}

struct KikiInlineError: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry).font(.subheadline.weight(.semibold))
        }.foregroundStyle(KikiPalette.lavender).padding(16)
            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct KikiPersonRow: View {
    let person: KikiPerson
    var body: some View {
        HStack(spacing: 13) {
            KikiAvatar(index: person.avatarIndex, size: 46, customURL: person.avatarURL)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(person.name).font(.body.weight(.semibold)).foregroundStyle(KikiPalette.text)
                    if person.mutual { Text("互关").font(.caption).foregroundStyle(KikiPalette.lavender) }
                }
                Text(person.bio.isEmpty ? "还没有填写简介" : person.bio)
                    .font(.subheadline).foregroundStyle(KikiPalette.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(KikiPalette.muted)
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
}

struct KikiPeopleDirectoryView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [KikiPerson] = []
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var selected: KikiPersonDestination?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let error { KikiInlineError(message: error) { Task { await reload() } } }
                    if isLoading && people.isEmpty { ProgressView().padding(30) }
                    else if people.isEmpty && error == nil {
                        KikiEmptyState(symbol: "person.2", title: query.isEmpty ? "认识同频的人" : "没有找到用户",
                                       message: query.isEmpty ? "这里会展示已完成资料的社区成员。" : "试试昵称或完整账号编号。")
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(people) { person in
                            Button { selected = .init(id: person.id) } label: { KikiPersonRow(person: person) }.buttonStyle(.plain)
                            if person.id != people.last?.id { Divider().overlay(KikiPalette.elevated) }
                        }
                    }.padding(.horizontal, 16).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    if nextCursor != nil { Button(isLoading ? "正在加载…" : "加载更多") { Task { await loadMore() } }.disabled(isLoading) }
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
            .background(KikiPalette.background.ignoresSafeArea()).refreshable { await reload() }
            .navigationTitle("找朋友").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索昵称或账号编号")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: store.socialPrivacyRevision) { _ in
                generation = UUID(); people = []; nextCursor = nil; isLoading = false
                Task { await reload() }
            }
            .task(id: query) {
                do { try await Task.sleep(nanoseconds: 300_000_000); await reload() } catch { }
            }
            .sheet(item: $selected) { KikiPublicProfileView(userID: $0.id, store: store) }
        }.tint(KikiPalette.lavender)
    }

    private func reload() async {
        let id = UUID(); generation = id; let privacy = store.socialPrivacyRevision; isLoading = true; error = nil
        defer { if generation == id { isLoading = false } }
        do {
            let page = try await store.socialPeople(query: query.trimmingCharacters(in: .whitespacesAndNewlines))
            try Task.checkCancellation(); guard generation == id, privacy == store.socialPrivacyRevision else { return }
            people = page.people; nextCursor = page.nextCursor
        } catch is CancellationError { }
        catch { if generation == id { self.error = error.localizedDescription; people = [] } }
    }

    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let id = generation; let privacy = store.socialPrivacyRevision; isLoading = true
        defer { if generation == id { isLoading = false } }
        do {
            let page = try await store.socialPeople(query: query.trimmingCharacters(in: .whitespacesAndNewlines), cursor: cursor)
            guard generation == id, privacy == store.socialPrivacyRevision else { return }
            let existing = Set(people.map(\.id)); people += page.people.filter { !existing.contains($0.id) }
            nextCursor = page.nextCursor; error = nil
        } catch is CancellationError { }
        catch { if generation == id { self.error = error.localizedDescription } }
    }
}

struct KikiPublicProfileView: View {
    let userID: String
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var person: KikiPerson?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isFollowing = false
    @State private var destination: Destination?
    @State private var confirmsBlock = false
    @State private var isBlocking = false
    @State private var moments: [KikiMoment] = []
    @State private var confirmsUnfollow = false
    private enum Destination: Identifiable {
        case direct(KikiPerson), report(KikiSocialReportTarget), moment(KikiMoment)
        var id: String {
            switch self {
            case .direct(let person): return "direct:" + person.id
            case .report(let report): return "report:" + report.id
            case .moment(let moment): return "moment:" + moment.id
            }
        }
    }

    private var room: KikiRoom? {
        guard let verifiedRoomID = person?.currentRoomID else { return nil }
        return store.rooms.first { $0.id == verifiedRoomID && $0.hostID == userID && $0.status == "live" }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if let error { KikiInlineError(message: error) { Task { await reload() } } }
                    if isLoading && person == nil { ProgressView().padding(45) }
                    if let person {
                        VStack(spacing: 14) {
                            KikiDecoratedAvatar(gifts: store.gifts, userID: person.id, index: person.avatarIndex, size: 88, customURL: person.avatarURL)
                            Text(person.name).font(.title2.weight(.semibold)).foregroundStyle(KikiPalette.text)
                            Text(person.bio.isEmpty ? "这个人很安静，还没有留下简介。" : person.bio)
                                .font(.body).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center)
                            Text(person.id).font(.caption.monospaced()).foregroundStyle(KikiPalette.muted).textSelection(.enabled)
                        }.frame(maxWidth: .infinity).padding(.top, 20)
                        HStack(spacing: 0) {
                            count(person.followingCount, title: "关注")
                            Divider().frame(height: 28)
                            count(person.followerCount, title: "粉丝")
                        }.padding(18).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                        if let room {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("正在语聊").font(.headline)
                                KikiRoomCard(room: room)
                                Button("进入房间") { Task { await open(room) } }.font(.body.weight(.semibold)).disabled(store.isJoiningRoom)
                            }
                        }
                        if !moments.isEmpty {
                            VStack(alignment: .leading, spacing: 13) {
                                Text("最近动态").font(.headline)
                                ForEach(moments.prefix(3)) { moment in
                                    Button { destination = .moment(moment) } label: {
                                        VStack(alignment: .leading, spacing: 10) {
                                            if !moment.text.isEmpty { Text(moment.text).font(.body).foregroundStyle(KikiPalette.text).lineLimit(4) }
                                            if let media = moment.media.first { KikiSocialImageView(media: media, store: store).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                            Label("\(moment.commentCount) 条评论", systemImage: "bubble.right").font(.caption).foregroundStyle(KikiPalette.muted)
                                        }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        Text("关注后，可以在语聊页的「关注」中找到对方正在开的房间。")
                            .font(.footnote).foregroundStyle(KikiPalette.muted).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea()).refreshable { await reload() }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let person, userID != store.userID {
                        actions(for: person).frame(maxWidth: 600).padding(.horizontal, 24).padding(.vertical, 12)
                            .frame(maxWidth: .infinity).background(KikiPalette.background)
                    }
                }
                .navigationTitle(userID == store.userID ? "我的主页" : "个人主页").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
                .task { await reload() }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    person = nil; moments = []; destination = nil
                    dismiss()
                }
                .sheet(item: $destination) { value in
                    Group {
                        switch value {
                        case .direct(let person): KikiDirectConversationView(person: person, store: store)
                        case .report(let target): KikiSocialReportForm(target: target, store: store)
                        case .moment(let moment): KikiMomentCommentsView(moment: moment, store: store)
                        }
                    }.kikiRoomSheet()
                }
                .confirmationDialog("拉黑后将停止互相关注、隐藏双方社交内容与私信，并屏蔽对方房间语音和文字。", isPresented: $confirmsBlock, titleVisibility: .visible) {
                    Button("拉黑用户", role: .destructive) { Task { await block() } }; Button("取消", role: .cancel) { }
                }
                .confirmationDialog("取消关注 \(person?.name ?? "此用户")？", isPresented: $confirmsUnfollow, titleVisibility: .visible) {
                    Button("取消关注", role: .destructive) { Task { await follow(false) } }
                    Button("保留关注", role: .cancel) { }
                }
        }.environmentObject(store).tint(KikiPalette.lavender)
    }

    private func actions(for person: KikiPerson) -> some View {
        let following = store.isFollowing(person)
        return HStack(spacing: 10) {
            KikiPublicProfileButton(style: .message, isEnabled: !isBlocking, isBusy: false, action: {
                guard destination == nil, !isBlocking else { return }
                destination = .direct(person)
            }).frame(maxWidth: .infinity).frame(height: 48)
            KikiPublicProfileButton(style: .follow(following), isEnabled: !isBlocking && !isFollowing, isBusy: isFollowing, action: {
                if following { confirmsUnfollow = true }
                else { Task { await follow(true) } }
            }).frame(maxWidth: .infinity).frame(height: 48)
            KikiPublicProfileButton(style: .more, isEnabled: !isBlocking, isBusy: false, action: {}, report: {
                    destination = .report(.init(kind: .profile, targetID: userID, name: person.name))
            }, block: { confirmsBlock = true }).frame(width: 44, height: 48)
        }
            .accessibilityElement(children: .contain).accessibilityIdentifier("social.profile.actions")
    }

    private func count(_ value: Int, title: String) -> some View {
        VStack(spacing: 6) { Text("\(value)").font(.title3.weight(.semibold)); Text(title).font(.subheadline).foregroundStyle(KikiPalette.secondary) }
            .frame(maxWidth: .infinity)
    }
    private func reload() async {
        isLoading = true; defer { isLoading = false }
        let privacy = store.socialPrivacyRevision
        do {
            let loaded = try await store.socialPerson(userID)
            guard privacy == store.socialPrivacyRevision else { return }
            person = loaded; error = nil
            await store.gifts.refreshDecorations(userIDs: [userID])
            guard privacy == store.socialPrivacyRevision else { return }
            let page = try? await store.socialMoments(kind: .all, userID: userID)
            guard privacy == store.socialPrivacyRevision else { return }
            moments = page?.moments ?? []
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; person = nil }
    }
    private func block() async {
        guard !isBlocking else { return }; isBlocking = true; defer { isBlocking = false }
        do { try await store.setSocialBlock(userID, enabled: true); dismiss() }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func follow(_ enabled: Bool) async {
        guard let person, !isFollowing else { return }; isFollowing = true; defer { isFollowing = false }
        do { self.person = try await store.setFollowing(person, enabled: enabled); error = nil }
        catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func open(_ room: KikiRoom) async {
        do { dismiss(); try await Task.sleep(nanoseconds: 450_000_000); try await store.openRoom(room) }
        catch is CancellationError { } catch { store.notify(error.localizedDescription) }
    }
}

/// Standard UIKit actions stay interactive inside nested native sheets. A single
/// profile destination above owns all secondary presentation; buttons only emit
/// intent and never perform their own presentation or network requests.
private struct KikiPublicProfileButton: UIViewRepresentable {
    enum Style { case message, follow(Bool), more }
    let style: Style
    let isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void
    var report: () -> Void = {}
    var block: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.addTarget(context.coordinator, action: #selector(Coordinator.activate(_:)), for: .touchUpInside)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action; context.coordinator.report = report; context.coordinator.block = block
        var configuration = UIButton.Configuration.filled()
        let title: String, symbol: String, identifier: String
        let foreground: UIColor, background: UIColor
        switch style {
        case .message:
            title = "发私信"; symbol = "bubble.left.and.bubble.right"; identifier = "social.direct.open"
            foreground = UIColor(KikiPalette.lavender); background = UIColor(KikiPalette.surface)
        case .follow(let following):
            title = following ? "已关注" : "关注"; symbol = following ? "checkmark" : "plus"; identifier = "social.follow"
            foreground = following ? UIColor(KikiPalette.lavender) : .white
            background = following ? UIColor(KikiPalette.elevated) : UIColor(KikiPalette.action)
        case .more:
            title = ""; symbol = "ellipsis"; identifier = "social.profile.more"
            foreground = UIColor(KikiPalette.lavender); background = UIColor(KikiPalette.surface)
        }
        configuration.title = title
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.imagePadding = 6; configuration.showsActivityIndicator = isBusy
        configuration.baseForegroundColor = foreground; configuration.baseBackgroundColor = background
        configuration.background.cornerRadius = 14; configuration.cornerStyle = .fixed
        configuration.contentInsets = .init(top: 0, leading: title.isEmpty ? 0 : 8, bottom: 0, trailing: title.isEmpty ? 0 : 8)
        let font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var value = incoming; value.font = font; return value
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true; button.titleLabel?.minimumScaleFactor = 0.55
        button.titleLabel?.numberOfLines = 1
        button.isEnabled = isEnabled && context.environment.isEnabled
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title.isEmpty ? "更多操作" : title
        if case .more = style {
            let coordinator = context.coordinator
            button.menu = UIMenu(children: [
                UIAction(title: "举报用户", image: UIImage(systemName: "exclamationmark.bubble")) { [weak coordinator] _ in coordinator?.report() },
                UIAction(title: "拉黑用户", image: UIImage(systemName: "person.crop.circle.badge.xmark"), attributes: .destructive) { [weak coordinator] _ in coordinator?.block() }
            ])
            button.showsMenuAsPrimaryAction = true
        } else { button.menu = nil; button.showsMenuAsPrimaryAction = false }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: 48)
    }
    final class Coordinator: NSObject {
        var action: () -> Void = {}, report: () -> Void = {}, block: () -> Void = {}
        @objc func activate(_ button: UIButton) { guard button.isEnabled else { return }; action() }
    }
}

struct KikiRelationshipsView: View {
    @ObservedObject var store: KikiAppStore
    let initialKind: KikiRelationshipKind
    @Environment(\.dismiss) private var dismiss
    @State private var kind: KikiRelationshipKind
    @State private var people: [KikiPerson] = []
    @State private var nextCursor: String?
    @State private var error: String?
    @State private var isLoading = false
    @State private var generation = UUID()
    @State private var selected: KikiPersonDestination?
    init(store: KikiAppStore, initialKind: KikiRelationshipKind) {
        self.store = store; self.initialKind = initialKind; _kind = State(initialValue: initialKind)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("关系", selection: $kind) { ForEach(KikiRelationshipKind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                    if let error { KikiInlineError(message: error) { Task { await reload() } } }
                    if isLoading && people.isEmpty { ProgressView().padding(30) }
                    else if people.isEmpty && error == nil { KikiEmptyState(symbol: "person.2", title: "暂无\(kind.title)", message: "在房间里认识朋友，再来这里看看。") }
                    LazyVStack(spacing: 0) {
                        ForEach(people) { person in
                            Button { selected = .init(id: person.id) } label: { KikiPersonRow(person: person) }.buttonStyle(.plain)
                            if person.id != people.last?.id { Divider() }
                        }
                    }.padding(.horizontal, 16).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    if nextCursor != nil { Button(isLoading ? "正在加载…" : "加载更多") { Task { await loadMore() } }.disabled(isLoading) }
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea()).refreshable { await reload() }
                .navigationTitle("我的朋友").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: kind) { await reload() }
                .onChange(of: store.socialRevision) { _ in Task { await reload() } }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); people = []; nextCursor = nil; isLoading = false
                    Task { await reload() }
                }
                .sheet(item: $selected, onDismiss: { Task { await reload() } }) { KikiPublicProfileView(userID: $0.id, store: store) }
        }.tint(KikiPalette.lavender)
    }
    private func reload() async {
        let id = UUID(); generation = id; let privacy = store.socialPrivacyRevision; isLoading = true; error = nil
        defer { if generation == id { isLoading = false } }
        do {
            let result = try await store.socialRelationships(kind)
            guard generation == id, privacy == store.socialPrivacyRevision else { return }; people = result.people; nextCursor = result.nextCursor
        } catch is CancellationError { } catch { if generation == id { self.error = error.localizedDescription; people = [] } }
    }
    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }; let id = generation; let privacy = store.socialPrivacyRevision
        isLoading = true; defer { if generation == id { isLoading = false } }
        do {
            let result = try await store.socialRelationships(kind, cursor: cursor)
            guard generation == id, privacy == store.socialPrivacyRevision else { return }
            let ids = Set(people.map(\.id)); people += result.people.filter { !ids.contains($0.id) }; nextCursor = result.nextCursor
        } catch is CancellationError { } catch { if generation == id { self.error = error.localizedDescription } }
    }
}

struct KikiMessagesView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.scenePhase) private var scenePhase
    var isActive: Bool
    @ObservedObject private var push: KikiPushController
    @State private var notifications: [KikiSocialNotification] = []
    @State private var conversations: [KikiConversation] = []
    @State private var notificationState = KikiNotificationInboxState()
    @State private var pendingDeletion: KikiInboxAction?
    @State private var activeMutation: KikiInboxAction?
    @State private var retryMutation: KikiInboxAction?
    @State private var conversationCursor: String?
    @State private var retentionDays = 30
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var directPerson: KikiPerson?
    @State private var showsNotifications = false
    @State private var isDismissingForInbox = false
    @State private var generation = UUID()
    @State private var isFetching = false
    @State private var reloadRequested = false
    @State private var loadMoreRequested = false

    init(store: KikiAppStore, isActive: Bool = true) {
        self.store = store; self.isActive = isActive
        let controller = store.pushController ?? .shared
        _push = ObservedObject(wrappedValue: controller)
    }
    private var entries: [KikiInboxEntry] {
        KikiInboxEntry.merged(conversations: conversations, notifications: notifications,
                              notificationUnreadCount: store.unreadNotificationCount, notificationState: notificationState)
    }
    private var refreshIsActive: Bool {
        isActive && scenePhase == .active && store.isAuthenticated && !store.isPresentingRoom
            && directPerson == nil && !showsNotifications
    }
    var body: some View {
        NavigationStack {
            List {
                if let error {
                    KikiInlineError(message: error) { Task { if let retryMutation { await perform(retryMutation) } else { await reload() } } }
                        .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
                }
                ForEach(entries) { entry in
                    KikiInboxConversationRow(entry: entry, isWorking: isWorking(entry), canDelete: deletionThroughID(entry) != nil,
                        onOpen: {
                            switch entry.content {
                            case .notifications: showsNotifications = true
                            case .direct(let conversation): directPerson = conversation.person
                            }
                        }, onTogglePin: { Task { await perform(.init(entry: entry, kind: .pin(!entry.isPinned), accountID: store.userID, privacyRevision: store.socialPrivacyRevision)) } },
                        onDelete: {
                            if let through = deletionThroughID(entry) { pendingDeletion = .init(entry: entry, kind: .clear(through), accountID: store.userID, privacyRevision: store.socialPrivacyRevision) }
                        })
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                        .listRowBackground(entry.isPinned ? KikiPalette.purple.opacity(0.07) : KikiPalette.surface)
                        .listRowSeparatorTint(KikiPalette.elevated)
                }
                if isLoading {
                    ProgressView(hasLoaded ? "正在加载…" : "正在同步消息…").frame(maxWidth: .infinity).padding(.vertical, 20)
                        .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
                } else if conversationCursor != nil {
                    Button("加载更多聊天") { Task { await loadMore() } }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
                } else if conversations.isEmpty && error == nil {
                    VStack(spacing: 8) {
                        Text("还没有聊天").font(.subheadline.weight(.medium)).foregroundStyle(KikiPalette.secondary)
                        Text("可以从对方主页发起聊天；对方回复前最多发送 5 条。")
                            .font(.footnote).foregroundStyle(KikiPalette.muted).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.vertical, 30)
                        .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
                }
                Text("消息保留 \(retentionDays) 天").font(.footnote).foregroundStyle(KikiPalette.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
                .background(KikiPalette.background.ignoresSafeArea())
                .refreshable { await reload() }
                .navigationTitle("消息")
                .task(id: refreshIsActive) {
                    if refreshIsActive {
                        handlePushRequest(); await reload(silent: hasLoaded)
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                            if refreshIsActive { await reload(silent: true) }
                        }
                    } else { generation = UUID(); isLoading = false }
                }
                .sheet(isPresented: $showsNotifications, onDismiss: localSheetDidDismiss) { KikiNotificationInboxView(store: store) }
                .sheet(item: $directPerson, onDismiss: localSheetDidDismiss) { KikiDirectConversationView(person: $0, store: store) }
                .onChange(of: push.inboxRequest) { _ in handlePushRequest() }
                .onChange(of: push.pendingInboxRequest) { _ in handlePushRequest() }
                .onChange(of: push.inboxPresentationReady) { _ in handlePushRequest() }
                .alert("删除“\(pendingDeletion?.entry.name ?? "")”？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
                    Button("删除", role: .destructive) {
                        guard let deletion = pendingDeletion else { return }
                        pendingDeletion = nil
                        Task { await perform(deletion) }
                    }
                    Button("取消", role: .cancel) { pendingDeletion = nil }
                } message: {
                    Text("将移除此会话并清空你这一侧的记录，对方不受影响。新消息到来后会重新显示。")
                }
                .onChange(of: store.socialRevision) { _ in if refreshIsActive { Task { await reload(silent: true) } } }
                .onChange(of: store.directContentRevision) { _ in if refreshIsActive { Task { await reload(silent: true) } } }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); notifications = []; conversations = []; conversationCursor = nil
                    notificationState = .init(); pendingDeletion = nil; activeMutation = nil; retryMutation = nil; error = nil
                    isLoading = false; hasLoaded = false; directPerson = nil; showsNotifications = false
                    isDismissingForInbox = false
                    if isActive && store.isAuthenticated { Task { await reload() } }
                }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private func deletionThroughID(_ entry: KikiInboxEntry) -> String? {
        switch entry.content {
        case .notifications: return notificationState.throughNotificationID
        case .direct(let conversation): return conversation.lastMessage?.id
        }
    }
    private func isWorking(_ entry: KikiInboxEntry) -> Bool {
        if activeMutation != nil || retryMutation != nil { return true }
        if case .direct(let conversation) = entry.content { return store.pendingDirectMessages[conversation.person.id]?.isSending == true }
        return false
    }
    private func perform(_ action: KikiInboxAction) async {
        guard activeMutation == nil, retryMutation == nil || retryMutation?.requestID == action.requestID,
              store.isAuthenticated, store.userID == action.accountID, store.socialPrivacyRevision == action.privacyRevision else { return }
        let privacy = store.socialPrivacyRevision
        generation = UUID(); isLoading = false; activeMutation = action; retryMutation = nil; error = nil
        do {
            switch action.kind {
            case .pin(let pinned): try await store.setInboxPinned(action.entry, pinned: pinned, requestID: action.requestID)
            case .clear(let through): try await store.clearInboxEntry(action.entry, throughID: through, requestID: action.requestID)
            }
            guard privacy == store.socialPrivacyRevision, store.isAuthenticated else { return }
            activeMutation = nil
            await reload()
        } catch is CancellationError {
            if privacy == store.socialPrivacyRevision { activeMutation = nil }
        } catch {
            guard privacy == store.socialPrivacyRevision, store.isAuthenticated else { return }
            activeMutation = nil
            guard !Task.isCancelled else { return }
            if KikiSocialMutation.needsSameIDRetry(error) { retryMutation = action }
            self.error = error.localizedDescription
        }
    }
    private func handlePushRequest() {
        guard isActive, store.isAuthenticated, !isDismissingForInbox,
              let request = push.pendingInboxRequest, push.inboxPresentationReady else { return }
        if directPerson != nil { isDismissingForInbox = true; directPerson = nil; return }
        if showsNotifications { isDismissingForInbox = true; showsNotifications = false; return }
        guard push.consumeInboxRequest(request) else { return }
        showsNotifications = true
    }
    private func localSheetDidDismiss() {
        isDismissingForInbox = false
        handlePushRequest()
        Task { await reload() }
    }
    private func isCurrent(_ id: UUID, privacy: Int) -> Bool {
        !Task.isCancelled && generation == id && privacy == store.socialPrivacyRevision && store.isAuthenticated
    }
    private func reload(silent: Bool = false) async {
        guard store.isAuthenticated, activeMutation == nil, !Task.isCancelled else { return }
        guard !isFetching else { reloadRequested = true; return }
        isFetching = true
        let id = UUID(); generation = id; let privacy = store.socialPrivacyRevision
        if !silent || !hasLoaded { isLoading = true }
        defer {
            if generation == id { isLoading = false }
            finishFetch()
        }
        do {
            let notices = try await store.socialNotifications()
            let direct = try await store.socialConversations()
            guard isCurrent(id, privacy: privacy) else { return }
            if notifications != notices.notifications { notifications = notices.notifications }
            if retentionDays != notices.retentionDays { retentionDays = notices.retentionDays }
            if notificationState != notices.inboxState { notificationState = notices.inboxState }
            if conversations != direct.conversations { conversations = direct.conversations }
            if conversationCursor != direct.nextCursor { conversationCursor = direct.nextCursor }
            if !hasLoaded { hasLoaded = true }
            if retryMutation == nil { error = nil }
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func loadMore() async {
        guard !Task.isCancelled, activeMutation == nil, retryMutation == nil else { return }
        guard !isFetching else { loadMoreRequested = true; return }
        guard !isLoading, let cursor = conversationCursor else { return }
        let id = generation; let privacy = store.socialPrivacyRevision; isLoading = true; isFetching = true
        defer { if generation == id { isLoading = false }; finishFetch() }
        do {
            let page = try await store.socialConversations(cursor: cursor)
            guard isCurrent(id, privacy: privacy) else { return }
            let ids = Set(conversations.map(\.id)); conversations += page.conversations.filter { !ids.contains($0.id) }
            conversationCursor = page.nextCursor; error = nil
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func finishFetch() {
        isFetching = false
        guard refreshIsActive else { reloadRequested = false; loadMoreRequested = false; return }
        if reloadRequested {
            reloadRequested = false
            Task { await reload(silent: true) }
        } else if loadMoreRequested {
            loadMoreRequested = false
            Task { await loadMore() }
        }
    }
}

private struct KikiInboxAction {
    enum Kind { case pin(Bool), clear(String) }
    let entry: KikiInboxEntry
    let kind: Kind
    let accountID: String
    let privacyRevision: Int
    let requestID = UUID()
}

/// The aggregate inbox row opens this page. Reading notifications never marks
/// private conversations read; those acknowledge only messages actually viewed.
struct KikiNotificationInboxView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var notifications: [KikiSocialNotification] = []
    @State private var clearedThroughSeq = 0
    @State private var nextCursor: String?
    @State private var retentionDays = 30
    @State private var isLoading = false
    @State private var isMarking = false
    @State private var error: String?
    @State private var selected: KikiPersonDestination?
    @State private var selectedMoment: KikiMoment?
    @State private var showsSafety = false
    @State private var showsReports = false
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            List {
                Button { showsSafety = true } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "shield.lefthalf.filled").foregroundStyle(KikiPalette.purple)
                            .frame(width: 42, height: 42).background(KikiPalette.purple.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("社区安全与运营通知").font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
                            Text("账号状态、处理结果与黑名单").font(.caption).foregroundStyle(KikiPalette.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(KikiPalette.muted)
                    }.padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain).listRowBackground(KikiPalette.surface)
                    .accessibilityIdentifier("messages.communitySafety")
                if let error { KikiInlineError(message: error) { Task { await reload() } }.listRowBackground(KikiPalette.background) }
                if isLoading && notifications.isEmpty { ProgressView("正在同步通知…").frame(maxWidth: .infinity).padding(.vertical, 25).listRowBackground(KikiPalette.background) }
                else if notifications.isEmpty && error == nil {
                    KikiEmptyState(symbol: "bell", title: "暂无互动通知", message: "新的关注、点赞和评论会显示在这里。")
                        .listRowBackground(KikiPalette.background).listRowSeparator(.hidden)
                }
                ForEach(notifications) { notice in
                    Button { Task { await open(notice) } } label: { notificationRow(notice) }
                        .buttonStyle(.plain).listRowBackground(KikiPalette.surface)
                        .accessibilityIdentifier("messages.notice." + notice.id)
                }
                if nextCursor != nil { Button(isLoading ? "正在加载…" : "加载更多通知") { Task { await loadMore() } }.disabled(isLoading).frame(maxWidth: .infinity) }
                Section {
                    Button("我的社交举报") { showsReports = true }
                } footer: { Text("通知最多保留 \(retentionDays) 天。这里的“全部已读”只处理互动通知。") }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
                .background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("通知").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("全部已读") { Task { await markAll() } }.disabled(isMarking || store.unreadNotificationCount == 0)
                            .accessibilityLabel("互动通知全部已读")
                    }
                }
                .task { await reload() }
                .refreshable { await reload() }
                .sheet(item: $selected) { KikiPublicProfileView(userID: $0.id, store: store) }
                .sheet(item: $selectedMoment) { KikiMomentCommentsView(moment: $0, store: store) }
                .sheet(isPresented: $showsSafety) { KikiSafetyCenter(rtc: KikiRTCService.shared) }
                .sheet(isPresented: $showsReports) { KikiSocialReportsView(store: store) }
                .onChange(of: store.notificationHistoryRevision) { _, _ in
                    generation = UUID(); notifications = []; nextCursor = nil; isLoading = false
                    Task { await reload() }
                }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); notifications = []; nextCursor = nil; isLoading = false; isMarking = false; clearedThroughSeq = 0
                    selected = nil; selectedMoment = nil; showsSafety = false; showsReports = false
                    if store.isAuthenticated { Task { await reload() } }
                }
                .onDisappear { generation = UUID(); isLoading = false }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private func notificationRow(_ notice: KikiSocialNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let actor = notice.actor { KikiAvatar(index: actor.avatarIndex, size: 42, customURL: actor.avatarURL) }
            else { Image(systemName: "bell").frame(width: 42, height: 42).background(KikiPalette.elevated, in: Circle()) }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(notice.title).font(.subheadline.weight(.semibold)); Spacer()
                    if notice.isUnread { Circle().fill(KikiPalette.purple).frame(width: 7, height: 7).accessibilityLabel("未读") }
                }
                Text(notice.text).font(.subheadline).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.leading)
                Text(Date(timeIntervalSince1970: notice.createdAt), format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(KikiPalette.muted)
            }
        }.padding(.vertical, 10).contentShape(Rectangle())
    }
    private func isCurrent(_ id: UUID, privacy: Int) -> Bool {
        !Task.isCancelled && generation == id && privacy == store.socialPrivacyRevision && store.isAuthenticated
    }
    private func reload() async {
        guard store.isAuthenticated else { return }
        let id = UUID(); generation = id; let privacy = store.socialPrivacyRevision; isLoading = true
        defer { if generation == id { isLoading = false } }
        do {
            let page = try await store.socialNotifications()
            guard isCurrent(id, privacy: privacy) else { return }
            clearedThroughSeq = max(clearedThroughSeq, page.inboxState.clearedThroughSeq)
            notifications = page.notifications.filter { clearedThroughSeq == 0 || $0.seq > clearedThroughSeq }; nextCursor = page.nextCursor; retentionDays = page.retentionDays; error = nil
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let id = generation; let privacy = store.socialPrivacyRevision; isLoading = true
        defer { if generation == id { isLoading = false } }
        do {
            let page = try await store.socialNotifications(cursor: cursor)
            guard isCurrent(id, privacy: privacy) else { return }
            clearedThroughSeq = max(clearedThroughSeq, page.inboxState.clearedThroughSeq)
            notifications = notifications.filter { clearedThroughSeq == 0 || $0.seq > clearedThroughSeq }
            let ids = Set(notifications.map(\.id)); notifications += page.notifications.filter { !ids.contains($0.id) && (clearedThroughSeq == 0 || $0.seq > clearedThroughSeq) }; nextCursor = page.nextCursor; error = nil
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func markAll() async {
        guard !isMarking else { return }
        let id = generation; let privacy = store.socialPrivacyRevision; isMarking = true
        defer { if privacy == store.socialPrivacyRevision { isMarking = false } }
        do { try await store.readNotifications(all: true); guard isCurrent(id, privacy: privacy) else { return }; await reload() }
        catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func open(_ notice: KikiSocialNotification) async {
        let id = generation; let privacy = store.socialPrivacyRevision
        do {
            if notice.isUnread { try await store.readNotifications(ids: [notice.id]) }
            guard isCurrent(id, privacy: privacy) else { return }
            if let momentID = notice.momentID {
                let moment = try await store.socialMoment(momentID)
                guard isCurrent(id, privacy: privacy) else { return }; selectedMoment = moment
            } else if let actor = notice.actor { selected = .init(id: actor.id) }
            else { showsSafety = true }
            await reload()
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
}

struct KikiRoomRecordView: View {
    let room: KikiRoom
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var person: KikiPersonDestination?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    KikiRoomCard(room: room)
                    Label("本次语聊已结束", systemImage: "clock").font(.headline)
                    Text("这条记录保留了你与这个房间的相遇。可以查看房主主页，关注下一次语聊。")
                        .font(.body).foregroundStyle(KikiPalette.secondary)
                    if room.createdAt > 0 {
                        LabeledContent("创建时间") { Text(Date(timeIntervalSince1970: Double(room.createdAt)), format: .dateTime.year().month().day().hour().minute()) }
                            .font(.subheadline)
                    }
                    Button { person = .init(id: room.hostID) } label: { Label("查看房主主页", systemImage: "person.crop.circle") }
                }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("房间记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .sheet(item: $person) { KikiPublicProfileView(userID: $0.id, store: store) }
        }.environmentObject(store).tint(KikiPalette.lavender)
    }
}

struct KikiSocialReportForm: View {
    let target: KikiSocialReportTarget
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var reason = KikiSocialReportReason.harassment
    @State private var details = ""
    @State private var requestID = UUID()
    @State private var attempted = false
    @State private var isSending = false
    @State private var error: String?
    @State private var receipt: KikiSocialReportReceipt.Report?
    var body: some View {
        NavigationStack {
            Form {
                Section("举报对象") { Text(target.name) }
                if let receipt {
                    Section("已提交") {
                        Text("运营会核查这条举报，提交成功不表示已认定违规。")
                        LabeledContent("举报编号", value: receipt.id).font(.caption).textSelection(.enabled)
                    }
                } else {
                    Section("问题类型") { Picker("原因", selection: $reason) { ForEach(KikiSocialReportReason.allCases) { Text($0.title).tag($0) } }.pickerStyle(.inline).labelsHidden().disabled(attempted) }
                    Section("补充说明（可选）") {
                        TextField("描述发生了什么，请勿填写密码或身份证信息。", text: $details, axis: .vertical).lineLimit(4...8)
                            .onChange(of: details) { if $0.count > 500 { details = String($0.prefix(500)) } }.disabled(attempted)
                    }
                    if let error { Section { Text(error).foregroundStyle(KikiPalette.lavender) } }
                    Section { Button(isSending ? "正在提交…" : (attempted ? "重试提交" : "提交举报")) { Task { await send() } }.disabled(isSending) }
                }
            }.navigationTitle("举报").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(isSending) } }
        }.tint(KikiPalette.lavender).interactiveDismissDisabled(isSending)
    }
    private func send() async {
        guard !isSending else { return }; attempted = true; isSending = true; defer { isSending = false }
        do { receipt = try await store.submitSocialReport(target, reason: reason, details: details.trimmingCharacters(in: .whitespacesAndNewlines), requestID: requestID).report; error = nil }
        catch is CancellationError { }
        catch {
            self.error = error.localizedDescription
            if !KikiSocialMutation.needsSameIDRetry(error) { attempted = false; requestID = UUID() }
        }
    }
}

struct KikiSocialReportsView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var reports: [KikiSocialReportReceipt.Report] = []
    @State private var retentionDays = 30
    @State private var error: String?
    @State private var isLoading = false
    var body: some View {
        NavigationStack {
            List {
                if isLoading { ProgressView() }
                if let error { Section { Text(error); Button("重试") { Task { await reload() } } } }
                if reports.isEmpty && !isLoading && error == nil { Text("暂无社交举报记录").foregroundStyle(.secondary) }
                ForEach(reports) { report in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(report.targetType == "profile" ? "用户举报" : (report.targetType == "direct_message" ? "私信举报" : "动态与评论举报")); Spacer(); Text(report.status == "pending" ? "待处理" : "已处理").foregroundStyle(.secondary) }
                        Text(report.id).font(.caption).textSelection(.enabled)
                        Text(Date(timeIntervalSince1970: report.createdAt), format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { Text("显示最近 \(retentionDays) 天的可用记录。房间举报另在社区安全中查看。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("我的社交举报").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await reload() }.refreshable { await reload() }
        }.tint(KikiPalette.lavender)
    }
    private func reload() async {
        guard !isLoading else { return }; isLoading = true; defer { isLoading = false }
        do { let result = try await store.socialReports(); reports = result.reports; retentionDays = result.retentionDays; error = nil }
        catch is CancellationError { } catch { self.error = error.localizedDescription; reports = [] }
    }
}
