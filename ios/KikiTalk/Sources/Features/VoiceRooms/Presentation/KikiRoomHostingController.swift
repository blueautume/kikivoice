import Foundation
import SwiftUI
import UIKit

@MainActor
final class KikiRoomSceneLifecycle: ObservableObject {
    @Published private(set) var phase: ScenePhase = .background

    func update(_ phase: ScenePhase) {
        if self.phase != phase { self.phase = phase }
    }
}

struct KikiRoomSceneRoot<Content: View>: View {
    let content: Content
    @ObservedObject var lifecycle: KikiRoomSceneLifecycle

    var body: some View {
        content.environment(\.scenePhase, lifecycle.phase)
    }
}

/// UIKit-presented hosts do not inherit the SwiftUI App's scene environment.
/// Keep one root view alive while forwarding only its actual window's lifecycle.
@MainActor
final class KikiRoomHostingController<Content: View>: UIHostingController<KikiRoomSceneRoot<Content>> {
    private let lifecycle: KikiRoomSceneLifecycle
    private let sceneNotificationCenter: NotificationCenter
    private weak var roomScene: UIWindowScene?
    private var isRoomVisible = false
    private var sceneObservers: [NSObjectProtocol] = []

    init(rootView: Content, notificationCenter: NotificationCenter = .default) {
        let lifecycle = KikiRoomSceneLifecycle()
        self.lifecycle = lifecycle
        self.sceneNotificationCenter = notificationCenter
        super.init(rootView: KikiRoomSceneRoot(content: rootView, lifecycle: lifecycle))
        observe(UIScene.didActivateNotification, phase: .active)
        observe(UIScene.willDeactivateNotification, phase: .inactive)
        observe(UIScene.didEnterBackgroundNotification, phase: .background)
        observe(UIScene.willEnterForegroundNotification, phase: .inactive)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(rootView:)") }

    deinit {
        sceneObservers.forEach { sceneNotificationCenter.removeObserver($0) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        roomScene = view.window?.windowScene ?? presentingViewController?.viewIfLoaded?.window?.windowScene
        lifecycle.update(.inactive)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        roomScene = view.window?.windowScene
        isRoomVisible = true
        switch roomScene?.activationState {
        case .foregroundActive: lifecycle.update(.active)
        case .foregroundInactive: lifecycle.update(.inactive)
        default: lifecycle.update(.background)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isRoomVisible = false
        lifecycle.update(.inactive)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycle.update(.background)
    }

    private func observe(_ name: Notification.Name, phase: ScenePhase) {
        sceneObservers.append(sceneNotificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, let scene = notification.object as? UIWindowScene,
                      scene === self.roomScene, self.isRoomVisible else { return }
                self.lifecycle.update(phase)
            }
        })
    }
}
