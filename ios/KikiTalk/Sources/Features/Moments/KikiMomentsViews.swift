import SwiftUI
import PhotosUI
import ImageIO

struct KikiSocialImageView: View {
    let media: KikiSocialMedia
    @ObservedObject var store: KikiAppStore
    @State private var image: UIImage?
    @State private var failed = false
    @State private var retryID = 0
    var body: some View {
        ZStack {
            KikiPalette.elevated
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed { Button { retryID += 1 } label: { Label("重试图片", systemImage: "arrow.clockwise").font(.caption) } }
            else { ProgressView().controlSize(.small) }
        }.clipped().accessibilityLabel("动态图片")
            .onChange(of: store.socialPrivacyRevision) { _ in image = nil; failed = false }
            .task(id: media.id + store.userID + String(store.socialPrivacyRevision) + String(retryID)) {
                image = nil; failed = false
                let privacy = store.socialPrivacyRevision
                do {
                    let loaded = try await store.socialImage(media)
                    guard privacy == store.socialPrivacyRevision else { return }
                    image = loaded
                }
                catch is CancellationError { } catch { failed = true }
            }
    }
}

struct KikiMomentCard: View {
    let moment: KikiMoment
    @ObservedObject var store: KikiAppStore
    let openPerson: (KikiPerson) -> Void
    let openComments: () -> Void
    let update: (KikiMoment) -> Void
    let remove: () -> Void
    var openDetails: (() -> Void)? = nil
    var showsCommentPreview = true
    var commentCountOverride: Int? = nil
    var dismissCommentInput: (() -> Void)? = nil
    var actionsDisabled = false
    var onMutationStateChanged: ((Bool) -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isChanging = false
    @State private var isFollowing = false
    @State private var error: String?
    @State private var report: KikiSocialReportTarget?
    @State private var confirmsDelete = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let openDetails {
                Button(action: openDetails) { content.allowsHitTesting(false).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("查看\(moment.author.name)的动态详情")
                    .accessibilityIdentifier("moment.content.\(moment.id)")
            } else { content.textSelection(.enabled) }
            HStack(spacing: 26) {
                Button { Task { await like() } } label: {
                    Label("\(moment.likeCount)", systemImage: moment.liked ? "heart.fill" : "heart")
                        .foregroundStyle(moment.liked ? KikiPalette.purple : KikiPalette.secondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }.disabled(isChanging || isFollowing || actionsDisabled)
                    .accessibilityLabel(moment.liked ? "取消点赞，\(moment.likeCount) 个赞" : "点赞，\(moment.likeCount) 个赞")
                    .accessibilityIdentifier("moment.like.\(moment.id)")
                Button(action: openComments) {
                    Label("\(commentCount)", systemImage: "bubble.right").foregroundStyle(KikiPalette.secondary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                }
                    .accessibilityLabel("评论，\(commentCount) 条评论")
                    .accessibilityIdentifier("moment.comment.\(moment.id)")
                Spacer()
                if isChanging { ProgressView().controlSize(.small) }
            }.font(.subheadline).buttonStyle(.plain).frame(minHeight: 36)
            if showsCommentPreview && commentCount > 0 && (!moment.commentPreview.isEmpty || commentCount > 3) {
                Divider().overlay(KikiPalette.elevated)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(moment.commentPreview.prefix(3))) { comment in
                        Button(action: openDetails ?? openComments) {
                            (Text(comment.author.name + "：").foregroundColor(KikiPalette.purple)
                             + Text(comment.text).foregroundColor(KikiPalette.text))
                                .font(.subheadline).lineSpacing(3).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("moment.commentPreview.\(comment.id)")
                    }
                    if commentCount > 3 {
                        Button(action: openDetails ?? openComments) {
                            Text("查看全部\(commentCount)条评论").font(.subheadline)
                                .foregroundStyle(KikiPalette.muted).frame(minHeight: 36, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("moment.allComments.\(moment.id)")
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(KikiPalette.lavender) }
        }.padding(.horizontal, 18).padding(.vertical, 20)
            .background {
                if let openDetails {
                    // Whitespace has its own action behind the card's controls;
                    // no parent tap gesture competes with their actions.
                    Button(action: openDetails) { KikiPalette.background }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看\(moment.author.name)的动态详情")
                        .accessibilityIdentifier("moment.open.\(moment.id)")
                } else { KikiPalette.surface.onTapGesture { dismissCommentInput?() } }
            }
            .sheet(item: $report) { KikiSocialReportForm(target: $0, store: store) }
            .confirmationDialog("删除这条动态及其图片和评论？", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("删除动态", role: .destructive) { Task { await delete() } }; Button("取消", role: .cancel) { }
            }
    }
    private var commentCount: Int { commentCountOverride ?? moment.commentCount }
    private var following: Bool { store.isFollowing(moment.author) }
    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                authorIdentity
                HStack { Spacer(minLength: 0); headerActions }
            }
        } else {
            HStack(spacing: 11) { authorIdentity; Spacer(minLength: 4); headerActions }
        }
    }
    private var authorIdentity: some View {
        HStack(alignment: .top, spacing: 11) {
            Button { openPerson(moment.author) } label: {
                KikiAvatar(index: moment.author.avatarIndex, size: 44, customURL: moment.author.avatarURL)
            }.buttonStyle(.plain).accessibilityLabel("查看\(moment.author.name)的主页")
                .accessibilityIdentifier("moment.authorAvatar.\(moment.id)")
            VStack(alignment: .leading, spacing: 4) {
                Button { openPerson(moment.author) } label: {
                    Text(moment.author.name).font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }.buttonStyle(.plain).accessibilityIdentifier("moment.authorName.\(moment.id)")
                if let openDetails {
                    Button(action: openDetails) { timestamp }
                        .buttonStyle(.plain).accessibilityIdentifier("moment.time.\(moment.id)")
                } else { timestamp }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var timestamp: some View {
        Text(Date(timeIntervalSince1970: moment.createdAt), format: .dateTime.month().day().hour().minute())
            .font(.caption).foregroundStyle(KikiPalette.muted)
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            if moment.author.id != store.userID {
                Button { Task { await follow() } } label: {
                    HStack(spacing: 5) {
                        if isFollowing { ProgressView().controlSize(.mini) }
                        Text(following ? "已关注" : "关注").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(following ? KikiPalette.secondary : .white)
                    .padding(.horizontal, 15).frame(minHeight: 34)
                    .background(following ? KikiPalette.elevated : KikiPalette.action, in: Capsule())
                    .frame(minHeight: 44)
                }.buttonStyle(.plain).disabled(isChanging || isFollowing || actionsDisabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(following ? "取消关注\(moment.author.name)" : "关注\(moment.author.name)")
                    .accessibilityIdentifier("moment.follow.\(moment.id)")
            }
            Menu {
                if moment.canDelete { Button("删除动态", systemImage: "trash", role: .destructive) { confirmsDelete = true } }
                else { Button("举报动态", systemImage: "exclamationmark.bubble") { report = .init(kind: .moment, targetID: moment.id, name: moment.author.name + "的动态") } }
            } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).foregroundStyle(KikiPalette.muted) }
                .disabled(isChanging || isFollowing || actionsDisabled).accessibilityLabel("动态操作")
        }
    }
    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 13) {
            if !moment.text.isEmpty {
                Text(moment.text).font(.body).lineSpacing(5).foregroundStyle(KikiPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !moment.media.isEmpty {
                if moment.media.count == 1, let media = moment.media.first {
                    Color.clear.frame(height: 240)
                        .overlay { KikiSocialImageView(media: media, store: store) }
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    HStack(spacing: 5) {
                        ForEach(Array(moment.media.prefix(3))) { media in
                            Color.clear.aspectRatio(1, contentMode: .fit).frame(maxWidth: .infinity)
                                .overlay { KikiSocialImageView(media: media, store: store) }
                                .clipped()
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func follow() async {
        guard !isFollowing, !isChanging, !actionsDisabled else { return }
        isFollowing = true; onMutationStateChanged?(true)
        defer { isFollowing = false; onMutationStateChanged?(false) }
        let account = store.userID; let privacy = store.socialPrivacyRevision
        do {
            _ = try await store.setFollowing(moment.author, enabled: !following)
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            error = nil
        } catch is CancellationError { } catch {
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            self.error = error.localizedDescription
        }
    }
    private func like() async {
        guard !isChanging, !isFollowing, !actionsDisabled else { return }
        isChanging = true; onMutationStateChanged?(true)
        defer { isChanging = false; onMutationStateChanged?(false) }
        let account = store.userID; let privacy = store.socialPrivacyRevision
        do {
            let value = try await store.likeMoment(moment)
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            update(value); error = nil
        } catch is CancellationError { } catch {
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            self.error = error.localizedDescription
        }
    }
    private func delete() async {
        guard !isChanging, !isFollowing, !actionsDisabled else { return }
        isChanging = true; onMutationStateChanged?(true)
        defer { isChanging = false; onMutationStateChanged?(false) }
        let account = store.userID; let privacy = store.socialPrivacyRevision
        do {
            try await store.deleteMoment(moment.id)
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            remove()
        } catch is CancellationError { } catch {
            guard account == store.userID, privacy == store.socialPrivacyRevision else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class KikiMomentFeedModel: ObservableObject {
    @Published private(set) var moments: [KikiMoment] = []
    @Published private(set) var nextCursor: String?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let fetchPage: (String?) async throws -> KikiMomentsPage
    private let fetchMoment: (String) async throws -> KikiMoment
    private var active = false
    private var revision = UUID()
    private var worker: Task<Void, Never>?
    private var reloadRequested = false
    private var pageRequested = false
    private var momentRequests: [String] = []
    private var inFlightMomentID: String?
    private var inFlightPage = false
    private var loadedPageCount = 0

    init(fetchPage: @escaping (String?) async throws -> KikiMomentsPage,
         fetchMoment: @escaping (String) async throws -> KikiMoment) {
        self.fetchPage = fetchPage; self.fetchMoment = fetchMoment
    }

    func setActive(_ value: Bool, refreshOnResume: Bool = true) {
        if !value && refreshOnResume { reloadRequested = true; pageRequested = false }
        guard active != value else { return }
        active = value
        if value {
            if refreshOnResume || loadedPageCount == 0 { invalidate() }
            else { startIfNeeded() }
        }
        else {
            revision = UUID()
            if inFlightPage { reloadRequested = true; pageRequested = false }
            if let id = inFlightMomentID, !momentRequests.contains(id) { momentRequests.insert(id, at: 0) }
            worker?.cancel(); isLoading = false
        }
    }

    func invalidate() {
        revision = UUID(); reloadRequested = true; pageRequested = false
        startIfNeeded()
    }

    func reload() async {
        // A pull during an older GET must await a new GET, rather than reuse
        // that GET's snapshot or disappear behind an isLoading guard.
        invalidate()
        await waitForReads()
    }

    func loadMore() async {
        guard nextCursor != nil, !reloadRequested else { return }
        pageRequested = true; startIfNeeded()
        await waitForReads()
    }

    func update(_ moment: KikiMoment) {
        revision = UUID()
        replace(moment)
        if worker != nil { reloadRequested = true; pageRequested = false }
    }

    func remove(_ id: String) {
        revision = UUID(); moments.removeAll { $0.id == id }
        momentRequests.removeAll { $0 == id }
        if worker != nil { reloadRequested = true; pageRequested = false }
    }

    func refreshMoment(_ id: String) async {
        guard moments.contains(where: { $0.id == id }) else { return }
        // This single-item read follows any older page in the same worker, so
        // its fresh detail value cannot later be overwritten by that page.
        if !momentRequests.contains(id) { momentRequests.append(id) }
        startIfNeeded()
        await waitForReads()
    }

    func reset() {
        setActive(false); revision = UUID()
        moments = []; nextCursor = nil; error = nil
        momentRequests = []; reloadRequested = true; pageRequested = false; loadedPageCount = 0
    }

    private func replace(_ moment: KikiMoment) {
        if let index = moments.firstIndex(where: { $0.id == moment.id }) { moments[index] = moment }
    }

    private func waitForReads() async {
        // Finishing a cancelled worker may start the queued foreground worker.
        // Await that successor too, including a pull's trailing fresh request.
        while active, let current = worker { await current.value }
    }

    private func startIfNeeded() {
        guard active, worker == nil, reloadRequested || pageRequested || !momentRequests.isEmpty else { return }
        isLoading = true
        worker = Task { await drain() }
    }

    private func drain() async {
        defer {
            worker = nil; inFlightMomentID = nil; isLoading = false
            startIfNeeded()
        }
        while active, !Task.isCancelled {
            let requestRevision = revision
            if !momentRequests.isEmpty {
                let id = momentRequests.removeFirst(); inFlightMomentID = id
                defer { inFlightMomentID = nil }
                do {
                    let value = try await fetchMoment(id)
                    guard active, !Task.isCancelled, revision == requestRevision else { continue }
                    replace(value); error = nil
                } catch {
                    guard active, !Task.isCancelled, revision == requestRevision else { continue }
                    if case KikiAPIError.server(404, _) = error { moments.removeAll { $0.id == id } }
                    else if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            } else if reloadRequested || pageRequested {
                let isReload = reloadRequested
                let cursor = isReload ? nil : nextCursor
                reloadRequested = false; pageRequested = false
                guard isReload || cursor != nil else { continue }
                inFlightPage = true
                defer { inFlightPage = false }
                do {
                    let result: (KikiMomentsPage, Int)
                    if isReload { result = try await readLoadedRange(revision: requestRevision) }
                    else { result = (try await fetchPage(cursor), loadedPageCount + 1) }
                    let (page, pageCount) = result
                    guard active, !Task.isCancelled, revision == requestRevision else { continue }
                    if isReload { moments = page.moments }
                    else {
                        let ids = Set(moments.map(\.id))
                        moments += page.moments.filter { !ids.contains($0.id) }
                    }
                    nextCursor = page.nextCursor; loadedPageCount = pageCount; error = nil
                } catch {
                    guard active, !Task.isCancelled, revision == requestRevision else { continue }
                    if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            } else { return }
        }
    }

    private func readLoadedRange(revision expected: UUID) async throws -> (KikiMomentsPage, Int) {
        let targetPages = max(1, loadedPageCount)
        var values: [KikiMoment] = [], ids = Set<String>(), cursor: String?, count = 0
        repeat {
            let page = try await fetchPage(cursor)
            guard active, !Task.isCancelled, revision == expected else { throw CancellationError() }
            values += page.moments.filter { ids.insert($0.id).inserted }
            cursor = page.nextCursor; count += 1
        } while count < targetPages && cursor != nil
        // Publish only once the previously loaded range is fresh. A failed or
        // superseded later page must not truncate the visible list or cursor.
        return (.init(moments: values, nextCursor: cursor), count)
    }
}

struct KikiMomentsView: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.scenePhase) private var scenePhase
    var isActive = true
    @StateObject private var feed: KikiMomentFeedModel
    @State private var showsComposer = false
    @State private var person: KikiPersonDestination?
    @State private var selectedMoment: KikiMomentDetailDestination?
    @State private var detailMomentID: String?
    init(store: KikiAppStore, isActive: Bool = true) {
        self.store = store; self.isActive = isActive
        _feed = StateObject(wrappedValue: KikiMomentFeedModel(
            fetchPage: { try await store.socialMoments(kind: .all, cursor: $0) },
            fetchMoment: { try await store.socialMoment($0) }))
    }
    private var pageIsActive: Bool {
        isActive && scenePhase == .active && store.isAuthenticated && !store.isPresentingRoom
    }
    private var refreshIsActive: Bool {
        pageIsActive && !showsComposer && person == nil && selectedMoment == nil
    }
    private var refreshScope: String {
        store.userID + ":" + String(store.socialPrivacyRevision) + ":" + String(pageIsActive) + ":" + String(refreshIsActive)
    }
    private func syncFeedActivity() {
        feed.setActive(refreshIsActive, refreshOnResume: !pageIsActive)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let error = feed.error { KikiInlineError(message: error) { Task { await feed.reload() } } }
                    if feed.isLoading && feed.moments.isEmpty { ProgressView().padding(30) }
                    else if feed.moments.isEmpty && feed.error == nil { KikiEmptyState(symbol: "text.bubble", title: "分享一点日常", message: "一段文字，或几张照片，让朋友更了解你。") }
                    LazyVStack(spacing: 0) {
                        ForEach(feed.moments) { moment in
                            KikiMomentCard(moment: moment, store: store, openPerson: { feed.setActive(false, refreshOnResume: false); person = .init(id: $0.id) },
                                openComments: { open(moment, focusComment: true) }, update: feed.update,
                                remove: { feed.remove(moment.id) },
                                openDetails: { open(moment, focusComment: false) })
                            if moment.id != feed.moments.last?.id {
                                Divider().overlay(KikiPalette.elevated).padding(.horizontal, 18)
                            }
                        }
                    }
                    if feed.nextCursor != nil { Button(feed.isLoading ? "正在加载…" : "加载更多") { Task { await feed.loadMore() } }.disabled(feed.isLoading) }
                }.padding(.vertical, 16).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea()).refreshable { await feed.reload() }
                .kikiMainTabScrollInsets()
                .kikiTransparentTopScrollEdge()
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { feed.setActive(false, refreshOnResume: false); showsComposer = true } label: {
                            Image(systemName: "square.and.pencil").font(.system(size: 20)).frame(width: 24, height: 24)
                        }.accessibilityLabel("发布动态").accessibilityIdentifier("moments.compose")
                    }
                }
                .task(id: refreshScope) { syncFeedActivity() }
                .onChange(of: store.socialRevision) { _ in syncFeedActivity(); feed.invalidate() }
                .onChange(of: store.momentContentRevision) { _ in syncFeedActivity(); feed.invalidate() }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    feed.reset(); showsComposer = false; person = nil; selectedMoment = nil; detailMomentID = nil
                    syncFeedActivity()
                }
                .onChange(of: store.userID) { _ in feed.reset(); syncFeedActivity() }
                .onDisappear { feed.setActive(false, refreshOnResume: !pageIsActive) }
                .sheet(isPresented: $showsComposer) { KikiMomentComposer(store: store) }
                .sheet(item: $person) { KikiPublicProfileView(userID: $0.id, store: store) }
                .sheet(item: $selectedMoment, onDismiss: {
                    let id = detailMomentID; detailMomentID = nil
                    if let id { Task { await feed.refreshMoment(id) } }
                }) {
                    KikiMomentCommentsView(moment: $0.moment, store: store, focusComment: $0.focusComment)
                }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private func open(_ moment: KikiMoment, focusComment: Bool) {
        feed.setActive(false, refreshOnResume: false)
        detailMomentID = moment.id; selectedMoment = .init(moment: moment, focusComment: focusComment)
    }
}

struct KikiMomentComposer: View {
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selection: [PhotosPickerItem] = []
    @State private var photos: [Data] = []
    @State private var uploaded: [String] = []
    @State private var requestID = UUID()
    @State private var attempted = false
    @State private var isProcessing = false
    @State private var isPublishing = false
    @State private var error: String?
    private var valid: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    TextField("今天有什么想分享的？", text: $text, axis: .vertical).lineLimit(6...15).font(.body)
                        .onChange(of: text) { if $0.count > 1000 { text = String($0.prefix(1000)) } }.disabled(attempted)
                    Text("\(text.count)/1000").font(.caption).foregroundStyle(KikiPalette.muted).frame(maxWidth: .infinity, alignment: .trailing)
                    if !photos.isEmpty {
                        HStack(spacing: 9) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { _, data in
                                if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill().frame(width: 88, height: 88).clipped().clipShape(RoundedRectangle(cornerRadius: 12)) }
                            }
                        }
                    }
                    PhotosPicker(selection: $selection, maxSelectionCount: 3, matching: .images, photoLibrary: .shared()) {
                        Label(isProcessing ? "正在处理图片…" : "添加照片（最多 3 张）", systemImage: "photo.on.rectangle")
                    }.disabled(isProcessing || isPublishing || attempted)
                    Text("仅上传你选择的照片。发布前会压缩并移除照片元数据，发布后社区成员可以查看。")
                        .font(.footnote).foregroundStyle(KikiPalette.secondary)
                    if let error { Text(error).font(.subheadline).foregroundStyle(KikiPalette.lavender) }
                    if attempted && !isPublishing { Text("上次发布尚未确认。重试会使用同一个发布编号，避免重复动态。") .font(.footnote).foregroundStyle(KikiPalette.secondary) }
                }.padding(24).frame(maxWidth: 650).frame(maxWidth: .infinity)
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle("发布动态").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isPublishing) }
                    ToolbarItem(placement: .confirmationAction) { Button(isPublishing ? "发布中…" : (attempted ? "重试" : "发布")) { Task { await publish() } }.disabled(!valid || isPublishing || isProcessing) }
                }
                .task(id: selection) { await processPhotos() }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text).interactiveDismissDisabled(isPublishing)
    }
    private func processPhotos() async {
        guard !attempted else { return }; isProcessing = true; defer { isProcessing = false }
        do {
            var result: [Data] = []
            for item in selection {
                guard let raw = try await item.loadTransferable(type: Data.self) else { throw KikiAPIError.server(422, "图片无法读取，请重新选择。") }
                try Task.checkCancellation(); result.append(try KikiSocialPhotoProcessor.jpeg(raw))
            }
            try Task.checkCancellation(); photos = result; uploaded = []; error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription; photos = [] }
    }
    private func publish() async {
        guard valid, !isPublishing, !isProcessing else { return }; isPublishing = true; attempted = true
        defer { isPublishing = false }
        do {
            for photo in photos.dropFirst(uploaded.count) { let media = try await store.uploadSocialImage(photo); uploaded.append(media.id) }
            _ = try await store.publishMoment(requestID: requestID, text: text.trimmingCharacters(in: .whitespacesAndNewlines), mediaIDs: uploaded)
            dismiss()
        } catch is CancellationError { }
        catch {
            self.error = error.localizedDescription
            if !KikiSocialMutation.needsSameIDRetry(error) { attempted = false; requestID = UUID() }
        }
    }
}

enum KikiSocialPhotoProcessor {
    static func jpeg(_ data: Data) throws -> Data {
        guard data.count <= 25 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else {
            throw KikiAPIError.server(422, "照片无法处理，请选择较小的静态图片。")
        }
        let picture = UIImage(cgImage: image)
        for quality in [0.85, 0.7, 0.55, 0.4] {
            if let result = picture.jpegData(compressionQuality: quality), result.count <= 2 * 1024 * 1024 { return result }
        }
        throw KikiAPIError.server(422, "图片压缩后仍过大，请重新选择。")
    }
}

private struct KikiMomentDetailDestination: Identifiable {
    let moment: KikiMoment
    let focusComment: Bool
    var id: String { moment.id }
}

struct KikiMomentCommentsView: View {
    let moment: KikiMoment
    @ObservedObject var store: KikiAppStore
    let focusComment: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var currentMoment: KikiMoment
    @State private var commentCount: Int
    @State private var comments: [KikiMomentComment] = []
    @State private var nextCursor: String?
    @State private var text = ""
    @State private var pendingText: String?
    @State private var requestID = UUID()
    @State private var isLoading = false
    @State private var isSending = false
    @State private var isChangingMoment = false
    @State private var deletingCommentID: String?
    @State private var generation = UUID()
    @State private var hasAppliedInitialFocus = false
    @FocusState private var isCommentFocused: Bool
    @State private var error: String?
    @State private var report: KikiSocialReportTarget?
    @State private var person: KikiPersonDestination?
    init(moment: KikiMoment, store: KikiAppStore, focusComment: Bool = false) {
        self.moment = moment; self.store = store; self.focusComment = focusComment
        _currentMoment = State(initialValue: moment)
        _commentCount = State(initialValue: moment.commentCount)
    }
    private var canSendComment: Bool {
        !isSending && !isLoading && !isChangingMoment && deletingCommentID == nil
            && (pendingText != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var sendLabel: String { isSending ? "发送中" : (pendingText == nil ? "发送" : "重试") }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        KikiMomentCard(moment: currentMoment, store: store,
                            openPerson: { person = .init(id: $0.id) },
                            openComments: { isCommentFocused = true },
                            update: {
                                currentMoment = $0
                            },
                            remove: { dismiss() }, showsCommentPreview: false, commentCountOverride: commentCount,
                            dismissCommentInput: { isCommentFocused = false },
                            actionsDisabled: isLoading || isSending || deletingCommentID != nil,
                            onMutationStateChanged: { isChangingMoment = $0 })
                        VStack(alignment: .leading, spacing: 16) {
                            Text("评论（\(commentCount)）").font(.headline).padding(.top, 4)
                                .accessibilityIdentifier("moment.detail.commentCount")
                            if let error { KikiInlineError(message: error) { Task { await reload() } } }
                            if isLoading && comments.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.vertical, 24) }
                            if comments.isEmpty && !isLoading && error == nil {
                                KikiEmptyState(symbol: "bubble.right", title: "还没有评论", message: "聊聊你的想法吧。")
                            }
                            ForEach(comments) { comment in
                                HStack(alignment: .top, spacing: 11) {
                                    Button { person = .init(id: comment.author.id) } label: {
                                        KikiAvatar(index: comment.author.avatarIndex, size: 36, customURL: comment.author.avatarURL)
                                    }.buttonStyle(.plain).accessibilityLabel("查看\(comment.author.name)的主页")
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(comment.author.name).font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.purple)
                                        Text(comment.text).font(.body).foregroundStyle(KikiPalette.text).textSelection(.enabled)
                                        Text(Date(timeIntervalSince1970: comment.createdAt), format: .dateTime.month().day().hour().minute())
                                            .font(.caption).foregroundStyle(KikiPalette.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    if deletingCommentID == comment.id { ProgressView().controlSize(.small) }
                                    else {
                                        Menu {
                                            if comment.canDelete { Button("删除评论", role: .destructive) { Task { await delete(comment) } } }
                                            else { Button("举报评论") { report = .init(kind: .comment, targetID: comment.id, name: comment.author.name + "的评论") } }
                                        } label: { Image(systemName: "ellipsis").frame(width: 32, height: 44).foregroundStyle(KikiPalette.muted) }
                                            .disabled(isSending || isLoading || isChangingMoment || deletingCommentID != nil)
                                            .accessibilityLabel("评论操作")
                                    }
                                }.padding(.vertical, 9)
                                Divider()
                            }
                            if nextCursor != nil {
                                Button(isLoading ? "正在加载…" : "更多评论") { Task { await loadMore() } }
                                    .disabled(isLoading || isSending || isChangingMoment || deletingCommentID != nil)
                                    .frame(minHeight: 44)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background { KikiPalette.surface.onTapGesture { isCommentFocused = false } }
                    }.frame(maxWidth: 720).frame(maxWidth: .infinity)
                        .frame(maxWidth: .infinity, minHeight: 1, alignment: .topLeading)
                }.scrollDismissesKeyboard(.interactively)
                    .background { KikiPalette.surface.onTapGesture { isCommentFocused = false } }
                    .refreshable { await reload() }
                HStack(alignment: .top, spacing: 10) {
                    TextField("写一条评论…", text: $text, axis: .vertical).lineLimit(1...5).font(.body)
                        .padding(.horizontal, 14).padding(.vertical, 12).frame(minHeight: 44)
                        .background(KikiPalette.elevated, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KikiPalette.muted.opacity(0.22), lineWidth: 1))
                        .focused($isCommentFocused)
                        .accessibilityIdentifier("moment.detail.commentInput")
                        .onChange(of: text) { if $0.count > 300 { text = String($0.prefix(300)) } }
                        .disabled(pendingText != nil)
                    Button { Task { await send() } } label: {
                        HStack(spacing: 6) {
                            if isSending { ProgressView().controlSize(.small).tint(.white).accessibilityHidden(true) }
                            Text(sendLabel).lineLimit(1)
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 52, minHeight: 44, maxHeight: .infinity).padding(.horizontal, 12)
                        .foregroundStyle(isSending || canSendComment ? Color.white : KikiPalette.secondary)
                        .background(isSending || canSendComment ? KikiPalette.action : KikiPalette.elevated,
                                    in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(KikiPalette.muted.opacity(0.22), lineWidth: 1))
                    }.buttonStyle(.plain).disabled(!canSendComment)
                        .accessibilityIdentifier("moment.detail.sendComment")
                }.fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .frame(maxWidth: 720).frame(maxWidth: .infinity).background(KikiPalette.surface)
                    .overlay(alignment: .top) { KikiPalette.elevated.frame(height: 1) }
            }.background(KikiPalette.surface.ignoresSafeArea()).navigationTitle("详情").navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(KikiPalette.surface, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { isCommentFocused = false; dismiss() } } }
                .task { await reload() }
                .task { await applyInitialFocus() }
                .onChange(of: store.socialPrivacyRevision) { _ in resetAndDismiss() }
                .onChange(of: store.userID) { _ in resetAndDismiss() }
                .onDisappear {
                    generation = UUID(); isLoading = false; isSending = false
                    deletingCommentID = nil; isCommentFocused = false
                }
                .sheet(item: $report) { KikiSocialReportForm(target: $0, store: store).kikiRoomSheet() }
                .sheet(item: $person) { KikiPublicProfileView(userID: $0.id, store: store).kikiRoomSheet() }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private func applyInitialFocus() async {
        guard !hasAppliedInitialFocus else { return }
        hasAppliedInitialFocus = true
        guard focusComment else { return }
        let account = store.userID; let privacy = store.socialPrivacyRevision
        // Wait for the presented native field to join its window, once per opening.
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard account == store.userID, privacy == store.socialPrivacyRevision, !Task.isCancelled else { return }
        isCommentFocused = true
    }
    private func resetAndDismiss() {
        generation = UUID(); comments = []; text = ""; pendingText = nil; nextCursor = nil
        isCommentFocused = false; dismiss()
    }
    private func isCurrent(_ account: String, _ privacy: Int, _ id: UUID) -> Bool {
        account == store.userID && privacy == store.socialPrivacyRevision && generation == id
    }
    private func reload() async {
        guard !isLoading, !isSending, !isChangingMoment, deletingCommentID == nil else { return }
        let id = UUID(); generation = id
        let account = store.userID; let privacy = store.socialPrivacyRevision
        isLoading = true; defer { if isCurrent(account, privacy, id) { isLoading = false } }
        do {
            async let updated = store.socialMoment(moment.id)
            async let page = store.socialComments(moment.id)
            let (freshMoment, freshPage) = try await (updated, page)
            guard isCurrent(account, privacy, id) else { return }
            currentMoment = freshMoment; commentCount = freshMoment.commentCount
            comments = freshPage.comments; nextCursor = freshPage.nextCursor; error = nil
        } catch is CancellationError { } catch {
            guard isCurrent(account, privacy, id) else { return }
            self.error = error.localizedDescription
        }
    }
    private func loadMore() async {
        guard !isLoading, !isSending, !isChangingMoment, deletingCommentID == nil, let cursor = nextCursor else { return }
        let id = generation; let account = store.userID; let privacy = store.socialPrivacyRevision
        isLoading = true; defer { if isCurrent(account, privacy, id) { isLoading = false } }
        do {
            let page = try await store.socialComments(moment.id, cursor: cursor)
            guard isCurrent(account, privacy, id) else { return }
            let ids = Set(comments.map(\.id)); comments += page.comments.filter { !ids.contains($0.id) }
            nextCursor = page.nextCursor
        } catch is CancellationError { } catch {
            guard isCurrent(account, privacy, id) else { return }
            self.error = error.localizedDescription
        }
    }
    private func send() async {
        guard !isSending, !isLoading, !isChangingMoment, deletingCommentID == nil else { return }
        let value = pendingText ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let id = generation; let account = store.userID; let privacy = store.socialPrivacyRevision
        pendingText = value; isSending = true
        defer { if isCurrent(account, privacy, id) { isSending = false } }
        do {
            let result = try await store.commentMoment(moment.id, text: value, requestID: requestID)
            guard isCurrent(account, privacy, id) else { return }
            if !comments.contains(where: { $0.id == result.id }) { comments.insert(result, at: 0); commentCount += 1 }
            text = ""; pendingText = nil; requestID = UUID(); error = nil
            await refreshMoment(account, privacy, id)
        } catch is CancellationError { }
        catch {
            guard isCurrent(account, privacy, id) else { return }
            self.error = error.localizedDescription
            if !KikiSocialMutation.needsSameIDRetry(error) { pendingText = nil; requestID = UUID() }
        }
    }
    private func delete(_ comment: KikiMomentComment) async {
        guard !isSending, !isLoading, !isChangingMoment, deletingCommentID == nil else { return }
        let id = generation; let account = store.userID; let privacy = store.socialPrivacyRevision
        deletingCommentID = comment.id
        defer { if isCurrent(account, privacy, id) { deletingCommentID = nil } }
        do {
            try await store.deleteComment(comment.id)
            guard isCurrent(account, privacy, id) else { return }
            comments.removeAll { $0.id == comment.id }; commentCount = max(0, commentCount - 1); error = nil
            await refreshMoment(account, privacy, id)
        } catch is CancellationError { } catch {
            guard isCurrent(account, privacy, id) else { return }
            self.error = error.localizedDescription
        }
    }
    private func refreshMoment(_ account: String, _ privacy: Int, _ id: UUID) async {
        do {
            let updated = try await store.socialMoment(moment.id)
            guard isCurrent(account, privacy, id) else { return }
            currentMoment = updated; commentCount = updated.commentCount
        } catch is CancellationError { } catch {
            // A confirmed comment is kept; refreshing metadata must not resend it.
        }
    }
}
