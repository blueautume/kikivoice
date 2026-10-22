import SwiftUI

struct KikiDirectConversationView: View {
    let person: KikiPerson
    @ObservedObject var store: KikiAppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var messages: [KikiDirectMessage] = []
    @State private var clearedThroughSeq = 0
    @State private var nextCursor: String?
    @State private var isLoading = false
    @State private var refreshRequestID: UUID?
    @State private var refreshAgain = false
    @State private var isVisible = false
    @State private var hasLoaded = false
    @State private var loadedPersonID: String?
    @State private var error: String?
    @State private var report: KikiSocialReportTarget?
    @State private var showsProfile = false
    @State private var generation = UUID()
    @State private var latestVisibleID: String?
    @State private var lastAcknowledgedID: String?
    @FocusState private var isComposing: Bool
    private var pending: KikiPendingDirectMessage? { store.pendingDirectMessages[person.id] }
    private var directAccess: KikiDirectMessageAccess? { store.directMessageAccess[person.id] }
    private var visibleMessages: [KikiDirectMessage] { loadedPersonID == person.id ? messages : [] }
    private var canSend: Bool { hasLoaded && loadedPersonID == person.id && directAccess?.canSend == true }
    private var refreshScope: KikiDirectRefreshScope {
        .init(personID: person.id, isForeground: scenePhase == .active, isVisible: isVisible,
              hasOverlay: showsProfile || report != nil)
    }
    private var draft: Binding<String> { Binding(get: { store.directDrafts[person.id] ?? "" }, set: { store.updateDirectDraft($0, personID: person.id) }) }
    private var canSubmit: Bool {
        (canSend || pending != nil) && pending?.isSending != true
            && (pending != nil || !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error { KikiInlineError(message: error) { Task { await reload() } }.padding(.horizontal, 16) }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if nextCursor != nil { Button("更早的消息") { Task { await loadMore() } }.disabled(isLoading) }
                            if isLoading && visibleMessages.isEmpty { ProgressView().padding(30) }
                            if !isLoading && visibleMessages.isEmpty && error == nil {
                                KikiEmptyState(symbol: "bubble.left.and.bubble.right", title: "从一句你好开始", message: "文字消息最多保留 30 天。")
                            }
                            ForEach(visibleMessages) { message in
                                VStack(spacing: 16) {
                                    if showsTimestamp(before: message) {
                                        Text(Date(timeIntervalSince1970: message.createdAt), format: .dateTime.month().day().hour().minute())
                                            .font(.caption2).foregroundStyle(KikiPalette.muted).padding(.top, 8)
                                    }
                                    messageRow(message)
                                }.id(message.id)
                                    .onAppear { if message.id == messages.last?.id { latestVisibleID = message.id; Task { await acknowledgeVisible() } } }
                            }
                            if let pending {
                                HStack { Spacer(minLength: 45)
                                    VStack(alignment: .trailing, spacing: 7) {
                                        Text(pending.text).font(.body).padding(13).background(KikiPalette.purple.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
                                        if pending.isSending { Label("正在发送", systemImage: "clock").font(.caption).foregroundStyle(KikiPalette.muted) }
                                        else { Button("发送未确认，点击重试") { Task { await send() } }.font(.caption).foregroundStyle(KikiPalette.lavender) }
                                    }
                                }.id("pending")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(18).frame(maxWidth: 760).frame(maxWidth: .infinity)
                    }.onChange(of: visibleMessages.last?.id) { old, _ in
                        if old == nil || latestVisibleID == old || isComposing { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                    }
                        .onChange(of: pending?.isSending) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                composer
            }.background(KikiPalette.background.ignoresSafeArea())
                .navigationTitle(person.name).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) { Button { showsProfile = true } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("查看个人主页") }
                }
                .onAppear { isVisible = true }
                .onDisappear { isVisible = false; generation = UUID(); isComposing = false }
                .onChange(of: person.id) { _, _ in
                    generation = UUID(); messages = []; loadedPersonID = nil; hasLoaded = false
                    clearedThroughSeq = 0; nextCursor = nil; error = nil; refreshRequestID = nil
                    latestVisibleID = nil; lastAcknowledgedID = nil; isLoading = false
                    requestRefresh()
                }
                .task(id: refreshScope) {
                    guard refreshScope.permitsRefresh else { return }
                    await reload(silent: hasLoaded)
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: KikiDirectRefreshScope.fallbackNanoseconds) } catch { return }
                        guard refreshScope.permitsRefresh else { return }
                        await reload(silent: true)
                    }
                }
                .onChange(of: store.directHistoryRevision[person.id]) { _, _ in
                    generation = UUID(); messages = []; nextCursor = nil; isLoading = false; refreshRequestID = nil
                    latestVisibleID = nil; lastAcknowledgedID = nil
                    if refreshScope.permitsRefresh { Task { await reload(silent: true) } }
                }
                .onChange(of: store.socialPrivacyRevision) { _ in
                    generation = UUID(); messages = []; nextCursor = nil; clearedThroughSeq = 0
                    hasLoaded = false
                    latestVisibleID = nil; lastAcknowledgedID = nil; isLoading = false; refreshRequestID = nil
                    report = nil; showsProfile = false
                    if refreshScope.permitsRefresh { Task { await reload() } }
                }
                .onChange(of: store.socialRevision) { _, _ in requestRefresh() }
                .onChange(of: store.directContentRevision) { _, _ in requestRefresh() }
                .sheet(isPresented: $showsProfile) { KikiPublicProfileView(userID: person.id, store: store) }
                .sheet(item: $report) { KikiSocialReportForm(target: $0, store: store) }
        }.tint(KikiPalette.lavender).foregroundStyle(KikiPalette.text)
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if hasLoaded, loadedPersonID == person.id, let explanation = directAccess?.explanation {
                Text(explanation).font(.footnote).foregroundStyle(KikiPalette.secondary)
                    .accessibilityIdentifier("social.direct.access")
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("写一条消息…", text: draft, axis: .vertical).lineLimit(1...5).font(.body)
                    .padding(12).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    .focused($isComposing).disabled(!canSend || pending != nil).accessibilityIdentifier("social.direct.draft")
                Button { Task { await send() } } label: {
                    Image(systemName: pending?.isSending == true ? "clock" : "arrow.up")
                        .font(.body.weight(.semibold)).foregroundStyle(canSubmit ? .white : KikiPalette.muted).frame(width: 44, height: 44)
                        .background(canSubmit ? KikiPalette.action : KikiPalette.elevated, in: Circle())
                }.disabled(!canSubmit)
                    .accessibilityLabel(pending == nil ? "发送消息" : "重试发送").accessibilityIdentifier("social.direct.send")
            }
        }
        .padding(16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(KikiPalette.background)
    }
    private func messageRow(_ message: KikiDirectMessage) -> some View {
        let mine = message.senderID == store.userID
        return HStack(alignment: .bottom, spacing: 10) {
            if mine { Spacer(minLength: 45) }
            else { KikiAvatar(index: person.avatarIndex, size: 34, customURL: person.avatarURL).accessibilityHidden(true) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
                Text(message.text).font(.body).multilineTextAlignment(.leading).padding(13)
                    .background(mine ? KikiPalette.purple.opacity(0.16) : KikiPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }.contextMenu {
                if !mine { Button("举报消息", systemImage: "exclamationmark.bubble") { report = .init(kind: .directMessage, targetID: message.id, name: person.name + "的消息") } }
            }
            if !mine { Spacer(minLength: 45) }
        }
    }
    private func showsTimestamp(before message: KikiDirectMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == message.id }), index > 0 else { return true }
        return KikiDirectTimeline.needsTimestamp(previous: messages[index - 1].createdAt, current: message.createdAt)
    }
    private func reload(silent: Bool = false) async {
        guard refreshScope.permitsRefresh else { return }
        guard refreshRequestID == nil else { refreshAgain = true; return }
        let requestID = UUID(); refreshRequestID = requestID
        let id = generation; let privacy = store.socialPrivacyRevision
        if !silent && !hasLoaded { isLoading = true }
        defer {
            if refreshRequestID == requestID {
                refreshRequestID = nil; isLoading = false
                if refreshAgain && refreshScope.permitsRefresh {
                    refreshAgain = false
                    Task { await reload(silent: true) }
                }
            }
        }
        do {
            let page = try await store.socialDirectMessages(person.id)
            try Task.checkCancellation(); guard generation == id, privacy == store.socialPrivacyRevision, refreshScope.permitsRefresh else { return }
            clearedThroughSeq = max(clearedThroughSeq, page.clearedThroughSeq)
            messages = KikiDirectTimeline.merged(existing: messages, fresh: page.messages, clearedThroughSeq: clearedThroughSeq)
            nextCursor = page.nextCursor; error = nil
            hasLoaded = true; loadedPersonID = person.id
            await acknowledgeVisible()
        } catch is CancellationError { }
        catch {
            guard generation == id, privacy == store.socialPrivacyRevision, refreshScope.permitsRefresh else { return }
            if let apiError = error as? KikiAPIError, case .server(let status, _) = apiError, status == 403 || status == 404 {
                messages = []; latestVisibleID = nil
            }
            if !silent || messages.isEmpty { self.error = error.localizedDescription }
        }
    }
    private func loadMore() async {
        guard !isLoading, refreshRequestID == nil, refreshScope.permitsRefresh, let cursor = nextCursor else { return }
        let requestID = UUID(); refreshRequestID = requestID
        let id = generation; let privacy = store.socialPrivacyRevision; isLoading = true
        defer {
            if refreshRequestID == requestID {
                refreshRequestID = nil; isLoading = false
                if refreshAgain && refreshScope.permitsRefresh {
                    refreshAgain = false
                    Task { await reload(silent: true) }
                }
            }
        }
        do {
            let page = try await store.socialDirectMessages(person.id, cursor: cursor)
            guard generation == id, privacy == store.socialPrivacyRevision, refreshScope.permitsRefresh else { return }
            clearedThroughSeq = max(clearedThroughSeq, page.clearedThroughSeq)
            messages = messages.filter { $0.seq > clearedThroughSeq }
            let ids = Set(messages.map(\.id)); messages += page.messages.filter { !ids.contains($0.id) && $0.seq > clearedThroughSeq }; messages.sort { $0.seq < $1.seq }
            nextCursor = page.nextCursor; error = nil
        } catch is CancellationError { } catch { if generation == id, privacy == store.socialPrivacyRevision { self.error = error.localizedDescription } }
    }
    private func send() async {
        let id = UUID(); generation = id
        let peer = person.id
        let privacy = store.socialPrivacyRevision
        do {
            let result = try await store.sendDirectDraft(peer)
            guard privacy == store.socialPrivacyRevision, generation == id, isVisible else { return }
            // A GET that began while this send was in flight cannot replace its
            // newly committed message or the receipt's admission decision.
            generation = UUID(); loadedPersonID = peer
            if result.message.seq > clearedThroughSeq, !messages.contains(where: { $0.id == result.message.id }) { messages.append(result.message); messages.sort { $0.seq < $1.seq } }
            error = nil
        } catch is CancellationError { } catch { if privacy == store.socialPrivacyRevision, generation == id, isVisible { self.error = error.localizedDescription } }
    }
    private func requestRefresh() {
        guard refreshScope.permitsRefresh else { return }
        Task { await reload(silent: true) }
    }
    private func acknowledgeVisible() async {
        guard refreshScope.permitsRefresh, loadedPersonID == person.id, let id = latestVisibleID, id != lastAcknowledgedID else { return }
        lastAcknowledgedID = id
        do { try await store.readDirectMessages(person.id, throughMessageID: id) }
        catch { if lastAcknowledgedID == id { lastAcknowledgedID = nil } }
    }
}
