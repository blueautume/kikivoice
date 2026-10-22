import SwiftUI
import UIKit

/// Observes room taps without taking focus, intercepting touches or looking at
/// the system keyboard. The room owns the actual focus/endEditing callback.
struct KikiRoomKeyboardDismissal: UIViewRepresentable {
    let isEnabled: Bool
    let onDismiss: () -> Void

    init(isEnabled: Bool, onDismiss: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        context.coordinator.update(probe: probe, isEnabled: isEnabled, onDismiss: onDismiss)
        return probe
    }

    func updateUIView(_ uiView: Probe, context: Context) {
        context.coordinator.update(probe: uiView, isEnabled: isEnabled, onDismiss: onDismiss)
    }

    static func dismantleUIView(_ uiView: Probe, coordinator: Coordinator) {
        coordinator.invalidate()
        uiView.coordinator = nil
    }

    @MainActor
    final class Probe: UIView {
        weak var coordinator: Coordinator?

        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.probeDidMove(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private(set) weak var installedWindow: UIWindow?
        private(set) var recognizer: UITapGestureRecognizer?
        private weak var probe: Probe?
        private var isEnabled = false
        private var onDismiss: (() -> Void)?
        private let target = WeakTapTarget()

        override init() {
            super.init()
            target.owner = self
        }

        deinit {
            // SwiftUI normally calls dismantle first. The weak target prevents a
            // window/recognizer ownership cycle if the coordinator releases early.
            let gesture = recognizer
            Task { @MainActor in
                guard let gesture else { return }
                gesture.isEnabled = false
                gesture.delegate = nil
                gesture.view?.removeGestureRecognizer(gesture)
            }
        }

        func update(probe: Probe, isEnabled: Bool, onDismiss: @escaping () -> Void) {
            if self.probe !== probe {
                self.probe?.coordinator = nil
                uninstall()
                self.probe = probe
                probe.coordinator = self
            }
            self.isEnabled = isEnabled
            self.onDismiss = onDismiss
            reconcileWindow()
        }

        func probeDidMove(_ probe: Probe) {
            guard self.probe === probe else { return }
            reconcileWindow()
        }

        func invalidate() {
            isEnabled = false
            onDismiss = nil
            probe?.coordinator = nil
            probe = nil
            uninstall()
        }

        /// Public UIKit supplies the touched view. Tests exercise this
        /// decision directly rather than constructing synthetic UITouch objects.
        func acceptsTap(from touchedView: UIView?) -> Bool {
            guard isEnabled, let window = installedWindow, let probe,
                  probe.window === window, recognizer?.view === window else { return false }
            return KikiRoomKeyboardDismissalPolicy.shouldDismiss(touchedView: touchedView, in: window, probe: probe)
        }

        /// Invoked only after UIKit recognizes an accepted tap. Keeping callback
        /// delivery separate allows lifecycle/callback tests with no fake touches.
        func dismissAfterRecognizedTap() {
            guard isEnabled, let window = installedWindow, let probe,
                  probe.window === window, recognizer?.view === window else { return }
            onDismiss?()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled && gestureRecognizer === recognizer && probe?.window === installedWindow
                && installedWindow != nil && gestureRecognizer.view === installedWindow
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === recognizer else { return false }
            return acceptsTap(from: touch.view)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer === recognizer || otherGestureRecognizer === recognizer
        }

        private func reconcileWindow() {
            guard isEnabled, let nextWindow = probe?.window else { uninstall(); return }
            if installedWindow === nextWindow, recognizer?.view === nextWindow { return }
            uninstall()
            let gesture = UITapGestureRecognizer(target: target, action: #selector(WeakTapTarget.didTap(_:)))
            gesture.name = "kiki.room.keyboard-dismiss"
            gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false
            gesture.delaysTouchesEnded = false
            gesture.requiresExclusiveTouchType = false
            gesture.delegate = self
            nextWindow.addGestureRecognizer(gesture)
            installedWindow = nextWindow
            recognizer = gesture
        }

        private func uninstall() {
            recognizer?.isEnabled = false
            recognizer?.delegate = nil
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            installedWindow = nil
        }

        @MainActor
        private final class WeakTapTarget: NSObject {
            weak var owner: Coordinator?
            @objc func didTap(_ recognizer: UITapGestureRecognizer) {
                guard recognizer.state == .ended, owner?.recognizer === recognizer else { return }
                owner?.dismissAfterRecognizedTap()
            }
        }
    }
}

@MainActor
enum KikiRoomKeyboardDismissalPolicy {
    static let excludedIdentifiers: Set<String> = [
        "livekit.room.emoji", "livekit.room.message", "livekit.room.composer"
    ]

    static func shouldDismiss(touchedView: UIView?, in window: UIWindow, probe: UIView) -> Bool {
        guard let touchedView, touchedView.window === window, probe.window === window else { return false }
        var ancestor: UIView? = touchedView
        while let view = ancestor {
            // SwiftUI may replace a representable's accessibility identifier;
            // its native input container must still keep editing on padding taps.
            if view === probe || view is KikiRoomMessageInput.InputView || view is UITextInput
                || excludedIdentifiers.contains(view.accessibilityIdentifier ?? "") {
                return false
            }
            if view === window { break }
            ancestor = view.superview
        }
        return true
    }

}
