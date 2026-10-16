import AVFoundation
import AtomicXCore
import Combine
import Foundation
import RTCRoomEngine
import TUILiveKit
import TUICore
import UIKit

/// Live room information returned by the real RTC service, rather than a local seed list.
struct KikiRTCListing: Identifiable, Equatable {
    let id: String
    let title: String
    let host: String
    let hostID: String
    let audience: Int
    let isLive: Bool
    let category: String
    let theme: Int
    let coverURL: String
    let avatarURL: String
    let startTime: Int
}

enum KikiRTCError: Foundation.LocalizedError {
    case unavailable(String)
    case sdk(Int, String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .sdk(let code, let message): return "\(message)（\(code)）"
        }
    }
}

extension Notification.Name {
    static let kikiRTCRoomClosed = Notification.Name("KikiRTCRoomClosed")
    static let kikiRTCSessionExpired = Notification.Name("KikiRTCSessionExpired")
}

/// Owns authentication and routes into TUILiveKit's production audio/video rooms.
/// UserSig is obtained from the application server; no SDK signing key is linked here.
@MainActor
final class KikiRTCService: ObservableObject {
    static let shared = KikiRTCService()

    @Published private(set) var isPresentingRoom = false
    @Published private(set) var currentRoomID: String?
    @Published private(set) var isVoiceRoomMinimized = false
    var onRoomClosed: ((String) -> Void)?
    var onSessionExpired: (() -> Void)?

    private weak var roomController: UIViewController?
    // Keep the original room and its SDK subscriptions alive while its UI is hidden.
    private var minimizedVoiceRoomController: TUIVoiceRoomViewController?
    private var voiceRoomOverlay: KikiVoiceRoomFloatingOverlay?
    private var isRestoringVoiceRoom = false
    private var voiceRoomPresentationGeneration = 0
    private var loginEvents: AnyCancellable?
    private var liveState: AnyCancellable?
    private var liveEvents: AnyCancellable?
    private var observedSDKRoomID: String?

    var isLoggedIn: Bool {
        LoginStore.shared.state.value.loginStatus == .logined
    }

    var currentSDKRoomID: String? {
        let live = LiveListStore.shared.state.value.currentLive
        return live.liveID.isEmpty ? nil : live.liveID
    }

    func isCurrentRoom(_ roomID: String) -> Bool {
        let live = LiveListStore.shared.state.value.currentLive
        return live.liveID == roomID && !live.isEmpty
    }

    private init() {
        KikiSDKAvatarTrust.install()
        TUIGlobalization.setPreferredLanguage("zh-Hans")
        TUIGlobalization.setRTLOption(false)
        UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        liveState = LiveListStore.shared.state.subscribe(StatePublisherSelector(keyPath: \LiveListState.currentLive))
            .receive(on: RunLoop.main)
            .sink { [weak self] live in
                guard let self else { return }
                let previous = self.observedSDKRoomID
                self.observedSDKRoomID = live.liveID.isEmpty ? nil : live.liveID
                if let previous, previous != self.observedSDKRoomID {
                    if self.isVoiceRoomMinimized, self.currentRoomID == previous {
                        self.clearMinimizedVoiceRoom()
                    }
                    // Floating-window close and remote termination can end a room
                    // without a visible controller being dismissed a second time.
                    self.notifyRoomClosed(previous)
                }
            }
        liveEvents = LiveListStore.shared.liveListEventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                guard let self, self.isVoiceRoomMinimized else { return }
                let roomID: String
                switch event {
                case .onLiveEnded(liveID: let id, reason: _, message: _): roomID = id
                case .onKickedOutOfLive(liveID: let id, reason: _, message: _): roomID = id
                }
                guard self.currentRoomID == roomID else { return }
                self.clearMinimizedVoiceRoom()
                self.notifyRoomClosed(roomID)
            }
        loginEvents = LoginStore.shared.loginEventPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.roomController?.dismiss(animated: false)
                    self.clearMinimizedVoiceRoom()
                    if FloatWindow.shared.isShowingFloatWindow() { FloatWindow.shared.releaseFloatWindow() }
                    self.onSessionExpired?()
                    NotificationCenter.default.post(name: .kikiRTCSessionExpired, object: nil)
                }
            }
    }

    func login(sdkAppID: Int, userID: String, userSig: String) async throws {
        guard sdkAppID > 0, let appID = Int32(exactly: sdkAppID), !userID.isEmpty, !userSig.isEmpty else {
            throw KikiRTCError.unavailable("音视频服务尚未配置，请联系管理员配置腾讯云应用。")
        }
        TUIGlobalization.setPreferredLanguage("zh-Hans")
        try await complete { completion in
            LoginStore.shared.login(sdkAppID: appID, userID: userID, userSig: userSig, completion: completion)
        }
    }

    func logout() async {
        let live = LiveListStore.shared.state.value.currentLive
        if !live.liveID.isEmpty {
            if live.liveOwner.userID == LoginStore.shared.state.value.loginUserInfo?.userID {
                _ = try? await result { completion in LiveListStore.shared.endLive(completion: completion) }
            } else {
                try? await complete { completion in LiveListStore.shared.leaveLive(completion: completion) }
            }
        }
        roomController?.dismiss(animated: false)
        clearMinimizedVoiceRoom()
        if FloatWindow.shared.isShowingFloatWindow() { FloatWindow.shared.releaseFloatWindow() }
        try? await complete { completion in LoginStore.shared.logout(completion: completion) }
    }

    func updateProfile(userID: String, name: String, bio: String, avatarURL: String) async throws {
        var profile = UserProfile(userID: userID, nickname: name, avatarURL: avatarURL)
        profile.selfSignature = bio
        try await complete { completion in
            LoginStore.shared.setSelfInfo(userProfile: profile, completion: completion)
        }
    }

    func fetchRooms() async throws -> [KikiRTCListing] {
        try requireLogin()
        var cursor = ""
        var rooms: [String: KikiRTCListing] = [:]
        // The SDK limits page size to 100. Stop on an unchanged cursor as well as
        // the last page so a failed pagination cursor cannot spin indefinitely.
        for _ in 0..<10 {
            try Task.checkCancellation()
            try await complete { completion in
                LiveListStore.shared.fetchLiveList(cursor: cursor, count: 100, completion: completion)
            }
            let state = LiveListStore.shared.state.value
            for info in state.liveList where info.liveID.hasPrefix("voice_kiki_") || info.liveID.hasPrefix("live_kiki_") {
                rooms[info.liveID] = listing(info)
            }
            let next = state.liveListCursor
            if next.isEmpty || next == cursor { break }
            cursor = next
        }
        return rooms.values.sorted { $0.startTime > $1.startTime }
    }

    /// Presents the SDK UI after confirming the room still exists on the RTC server.
    func presentRoom(roomID: String, isLive: Bool, isOwner: Bool) async throws {
        try requireLogin()
        if isVoiceRoomMinimized, currentRoomID == roomID {
            try await resumeMinimizedVoiceRoom()
            return
        }
        if FloatWindow.shared.isShowingFloatWindow(), FloatWindow.shared.getCurrentRoomId() == roomID,
           let presenter = Self.topController() {
            _ = FloatWindow.shared.resumeLive(atViewController: presenter)
            return
        }
        try requireNoActiveRoom()
        let info: LiveInfo = try await result { completion in
            LiveListStore.shared.fetchLiveInfo(liveID: roomID, completion: completion)
        }
        let actualOwner = info.liveOwner.userID == LoginStore.shared.state.value.loginUserInfo?.userID
        let video = isVideoRoom(info)
        let child: UIViewController
        if video {
            child = actualOwner
                ? TUILiveRoomAnchorViewController(liveInfo: info, behavior: .enterRoom)
                : TUILiveRoomAudienceViewController(roomId: roomID)
            (child as? TUILiveRoomAudienceViewController)?.enableRoomSwiping = false
            (child as? TUILiveRoomAudienceViewController)?.enableGifts = false
        } else {
            let params = RoomParams(maxSeatCount: 8, seatMode: .applyToTake)
            params.usesKikiAppearance = true
            params.enableMinimization = true
            params.enableKaraoke = false
            params.enableCrossRoomInteraction = false
            params.enableGifts = false
            params.initialLiveInfo = info
            child = TUIVoiceRoomViewController(roomId: roomID, behavior: actualOwner ? .resume : .join, roomParams: params)
        }
        if actualOwner { try await requireMediaPermission(video: video) }
        try await present(child, roomID: roomID)
        try await waitUntilJoined(roomID)
    }

    /// Creates the real RTC room through the SDK host UI. Success means the SDK
    /// has confirmed the room is running, so callers can then publish their registry record.
    func createRoom(roomID: String, title: String, category: String, isLive: Bool, theme: Int) async throws {
        try requireLogin()
        try requireNoActiveRoom()
        guard !roomID.isEmpty, roomID.utf8.count <= 48 else {
            throw KikiRTCError.unavailable("房间编号无效，请重新创建房间。")
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 100 else {
            throw KikiRTCError.unavailable("房间名称过长，请控制在 100 字节以内（约 33 个汉字）。")
        }
        try await requireMediaPermission(video: isLive)
        var info = LiveInfo(seatTemplate: isLive ? .videoDynamicGrid9Seats : .audioSalon(seatCount: 8))
        info.liveID = roomID
        info.liveName = title
        info.isPublicVisible = true
        info.keepOwnerOnSeat = true
        info.seatMode = .apply
        info.isGiftEnabled = false
        info.metaData = ["kiki.category": category, "kiki.theme": String(theme), "kiki.kind": isLive ? "live" : "voice"]
        let child: UIViewController
        if isLive {
            child = TUILiveRoomAnchorViewController(liveInfo: info, behavior: .createRoom)
        } else {
            let params = RoomParams(maxSeatCount: 8, seatMode: .applyToTake)
            params.usesKikiAppearance = true
            params.enableMinimization = true
            params.enableKaraoke = false
            params.enableCrossRoomInteraction = false
            params.enableGifts = false
            params.initialLiveInfo = info
            child = TUIVoiceRoomViewController(roomId: roomID, behavior: .autoCreate, roomParams: params)
        }
        try await present(child, roomID: roomID)
        do {
            try await waitUntilJoined(roomID)
            // Metadata is also written explicitly for SDK/server versions that do
            // not carry initial metadata through startLive.
            try await complete { completion in
                LiveListStore.shared.updateLiveMetaData(info.metaData, completion: completion)
            }
        } catch {
            if LiveListStore.shared.state.value.currentLive.liveID == roomID {
                _ = try? await result { completion in LiveListStore.shared.endLive(completion: completion) }
            }
            roomController?.dismiss(animated: true)
            throw error
        }
    }

    private func listing(_ info: LiveInfo) -> KikiRTCListing {
        return KikiRTCListing(id: info.liveID, title: info.liveName, host: info.liveOwner.userName.isEmpty ? info.liveOwner.userID : info.liveOwner.userName,
                              hostID: info.liveOwner.userID, audience: info.totalViewerCount, isLive: isVideoRoom(info),
                              category: info.metaData["kiki.category"] ?? "随心聊", theme: Int(info.metaData["kiki.theme"] ?? "") ?? 0,
                              coverURL: info.coverURL, avatarURL: info.liveOwner.avatarURL, startTime: info.createTime)
    }

    private func isVideoRoom(_ info: LiveInfo) -> Bool {
        switch info.seatTemplate {
        case .audioSalon, .karaoke: return false
        default: return true
        }
    }

    private func requireLogin() throws {
        guard LoginStore.shared.state.value.loginStatus == .logined else {
            throw KikiRTCError.unavailable("请先登录账号。")
        }
    }

    func requireNoActiveRoom() throws {
        guard !isPresentingRoom, !isVoiceRoomMinimized, !isRestoringVoiceRoom,
              currentSDKRoomID == nil, !FloatWindow.shared.isShowingFloatWindow() else {
            throw KikiRTCError.unavailable(isVoiceRoomMinimized ? "你仍在语聊房中，请先点击悬浮球返回并离开房间。" : "请先退出当前房间。")
        }
    }

    private func present(_ child: UIViewController, roomID: String) async throws {
        // A SwiftUI creation sheet can still be completing its dismissal animation.
        // Wait for that transition before presenting the SDK controller.
        for _ in 0..<15 {
            if Self.topController()?.isBeingDismissed != true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let presenter = Self.topController(), presenter.viewIfLoaded?.window != nil else {
            throw KikiRTCError.unavailable("当前页面尚未准备好，请稍后重试。")
        }
        child.modalPresentationStyle = .fullScreen
        if let anchor = child as? TUILiveRoomAnchorViewController,
           let anchorView = anchor.view as? AnchorView {
            anchorView.bottomItems = [.coGuest, .more]
        }
        let onPresentationChanged: (Bool) -> Void = { [weak self, weak child] visible in
            guard let self else { return }
            guard self.currentRoomID == roomID || self.roomController === child else { return }
            self.isPresentingRoom = visible
            if !visible, self.isVoiceRoomMinimized, self.minimizedVoiceRoomController === child {
                // Dismissing the full-screen UI is not leaving the RTC room.
                return
            }
            self.currentRoomID = visible ? roomID : nil
            self.roomController = visible || self.isCurrentRoom(roomID) ? child : nil
            if !visible, !self.isCurrentRoom(roomID) {
                self.notifyRoomClosed(roomID)
            }
        }
        if let voice = child as? TUIVoiceRoomViewController {
            voice.onRoomPresentationChanged = onPresentationChanged
            voice.onMinimizeRequested = { [weak self] in self?.minimizeVoiceRoom() }
        }
        if let anchor = child as? TUILiveRoomAnchorViewController { anchor.onRoomPresentationChanged = onPresentationChanged }
        if let audience = child as? TUILiveRoomAudienceViewController { audience.onRoomPresentationChanged = onPresentationChanged }
        currentRoomID = roomID
        isPresentingRoom = true
        roomController = child
        await withCheckedContinuation { continuation in
            presenter.present(child, animated: true) { continuation.resume() }
        }
    }

    /// Hides only the room UI. Audio, seats, chat and the room owner stay connected.
    @discardableResult
    func minimizeVoiceRoom() -> Bool {
        let live = LiveListStore.shared.state.value.currentLive
        guard !isVoiceRoomMinimized, !isRestoringVoiceRoom,
              let controller = roomController as? TUIVoiceRoomViewController,
              let roomID = currentRoomID, live.liveID == roomID, live.status == .running,
              controller.presentingViewController != nil, !controller.isBeingDismissed,
              controller.presentedViewController == nil,
              let scene = controller.view.window?.windowScene else { return false }

        voiceRoomPresentationGeneration += 1
        let generation = voiceRoomPresentationGeneration
        minimizedVoiceRoomController = controller
        isVoiceRoomMinimized = true
        voiceRoomOverlay = KikiVoiceRoomFloatingOverlay(windowScene: scene, roomTitle: live.liveName,
                                                       avatarURL: live.liveOwner.avatarURL) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                do { try await self.resumeMinimizedVoiceRoom() }
                catch {
                    guard let presenter = Self.topController(), !(presenter is UIAlertController) else { return }
                    let alert = UIAlertController(title: "暂时无法返回语聊房", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "知道了", style: .default))
                    presenter.present(alert, animated: true)
                }
            }
        }
        controller.view.endEditing(true)
        // Keep SDK state subscriptions running, but queue popovers such as seat
        // invitations until their original controller is visible again.
        controller.enableSubscribeRouter(enable: false)
        controller.dismiss(animated: true) { [weak self] in
            guard let self, self.voiceRoomPresentationGeneration == generation,
                  self.isVoiceRoomMinimized, !self.isRestoringVoiceRoom,
                  self.isCurrentRoom(roomID) else { return }
            UIApplication.shared.isIdleTimerDisabled = false
            self.voiceRoomOverlay?.show()
        }
        return true
    }

    /// Presents the retained controller instead of rejoining or rebuilding the room.
    func resumeMinimizedVoiceRoom() async throws {
        guard isVoiceRoomMinimized, !isRestoringVoiceRoom,
              let controller = minimizedVoiceRoomController, let roomID = currentRoomID else { return }
        guard isCurrentRoom(roomID), LiveListStore.shared.state.value.currentLive.status == .running else {
            clearMinimizedVoiceRoom()
            throw KikiRTCError.unavailable("语聊房已结束，请刷新房间列表。")
        }
        try requireLogin()
        isRestoringVoiceRoom = true
        let generation = voiceRoomPresentationGeneration
        defer {
            if voiceRoomPresentationGeneration == generation {
                isRestoringVoiceRoom = false
                // A card can begin restoring before the minimize animation ends.
                // If that attempt fails or is cancelled, keep a visible way back.
                if isVoiceRoomMinimized, isCurrentRoom(roomID), controller.presentingViewController == nil {
                    UIApplication.shared.isIdleTimerDisabled = false
                    voiceRoomOverlay?.show()
                }
            }
        }
        // A room can be resumed from a card while the minimize animation finishes,
        // or above a profile sheet that is still transitioning.
        for _ in 0..<20 {
            try Task.checkCancellation()
            let top = Self.topController()
            if !controller.isBeingDismissed, controller.presentingViewController == nil,
               top?.isBeingDismissed != true, top?.isBeingPresented != true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard voiceRoomPresentationGeneration == generation, isCurrentRoom(roomID) else {
            throw KikiRTCError.unavailable("语聊房已结束，请刷新房间列表。")
        }
        if let alert = Self.topController() as? UIAlertController {
            await withCheckedContinuation { continuation in
                alert.dismiss(animated: false) { continuation.resume() }
            }
        }
        guard let presenter = Self.topController(), presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented,
              controller.presentingViewController == nil, !controller.isBeingDismissed else {
            throw KikiRTCError.unavailable("页面正在切换，请稍后再点击悬浮球。")
        }
        presenter.view.endEditing(true)
        voiceRoomOverlay?.hide()
        controller.modalPresentationStyle = .fullScreen
        UIApplication.shared.isIdleTimerDisabled = true
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: true) { continuation.resume() }
        }
        guard voiceRoomPresentationGeneration == generation, isCurrentRoom(roomID) else {
            controller.dismiss(animated: false)
            throw KikiRTCError.unavailable("语聊房已结束，请刷新房间列表。")
        }
        isPresentingRoom = true
        isVoiceRoomMinimized = false
        minimizedVoiceRoomController = nil
        voiceRoomOverlay = nil
        controller.enableSubscribeRouter(enable: true)
    }

    private func clearMinimizedVoiceRoom() {
        guard isVoiceRoomMinimized || minimizedVoiceRoomController != nil else { return }
        voiceRoomPresentationGeneration += 1
        let controller = minimizedVoiceRoomController
        voiceRoomOverlay?.hide()
        voiceRoomOverlay = nil
        minimizedVoiceRoomController = nil
        isVoiceRoomMinimized = false
        isRestoringVoiceRoom = false
        if roomController === controller {
            roomController = nil
            currentRoomID = nil
            isPresentingRoom = false
        }
        controller?.dismiss(animated: false)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func notifyRoomClosed(_ roomID: String) {
        onRoomClosed?(roomID)
        NotificationCenter.default.post(name: .kikiRTCRoomClosed, object: nil, userInfo: ["roomID": roomID])
    }

    private func waitUntilJoined(_ roomID: String) async throws {
        for _ in 0..<250 {
            try Task.checkCancellation()
            let live = LiveListStore.shared.state.value.currentLive
            if live.liveID == roomID, live.status == .running { return }
            guard isPresentingRoom else { throw KikiRTCError.unavailable("已退出房间。") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        roomController?.dismiss(animated: true)
        throw KikiRTCError.unavailable("连接房间超时，请检查网络或音视频服务配置后重试。")
    }

    private func requireMediaPermission(video: Bool) async throws {
        if video, AVCaptureDevice.default(for: .video) == nil {
            throw KikiRTCError.unavailable("当前设备没有可用摄像头，请使用真机开播。")
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard microphone else { throw KikiRTCError.unavailable("请在系统设置中允许 Kiki语聊使用麦克风。") }
        if video {
            let camera = await AVCaptureDevice.requestAccess(for: .video)
            guard camera else { throw KikiRTCError.unavailable("请在系统设置中允许 Kiki语聊使用摄像头。") }
        }
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var current = root
        while let presented = current.presentedViewController { current = presented }
        if let navigation = current as? UINavigationController { return navigation.visibleViewController ?? navigation }
        if let tabs = current as? UITabBarController { return tabs.selectedViewController ?? tabs }
        return current
    }

    private func complete(_ invoke: (@escaping CompletionClosure) -> Void) async throws {
        let _: Void = try await result(invoke)
    }

    private func result<Value>(_ invoke: (@escaping (Result<Value, ErrorInfo>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            invoke { result in
                continuation.resume(with: result.mapError { KikiRTCError.sdk($0.code, $0.message) })
            }
        }
    }
}
