import AuthenticationServices
import Combine
import SwiftUI
import UIKit

@available(iOS 16.0, *)
@MainActor
struct KikiRootView: View {
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
    @StateObject private var store: KikiAppStore
    @ObservedObject private var push = KikiPushController.shared
    @State private var selectedTab = 0
    @State private var isRoomSearchFocused = false
    @Environment(\.scenePhase) private var scenePhase

    init(consent: KikiConsentStore) {
        _store = StateObject(wrappedValue: KikiAppStore(consent: consent))
    }

    private var foregroundSessionKey: String? {
        guard scenePhase == .active, store.isAuthenticated, !store.needsNickname else { return nil }
        return store.pushSessionKey
    }

    private var roomCatalogKey: String? {
        guard selectedTab == 0, !store.isPresentingRoom else { return nil }
        return foregroundSessionKey
    }

    private var pushedMoment: Binding<KikiPushNavigation?> {
        Binding(get: {
            guard let route = push.navigation, case .moment = route.content else { return nil }
            return route
        }, set: { push.navigation = $0 })
    }

    var body: some View {
        ZStack {
            KikiPalette.background.ignoresSafeArea()
            if !store.startupFinished {
                KikiStartupView()
            } else if store.isAuthenticated && store.needsNickname {
                KikiNicknameOnboardingView()
            } else if store.isAuthenticated {
                KikiMainTabLayout(isRoomSearchFocused: selectedTab == 0 && isRoomSearchFocused) {
                    ZStack {
                        KikiDiscoverView(isActive: selectedTab == 0, onSearchFocusChange: { isRoomSearchFocused = $0 })
                            .opacity(selectedTab == 0 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 0).accessibilityHidden(selectedTab != 0)
                        KikiMomentsView(store: store, isActive: selectedTab == 1).opacity(selectedTab == 1 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 1).accessibilityHidden(selectedTab != 1)
                        KikiMessagesView(store: store, isActive: selectedTab == 2 && push.navigation == nil).opacity(selectedTab == 2 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 2).accessibilityHidden(selectedTab != 2)
                        KikiProfileView(isActive: selectedTab == 3).opacity(selectedTab == 3 ? 1 : 0)
                            .allowsHitTesting(selectedTab == 3).accessibilityHidden(selectedTab != 3)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } tabBar: {
                    if selectedTab != 2 || store.directConversationPath.isEmpty { tabBar }
                }
            } else { KikiLoginView() }
        }
        .foregroundStyle(KikiPalette.text).environmentObject(store)
        .tint(KikiPalette.purple)
        .task {
            push.attach(store)
            push.foregroundContext = { [weak store] in store?.foregroundNotificationContext ?? .init(isActive: false) }
            store.setAppForeground(scenePhase == .active)
            await store.start()
            await push.refresh()
        }
        .task(id: store.pushSessionKey) { if store.pushSessionKey != nil { await push.refresh() } }
        .onChange(of: store.isPresentingRoom) { _ in push.foregroundContextDidChange() }
        .onChange(of: store.notificationsEnabled) { _ in push.foregroundContextDidChange() }
        .onChange(of: push.inboxRequest) { _ in
            guard store.isAuthenticated else { return }
            if let route = push.navigation, case .direct(let person) = route.content {
                push.navigation = nil
                store.requestDirectConversation(person)
            } else {
                store.cancelPendingDirectConversation()
            }
            selectedTab = 2
        }
        .onChange(of: selectedTab) { _ in
            isRoomSearchFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(item: pushedMoment, onDismiss: { push.navigationDidDismiss() }) { route in
            switch route.content {
            case .moment(let moment): KikiMomentCommentsView(moment: moment, store: store)
            case .direct: EmptyView()
            }
        }
        .background(KikiDirectConversationPresenter(store: store, onOpen: { selectedTab = 2 })
            .allowsHitTesting(false).accessibilityHidden(true))
        .task(id: roomCatalogKey) {
            guard roomCatalogKey != nil else { return }
            await store.watchRoomCatalog()
        }
        .task(id: foregroundSessionKey) {
            guard foregroundSessionKey != nil else { return }
            while !Task.isCancelled {
                await store.refreshInboxSummary()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                catch { return }
            }
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
            store.setAppForeground(phase == .active)
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
        .background(KikiForegroundNoticePresenter(push: push))
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
                            Circle().fill(.red).frame(width: 8, height: 8)
                                .offset(x: 5, y: -3).accessibilityHidden(true)
                        }
                    }
                Text(title).font(.system(size: 10, weight: .medium))
            }.foregroundStyle(selectedTab == index ? KikiPalette.lavender : KikiPalette.muted)
                .frame(maxWidth: .infinity).frame(height: 43).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(index == 0 ? "discoverTab" : (index == 1 ? "momentsTab" : (index == 2 ? "messagesTab" : "profileTab")))
            .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
            .accessibilityValue(index == 2 && store.unreadMessageCount > 0 ? "\(store.unreadMessageCount) 条未读消息" : "")
    }
}

/// Finish dismissing the current scene's entire presentation chain before the
/// messages stack opens a conversation. UIKit's completion owns the handoff;
/// no timing delay or unrelated scene/window lookup is involved.
struct KikiDirectConversationPresenter: UIViewControllerRepresentable {
    @ObservedObject var store: KikiAppStore
    let onOpen: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.view.backgroundColor = .clear
        host.appeared = { [weak coordinator = context.coordinator] in coordinator?.schedule() }
        return host
    }
    func updateUIViewController(_ host: Host, context: Context) {
        context.coordinator.host = host
        context.coordinator.attach(store)
        context.coordinator.onOpen = onOpen
        context.coordinator.schedule()
    }
    static func dismantleUIViewController(_ host: Host, coordinator: Coordinator) {
        host.appeared = nil
        coordinator.task?.cancel()
        coordinator.requestSubscription?.cancel()
        coordinator.requestSubscription = nil
        coordinator.host = nil
    }

    final class Host: UIViewController {
        var appeared: (() -> Void)?
        weak var hostingWindow: UIWindow?
        override func loadView() {
            let view = WindowView()
            view.attached = { [weak self] window in
                self?.hostingWindow = window
                self?.appeared?()
            }
            self.view = view
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let window = view.window { hostingWindow = window }
            appeared?()
        }
    }

    final class WindowView: UIView {
        var attached: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { attached?(window) }
        }
    }

    @MainActor final class Coordinator {
        weak var host: Host?
        weak var store: KikiAppStore?
        var onOpen: (() -> Void)?
        var task: Task<Void, Never>?
        var requestSubscription: AnyCancellable?
        private var isRouting = false

        func attach(_ store: KikiAppStore) {
            guard self.store !== store else { return }
            self.store = store
            // A full-screen room may suspend the underlying SwiftUI root's
            // rendering. Observe the intent directly instead of waiting for a
            // representable update. @Published emits before assigning its value.
            requestSubscription = store.$pendingDirectConversation.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.schedule() }
            }
        }

        func schedule() {
            guard !isRouting, let store, let request = store.pendingDirectConversation,
                  store.isCurrentDirectConversationRequest(request.id), presentationRoot != nil else { return }
            isRouting = true
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.isRouting = false; self.task = nil }
                while !Task.isCancelled, let store = self.store, let request = store.pendingDirectConversation,
                      store.isCurrentDirectConversationRequest(request.id) {
                    guard let initialRoot = self.presentationRoot else { return }
                    await self.waitForTransitions(from: initialRoot, requestID: request.id)
                    guard !Task.isCancelled else { return }
                    guard store.isCurrentDirectConversationRequest(request.id) else { continue }
                    await store.prepareForMessageNavigation()
                    guard !Task.isCancelled else { return }
                    guard store.isCurrentDirectConversationRequest(request.id) else { continue }
                    guard let root = self.presentationRoot else { return }
                    root.view.endEditing(true)
                    await self.dismissPresentations(from: root, requestID: request.id)
                    guard !Task.isCancelled else { return }
                    if store.completeDirectConversationNavigation(request.id) { self.onOpen?() }
                }
            }
        }

        private var presentationRoot: UIViewController? {
            // A full-screen room detaches the underlying host's view. Keep a
            // weak reference to this same window so the room can minimize.
            (host?.viewIfLoaded?.window ?? host?.hostingWindow)?.rootViewController
        }

        private func waitForTransitions(from root: UIViewController, requestID: UUID) async {
            while !Task.isCancelled, store?.isCurrentDirectConversationRequest(requestID) == true {
                var controller: UIViewController? = root
                var transition: UIViewControllerTransitionCoordinator?
                while let current = controller {
                    if current.isBeingPresented || current.isBeingDismissed,
                       let active = current.transitionCoordinator { transition = active; break }
                    controller = current.presentedViewController
                }
                guard let transition else { return }
                let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        var resumed = false
                        let finish: (Bool) -> Void = { completed in
                            guard !resumed else { return }; resumed = true
                            continuation.resume(returning: completed)
                        }
                        if !transition.animate(alongsideTransition: nil, completion: { _ in finish(true) }) { finish(false) }
                }
                guard completed else { return }
            }
        }

        private func dismissPresentations(from root: UIViewController, requestID: UUID) async {
            while !Task.isCancelled, store?.isCurrentDirectConversationRequest(requestID) == true,
                  root.presentedViewController != nil {
                await waitForTransitions(from: root, requestID: requestID)
                guard !Task.isCancelled, store?.isCurrentDirectConversationRequest(requestID) == true else { return }
                if root.presentedViewController == nil { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    root.dismiss(animated: true) { continuation.resume() }
                }
            }
        }
    }
}

/// Preserve normal keyboard avoidance for inputs while keeping the main tabs
/// out of a room-search editing session, including the keyboard hide animation.
struct KikiMainTabLayout<Content: View, TabBar: View>: View {
    let isRoomSearchFocused: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var tabBar: () -> TabBar
    @State private var searchKeyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            content().frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isRoomSearchFocused && !searchKeyboardVisible { tabBar() }
        }
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                // Only the system status area gets a backdrop. The navigation
                // controls below it float over the scrolling page content.
                Rectangle().fill(.regularMaterial)
                    .frame(height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top)
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            if isRoomSearchFocused { searchKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            if isRoomSearchFocused { searchKeyboardVisible = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            searchKeyboardVisible = false
        }
    }
}

extension View {
    /// The shared status backdrop supplies the top protection. Disable the
    /// additional iOS 26 scroll fade below it so content stays clear there.
    @ViewBuilder func kikiTransparentTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .top) }
        else { self }
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
