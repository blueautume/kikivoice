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
            switch consent.presentation {
            case .withdrawing:
                KikiWithdrawalPendingView()
            case .checking:
                KikiStartupView(errorMessage: consent.documentError, showsOfflineDocuments: true) {
                    Task { await consent.refreshDocuments() }
                }
            case .accepted:
                if startupPermissions.isReady(for: consent) { KikiAuthorizedRootView(consent: consent) }
                else { KikiStartupPermissionsView(permissions: startupPermissions) }
            case .acceptanceRequired:
                KikiConsentGateView()
            }
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
        KikiStartupView(errorMessage: permissions.stage == .failed ? permissions.errorMessage : nil,
                        retryIdentifier: "startup.retryNetwork") {
            Task { await permissions.retry(consent: consent) }
        }
        .accessibilityIdentifier("startup.permissions")
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

    var body: some View {
        ZStack {
            KikiPalette.background.ignoresSafeArea()
            if !store.startupFinished {
                KikiStartupView()
            } else if store.isAuthenticated && store.needsNickname {
                KikiNicknameOnboardingView()
            } else if store.isAuthenticated {
                KikiMainTabs(selection: $selectedTab, unreadCount: store.unreadMessageCount,
                             isRoomSearchFocused: selectedTab == 0 && isRoomSearchFocused,
                             hidesTabBar: selectedTab == 2 && !store.directConversationPath.isEmpty) {
                    KikiDiscoverView(isActive: selectedTab == 0, onSearchFocusChange: { isRoomSearchFocused = $0 })
                } messages: {
                    KikiMessagesView(store: store, isActive: selectedTab == 2 && push.navigation == nil)
                } profile: {
                    KikiProfileView(isActive: selectedTab == 3)
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
            guard push.inboxNavigationRevision == nil || push.inboxNavigationRevision == store.socialNavigationRevision else {
                push.navigation = nil; return
            }
            if let route = push.navigation, case .direct(let person) = route.content {
                push.navigation = nil
                store.requestDirectConversation(person)
                selectedTab = 2
            } else if let route = push.navigation, case .room = route.content {
                push.navigation = nil
            } else {
                store.cancelPendingSocialNavigation()
                selectedTab = 2
            }
        }
        .onChange(of: selectedTab) { _ in
            isRoomSearchFocused = false
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .background(KikiDirectConversationPresenter(store: store, onOpen: { selectedTab = 2 }, onOpenRoom: { selectedTab = 0 })
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

}

/// Finish dismissing the current scene's entire presentation chain before the
/// messages stack opens a conversation. UIKit's completion owns the handoff;
/// no timing delay or unrelated scene/window lookup is involved.
struct KikiDirectConversationPresenter: UIViewControllerRepresentable {
    @ObservedObject var store: KikiAppStore
    let onOpen: () -> Void
    var onOpenRoom: () -> Void = {}

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
        context.coordinator.onOpenRoom = onOpenRoom
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
        var onOpenRoom: (() -> Void)?
        var task: Task<Void, Never>?
        var requestSubscription: AnyCancellable?
        private var isRouting = false

        func attach(_ store: KikiAppStore) {
            guard self.store !== store else { return }
            self.store = store
            // A full-screen room may suspend the underlying SwiftUI root's
            // rendering. Observe the intent directly instead of waiting for a
            // representable update. @Published emits before assigning its value.
            requestSubscription = store.$pendingDirectConversation.combineLatest(store.$pendingRoomNotification).sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.schedule() }
            }
        }

        func schedule() {
            guard !isRouting, let store, store.pendingDirectConversation != nil || store.pendingRoomNotification != nil,
                  presentationRoot != nil else { return }
            isRouting = true
            task = Task { [weak self] in
                guard let self else { return }
                defer { self.isRouting = false; self.task = nil }
                while !Task.isCancelled, let store = self.store {
                    if let request = store.pendingRoomNotification, store.isCurrentRoomNotificationRequest(request.id) {
                        do {
                            let room = try await store.roomForNotificationNavigation(request.id)
                            guard store.isCurrentRoomNotificationRequest(request.id), !Task.isCancelled else { continue }
                            guard let initialRoot = self.presentationRoot else { return }
                            await self.waitForTransitions(from: initialRoot, requestID: request.id)
                            guard store.isCurrentRoomNotificationRequest(request.id), !Task.isCancelled else { continue }
                            await store.prepareForMessageNavigation()
                            guard store.isCurrentRoomNotificationRequest(request.id), !Task.isCancelled else { continue }
                            guard let root = self.presentationRoot else { return }
                            root.view.endEditing(true)
                            await self.dismissPresentations(from: root, requestID: request.id)
                            guard store.isCurrentRoomNotificationRequest(request.id), !Task.isCancelled else { continue }
                            self.onOpenRoom?()
                            try await store.completeRoomNotificationNavigation(request.id, room: room)
                        } catch {
                            if store.isCurrentRoomNotificationRequest(request.id) {
                                store.cancelRoomNotificationRequest(request.id)
                                if !(error is CancellationError) { store.notify(error.localizedDescription) }
                            }
                        }
                        continue
                    }
                    guard let request = store.pendingDirectConversation,
                          store.isCurrentDirectConversationRequest(request.id) else { return }
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

        private func isCurrentRequest(_ id: UUID) -> Bool {
            store?.isCurrentDirectConversationRequest(id) == true || store?.isCurrentRoomNotificationRequest(id) == true
        }

        private func waitForTransitions(from root: UIViewController, requestID: UUID) async {
            while !Task.isCancelled, isCurrentRequest(requestID) {
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
            while !Task.isCancelled, isCurrentRequest(requestID),
                  root.presentedViewController != nil {
                await waitForTransitions(from: root, requestID: requestID)
                guard !Task.isCancelled, isCurrentRequest(requestID) else { return }
                if root.presentedViewController == nil { return }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    root.dismiss(animated: true) { continuation.resume() }
                }
            }
        }
    }
}

/// Let the system own the tab bar's glass, selected shape, hit targets and
/// safe-area insets, using the same native component as Apple's apps.
struct KikiMainTabs<Rooms: View, Messages: View, Profile: View>: View {
    @Binding var selection: Int
    let unreadCount: Int
    var isRoomSearchFocused = false
    var hidesTabBar = false
    @ViewBuilder var rooms: () -> Rooms
    @ViewBuilder var messages: () -> Messages
    @ViewBuilder var profile: () -> Profile
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var searchKeyboardVisible = false

    private var barVisibility: Visibility {
        isRoomSearchFocused || searchKeyboardVisible || hidesTabBar ? .hidden : .visible
    }

    var body: some View {
        systemTabs
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

    @ViewBuilder private var systemTabs: some View {
        if #available(iOS 26.0, *) {
            tabs.tabViewStyle(.tabBarOnly).tabBarMinimizeBehavior(.never)
        } else if #available(iOS 18.0, *) {
            tabs.tabViewStyle(.tabBarOnly)
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            nativePage(rooms())
                .tabItem { Label("语聊", systemImage: "waveform").accessibilityIdentifier("discoverTab") }
                .tag(0)
            nativePage(messages())
                .tabItem {
                    Label {
                        Text("消息")
                    } icon: {
                        Image(uiImage: messageTabImage).renderingMode(.original)
                    }
                        .accessibilityIdentifier("messagesTab")
                        .accessibilityValue(unreadCount > 0 ? "\(unreadCount) 条未读消息" : "")
                }
                .badge(textOnlyMessageBadge)
                .tag(2)
            nativePage(profile())
                .tabItem { Label("我", systemImage: "person.crop.circle").accessibilityIdentifier("profileTab") }
                .tag(3)
        }
        .tint(KikiPalette.purple)
    }

    private var textOnlyMessageBadge: String? {
        // iPad's regular-width top tabs hide icons, including the composed dot.
        if #available(iOS 18.0, *), UIDevice.current.userInterfaceIdiom == .pad,
           horizontalSizeClass == .regular, unreadCount > 0 { return "" }
        return nil
    }

    private var messageTabImage: UIImage {
        // The system badge has a fixed minimum size. Compose a smaller dot into
        // the icon while keeping the native tab's layout and touch target.
        let size = CGSize(width: 34, height: 28)
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let color = selection == 2 ? UIColor(KikiPalette.purple) : UIColor.label
        let symbol = UIImage(systemName: "bubble.left.and.bubble.right.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 23, weight: .regular))?
            .withTintColor(color.resolvedColor(with: traits), renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: size).image { _ in
            if let symbol {
                symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2,
                                        y: (size.height - symbol.size.height) / 2))
            }
            if unreadCount > 0 {
                UIColor.systemRed.resolvedColor(with: traits).setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width - 6, y: 0, width: 6, height: 6)).fill()
            }
        }.withRenderingMode(.alwaysOriginal)
    }

    private func nativePage<Page: View>(_ page: Page) -> some View {
        page.toolbar(barVisibility, for: .tabBar)
            .background(KikiNativeTabLayoutObserver().allowsHitTesting(false).accessibilityHidden(true))
    }
}

/// The room avatar lives in a separate window. Notify it when native tab
/// layout changes, without polling or imposing any custom tab-bar geometry.
private struct KikiNativeTabLayoutObserver: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ uiView: Probe, context: Context) { }

    final class Probe: UIView {
        private var lastBounds: CGRect?
        private var lastInsets: UIEdgeInsets?

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            lastBounds = nil
            reportLayout()
        }
        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            reportLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            reportLayout()
        }
        private func reportLayout() {
            guard let window, lastBounds != bounds || lastInsets != safeAreaInsets else { return }
            lastBounds = bounds
            lastInsets = safeAreaInsets
            KikiVoiceRoomFloatingOverlay.mainNavigationDidLayout(in: window)
        }
    }
}

extension View {
    /// Keep the status area and the content below it transparent, without the
    /// additional iOS 26 top scroll-edge blur or fade.
    @ViewBuilder func kikiTransparentTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .top) }
        else { self }
    }
}

@available(iOS 16.0, *)
struct KikiStartupView: View {
    var errorMessage: String?
    var retryIdentifier = "retryLegalDocuments"
    var showsOfflineDocuments = false
    var retryAction: (() -> Void)?
    @State private var isReadingOfflineDocuments = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color("KikiLaunchBackground").ignoresSafeArea()

                if let errorMessage {
                    ScrollView {
                        VStack(spacing: 40) {
                            brand.padding(.top, max(32, geometry.size.height / 2 - 121))
                            VStack(spacing: 16) {
                                Text(errorMessage).font(.footnote).lineSpacing(4)
                                    .foregroundStyle(KikiPalette.secondary).multilineTextAlignment(.center)
                                Button("重试连接") { retryAction?() }
                                    .font(.body.weight(.semibold)).foregroundStyle(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(KikiPalette.action, in: RoundedRectangle(cornerRadius: 16))
                                    .accessibilityIdentifier(retryIdentifier)
                                Link("打开系统设置", destination: URL(string: UIApplication.openSettingsURLString)!)
                                    .font(.footnote).foregroundStyle(KikiPalette.lavender)
                                if showsOfflineDocuments {
                                    Button("离线阅读已保存的协议") { isReadingOfflineDocuments = true }
                                        .font(.footnote).foregroundStyle(KikiPalette.lavender)
                                }
                            }.frame(maxWidth: 380)
                        }.padding(.horizontal, 24).padding(.bottom, 24).frame(maxWidth: .infinity)
                    }
                } else {
                    // Keep the native launch appearance throughout silent checks.
                    brand.position(x: geometry.size.width / 2, y: geometry.size.height / 2 - 28)
                }
            }
        }
        .accessibilityIdentifier("startup.brand")
        .sheet(isPresented: $isReadingOfflineDocuments) {
            NavigationStack {
                ScrollView { KikiLocalLegalLinks().padding(24) }
                    .background(KikiPalette.background.ignoresSafeArea())
                    .navigationTitle("已保存的协议").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { isReadingOfflineDocuments = false } } }
            }
        }
    }

    private var brand: some View {
        VStack(spacing: 0) {
            Image("KikiLaunchMark")
                .resizable().scaledToFit().frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text("Kiki")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color("KikiLaunchText")).frame(height: 34)
                .padding(.top, 24)
        }.dynamicTypeSize(.medium)
    }
}
