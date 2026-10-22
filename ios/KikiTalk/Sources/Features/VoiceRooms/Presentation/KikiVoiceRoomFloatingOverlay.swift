import CoreImage
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

    init(windowScene: UIWindowScene, roomTitle: String, avatarURL: String?, avatarIndex: Int = 0, hostName: String = "", onResume: @escaping () -> Void) {
        window = KikiVoiceRoomOverlayWindow(windowScene: windowScene)
        self.onResume = onResume
        super.init()

        window.frame = windowScene.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.accessibilityIdentifier = "voiceRoomFloatingWindow"
        window.rootViewController = controller
        window.bubble = controller.bubble
        controller.onLayout = { [weak self] in self?.positionBubble() }
        controller.bubble.accessibilityLabel = "返回语聊房"
        controller.bubble.setAvatar(url: avatarURL, index: avatarIndex)
        controller.bubble.setMetadata(roomTitle: roomTitle, status: "语聊中", hostName: hostName)
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
        controller.bubble.setPresentationVisible(true)
        // Deliberately do not call makeKeyAndVisible: text fields retain their keyboard focus.
        if !UIAccessibility.isReduceMotionEnabled {
            controller.bubble.alpha = 0
            UIView.animate(withDuration: 0.18) { self.controller.bubble.alpha = 1 }
        }
    }

    func hide() {
        controller.bubble.setPresentationVisible(false)
        controller.bubble.layer.removeAllAnimations()
        controller.bubble.alpha = 1
        window.isHidden = true
    }

    func update(roomTitle: String, status: String, avatarURL: String? = nil, avatarIndex: Int = 0,
                hostName: String = "", isSpeaking: Bool = false, isOnline: Bool = true) {
        controller.bubble.setAvatar(url: avatarURL, index: avatarIndex)
        controller.bubble.setMetadata(roomTitle: roomTitle, status: status, hostName: hostName, isOnline: isOnline)
        controller.bubble.setSpeaking(isSpeaking)
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

    private func avoidingKeyboard(_ center: CGPoint, in area: CGRect) -> CGPoint {
        guard let keyboardFrameInScreen else { return center }
        let keyboardInWindow = window.convert(keyboardFrameInScreen, from: window.screen.coordinateSpace)
        let keyboard = controller.view.convert(keyboardInWindow, from: window).intersection(controller.view.bounds)
        guard !keyboard.isNull, !keyboard.isEmpty else { return center }

        // A floating iPad keyboard only displaces the bubble when it actually covers it.
        let size = KikiVoiceRoomBubbleButton.size
        let obstruction = keyboard.insetBy(dx: -size.width / 2 - 12, dy: -size.height / 2 - 12)
        guard obstruction.contains(center) else { return center }
        let candidates = [
            CGPoint(x: center.x, y: obstruction.minY),
            CGPoint(x: center.x, y: obstruction.maxY),
            CGPoint(x: obstruction.minX, y: center.y),
            CGPoint(x: obstruction.maxX, y: center.y)
        ].filter { $0.x >= area.minX && $0.x <= area.maxX && $0.y >= area.minY && $0.y <= area.maxY }
        return candidates.min {
            hypot($0.x - center.x, $0.y - center.y) < hypot($1.x - center.x, $1.y - center.y)
        } ?? center
    }

    private func positionBubble(animated: Bool = false, duration: TimeInterval = 0.22) {
        guard controller.isViewLoaded, !controller.view.bounds.isEmpty else { return }
        let resting = restingArea
        let preferred = CGPoint(x: isOnRight ? resting.maxX : resting.minX,
                                y: resting.minY + resting.height * verticalFraction)
        let center = avoidingKeyboard(preferred, in: resting)
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
            let area = restingArea
            let preferred = CGPoint(x: min(max(dragStart.x + translation.x, area.minX), area.maxX),
                                    y: min(max(dragStart.y + translation.y, area.minY), area.maxY))
            bubble.center = avoidingKeyboard(preferred, in: area)
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

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        onLayout?()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }
}

@MainActor
final class KikiVoiceRoomBubbleButton: UIButton {
    static let size = CGSize(width: 80, height: 80)
    private let avatarDisc = UIView()
    private let gradient = CAGradientLayer()
    private let avatar = UIImageView()
    private let fallback = UILabel()
    private let rings = [CAShapeLayer(), CAShapeLayer()]
    private var avatarTask: Task<Void, Never>?
    private var avatarURL: String?
    private var avatarIndex: Int?
    private var sourceAvatar: UIImage?
    private var avatarColors: [CGColor] = []
    private var isOnline = true
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var speaking = false
    private var presentationVisible = false
    private var roomTitle = "语聊房"
    private var status = "语聊中"
    private var hostName = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "voiceRoomFloatingBubble"
        for (index, ring) in rings.enumerated() {
            ring.name = "voiceRoomSpeakingRing\(index)"
            ring.fillColor = UIColor.clear.cgColor
            ring.lineWidth = 1.8
            ring.opacity = 0
            layer.addSublayer(ring)
        }
        avatarDisc.isUserInteractionEnabled = false
        avatarDisc.layer.masksToBounds = true
        avatarDisc.layer.borderWidth = 2
        avatarDisc.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        avatarDisc.layer.addSublayer(gradient)
        gradient.startPoint = CGPoint(x: 0.1, y: 0)
        gradient.endPoint = CGPoint(x: 0.9, y: 1)
        avatar.contentMode = .scaleAspectFill
        avatar.isUserInteractionEnabled = false
        avatar.accessibilityIdentifier = "voiceRoomFloatingAvatar"
        fallback.textAlignment = .center
        fallback.isUserInteractionEnabled = false
        fallback.font = .systemFont(ofSize: 39)
        avatarDisc.addSubview(fallback)
        avatarDisc.addSubview(avatar)
        addSubview(avatarDisc)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.22
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 3)
        NotificationCenter.default.addObserver(self, selector: #selector(reduceMotionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        updateRingColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { avatarTask?.cancel(); NotificationCenter.default.removeObserver(self) }

    func setAvatar(url: String?, index: Int) {
        guard avatarURL != url || avatarIndex != index else { return }
        avatarTask?.cancel()
        avatarURL = url
        avatarIndex = index
        let faces = ["🧑🏻‍🚀", "👩🏻", "🧑🏼", "👩🏽‍🦱", "🧑🏻‍🎨", "👩🏼‍🦰", "🧑🏽‍🎤", "👨🏻‍🦱", "👩🏻‍🎤", "🧑🏼‍🚀", "👩🏾", "👨🏼"]
        let colors: [UIColor] = [UIColor(red: 0.39, green: 0.32, blue: 0.64, alpha: 1),
                                 UIColor(red: 0.58, green: 0.51, blue: 0.57, alpha: 1),
                                 UIColor(red: 0.46, green: 0.53, blue: 0.47, alpha: 1),
                                 UIColor(red: 0.68, green: 0.47, blue: 0.42, alpha: 1),
                                 UIColor(red: 0.42, green: 0.56, blue: 0.61, alpha: 1)]
        let faceIndex = (index % faces.count + faces.count) % faces.count
        let colorIndex = (index % colors.count + colors.count) % colors.count
        fallback.text = faces[faceIndex]
        avatarColors = [colors[colorIndex].cgColor, colors[colorIndex].withAlphaComponent(0.45).cgColor]
        sourceAvatar = url.flatMap { KikiAccountAPIClient.shared.cachedAvatar($0) }
        updateAvatarAppearance()
        guard let url, sourceAvatar == nil else { return }
        avatarTask = Task { @MainActor [weak self] in
            do {
                let image = try await KikiAccountAPIClient.shared.loadAvatar(url)
                try Task.checkCancellation()
                guard let self, self.avatarURL == url, self.avatarIndex == index else { return }
                self.sourceAvatar = image
                self.updateAvatarAppearance()
            } catch { /* A trusted cached or preset host avatar remains usable offline. */ }
        }
    }

    func setMetadata(roomTitle: String, status: String, hostName: String, isOnline: Bool = true) {
        self.roomTitle = roomTitle
        self.status = status
        self.hostName = hostName
        if self.isOnline != isOnline {
            self.isOnline = isOnline
            updateAvatarAppearance()
            updateRings()
        }
        updateAccessibility()
    }

    private func updateAvatarAppearance() {
        gradient.colors = isOnline ? avatarColors : [UIColor.darkGray.cgColor, UIColor.gray.cgColor]
        avatarDisc.alpha = isOnline ? 1 : 0.46
        avatarDisc.layer.borderColor = (isOnline ? UIColor.white.withAlphaComponent(0.85) : UIColor.gray).cgColor
        if isOnline {
            avatar.image = sourceAvatar
        } else {
            // Render only on a real avatar/connectivity change, never on a polling tick.
            let source = sourceAvatar ?? UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { _ in
                (fallback.text ?? "").draw(in: CGRect(x: 4, y: 8, width: 56, height: 56),
                                           withAttributes: [.font: UIFont.systemFont(ofSize: 39)])
            }
            if let input = CIImage(image: source),
               let result = imageContext.createCGImage(input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]), from: input.extent) {
                avatar.image = UIImage(cgImage: result, scale: source.scale, orientation: source.imageOrientation)
            } else { avatar.image = source }
        }
        fallback.isHidden = avatar.image != nil
    }

    func setSpeaking(_ value: Bool) {
        guard speaking != value else { return }
        speaking = value
        updateAccessibility()
        updateRings()
    }

    func setPresentationVisible(_ value: Bool) {
        presentationVisible = value
        updateRings()
    }

    private func updateAccessibility() {
        accessibilityLabel = hostName.isEmpty ? "返回语聊房" : "返回\(hostName)的语聊房"
        accessibilityValue = "\(roomTitle)，\(!isOnline ? "连接中断，等待恢复" : (speaking ? "房内有人正在发言" : status))"
        accessibilityHint = "轻点返回聊天室，也可以拖动悬浮球调整位置"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let circle = bounds.insetBy(dx: 8, dy: 8)
        avatarDisc.frame = circle
        avatarDisc.layer.cornerRadius = circle.height / 2
        gradient.frame = avatarDisc.bounds
        avatar.frame = avatarDisc.bounds
        fallback.frame = avatarDisc.bounds
        layer.shadowPath = UIBezierPath(ovalIn: circle).cgPath
        for ring in rings {
            ring.frame = bounds
            ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 10, dy: 10)).cgPath
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRings()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateRingColors()
    }

    private func updateRingColors() {
        let color = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(red: 0.75, green: 0.62, blue: 1, alpha: 1)
                : UIColor(red: 0.47, green: 0.32, blue: 0.82, alpha: 1)
        }.resolvedColor(with: traitCollection)
        rings.forEach { $0.strokeColor = color.cgColor }
    }

    @objc private func reduceMotionChanged() { updateRings(force: true) }

    private func updateRings(force: Bool = false) {
        let visible = isOnline && speaking && presentationVisible && window != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, ring) in rings.enumerated() {
            guard visible else {
                ring.removeAllAnimations()
                ring.opacity = 0
                continue
            }
            if UIAccessibility.isReduceMotionEnabled {
                ring.removeAllAnimations()
                ring.opacity = index == 0 ? 0.6 : 0
                continue
            }
            ring.opacity = 0
            guard force || ring.animation(forKey: "voiceRoomSpeaking") == nil else { continue }
            let expansion = CABasicAnimation(keyPath: "transform.scale")
            expansion.fromValue = 0.94
            expansion.toValue = 1.28
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.65
            fade.toValue = 0
            let pulse = CAAnimationGroup()
            pulse.animations = [expansion, fade]
            pulse.duration = 1.4
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.7
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(pulse, forKey: "voiceRoomSpeaking")
        }
    }

    override var isHighlighted: Bool {
        didSet { avatarDisc.alpha = (isOnline ? 1 : 0.46) * (isHighlighted ? 0.72 : 1) }
    }
}
