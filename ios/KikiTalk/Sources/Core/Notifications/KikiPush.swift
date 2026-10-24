import SwiftUI
import UIKit
import UserNotifications

enum KikiPushPermission: String, Equatable {
    case unknown, notDetermined, denied, authorized, provisional
    var permitsDelivery: Bool { self == .authorized || self == .provisional }
    var label: String {
        switch self {
        case .unknown: return "正在检查"
        case .notDetermined: return "尚未允许"
        case .denied: return "系统通知已关闭"
        case .authorized: return "已允许"
        case .provisional: return "静默通知已允许"
        }
    }
}

struct KikiPushStatus: Decodable {
    let enabled: Bool
    let registered: Bool
    let badgeCount: Int
    let accountTag: String
    let hideNotificationContent: Bool

    private enum CodingKeys: String, CodingKey { case enabled, registered, badgeCount, accountTag, hideNotificationContent }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        registered = try values.decode(Bool.self, forKey: .registered)
        badgeCount = try values.decode(Int.self, forKey: .badgeCount)
        accountTag = try values.decode(String.self, forKey: .accountTag)
        hideNotificationContent = try values.decodeIfPresent(Bool.self, forKey: .hideNotificationContent) ?? false
    }
}
struct KikiPushReceipt: Decodable { let ok: Bool; let accountTag: String; let registered: Bool }
struct KikiPushRoute: Decodable {
    let type: String
    let personID: String?
    let notificationID: String?
    let roomID: String?
}
struct KikiPushTap: Equatable {
    let deliveryID: String
    let accountTag: String
    init?(payload: [AnyHashable: Any]) {
        guard let id = payload["deliveryID"] as? String, UUID(uuidString: id) != nil,
              let tag = payload["accountTag"] as? String, !tag.isEmpty, tag.utf8.count <= 256 else { return nil }
        deliveryID = id; accountTag = tag
    }
}

struct KikiForegroundNotificationScope: Equatable {
    let sessionKey: String
    let privacyRevision: Int
}

struct KikiForegroundNotificationContext: Equatable {
    let isActive: Bool
    var conversationPersonID: String? = nil
    var hasConversationOverlay = false
    var currentRoomID: String? = nil

    func isReading(_ candidate: KikiForegroundNotificationCandidate) -> Bool {
        if case .direct(let personID) = candidate.kind {
            return conversationPersonID == personID && !hasConversationOverlay
        }
        if case .room(let roomID) = candidate.kind { return currentRoomID == roomID }
        return false
    }
}

/// Candidates come only from accepted authenticated inbox responses. Remote
/// notification payloads can invalidate those responses, never supply a preview.
struct KikiForegroundNotificationCandidate: Equatable {
    enum Kind: Equatable { case direct(personID: String), notifications, room(roomID: String) }
    let id: String
    let kind: Kind
    var preview: KikiForegroundNotificationPreview? = nil

    fileprivate var key: String {
        switch kind {
        case .direct(let personID): return "direct:\(personID):\(id)"
        case .notifications: return "notification:\(id)"
        case .room: return "notification:\(id)"
        }
    }
    fileprivate var isValid: Bool {
        guard !id.isEmpty, id.utf8.count <= 256 else { return false }
        if case .direct(let personID) = kind { return !personID.isEmpty && personID.utf8.count <= 160 }
        if case .room(let roomID) = kind { return KikiRoomNotificationRequest.isValidRoomID(roomID) }
        return true
    }
}

/// Only accepted HTTPS inbox DTOs construct this preview. Missing names or
/// content retain the generic fallback rather than using a remote push body.
struct KikiForegroundNotificationPreview: Equatable {
    let title: String
    let message: String

    init?(title: String, message: String) {
        let title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let message = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !title.isEmpty, !message.isEmpty else { return nil }
        self.title = String(title.prefix(80))
        self.message = String(message.prefix(240))
    }
}

struct KikiForegroundNotice: Identifiable, Equatable {
    let id = UUID()
    let scope: KikiForegroundNotificationScope
    let candidate: KikiForegroundNotificationCandidate
    var hideContent = false
    var title: String { hideContent ? "收到新消息" : candidate.preview?.title ?? "收到新消息" }
    var message: String {
        if !hideContent, let preview = candidate.preview { return preview.message }
        if case .direct = candidate.kind { return "收到一条新私信，可在消息页查看。" }
        return "有新的互动消息，可在消息页查看。"
    }
}

/// Consume suppressed/baseline events too: leaving a conversation, returning
/// from the background or enabling notifications must not replay old alerts.
struct KikiForegroundNotificationGate {
    private var scope: KikiForegroundNotificationScope?
    private var seen: Set<String> = []
    private var order: [String] = []

    mutating func reset() { scope = nil; seen = []; order = [] }

    mutating func accepts(_ candidate: KikiForegroundNotificationCandidate,
                         scope expected: KikiForegroundNotificationScope,
                         currentScope: KikiForegroundNotificationScope?,
                         context: KikiForegroundNotificationContext,
                         notificationsEnabled: Bool, baseline: Bool) -> Bool {
        guard expected == currentScope, candidate.isValid else { return false }
        if scope != expected { reset(); scope = expected }
        if seen.contains(candidate.key) {
            order.removeAll { $0 == candidate.key }
            order.append(candidate.key)
            return false
        }
        seen.insert(candidate.key)
        order.append(candidate.key)
        if order.count > 512 { seen.remove(order.removeFirst()) }
        guard !baseline, notificationsEnabled, context.isActive else { return false }
        if context.isReading(candidate) { return false }
        return true
    }
}

struct KikiPushNavigation: Identifiable {
    enum Content { case direct(KikiPerson), room(roomID: String, notificationID: String) }
    let id = UUID()
    let content: Content
}

@MainActor protocol KikiPushSystem {
    func permission() async -> KikiPushPermission
    func requestPermission() async throws
    func register()
    func unregister()
    func setBadge(_ count: Int)
    func clearNotifications()
}

@MainActor final class KikiNativePushSystem: KikiPushSystem {
    private var center: UNUserNotificationCenter { .current() }
    func permission() async -> KikiPushPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .unknown
        }
    }
    func requestPermission() async throws { _ = try await center.requestAuthorization(options: [.alert, .badge, .sound]) }
    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
    func setBadge(_ count: Int) {
        // The main-actor synchronous setter also prevents an older asynchronous
        // badge completion from restoring an account's badge after logout.
        UIApplication.shared.applicationIconBadgeNumber = max(0, count)
    }
    func clearNotifications() {
        center.removeAllDeliveredNotifications(); center.removeAllPendingNotificationRequests(); setBadge(0)
    }
}

enum KikiPushEnvironment {
    /// Read the installed profile, rather than guessing from DEBUG/Release.
    /// Xcode/export selects the entitlement from the provisioning profile.
    static func current(bundle: Bundle = .main) -> String? {
        #if targetEnvironment(simulator)
        return nil
        #else
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let result = fromProvisioningProfile(data) { return result }
        // App Store and TestFlight deliveries may omit the embedded profile.
        // Both use production APNs, including TestFlight's sandbox receipt.
        if let receipt = bundle.appStoreReceiptURL, FileManager.default.fileExists(atPath: receipt.path) { return "production" }
        return nil
        #endif
    }
    static func fromProvisioningProfile(_ data: Data) -> String? {
        let start = Data("<?xml".utf8), end = Data("</plist>".utf8)
        guard let lower = data.range(of: start), let upper = data.range(of: end, in: lower.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: lower.lowerBound..<upper.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        switch entitlements["aps-environment"] as? String {
        case "development": return "sandbox"
        case "production": return "production"
        default: return nil
        }
    }
}

/// This object can exist before consent, but reads no identifier and starts no
/// networking until an authenticated, consented store explicitly attaches.
@MainActor final class KikiPushController: ObservableObject {
    static let shared = KikiPushController()
    @Published private(set) var permission = KikiPushPermission.unknown
    @Published private(set) var isBusy = false
    @Published private(set) var isRegistered = false
    @Published private(set) var message: String?
    @Published private(set) var inboxRequest = UUID()
    private(set) var inboxNavigationRevision: Int?
    @Published private(set) var pendingInboxRequest: UUID?
    @Published private(set) var foregroundNotice: KikiForegroundNotice?
    var foregroundContext: @MainActor () -> KikiForegroundNotificationContext = { .init(isActive: false) } {
        didSet { foregroundContextDidChange() }
    }
    @Published var navigation: KikiPushNavigation?
    private let system: any KikiPushSystem
    private let identity: any KikiIdentityStoring
    private let environment: () -> String?
    private weak var store: KikiAppStore?
    private var task: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var bindingTask: Task<Void, Never>?
    private var bindingFingerprint: String?
    private var bindingAttempt = UUID()
    private var operation = UUID()
    private var sessionKey: String?
    private var token: String?
    private var registeredFingerprint: String?
    private var lastRegisteredAt: Date?
    private var accountTag: String?
    private var pendingTap: KikiPushTap?
    private var tapAccount: String?
    private var tapNavigationRevision: Int?
    private var resolving = false
    private var foregroundGate = KikiForegroundNotificationGate()

    var currentForegroundScope: KikiForegroundNotificationScope? {
        guard let store, let key = store.pushSessionKey else { return nil }
        return .init(sessionKey: key, privacyRevision: store.socialPrivacyRevision)
    }

    init(system: (any KikiPushSystem)? = nil, identity: any KikiIdentityStoring = KikiKeychainStorage(),
         environment: @escaping () -> String? = { KikiPushEnvironment.current() }) {
        self.system = system ?? KikiNativePushSystem(); self.identity = identity; self.environment = environment
    }

    func attach(_ store: KikiAppStore) {
        if let existing = self.store, existing !== store { endSession() }
        self.store = store; store.pushController = self
    }

    func refresh() async {
        guard let store, let key = store.pushSessionKey else { return }
        if let previous = sessionKey, previous != key { endSession() }
        sessionKey = key
        let id = UUID(); operation = id
        let settings = await system.permission()
        guard valid(id, key: key) else { return }
        permission = settings
        do {
            let status = try await store.pushStatus()
            guard valid(id, key: key) else { return }
            accountTag = status.accountTag
            if !status.enabled { foregroundNotice = nil }
            if !status.registered { isRegistered = false; registeredFingerprint = nil }
            system.setBadge(status.enabled && settings.permitsDelivery ? status.badgeCount : 0)
            if !status.enabled || !settings.permitsDelivery {
                isRegistered = false; registeredFingerprint = nil
                system.unregister()
                await unbindCurrent()
                guard valid(id, key: key) else { return }
            } else {
                // Ask APNs on every launch/foreground. Never persist a device token.
                system.register()
                await bindIfReady(id: id, key: key)
            }
            guard valid(id, key: key) else { return }
            await resolvePendingTap(id: id, key: key)
        } catch is CancellationError { }
        catch { if valid(id, key: key) { message = "通知状态暂时无法同步，请稍后重试。" } }
    }

    func enable() async {
        guard let store, let key = store.pushSessionKey, !isBusy else { return }
        isBusy = true; message = nil; defer { isBusy = false }
        do {
            let settings = await system.permission()
            guard store.pushSessionKey == key else { return }
            if settings == .notDetermined { try await system.requestPermission() }
            guard store.pushSessionKey == key else { return }
            permission = await system.permission()
            guard store.pushSessionKey == key else { return }
            if permission.permitsDelivery { try await store.setNotificationsEnabled(true) }
            else { message = "请在系统设置中允许通知，再开启消息提醒。" }
            await refresh()
        } catch is CancellationError { }
        catch { if store.pushSessionKey == key { message = error.localizedDescription } }
    }

    func disable() async {
        guard let store, let key = store.pushSessionKey, !isBusy else { return }
        isBusy = true; message = nil; defer { isBusy = false }
        do {
            try await store.setNotificationsEnabled(false)
            guard store.pushSessionKey == key else { return }
            pendingTap = nil; tapAccount = nil; navigation = nil
            pendingInboxRequest = nil
            foregroundNotice = nil
            system.clearNotifications()
            await refresh()
        } catch is CancellationError { }
        catch { if store.pushSessionKey == key { message = error.localizedDescription } }
    }

    func receivedToken(_ data: Data) {
        guard !data.isEmpty, data.count <= 256 else { registrationFailed(); return }
        // APNs token length is not assumed to be 32 bytes.
        token = data.map { String(format: "%02x", $0) }.joined()
        guard let key = sessionKey, store?.pushSessionKey == key else { return }
        let id = operation
        bindingTask = Task { [weak self] in await self?.bindIfReady(id: id, key: key) }
    }
    func registrationFailed() {
        token = nil; registeredFingerprint = nil; isRegistered = false
        if store?.pushSessionKey != nil { message = "系统通知注册未完成，可稍后重试。" }
    }
    func receiveTap(_ tap: KikiPushTap) {
        if let store, store.pushSessionKey != nil {
            if tap.accountTag == accountTag { store.cancelPendingSocialNavigation() }
            tapNavigationRevision = store.socialNavigationRevision
        } else { tapNavigationRevision = nil }
        foregroundNotice = nil
        pendingInboxRequest = nil
        pendingTap = tap; tapAccount = store?.pushSessionKey
        scheduleRefresh()
    }
    func receiveForeground(_ tap: KikiPushTap?) {
        // A push invalidates visible content; HTTPS remains authoritative.
        guard let tap, let store, let scope = currentForegroundScope,
              accountTag == nil || tap.accountTag == accountTag else { return }
        Task { [weak self, weak store] in
            guard let self, let store else { return }
            if self.accountTag == nil { await self.refresh() }
            guard self.currentForegroundScope == scope, tap.accountTag == self.accountTag else { return }
            store.directMessagePushReceived()
            await store.refreshSocialSummary()
            guard self.currentForegroundScope == scope else { return }
            await self.refresh()
        }
    }

    func receiveForegroundCandidates(_ candidates: [KikiForegroundNotificationCandidate],
                                     scope: KikiForegroundNotificationScope, baseline: Bool = false) {
        let current = currentForegroundScope
        let context = foregroundContext()
        let enabled = store?.notificationsEnabled == true
        foregroundContextDidChange()
        for candidate in candidates {
            if foregroundGate.accepts(candidate, scope: scope, currentScope: current, context: context,
                                      notificationsEnabled: enabled, baseline: baseline) {
                foregroundNotice = .init(scope: scope, candidate: candidate,
                                         hideContent: store?.notificationContentHiddenForPresentation ?? true)
            }
        }
    }

    /// Call after changing scene visibility or the currently visible conversation.
    func foregroundContextDidChange() {
        let context = foregroundContext()
        guard let notice = foregroundNotice else { return }
        guard notice.scope == currentForegroundScope, context.isActive, store?.notificationsEnabled == true else {
            foregroundNotice = nil; return
        }
        if context.isReading(notice.candidate) { foregroundNotice = nil }
    }

    /// Preference changes remove an already visible preview without resetting
    /// event deduplication or replaying it when details are enabled again.
    func notificationContentPreferenceDidChange() {
        foregroundNotice = nil
        if let store, store.notificationContentHiddenForPresentation {
            system.clearNotifications()
            system.setBadge(store.notificationsEnabled && permission.permitsDelivery ? store.unreadMessageCount : 0)
        }
    }

    func dismissForegroundNotice(_ id: UUID? = nil) {
        guard id == nil || foregroundNotice?.id == id else { return }
        foregroundNotice = nil
    }

    private func clearForegroundSession() {
        foregroundNotice = nil; foregroundGate.reset()
    }
    func privacyChanged() {
        clearForegroundSession()
        operation = UUID(); task?.cancel(); task = nil
        bindingTask?.cancel(); bindingTask = nil; bindingFingerprint = nil
        bindingAttempt = UUID()
        pendingTap = nil; tapAccount = nil; navigation = nil; resolving = false
        pendingInboxRequest = nil
        system.clearNotifications()
        scheduleRefresh()
    }
    func endSession() {
        clearForegroundSession()
        let oldStore = store
        let removal = sessionKey != nil ? nextRevision(create: false) : nil
        operation = UUID(); task?.cancel(); task = nil
        bindingTask?.cancel(); bindingTask = nil; bindingFingerprint = nil
        bindingAttempt = UUID()
        pendingTap = nil; tapAccount = nil; navigation = nil; resolving = false
        pendingInboxRequest = nil
        sessionKey = nil; accountTag = nil; registeredFingerprint = nil; token = nil
        lastRegisteredAt = nil
        isRegistered = false; isBusy = false; message = nil
        system.unregister(); system.clearNotifications()
        if let removal, let unbind = oldStore?.pushUnbindOperation(installationID: removal.0, revision: removal.1) {
            // Rights-only request captured with the old bearer; server requires
            // the matching session and revision, so it cannot detach a new user.
            let previous = teardownTask
            teardownTask = Task { _ = await previous?.result; try? await unbind() }
        }
    }
    func waitForTeardown() async { _ = await teardownTask?.result }
    func consumeInboxRequest(_ id: UUID) -> Bool {
        guard pendingInboxRequest == id else { return false }
        pendingInboxRequest = nil
        return true
    }
    private func scheduleRefresh() {
        task?.cancel()
        task = Task { [weak self] in await self?.refresh() }
    }
    private func valid(_ id: UUID, key: String) -> Bool {
        !Task.isCancelled && operation == id && sessionKey == key && store?.pushSessionKey == key
    }
    private func nextRevision(create: Bool) -> (String, Int64)? {
        var installation = identity.read("pushInstallationID")
        if installation == nil, create {
            let id = UUID().uuidString.lowercased()
            guard (try? identity.write(id, key: "pushInstallationID")) != nil else { message = "无法安全保存通知设备标识。"; return nil }
            installation = id
        }
        guard let installation, UUID(uuidString: installation) != nil else { return nil }
        let previous = Int64(identity.read("pushRegistrationRevision") ?? "0") ?? 0
        guard previous >= 0, previous < Int64.max else { return nil }
        let revision = previous + 1
        do { try identity.write(String(revision), key: "pushRegistrationRevision"); return (installation, revision) }
        catch { message = "无法安全保存通知设备状态。"; return nil }
    }
    private func unbindCurrent() async {
        guard let removal = nextRevision(create: false), let action = store?.pushUnbindOperation(installationID: removal.0, revision: removal.1) else { return }
        try? await action()
    }
    private func bindIfReady(id: UUID, key: String) async {
        guard valid(id, key: key), permission.permitsDelivery, let store, store.notificationsEnabled, let token else { return }
        guard let environment = environment() else { message = "当前安装包尚不能确认通知签名环境，请使用已启用推送的真机版本。"; return }
        let fingerprint = "\(key)|\(token)|\(environment)|\(permission.rawValue)"
        guard registeredFingerprint != fingerprint || Date().timeIntervalSince(lastRegisteredAt ?? .distantPast) >= 43_200 else { return }
        guard bindingFingerprint != fingerprint else { return }
        let attempt = UUID(); bindingAttempt = attempt
        bindingFingerprint = fingerprint
        defer { if bindingAttempt == attempt { bindingFingerprint = nil } }
        guard let registration = nextRevision(create: true) else { return }
        do {
            let receipt = try await store.registerPush(installationID: registration.0, revision: registration.1,
                                                       deviceToken: token, environment: environment, permission: permission.rawValue)
            guard valid(id, key: key), bindingAttempt == attempt else { return }
            guard receipt.ok, receipt.accountTag == accountTag else { throw KikiAPIError.invalidResponse }
            isRegistered = receipt.registered; registeredFingerprint = receipt.registered ? fingerprint : nil
            lastRegisteredAt = receipt.registered ? Date() : nil
            message = receipt.registered ? nil : "通知提醒暂未启用，请检查账号通知开关。"
        } catch is CancellationError { }
        catch { if valid(id, key: key), bindingAttempt == attempt { isRegistered = false; message = "通知设备登记未完成，请稍后重试。" } }
    }
    private func resolvePendingTap(id: UUID, key: String) async {
        guard let tap = pendingTap, !resolving, let store, valid(id, key: key) else { return }
        guard (tapAccount == nil || tapAccount == key), tap.accountTag == accountTag else {
            pendingTap = nil; tapAccount = nil; system.clearNotifications(); return
        }
        if let expected = tapNavigationRevision, expected != store.socialNavigationRevision {
            pendingTap = nil; tapAccount = nil; return
        }
        store.cancelPendingSocialNavigation()
        resolving = true
        defer {
            resolving = false
            // A newer tap may have refreshed while this lookup was in flight.
            // Resolve it now rather than waiting for a later foreground poll.
            if let pendingTap, pendingTap != tap { scheduleRefresh() }
        }
        let navigationRevision = store.socialNavigationRevision
        tapNavigationRevision = navigationRevision
        do {
            let route = try await store.resolvePush(tap.deliveryID)
            guard validTap(id, key: key, tap: tap, navigationRevision: navigationRevision) else { return }
            let content: KikiPushNavigation.Content?
            if route.type == "direct_message", let peer = route.personID { content = .direct(try await store.socialPerson(peer)) }
            else if route.type == "notification", let roomID = route.roomID {
                guard KikiRoomNotificationRequest.isValidRoomID(roomID), let notificationID = route.notificationID,
                      UUID(uuidString: notificationID) != nil else { throw KikiAPIError.invalidResponse }
                content = .room(roomID: roomID, notificationID: notificationID)
            }
            else if route.type == "notification" { content = nil }
            else { throw KikiAPIError.invalidResponse }
            guard validTap(id, key: key, tap: tap, navigationRevision: navigationRevision) else { return }
            await store.prepareForMessageNavigation()
            guard validTap(id, key: key, tap: tap, navigationRevision: navigationRevision) else { return }
            pendingTap = nil; tapAccount = nil
            if let content, case .room(let roomID, let notificationID) = content {
                // Root can be detached under a full-screen room. Publish the
                // intent directly to the same subscribed scene presenter.
                store.requestRoomNotification(roomID: roomID, notificationID: notificationID)
            }
            commitNavigation(content)
            await store.refreshSocialSummary()
        } catch is CancellationError { }
        catch {
            guard valid(id, key: key), navigationRevision == store.socialNavigationRevision else { return }
            pendingTap = nil; tapAccount = nil
            store.notify("这条提醒已失效或当前账号无法查看。")
        }
    }

    private func validTap(_ id: UUID, key: String, tap: KikiPushTap, navigationRevision: Int) -> Bool {
        guard valid(id, key: key), pendingTap == tap else { return false }
        guard store?.socialNavigationRevision == navigationRevision else {
            pendingTap = nil; tapAccount = nil; return false
        }
        return true
    }

    private func commitNavigation(_ content: KikiPushNavigation.Content?) {
        let request = UUID()
        inboxNavigationRevision = store?.socialNavigationRevision
        pendingInboxRequest = content == nil ? request : nil
        navigation = content.map { KikiPushNavigation(content: $0) }
        inboxRequest = request
    }
}

@MainActor final class KikiPushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        KikiPushController.shared.receivedToken(deviceToken)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        KikiPushController.shared.registrationFailed()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let tap = KikiPushTap(payload: notification.request.content.userInfo)
        Task { @MainActor in KikiPushController.shared.receiveForeground(tap) }
        completionHandler([])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tap = response.actionIdentifier == UNNotificationDismissActionIdentifier ? nil : KikiPushTap(payload: response.notification.request.content.userInfo)
        if let tap { Task { @MainActor in KikiPushController.shared.receiveTap(tap) } }
        completionHandler()
    }
}

struct KikiPushPreferencesView: View {
    @ObservedObject var store: KikiAppStore
    @ObservedObject var push: KikiPushController
    @Environment(\.dismiss) private var dismiss
    @State private var contentPreferenceError: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("消息提醒", systemImage: "bell.badge").font(.title3.weight(.semibold))
                    Text("收到私信、新的关注或关注的人开播时，及时提醒你。开启隐藏消息内容后，通知将不显示对方姓名和消息正文。")
                        .foregroundStyle(KikiPalette.secondary)
                }
                Section("提醒设置") {
                    Toggle("允许账号接收通知", isOn: Binding(get: { store.notificationsEnabled }, set: { enabled in
                        Task { if enabled { await push.enable() } else { await push.disable() } }
                    })).disabled(push.isBusy).accessibilityIdentifier("push.accountToggle")
                    Toggle("隐藏消息内容", isOn: Binding(get: { store.hideNotificationContent }, set: { hidden in
                        contentPreferenceError = nil
                        let account = store.pushSessionKey
                        Task {
                            guard account != nil, account == store.pushSessionKey else { return }
                            do { try await store.setHideNotificationContent(hidden) }
                            catch is CancellationError { }
                            catch { if account == store.pushSessionKey { contentPreferenceError = error.localizedDescription } }
                        }
                    })).disabled(store.isUpdatingNotificationContent).accessibilityIdentifier("push.hideContentToggle")
                    LabeledContent("本机系统权限", value: push.permission.label)
                    if push.permission == .denied {
                        Link("前往系统设置允许通知", destination: URL(string: UIApplication.openSettingsURLString)!)
                    } else if push.permission == .notDetermined {
                        Button("允许系统通知") { Task { await push.enable() } }.disabled(push.isBusy)
                    } else if store.notificationsEnabled && push.permission.permitsDelivery {
                        Label(push.isRegistered ? "本机已登记" : "正在准备本机通知", systemImage: push.isRegistered ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(KikiPalette.secondary)
                    }
                    if let message = push.message { Text(message).font(.footnote).foregroundStyle(KikiPalette.secondary) }
                    if let contentPreferenceError { Text(contentPreferenceError).font(.footnote).foregroundStyle(KikiPalette.secondary) }
                }
                Section {
                    Text("账号开关会同步到你登录的其他设备。关闭通知不影响 App 内的私信和互动记录。系统是否展示横幅、声音或角标，还取决于本机的通知设置和专注模式。")
                        .font(.footnote).foregroundStyle(KikiPalette.secondary)
                }
            }.scrollContentBackground(.hidden).background(KikiPalette.background)
                .navigationTitle("通知设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .task { await push.refresh() }
                .onChange(of: store.pushSessionKey) { _ in contentPreferenceError = nil }
        }.tint(KikiPalette.purple)
    }
}
