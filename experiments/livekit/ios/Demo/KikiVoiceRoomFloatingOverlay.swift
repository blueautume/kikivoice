import UIKit

/// A scene-local, non-key window keeps the current voice room reachable above app sheets.
@MainActor
final class KikiVoiceRoomFloatingOverlay: NSObject {
    private let window: KikiVoiceRoomOverlayWindow
    private let controller = KikiVoiceRoomOverlayController()
    private let onResume: () -> Void
    private var verticalFraction: CGFloat = 0.68
    private var isOnRight = true
    private var dragStart = CGPoint.zero
    private var keyboardFrameInScreen: CGRect?

    var isVisible: Bool { !window.isHidden }

    init(windowScene: UIWindowScene, roomTitle: String, avatarURL: String?, onResume: @escaping () -> Void) {
        window = KikiVoiceRoomOverlayWindow(windowScene: windowScene)
        self.onResume = onResume
        super.init()

        // A static waveform avoids making another avatar request while the room is minimized.
        _ = avatarURL
        window.frame = windowScene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = controller
        window.bubble = controller.bubble
        controller.onLayout = { [weak self] in self?.positionBubble() }
        controller.bubble.accessibilityLabel = "返回语聊房"
        controller.bubble.accessibilityValue = roomTitle
        controller.bubble.accessibilityHint = "轻点返回聊天室，也可以拖动悬浮球调整位置"
        controller.bubble.accessibilityIdentifier = "voiceRoomFloatingBubble"
        controller.bubble.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "移到左侧", target: self, selector: #selector(moveToLeft)),
            UIAccessibilityCustomAction(name: "移到右侧", target: self, selector: #selector(moveToRight))
        ]
        controller.bubble.addTarget(self, action: #selector(resumeRoom), for: .touchUpInside)
        controller.bubble.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragBubble(_:))))
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func show() {
        guard window.isHidden else { return }
        window.isHidden = false
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        positionBubble()
        // Deliberately do not call makeKeyAndVisible: text fields retain their keyboard focus.
        if !UIAccessibility.isReduceMotionEnabled {
            controller.bubble.alpha = 0
            UIView.animate(withDuration: 0.18) { self.controller.bubble.alpha = 1 }
        }
    }

    func hide() {
        controller.bubble.layer.removeAllAnimations()
        controller.bubble.alpha = 1
        window.isHidden = true
    }

    func update(roomTitle: String, status: String) {
        controller.bubble.accessibilityValue = "\(roomTitle)，\(status)"
        controller.bubble.setStatus(status)
    }

    @objc private func resumeRoom() { onResume() }

    @objc private func moveToLeft() -> Bool {
        isOnRight = false
        positionBubble(animated: true)
        return true
    }

    @objc private func moveToRight() -> Bool {
        isOnRight = true
        positionBubble(animated: true)
        return true
    }

    /// The bottom reserve keeps the floating control clear of the app's two-tab navigation.
    private var restingArea: CGRect {
        let safe = controller.view.bounds.inset(by: controller.view.safeAreaInsets)
        let size = KikiVoiceRoomBubbleButton.size
        let minX = safe.minX + 8 + size.width / 2
        let maxX = max(minX, safe.maxX - 8 - size.width / 2)
        let minY = safe.minY + 12 + size.height / 2
        let maxY = max(minY, safe.maxY - 64 - 12 - size.height / 2)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private var availableArea: CGRect {
        var area = restingArea
        if let keyboardFrameInScreen {
            let keyboard = window.convert(keyboardFrameInScreen, from: window.screen.coordinateSpace)
            if window.bounds.intersects(keyboard) {
                let maxY = max(area.minY, keyboard.minY - 12 - KikiVoiceRoomBubbleButton.size.height / 2)
                area.size.height = max(0, min(area.maxY, maxY) - area.minY)
            }
        }
        return area
    }

    private func positionBubble(animated: Bool = false, duration: TimeInterval = 0.22) {
        guard controller.isViewLoaded, !controller.view.bounds.isEmpty else { return }
        let resting = restingArea
        let available = availableArea
        let center = CGPoint(x: isOnRight ? available.maxX : available.minX,
                             y: min(available.maxY, resting.minY + resting.height * verticalFraction))
        let updates = { self.controller.bubble.center = center }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: updates)
        } else { updates() }
    }

    @objc private func dragBubble(_ gesture: UIPanGestureRecognizer) {
        let bubble = controller.bubble
        switch gesture.state {
        case .began:
            bubble.layer.removeAllAnimations()
            dragStart = bubble.center
        case .changed:
            let translation = gesture.translation(in: controller.view)
            let area = availableArea
            bubble.center = CGPoint(x: min(max(dragStart.x + translation.x, area.minX), area.maxX),
                                    y: min(max(dragStart.y + translation.y, area.minY), area.maxY))
        case .ended, .cancelled, .failed:
            let resting = restingArea
            isOnRight = bubble.center.x >= controller.view.bounds.midX
            verticalFraction = resting.height > 0 ? min(max((bubble.center.y - resting.minY) / resting.height, 0), 1) : 0.5
            positionBubble(animated: true)
        default: break
        }
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        keyboardFrameInScreen = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        positionBubble(animated: isVisible, duration: keyboardDuration(notification))
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardFrameInScreen = nil
        positionBubble(animated: isVisible, duration: keyboardDuration(notification))
    }

    private func keyboardDuration(_ notification: Notification) -> TimeInterval {
        (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    }
}

@MainActor
private final class KikiVoiceRoomOverlayWindow: UIWindow {
    weak var bubble: UIView?

    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, let bubble, !bubble.isHidden,
              bubble.point(inside: bubble.convert(point, from: self), with: event) else { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
private final class KikiVoiceRoomOverlayController: UIViewController {
    let bubble = KikiVoiceRoomBubbleButton(frame: CGRect(origin: .zero, size: KikiVoiceRoomBubbleButton.size))
    var onLayout: (() -> Void)?

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
        view.addSubview(bubble)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
}

@MainActor
private final class KikiVoiceRoomBubbleButton: UIButton {
    static let size = CGSize(width: 76, height: 88)
    private let disc = UIView()
    private let gradient = CAGradientLayer()
    private let waveform = UIImageView()
    private let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        disc.isUserInteractionEnabled = false
        disc.layer.cornerRadius = 32
        disc.layer.shadowColor = UIColor.black.cgColor
        disc.layer.shadowOpacity = 0.30
        disc.layer.shadowRadius = 10
        disc.layer.shadowOffset = CGSize(width: 0, height: 5)
        gradient.colors = [UIColor(red: 0.64, green: 0.48, blue: 1, alpha: 1).cgColor,
                           UIColor(red: 0.45, green: 0.24, blue: 0.93, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0.1, y: 0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        gradient.cornerRadius = 32
        gradient.borderWidth = 1
        gradient.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        disc.layer.addSublayer(gradient)
        waveform.image = UIImage(systemName: "waveform", withConfiguration: UIImage.SymbolConfiguration(pointSize: 27, weight: .semibold))
        waveform.tintColor = .white
        waveform.contentMode = .scaleAspectFit
        waveform.isUserInteractionEnabled = false
        disc.addSubview(waveform)
        caption.text = "语聊中"
        caption.textColor = UIColor(white: 1, alpha: 0.95)
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textAlignment = .center
        caption.backgroundColor = UIColor(red: 0.17, green: 0.11, blue: 0.28, alpha: 0.94)
        caption.layer.cornerRadius = 9
        caption.layer.masksToBounds = true
        caption.isUserInteractionEnabled = false
        addSubview(disc)
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStatus(_ value: String) { caption.text = value }

    override func layoutSubviews() {
        super.layoutSubviews()
        disc.frame = CGRect(x: (bounds.width - 64) / 2, y: 1, width: 64, height: 64)
        gradient.frame = disc.bounds
        disc.layer.shadowPath = UIBezierPath(ovalIn: disc.bounds).cgPath
        waveform.frame = disc.bounds.insetBy(dx: 17, dy: 17)
        caption.frame = CGRect(x: (bounds.width - 56) / 2, y: 67, width: 56, height: 19)
    }

    override var isHighlighted: Bool {
        didSet { disc.alpha = isHighlighted ? 0.74 : 1 }
    }
}
