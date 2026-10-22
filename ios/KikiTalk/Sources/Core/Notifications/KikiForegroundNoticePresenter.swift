import SwiftUI
import UIKit

/// A scene-local, non-key window keeps a brief notice above SwiftUI sheets
/// without dismissing their bindings or interrupting an active text field.
@MainActor
struct KikiForegroundNoticePresenter: UIViewRepresentable {
    @ObservedObject var push: KikiPushController
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> KikiForegroundNoticeHostView {
        let view = KikiForegroundNoticeHostView()
        view.isUserInteractionEnabled = false
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.render() }
        context.coordinator.host = view
        return view
    }

    func updateUIView(_ uiView: KikiForegroundNoticeHostView, context: Context) {
        context.coordinator.push = push
        context.coordinator.colorScheme = colorScheme
        context.coordinator.render()
    }

    static func dismantleUIView(_ uiView: KikiForegroundNoticeHostView, coordinator: Coordinator) {
        uiView.windowChanged = nil
        coordinator.stop()
    }

    @MainActor final class Coordinator: NSObject {
        weak var host: KikiForegroundNoticeHostView?
        weak var push: KikiPushController?
        var colorScheme = ColorScheme.light
        private let presentation = KikiForegroundNoticePresentation()
        private var noticeID: UUID?
        private var dismissal: Task<Void, Never>?

        override init() {
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                name: UIScene.willDeactivateNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                name: UIScene.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(sceneActivated(_:)),
                name: UIScene.didActivateNotification, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self); dismissal?.cancel() }

        func render() {
            guard let push, let scene = host?.window?.windowScene, scene.activationState == .foregroundActive,
                  let notice = push.foregroundNotice, notice.scope == push.currentForegroundScope,
                  push.foregroundContext().isActive else { stop(); return }
            presentation.show(notice, in: scene, colorScheme: colorScheme) { [weak self, weak push] in
                push?.dismissForegroundNotice(notice.id)
                self?.render()
            }
            guard noticeID != notice.id else { return }
            dismissal?.cancel()
            noticeID = notice.id
            dismissal = Task { [weak self, weak push] in
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                guard !Task.isCancelled, self?.noticeID == notice.id else { return }
                push?.dismissForegroundNotice(notice.id)
                self?.render()
            }
        }

        func stop() {
            dismissal?.cancel(); dismissal = nil; noticeID = nil
            presentation.hide()
        }

        @objc private func sceneDeactivated(_ notification: Notification) {
            guard let scene = notification.object as? UIWindowScene, scene === host?.window?.windowScene else { return }
            let id = noticeID
            stop()
            if let id { push?.dismissForegroundNotice(id) }
        }

        @objc private func sceneActivated(_ notification: Notification) {
            guard let scene = notification.object as? UIWindowScene, scene === host?.window?.windowScene else { return }
            render()
        }
    }
}

@MainActor final class KikiForegroundNoticeHostView: UIView {
    var windowChanged: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); windowChanged?() }
}

/// Owns the real UIKit presentation so its focus and touch behavior can also
/// be exercised without signing in or fetching private inbox data.
@MainActor final class KikiForegroundNoticePresentation {
    private(set) var window: KikiForegroundNoticeWindow?
    private var noticeID: UUID?
    private var colorScheme: ColorScheme?

    func show(_ notice: KikiForegroundNotice, in scene: UIWindowScene, colorScheme: ColorScheme,
              onDismiss: @escaping () -> Void) {
        if window?.windowScene !== scene {
            hide()
            let overlay = KikiForegroundNoticeWindow(windowScene: scene)
            overlay.windowLevel = .normal + 2
            overlay.backgroundColor = .clear
            overlay.accessibilityViewIsModal = false
            window = overlay
        }
        guard let window else { return }
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        if noticeID != notice.id || self.colorScheme != colorScheme {
            let banner = KikiForegroundNoticeBanner(notice: notice, onDismiss: onDismiss) { [weak window] frame in
                window?.bannerFrame = frame
            }
            let controller = UIHostingController(rootView: banner.environment(\.colorScheme, colorScheme))
            controller.view.backgroundColor = .clear
            controller.view.accessibilityViewIsModal = false
            controller.safeAreaRegions = .container
            window.rootViewController = controller
            noticeID = notice.id
            self.colorScheme = colorScheme
        }
        window.isHidden = false
    }

    func hide() {
        window?.isHidden = true
        window?.bannerFrame = .zero
        window?.rootViewController = nil
        window?.windowScene = nil
        window = nil
        noticeID = nil
        colorScheme = nil
    }
}

@MainActor final class KikiForegroundNoticeWindow: UIWindow {
    var bannerFrame = CGRect.zero
    override var canBecomeKey: Bool { false }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bannerFrame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}

private struct KikiForegroundNoticeBanner: View {
    let notice: KikiForegroundNotice
    let onDismiss: () -> Void
    let frameChanged: (CGRect) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onDismiss) {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.title3).foregroundStyle(KikiPalette.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title).font(.subheadline.weight(.semibold)).foregroundStyle(KikiPalette.text)
                        Text(notice.message).font(.footnote).foregroundStyle(KikiPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("foregroundNotice.message")
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                    .foregroundStyle(KikiPalette.secondary).frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("关闭新消息提醒")
                .accessibilityIdentifier("foregroundNotice.close")
        }
        .padding(14)
        .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(KikiPalette.muted.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 6)
        .frame(maxWidth: 560)
        .background(KikiForegroundNoticeHitRegion(frameChanged: frameChanged))
        .padding(.horizontal, 16).padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct KikiForegroundNoticeHitRegion: UIViewRepresentable {
    let frameChanged: (CGRect) -> Void
    func makeUIView(context: Context) -> RegionView {
        let view = RegionView(); view.isUserInteractionEnabled = false
        view.frameChanged = frameChanged
        return view
    }
    func updateUIView(_ uiView: RegionView, context: Context) { uiView.frameChanged = frameChanged }

    final class RegionView: UIView {
        var frameChanged: ((CGRect) -> Void)?
        override func layoutSubviews() { super.layoutSubviews(); reportFrame() }
        override func didMoveToWindow() { super.didMoveToWindow(); reportFrame() }
        private func reportFrame() {
            guard let window else { return }
            frameChanged?(convert(bounds, to: window))
        }
    }
}
