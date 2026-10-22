import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiRoomKeyboardDismissalTests: XCTestCase {
    func testRoomTapPolicyIncludesChatSeatsBlankSpaceAndOtherButtons() {
        let fixture = Fixture()
        defer { fixture.coordinator.invalidate() }
        let chat = UIView(), seat = UIView(), button = UIButton(type: .system)
        chat.accessibilityIdentifier = "livekit.room.chat"
        seat.accessibilityIdentifier = "livekit.room.seat"
        button.accessibilityIdentifier = "livekit.room.more"
        [chat, seat, button].forEach { fixture.root.addSubview($0) }
        for view in [fixture.root, chat, seat, button] {
            XCTAssertTrue(fixture.coordinator.acceptsTap(from: view))
        }
        XCTAssertFalse(fixture.coordinator.acceptsTap(from: nil))
        XCTAssertFalse(fixture.coordinator.acceptsTap(from: fixture.probe))
        XCTAssertFalse(fixture.probe.isUserInteractionEnabled)
        XCTAssertTrue(fixture.probe.accessibilityElementsHidden)
    }

    func testNativeComposerAndEmojiAncestorsExcludeTheirEntireTouchSubtrees() {
        let fixture = Fixture()
        defer { fixture.coordinator.invalidate() }
        for identifier in ["livekit.room.emoji", "livekit.room.message", "livekit.room.composer"] {
            let container = UIView()
            container.accessibilityIdentifier = identifier
            let innerControl = UIButton(type: .system)
            let image = UIImageView()
            innerControl.addSubview(image)
            container.addSubview(innerControl)
            fixture.root.addSubview(container)
            XCTAssertFalse(fixture.coordinator.acceptsTap(from: container), identifier)
            XCTAssertFalse(fixture.coordinator.acceptsTap(from: innerControl), identifier)
            XCTAssertFalse(fixture.coordinator.acceptsTap(from: image), identifier)
        }
        XCTAssertTrue(fixture.coordinator.acceptsTap(from: fixture.root),
                      "Excluding the composer must not exclude the rest of its room window")
    }

    func testTextInputAndItsUIKitDescendantsNeverRequestDismissal() {
        let fixture = Fixture()
        defer { fixture.coordinator.invalidate() }
        let field = UITextField()
        let fieldDecoration = UIView()
        field.addSubview(fieldDecoration)
        let textView = UITextView()
        let textDecoration = UILabel()
        textView.addSubview(textDecoration)
        fixture.root.addSubview(field)
        fixture.root.addSubview(textView)
        for view in [field as UIView, fieldDecoration, textView, textDecoration] {
            XCTAssertFalse(fixture.coordinator.acceptsTap(from: view))
        }
        XCTAssertTrue(fixture.coordinator.acceptsTap(from: fixture.root))
    }

    func testObserverKeepsOriginalButtonActionsAndSimultaneousGesturesAvailable() throws {
        var dismissals = 0
        var buttonActions = 0
        let fixture = Fixture { dismissals += 1 }
        defer { fixture.coordinator.invalidate() }
        let gesture = try XCTUnwrap(fixture.coordinator.recognizer)
        XCTAssertTrue(gesture.view === fixture.window)
        XCTAssertFalse(gesture.cancelsTouchesInView)
        XCTAssertFalse(gesture.delaysTouchesBegan)
        XCTAssertFalse(gesture.delaysTouchesEnded)
        XCTAssertFalse(gesture.requiresExclusiveTouchType)
        let button = UIButton(type: .system)
        button.addAction(UIAction { _ in buttonActions += 1 }, for: .touchUpInside)
        fixture.root.addSubview(button)
        let other = UIPanGestureRecognizer()
        fixture.root.addGestureRecognizer(other)
        XCTAssertTrue(fixture.coordinator.gestureRecognizer(gesture, shouldRecognizeSimultaneouslyWith: other))
        XCTAssertTrue(fixture.coordinator.gestureRecognizerShouldBegin(gesture))
        XCTAssertTrue(fixture.coordinator.acceptsTap(from: button))
        // Public callback/action delivery checks side effects independently; no
        // synthetic UITouch or fake recognizer state is used as a tap test.
        fixture.coordinator.dismissAfterRecognizedTap()
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(dismissals, 1)
        XCTAssertEqual(buttonActions, 1)
    }

    func testDisabledStateDoesNotObserveAndUpdatesUseLatestCallbackWithoutDuplicatingObserver() throws {
        let fixture = Fixture(enabled: false)
        defer { fixture.coordinator.invalidate() }
        var oldCallback = 0
        var newCallback = 0
        XCTAssertNil(fixture.coordinator.recognizer)
        XCTAssertNil(fixture.coordinator.installedWindow)
        XCTAssertFalse(fixture.coordinator.acceptsTap(from: fixture.root))
        fixture.coordinator.update(probe: fixture.probe, isEnabled: true) { oldCallback += 1 }
        let original = try XCTUnwrap(fixture.coordinator.recognizer)
        fixture.coordinator.update(probe: fixture.probe, isEnabled: true) { newCallback += 1 }
        XCTAssertTrue(fixture.coordinator.recognizer === original)
        XCTAssertEqual(fixture.window.gestureRecognizers?.filter { $0.name == "kiki.room.keyboard-dismiss" }.count, 1)
        fixture.coordinator.dismissAfterRecognizedTap()
        XCTAssertEqual(oldCallback, 0)
        XCTAssertEqual(newCallback, 1)
        fixture.coordinator.update(probe: fixture.probe, isEnabled: false) { newCallback += 100 }
        XCTAssertNil(fixture.coordinator.recognizer)
        XCTAssertNil(original.view)
        XCTAssertFalse(original.isEnabled)
        XCTAssertFalse(fixture.coordinator.gestureRecognizerShouldBegin(original))
        fixture.coordinator.dismissAfterRecognizedTap()
        XCTAssertEqual(newCallback, 1)
    }

    func testProbeMovesOnlyItsOwnWindowObserverAndRemovalOrDismantleUninstalls() throws {
        let fixture = Fixture()
        defer { fixture.coordinator.invalidate() }
        let firstGesture = try XCTUnwrap(fixture.coordinator.recognizer)
        let unrelatedFirst = UIPanGestureRecognizer()
        unrelatedFirst.name = "fixture.unrelated.first-window"
        fixture.window.addGestureRecognizer(unrelatedFirst)
        XCTAssertEqual(roomObservers(in: fixture.window).count, 1)

        let otherWindow = UIWindow(frame: fixture.window.frame)
        let otherRoot = UIView(frame: otherWindow.bounds)
        otherWindow.addSubview(otherRoot)
        let unrelatedSecond = UITapGestureRecognizer()
        unrelatedSecond.name = "fixture.unrelated.second-window"
        otherWindow.addGestureRecognizer(unrelatedSecond)
        XCTAssertFalse(fixture.coordinator.acceptsTap(from: otherRoot))
        otherRoot.addSubview(fixture.probe)
        XCTAssertNil(firstGesture.view)
        XCTAssertFalse(firstGesture.isEnabled)
        XCTAssertNil(firstGesture.delegate)
        XCTAssertTrue(fixture.coordinator.installedWindow === otherWindow)
        XCTAssertFalse(fixture.coordinator.acceptsTap(from: fixture.root))
        XCTAssertTrue(fixture.coordinator.acceptsTap(from: otherRoot))
        XCTAssertEqual(roomObservers(in: fixture.window).count, 0)
        XCTAssertEqual(roomObservers(in: otherWindow).count, 1)
        XCTAssertTrue(unrelatedFirst.view === fixture.window,
                      "Moving the room observer must preserve unrelated window gestures")
        XCTAssertTrue(unrelatedSecond.view === otherWindow)

        let secondGesture = try XCTUnwrap(fixture.coordinator.recognizer)
        fixture.probe.removeFromSuperview()
        XCTAssertNil(secondGesture.view)
        XCTAssertFalse(secondGesture.isEnabled)
        XCTAssertNil(secondGesture.delegate)
        XCTAssertNil(fixture.coordinator.installedWindow)
        XCTAssertNil(fixture.coordinator.recognizer)
        XCTAssertEqual(roomObservers(in: otherWindow).count, 0)
        XCTAssertTrue(unrelatedSecond.view === otherWindow)
        otherRoot.addSubview(fixture.probe)
        let thirdGesture = try XCTUnwrap(fixture.coordinator.recognizer)
        XCTAssertTrue(thirdGesture !== secondGesture)
        XCTAssertEqual(roomObservers(in: otherWindow).count, 1)

        KikiRoomKeyboardDismissal.dismantleUIView(fixture.probe, coordinator: fixture.coordinator)
        XCTAssertNil(fixture.coordinator.recognizer)
        XCTAssertNil(thirdGesture.view)
        XCTAssertFalse(thirdGesture.isEnabled)
        XCTAssertNil(thirdGesture.delegate)
        XCTAssertEqual(roomObservers(in: otherWindow).count, 0)
        XCTAssertTrue(unrelatedSecond.view === otherWindow,
                      "Dismantling must remove only this component, not UIKit or other feature gestures")
        fixture.root.addSubview(fixture.probe)
        XCTAssertNil(fixture.coordinator.recognizer, "A dismantled representable cannot reinstall itself after a later view move")
        XCTAssertEqual(roomObservers(in: fixture.window).count, 0)
        XCTAssertTrue(unrelatedFirst.view === fixture.window)
    }

    private func roomObservers(in window: UIWindow) -> [UIGestureRecognizer] {
        (window.gestureRecognizers ?? []).filter { $0.name == "kiki.room.keyboard-dismiss" }
    }

    func testReleasingCoordinatorDoesNotLeaveAWindowObserverOrRetainCycle() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView(frame: window.bounds)
        window.addSubview(root)
        let probe = KikiRoomKeyboardDismissal.Probe()
        root.addSubview(probe)
        var coordinator: KikiRoomKeyboardDismissal.Coordinator? = .init()
        weak var weakCoordinator = coordinator
        coordinator?.update(probe: probe, isEnabled: true) { XCTFail("A released coordinator must never deliver a callback") }
        XCTAssertNotNil(coordinator?.recognizer)
        coordinator = nil
        XCTAssertNil(weakCoordinator)
        let deadline = Date().addingTimeInterval(2)
        while window.gestureRecognizers?.contains(where: { $0.name == "kiki.room.keyboard-dismiss" }) == true,
              Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(window.gestureRecognizers?.contains { $0.name == "kiki.room.keyboard-dismiss" } == true)
        XCTAssertNil(probe.coordinator)
    }

    @MainActor
    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIView()
        let probe = KikiRoomKeyboardDismissal.Probe()
        let coordinator = KikiRoomKeyboardDismissal.Coordinator()

        init(enabled: Bool = true, onDismiss: @escaping () -> Void = {}) {
            root.frame = window.bounds
            window.addSubview(root)
            // Configure before attachment to exercise didMoveToWindow install.
            coordinator.update(probe: probe, isEnabled: enabled, onDismiss: onDismiss)
            root.addSubview(probe)
        }
    }
}
