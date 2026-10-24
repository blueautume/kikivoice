import SwiftUI

struct KikiEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(KikiPalette.lavender)
            Text(title).font(.headline).foregroundStyle(KikiPalette.text)
            if !message.isEmpty { Text(message).font(.subheadline).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center) }
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
    var leadingAction: AnyView? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var person: KikiPerson?
    @State private var error: String?
    @State private var isLoading = false
    @State private var isFollowing = false
    @State private var reportTarget: KikiSocialReportTarget?
    @State private var confirmsBlock = false
    @State private var isBlocking = false
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
                            KikiAvatar(index: person.avatarIndex, size: 88, customURL: person.avatarURL)
                            Text(person.name).font(.title2.weight(.semibold)).foregroundStyle(KikiPalette.text)
                            Text(person.bio.isEmpty ? "这个人很安静，还没有留下简介。" : person.bio)
                                .font(.body).foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center)
                            Text(person.publicID).font(.caption.monospaced()).foregroundStyle(KikiPalette.muted).textSelection(.enabled)
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
                    if let leadingAction {
                        if #available(iOS 26.0, *) {
                            ToolbarItem(placement: .topBarLeading) { leadingAction }
                                .sharedBackgroundVisibility(.hidden)
                        } else {
                            ToolbarItem(placement: .topBarLeading) { leadingAction }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
                .task { await reload() }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    person = nil; reportTarget = nil
                    dismiss()
                }
                .sheet(item: $reportTarget) { target in
                    KikiSocialReportForm(target: target, store: store).kikiRoomSheet()
                }
                .confirmationDialog("拉黑后将停止互相关注、隐藏双方社交内容与私信，并屏蔽对方房间语音和文字。", isPresented: $confirmsBlock, titleVisibility: .visible) {
                    Button("拉黑用户", role: .destructive) { Task { await block() } }; Button("取消", role: .cancel) { }
                }

        }.environmentObject(store).tint(KikiPalette.lavender)
    }

    private func actions(for person: KikiPerson) -> some View {
        let following = store.isFollowing(person)
        return HStack(spacing: 10) {
            KikiPublicProfileButton(style: .message, isEnabled: !isBlocking, isBusy: false, action: {
                guard reportTarget == nil, !isBlocking else { return }
                store.requestDirectConversation(person)
            }).frame(maxWidth: .infinity).frame(height: 48)
            KikiPublicProfileButton(style: .follow(following), isEnabled: !isBlocking && !isFollowing, isBusy: isFollowing, action: {
                Task { await follow(!following) }
            }).frame(maxWidth: .infinity).frame(height: 48)
            KikiPublicProfileButton(style: .more, isEnabled: !isBlocking, isBusy: false, action: {}, report: {
                    reportTarget = .init(kind: .profile, targetID: userID, name: person.name)
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
    enum Style { case message, follow(Bool), more, relationship(String, Bool, String) }
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
        case .relationship(let label, let prominent, let userID):
            title = label; symbol = ""; identifier = "relationships.action." + userID
            foreground = prominent ? .white : UIColor(KikiPalette.purple)
            background = prominent ? UIColor(KikiPalette.action) : UIColor(KikiPalette.purple.opacity(0.1))
        case .more:
            title = ""; symbol = "ellipsis"; identifier = "social.profile.more"
            foreground = UIColor(KikiPalette.lavender); background = UIColor(KikiPalette.surface)
        }
        configuration.title = title
        configuration.image = symbol.isEmpty ? nil : UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.imagePadding = 6; configuration.showsActivityIndicator = isBusy
        configuration.baseForegroundColor = foreground; configuration.baseBackgroundColor = background
        configuration.background.cornerRadius = 14; configuration.cornerStyle = .fixed
        configuration.contentInsets = .init(top: 0, leading: title.isEmpty ? 0 : 8, bottom: 0, trailing: title.isEmpty ? 0 : 8)
        let font: UIFont
        switch style {
        case .follow, .relationship:
            // Shrink the visible control while preserving its native tap area.
            configuration.background.backgroundInsets = .init(top: 5, leading: 0, bottom: 5, trailing: 0)
            configuration.background.cornerRadius = 12
            configuration.titleLineBreakMode = .byClipping
            configuration.image = symbol.isEmpty ? nil : UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
            font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .semibold), compatibleWith: button.traitCollection)
            if case .relationship = style { configuration.cornerStyle = .capsule }
        case .message, .more:
            font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        }
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
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width, height: max(44, proposal.height ?? 48))
    }
    final class Coordinator: NSObject {
        var action: () -> Void = {}, report: () -> Void = {}, block: () -> Void = {}
        @objc func activate(_ button: UIButton) { guard button.isEnabled else { return }; action() }
    }
}

struct KikiRelationshipsView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind: KikiRelationshipKind
    @State private var people: [KikiPerson] = []
    @State private var nextCursor: String?
    // Keep loaded following rows for this sheet's lifetime so an unfollow can
    // be reversed. A new sheet fetches current membership again.
    @State private var followingSnapshot: KikiPeoplePage?
    @State private var error: String?
    @State private var isLoading = false
    @State private var generation = UUID()
    @State private var selected: KikiPersonDestination?
    @State private var changingPeople: Set<String> = []

    init(store: KikiAppStore, initialKind: KikiRelationshipKind) {
        self.store = store; _kind = State(initialValue: initialKind)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("关系", selection: $kind) {
                        ForEach(KikiRelationshipKind.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("relationships.tabs")
                    if let error { KikiInlineError(message: error) { Task { await reload() } } }
                    if isLoading && people.isEmpty { ProgressView().padding(30) }
                    else if people.isEmpty && error == nil {
                        KikiEmptyState(symbol: "person.2", title: "暂无\(kind.title)", message: "")
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(people) { person in
                            HStack(spacing: 12) {
                                Button { selected = .init(id: person.id) } label: {
                                    KikiPersonRow(person: person).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("relationships.person." + person.id)
                                relationshipAction(for: person)
                            }
                            if person.id != people.last?.id { Divider() }
                        }
                    }.padding(.horizontal, 16).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    if nextCursor != nil {
                        Button(isLoading ? "正在加载…" : "加载更多") { Task { await loadMore() } }.disabled(isLoading)
                    }
                }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea()).refreshable { await reload() }
                .navigationTitle("关注 / 粉丝").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task(id: kind) { await reload() }
                .onChange(of: store.socialRevision) { _ in Task { await reload() } }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); people = []; nextCursor = nil; followingSnapshot = nil
                    isLoading = false; changingPeople = []
                    Task { await reload() }
                }
                .sheet(item: $selected, onDismiss: { Task { await reload() } }) {
                    KikiPublicProfileView(userID: $0.id, store: store)
                }
        }.tint(KikiPalette.lavender)
    }

    private func relationshipAction(for person: KikiPerson) -> some View {
        let following = store.isFollowing(person)
        let label = kind == .mutual ? "聊天" : (following ? (person.followsYou ? "互相关注" : "已关注") : "关注")
        return KikiPublicProfileButton(style: .relationship(label, kind != .mutual && !following, person.id),
            isEnabled: !changingPeople.contains(person.id), isBusy: changingPeople.contains(person.id), action: {
                if kind == .mutual { store.requestDirectConversation(person) }
                else { Task { await setFollowing(person, enabled: !following) } }
            })
            .frame(width: 88, height: 44)
            .disabled(changingPeople.contains(person.id))
    }

    private func setFollowing(_ person: KikiPerson, enabled: Bool) async {
        guard !changingPeople.contains(person.id) else { return }
        let privacy = store.socialPrivacyRevision, account = store.userID, requestedKind = kind
        changingPeople.insert(person.id)
        defer { if privacy == store.socialPrivacyRevision, account == store.userID { changingPeople.remove(person.id) } }
        do {
            let updated = try await store.setFollowing(person, enabled: enabled)
            guard privacy == store.socialPrivacyRevision, account == store.userID else { return }
            if let snapshot = followingSnapshot {
                followingSnapshot = .init(people: snapshot.people.map { $0.id == updated.id ? updated : $0 },
                                          nextCursor: snapshot.nextCursor)
            }
            if kind == requestedKind {
                people = people.compactMap { current in
                    guard current.id == updated.id else { return current }
                    if kind == .mutual && !updated.mutual { return nil }
                    return updated
                }
            }
            error = nil
        } catch is CancellationError { }
        catch { if privacy == store.socialPrivacyRevision, account == store.userID { self.error = error.localizedDescription } }
    }

    private func reload() async {
        let id = UUID(); generation = id
        let privacy = store.socialPrivacyRevision, revision = store.socialRevision, requestedKind = kind
        if requestedKind == .following, let snapshot = followingSnapshot {
            people = snapshot.people; nextCursor = snapshot.nextCursor
            isLoading = false; error = nil
            return
        }
        isLoading = true; error = nil
        defer { if generation == id { isLoading = false } }
        do {
            let result = try await store.socialRelationships(requestedKind)
            try Task.checkCancellation()
            guard generation == id, privacy == store.socialPrivacyRevision, revision == store.socialRevision,
                  kind == requestedKind else { return }
            people = result.people; nextCursor = result.nextCursor
            if requestedKind == .following { followingSnapshot = result }
        } catch is CancellationError { }
        catch { if generation == id { self.error = error.localizedDescription; people = [] } }
    }

    private func loadMore() async {
        guard !isLoading, let cursor = nextCursor else { return }
        let id = generation, privacy = store.socialPrivacyRevision, revision = store.socialRevision, requestedKind = kind
        isLoading = true
        defer { if generation == id { isLoading = false } }
        do {
            let result = try await store.socialRelationships(requestedKind, cursor: cursor)
            try Task.checkCancellation()
            guard generation == id, privacy == store.socialPrivacyRevision, revision == store.socialRevision,
                  kind == requestedKind else { return }
            let ids = Set(people.map(\.id))
            people += result.people.filter { !ids.contains($0.id) }; nextCursor = result.nextCursor
            if requestedKind == .following { followingSnapshot = .init(people: people, nextCursor: nextCursor) }
        } catch is CancellationError { }
        catch { if generation == id { self.error = error.localizedDescription } }
    }
}

struct KikiMessagesView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.scenePhase) private var scenePhase
    var isActive: Bool
    @ObservedObject private var push: KikiPushController
    @State private var entries: [KikiInboxEntry] = []
    @State private var nextCursor: String?
    @State private var pendingDeletion: KikiInboxAction?
    @State private var activeMutation: KikiInboxAction?
    @State private var retryMutation: KikiInboxAction?
    @State private var pendingBulkDeletion: KikiInboxBulkAction?
    @State private var activeBulk: KikiInboxBulkAction?
    @State private var retryBulk: KikiInboxBulkAction?
    @State private var isPreparingBulk = false
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var selectedPerson: KikiPersonDestination?
    @State private var showsSafety = false
    @State private var isDismissingForInbox = false
    @State private var generation = UUID()
    @State private var navigationRequestID = UUID()
    @State private var isFetching = false
    @State private var reloadRequested = false
    @State private var loadMoreRequested = false

    init(store: KikiAppStore, isActive: Bool = true) {
        self.store = store; self.isActive = isActive
        _push = ObservedObject(wrappedValue: store.pushController ?? .shared)
    }
    private var isMutating: Bool { activeMutation != nil || activeBulk != nil || isPreparingBulk }
    private var hasRetry: Bool { retryMutation != nil || retryBulk != nil }
    private var refreshIsActive: Bool {
        isActive && scenePhase == .active && store.isAuthenticated && !store.isPresentingRoom
            && store.directConversationPath.isEmpty && selectedPerson == nil && !showsSafety
    }
    private var showsDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil || pendingBulkDeletion != nil }, set: { if !$0 { pendingDeletion = nil; pendingBulkDeletion = nil } })
    }
    private var deletionTitle: String {
        if pendingBulkDeletion != nil { return "删除全部消息？" }
        guard let entry = pendingDeletion?.entry else { return "删除消息？" }
        switch entry.content {
        case .notification: return "删除这条提醒？"
        case .direct: return "删除“\(entry.name)”？"
        }
    }
    private var deletionMessage: String {
        if pendingBulkDeletion != nil {
            return "清空你这一侧已有的私聊记录和互动提醒，对方不受影响。确认期间收到的新消息会保留。"
        }
        if let entry = pendingDeletion?.entry, case .notification = entry.content {
            return "仅删除这条提醒，其他提醒和私聊记录不受影响。"
        }
        return "将移除此会话并清空你这一侧的记录，对方不受影响。新消息到来后会重新显示。"
    }
    var body: some View {
        NavigationStack(path: $store.directConversationPath) {
            messageList
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationDestination(for: KikiDirectConversationRoute.self) { route in
                    KikiDirectConversationView(person: route.person, store: store, isActive: isActive)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("全部已读", systemImage: "checkmark.bubble") { Task { await prepareBulk(clear: false) } }
                                .disabled(store.unreadMessageCount == 0)
                            Button("全部删除", systemImage: "trash", role: .destructive) { Task { await prepareBulk(clear: true) } }
                        } label: {
                            if isPreparingBulk || activeBulk != nil { ProgressView() }
                            else { Image(systemName: "ellipsis").font(.system(size: 20)).frame(width: 24, height: 24) }
                        }
                        .accessibilityLabel("消息操作").accessibilityIdentifier("messages.actions")
                        .disabled(!hasLoaded || isMutating || hasRetry)
                    }
                }
                .task(id: refreshIsActive) {
                    if refreshIsActive {
                        handlePushRequest(); await reload(silent: hasLoaded)
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                            if refreshIsActive { await reload(silent: true) }
                        }
                    } else {
                        generation = UUID(); isLoading = false
                        if !isActive || scenePhase != .active || store.isPresentingRoom { navigationRequestID = UUID() }
                    }
                }
                .sheet(item: $selectedPerson, onDismiss: localSheetDidDismiss) { KikiPublicProfileView(userID: $0.id, store: store) }
                .sheet(isPresented: $showsSafety, onDismiss: localSheetDidDismiss) { KikiSafetyCenter(rtc: .shared) }
                .onChange(of: push.inboxRequest) { _ in handlePushRequest() }
                .onChange(of: push.pendingInboxRequest) { _ in handlePushRequest() }
                .alert(deletionTitle, isPresented: showsDeletion) {
                    Button("删除", role: .destructive) {
                        let bulk = pendingBulkDeletion; let single = pendingDeletion
                        pendingBulkDeletion = nil; pendingDeletion = nil
                        if let bulk { Task { await performBulk(bulk) } }
                        else if let single { Task { await perform(single) } }
                    }
                    Button("取消", role: .cancel) { pendingDeletion = nil; pendingBulkDeletion = nil }
                } message: {
                    Text(deletionMessage)
                }
                .onChange(of: store.socialRevision) { _ in if refreshIsActive { Task { await reload(silent: true) } } }
                .onChange(of: store.directContentRevision) { _ in if refreshIsActive { Task { await reload(silent: true) } } }
                .onChange(of: store.notificationHistoryRevision) { _ in if refreshIsActive { Task { await reload(silent: true) } } }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); navigationRequestID = UUID(); entries = []; nextCursor = nil
                    pendingDeletion = nil; activeMutation = nil; retryMutation = nil
                    pendingBulkDeletion = nil; activeBulk = nil; retryBulk = nil; isPreparingBulk = false; error = nil
                    isLoading = false; hasLoaded = false; selectedPerson = nil; showsSafety = false
                    isDismissingForInbox = false
                    if isActive && store.isAuthenticated { Task { await reload() } }
                }
                .onDisappear { navigationRequestID = UUID() }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private var messageList: some View {
        List {
            if let error {
                KikiInlineError(message: error) {
                    Task {
                        if let retryBulk { await performBulk(retryBulk) }
                        else if let retryMutation { await perform(retryMutation) }
                        else { await reload() }
                    }
                }.listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
            }
            ForEach(entries) { entry in
                KikiInboxConversationRow(entry: entry, isWorking: isWorking(entry), canDelete: deletionThroughID(entry) != nil,
                    canPin: isDirect(entry), onOpen: { Task { await open(entry) } },
                    onTogglePin: { Task { await perform(.init(entry: entry, kind: .pin(!entry.isPinned), accountID: store.userID, privacyRevision: store.socialPrivacyRevision)) } },
                    onDelete: {
                        if let through = deletionThroughID(entry) { pendingDeletion = .init(entry: entry, kind: .clear(through), accountID: store.userID, privacyRevision: store.socialPrivacyRevision) }
                    })
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(KikiPalette.elevated)
            }
            if isLoading {
                ProgressView(hasLoaded ? "正在加载…" : "正在同步消息…").frame(maxWidth: .infinity).padding(.vertical, 20)
                    .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
            } else if nextCursor != nil {
                Button("加载更多") { Task { await loadMore() } }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    .listRowSeparator(.hidden).listRowBackground(KikiPalette.background)
            }
        }.listStyle(.plain).scrollContentBackground(.hidden)
            .kikiTransparentTopScrollEdge()
            .frame(maxWidth: 760).frame(maxWidth: .infinity)
            .background(KikiPalette.background.ignoresSafeArea())
            .overlay {
                if hasLoaded && entries.isEmpty && !isLoading && error == nil && nextCursor == nil {
                    KikiEmptyState(symbol: "bubble.left.and.bubble.right", title: "这里什么都没有", message: "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("messages.empty")
                }
            }
            .refreshable { await reload() }
    }
    private func isDirect(_ entry: KikiInboxEntry) -> Bool {
        if case .direct = entry.content { return true }; return false
    }
    private func deletionThroughID(_ entry: KikiInboxEntry) -> String? {
        switch entry.content {
        case .notification(let notice): return notice.id
        case .direct(let conversation): return conversation.lastMessage?.id
        }
    }
    private func isWorking(_ entry: KikiInboxEntry) -> Bool {
        if isMutating || hasRetry { return true }
        if case .direct(let conversation) = entry.content { return store.pendingDirectMessages[conversation.person.id]?.isSending == true }
        return false
    }
    private func open(_ entry: KikiInboxEntry) async {
        let id = UUID(); navigationRequestID = id
        switch entry.content {
        case .direct(let conversation): store.requestDirectConversation(conversation.person)
        case .notification(let notice):
            let privacy = store.socialPrivacyRevision; let account = store.userID
            do {
                if notice.isUnread { try await store.readNotifications(ids: [notice.id]) }
                guard canNavigate(id, privacy: privacy, account: account) else { return }
                if notice.kind == "room_started", let roomID = notice.roomID {
                    store.requestRoomNotification(roomID: roomID, notificationID: notice.id)
                } else if let actor = notice.actor { selectedPerson = .init(id: actor.id) }
                else { showsSafety = true }
            } catch is CancellationError { }
            catch { if canNavigate(id, privacy: privacy, account: account) { self.error = error.localizedDescription } }
        }
    }
    private func canNavigate(_ id: UUID, privacy: Int, account: String) -> Bool {
        !Task.isCancelled && navigationRequestID == id && privacy == store.socialPrivacyRevision
            && account == store.userID && store.isAuthenticated && isActive && scenePhase == .active && !store.isPresentingRoom
    }
    private func prepareBulk(clear: Bool) async {
        guard !isMutating, !hasRetry, store.isAuthenticated else { return }
        let account = store.userID; let privacy = store.socialPrivacyRevision
        isPreparingBulk = true; error = nil
        defer { if privacy == store.socialPrivacyRevision { isPreparingBulk = false } }
        do {
            let snapshot = try await store.inboxSnapshot()
            guard privacy == store.socialPrivacyRevision, account == store.userID, store.isAuthenticated else { return }
            let action = KikiInboxBulkAction(snapshot: snapshot, clear: clear, accountID: account, privacyRevision: privacy)
            if clear { pendingBulkDeletion = action }
            else { await performBulk(action) }
        } catch is CancellationError { }
        catch { if privacy == store.socialPrivacyRevision { self.error = error.localizedDescription } }
    }
    private func performBulk(_ action: KikiInboxBulkAction) async {
        guard activeMutation == nil, activeBulk == nil, retryBulk == nil || retryBulk?.requestID == action.requestID,
              store.isAuthenticated, store.userID == action.accountID, store.socialPrivacyRevision == action.privacyRevision else { return }
        generation = UUID(); isLoading = false; activeBulk = action; retryBulk = nil; error = nil
        do {
            try await store.mutateInbox(snapshot: action.snapshot, clear: action.clear, requestID: action.requestID)
            guard action.privacyRevision == store.socialPrivacyRevision, store.userID == action.accountID, store.isAuthenticated else { return }
            activeBulk = nil
            await reload()
        } catch {
            guard action.privacyRevision == store.socialPrivacyRevision, store.userID == action.accountID, store.isAuthenticated else { return }
            activeBulk = nil
            if error is CancellationError || KikiSocialMutation.needsSameIDRetry(error) { retryBulk = action }
            self.error = error is CancellationError ? "操作结果尚未确认，请重试。" : error.localizedDescription
        }
    }
    private func perform(_ action: KikiInboxAction) async {
        guard !isMutating, retryMutation == nil || retryMutation?.requestID == action.requestID,
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
        } catch {
            guard privacy == store.socialPrivacyRevision, store.isAuthenticated else { return }
            activeMutation = nil
            if error is CancellationError || KikiSocialMutation.needsSameIDRetry(error) { retryMutation = action }
            self.error = error is CancellationError ? "操作结果尚未确认，请重试。" : error.localizedDescription
        }
    }
    private func handlePushRequest() {
        guard isActive, store.isAuthenticated, !isDismissingForInbox,
              let request = push.pendingInboxRequest else { return }
        store.directConversationPath = []
        if selectedPerson != nil || showsSafety {
            isDismissingForInbox = true; selectedPerson = nil; showsSafety = false
            return
        }
        guard push.consumeInboxRequest(request) else { return }
        Task { await reload(silent: hasLoaded) }
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
        guard store.isAuthenticated, activeMutation == nil, activeBulk == nil, !Task.isCancelled else { return }
        guard !isFetching else { reloadRequested = true; return }
        isFetching = true
        let id = UUID(); generation = id; let privacy = store.socialPrivacyRevision
        if !silent || !hasLoaded { isLoading = true }
        defer { if generation == id { isLoading = false }; finishFetch() }
        do {
            let page = try await store.socialInbox()
            guard isCurrent(id, privacy: privacy) else { return }
            if entries != page.entries { entries = page.entries }
            nextCursor = page.nextCursor; hasLoaded = true
            if !hasRetry { error = nil }
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func loadMore() async {
        guard !Task.isCancelled, !isMutating, !hasRetry else { return }
        guard !isFetching else { loadMoreRequested = true; return }
        guard !isLoading, let cursor = nextCursor else { return }
        let id = generation; let privacy = store.socialPrivacyRevision; isLoading = true; isFetching = true
        defer { if generation == id { isLoading = false }; finishFetch() }
        do {
            let page = try await store.socialInbox(cursor: cursor)
            guard isCurrent(id, privacy: privacy) else { return }
            let ids = Set(entries.map(\.id)); entries += page.entries.filter { !ids.contains($0.id) }
            nextCursor = page.nextCursor; error = nil
        } catch is CancellationError { }
        catch { if isCurrent(id, privacy: privacy) { self.error = error.localizedDescription } }
    }
    private func finishFetch() {
        isFetching = false
        guard refreshIsActive else { reloadRequested = false; loadMoreRequested = false; return }
        if reloadRequested { reloadRequested = false; Task { await reload(silent: true) } }
        else if loadMoreRequested { loadMoreRequested = false; Task { await loadMore() } }
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

private struct KikiInboxBulkAction {
    let snapshot: KikiInboxSnapshot
    let clear: Bool
    let accountID: String
    let privacyRevision: Int
    let requestID = UUID()
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
                        HStack { Text(report.targetType == "profile" ? "用户举报" : (report.targetType == "direct_message" ? "私信举报" : "历史举报")); Spacer(); Text(report.status == "pending" ? "待处理" : "已处理").foregroundStyle(.secondary) }
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
