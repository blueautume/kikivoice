import SwiftUI
import UIKit
import XCTest
@testable import KikiTalk

@MainActor
final class KikiRoomMessageInputTests: XCTestCase {
    func testPlainTextConfigurationAndNativeAccessibilityIdentifiers() throws {
        let fixture = try Fixture(text: "还没发送的草稿")
        defer { fixture.close() }
        let field = fixture.input.textView
        XCTAssertEqual(fixture.input.accessibilityIdentifier, "livekit.room.composer")
        XCTAssertEqual(field.accessibilityIdentifier, "livekit.room.message")
        XCTAssertEqual(fixture.input.emojiButton.accessibilityIdentifier, "livekit.room.emoji")
        XCTAssertFalse(fixture.input.isAccessibilityElement)
        XCTAssertEqual(field.keyboardType, .default)
        XCTAssertEqual(field.returnKeyType, .default)
        XCTAssertEqual(field.keyboardAppearance, .dark)
        XCTAssertEqual(field.textColor, .white)
        XCTAssertFalse(field.allowsEditingTextAttributes)
        if #available(iOS 18.0, *) { XCTAssertFalse(field.supportsAdaptiveImageGlyph) }
        XCTAssertTrue(field.adjustsFontForContentSizeCategory)
        XCTAssertLessThanOrEqual(try XCTUnwrap(field.font).pointSize, 28)
        XCTAssertEqual(field.text, "还没发送的草稿")
        XCTAssertEqual(fixture.input.placeholderLabel.text, "说点什么…")
    }

    func testSystemUnicodeInsertionRoundTripsAndRedrawPreservesDraftAndCaret() async throws {
        let fixture = try Fixture(text: "你好")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        XCTAssertTrue(field.isFirstResponder)
        let emoji = "👩🏽‍💻🇨🇳❤️‍🔥🧑‍🤝‍🧑"
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.insertText(emoji)
        fixture.coordinator.textViewDidChange(field)
        XCTAssertEqual(field.text, "你好" + emoji)
        XCTAssertEqual(fixture.state.text, "你好" + emoji)
        let caret = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 2))
        field.selectedTextRange = field.textRange(from: caret, to: caret)
        for _ in 0..<4 { fixture.update() }
        XCTAssertEqual(field.text, "你好" + emoji)
        XCTAssertEqual(fixture.state.text, "你好" + emoji)
        XCTAssertEqual(field.offset(from: field.beginningOfDocument,
                                    to: try XCTUnwrap(field.selectedTextRange).start), 2)
        XCTAssertEqual(fixture.state.submissions, 0)
    }

    func testMarkedTextIsNotOverwrittenByAnExternalDraftDuringRedraw() async throws {
        let fixture = try Fixture(text: "前文")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        field.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0))
        XCTAssertNotNil(field.markedTextRange)
        let provisional = field.text
        fixture.state.text = "迟到的外部草稿"
        fixture.update()
        XCTAssertEqual(field.text, provisional)
        XCTAssertNotNil(field.markedTextRange, "Redrawing cannot commit or discard an IME candidate")
        // The test simulates the input system confirming its candidate. The
        // product never calls unmarkText to force this transition.
        field.unmarkText()
        fixture.coordinator.textViewDidChange(field)
        XCTAssertEqual(fixture.state.text, field.text)
        XCTAssertEqual(fixture.state.submissions, 0)
    }

    func testExternalResignDoesNotReopenKeyboardWhenTheOldFocusBindingRedraws() async throws {
        let fixture = try Fixture(text: "保留这段")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        XCTAssertTrue(fixture.input.textView.isFirstResponder)
        XCTAssertTrue(fixture.state.focused)
        fixture.input.textView.resignFirstResponder()
        // Deliberately redraw before the deferred didEndEditing binding write.
        fixture.update()
        XCTAssertFalse(fixture.input.textView.isFirstResponder)
        await settle()
        XCTAssertFalse(fixture.state.focused)
        for _ in 0..<5 { fixture.update() }
        await settle()
        XCTAssertFalse(fixture.input.textView.isFirstResponder)
        XCTAssertEqual(fixture.state.text, "保留这段")
        XCTAssertEqual(fixture.input.textView.text, "保留这段")
        fixture.state.focused = true
        fixture.update()
        XCTAssertTrue(fixture.input.textView.isFirstResponder,
                      "A subsequent explicit focus request must still work")
    }

    func testDisablingInputReleasesFocusWithoutClearingDraftOrRefocusingOnEnable() async throws {
        let fixture = try Fixture(text: "暂停发送")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        XCTAssertTrue(fixture.input.textView.isFirstResponder)
        fixture.state.enabled = false
        fixture.update()
        XCTAssertFalse(fixture.input.textView.isFirstResponder)
        XCTAssertFalse(fixture.input.textView.isEditable)
        XCTAssertFalse(fixture.input.emojiButton.isEnabled)
        await settle()
        XCTAssertFalse(fixture.state.focused)
        XCTAssertEqual(fixture.state.text, "暂停发送")
        fixture.state.enabled = true
        fixture.update()
        XCTAssertTrue(fixture.input.textView.isEditable)
        XCTAssertFalse(fixture.input.textView.isFirstResponder)
    }

    func testNativeNewlinesAndExplicitSubmitDoNotSendIMEProvisionalText() async throws {
        let fixture = try Fixture(text: "普通消息😀")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        field.insertText("\n第二行")
        fixture.coordinator.textViewDidChange(field)
        XCTAssertEqual(fixture.state.text, "普通消息😀\n第二行")
        XCTAssertEqual(fixture.state.submissions, 0, "Native Return adds a line; the visible send button submits")
        fixture.coordinator.submitConfirmedText()
        XCTAssertEqual(fixture.state.submissions, 1)
        XCTAssertTrue(field.isFirstResponder)
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        let provisional = field.text
        fixture.coordinator.submitConfirmedText()
        XCTAssertEqual(fixture.state.submissions, 1)
        XCTAssertEqual(field.text, provisional)
        XCTAssertNotNil(field.markedTextRange)
        field.unmarkText()
        fixture.coordinator.textViewDidChange(field)
        fixture.coordinator.submitConfirmedText()
        XCTAssertEqual(fixture.state.submissions, 2)
        XCTAssertEqual(fixture.state.text, field.text)
    }

    func testNativeMultilineInputGrowsThenScrollsWithinFourLines() async throws {
        let fixture = try Fixture(text: "短消息")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let input = fixture.input
        let short = input.fittingHeight(width: 240)
        fixture.state.text = String(repeating: "多行消息会自动换行 😀，不应横向撑开输入栏。", count: 20)
        fixture.update()
        let long = input.fittingHeight(width: 240)
        XCTAssertGreaterThan(long, short + 20)
        XCTAssertLessThanOrEqual(long, ceil((input.textView.font?.lineHeight ?? 18) * 4 + 22))
        input.frame.size = CGSize(width: 240, height: long)
        input.setNeedsLayout(); input.layoutIfNeeded()
        XCTAssertTrue(input.textView.isScrollEnabled)
        XCTAssertEqual(input.textView.textContainer.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(input.textView.text, fixture.state.text)
        XCTAssertTrue(input.placeholderLabel.isHidden)
        fixture.state.text = ""
        fixture.update()
        XCTAssertFalse(input.placeholderLabel.isHidden)
        XCTAssertEqual(input.fittingHeight(width: 240), short, accuracy: 1)
    }

    func testMissingSystemEmojiModeKeepsDraftFocusAndReportsTheSettingsFallback() async throws {
        let fixture = try Fixture(text: "没启用 Emoji 也不能丢稿")
        defer { fixture.close() }
        fixture.coordinator.inputModes = { [] }
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        await settle()
        XCTAssertEqual(fixture.state.notices.count, 1)
        XCTAssertTrue(fixture.state.notices[0].contains("表情符号"))
        XCTAssertTrue(fixture.input.textView.isFirstResponder)
        XCTAssertTrue(fixture.state.focused)
        XCTAssertEqual(fixture.state.text, "没启用 Emoji 也不能丢稿")
        XCTAssertEqual(fixture.input.textView.text, fixture.state.text)
        XCTAssertEqual(fixture.state.submissions, 0)
        XCTAssertEqual(fixture.input.textView.textInputMode?.primaryLanguage,
                       fixture.input.textView.systemTextInputMode?.primaryLanguage,
                       "A missing Emoji mode cannot install a different keyboard preference")
    }

    func testEmojiRequestWaitsForMarkedTextAndDoesNotSendOrForceCommit() async throws {
        let fixture = try Fixture(text: "前文")
        defer { fixture.close() }
        var modeQueries = 0
        fixture.coordinator.inputModes = { modeQueries += 1; return [] }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        field.setMarkedText("hao", selectedRange: NSRange(location: 3, length: 0))
        let provisional = field.text
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        await settle()
        XCTAssertEqual(modeQueries, 0)
        XCTAssertTrue(fixture.state.notices.isEmpty)
        XCTAssertEqual(field.text, provisional)
        XCTAssertNotNil(field.markedTextRange)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertEqual(fixture.state.submissions, 0)
        field.unmarkText()
        fixture.coordinator.textViewDidChange(field)
        await settle()
        XCTAssertEqual(modeQueries, 1)
        XCTAssertEqual(fixture.state.notices.count, 1)
        XCTAssertEqual(fixture.state.text, field.text)
        XCTAssertEqual(fixture.state.submissions, 0)
    }

    func testMissingEmojiWithEnabledTextModesDoesNotSelectTheFirstLanguage() async throws {
        let fixture = try Fixture(text: "保持当前输入语言")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        let originalLanguage = field.systemTextInputMode?.primaryLanguage
        // These are genuine queried modes, with Emoji omitted to model it being
        // unavailable. Reversing them catches an unwanted first-language choice.
        let textModes = Array(UITextInputMode.activeInputModes.filter { $0.primaryLanguage != "emoji" }.reversed())
        fixture.coordinator.inputModes = { textModes }
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        await settle()
        XCTAssertEqual(fixture.state.notices.count, 1)
        XCTAssertNil(field.preferredLanguage)
        XCTAssertEqual(field.systemTextInputMode?.primaryLanguage, originalLanguage)
        XCTAssertEqual(fixture.state.text, "保持当前输入语言")
        XCTAssertTrue(field.isFirstResponder)
    }

    func testDismantleCancelsPendingCompositionFocusAndCallbacks() async throws {
        let fixture = try Fixture(text: "仍由业务保留")
        defer { fixture.close() }
        fixture.coordinator.inputModes = { XCTFail("Dismantled input cannot request a keyboard"); return [] }
        fixture.state.focused = true
        fixture.update()
        let field = fixture.input.textView
        field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        let draftBeforeDismantle = fixture.state.text
        KikiRoomMessageInput.dismantleUIView(fixture.input, coordinator: fixture.coordinator)
        XCTAssertTrue(fixture.coordinator.isInvalidated)
        XCTAssertFalse(fixture.coordinator.isObservingInputModes)
        XCTAssertNil(field.delegate)
        XCTAssertNil(fixture.input.coordinator)
        XCTAssertFalse(field.isFirstResponder)
        field.unmarkText()
        fixture.coordinator.textViewDidChange(field)
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        fixture.update()
        await settle()
        XCTAssertFalse(field.isFirstResponder)
        XCTAssertEqual(fixture.state.text, draftBeforeDismantle)
        XCTAssertEqual(fixture.state.submissions, 0)
        XCTAssertTrue(fixture.state.notices.isEmpty)
    }

    func testSwiftUIComposerAndOutsideDismissalPhoneAndIPadFixtureScreenshots() async throws {
        let scene = try foregroundScene()
        let inspectSoftwareKeyboard = ProcessInfo.processInfo.environment["KIKI_ROOM_COMPOSER_SOFTWARE_KEYBOARD"] == "1"
        if inspectSoftwareKeyboard, UIDevice.current.userInterfaceIdiom != .phone {
            throw XCTSkip("Software-keyboard avoidance is verified on the simulator's native phone viewport; the regular fixture run covers iPad layout")
        }
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKeyAndVisible() }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        // A real keyboard belongs to the scene's physical viewport. Resizing its
        // window to emulate another device would make the guide assertion invalid.
        let cases: [(String, CGSize)] = inspectSoftwareKeyboard ? [
            ("phone-native", scene.coordinateSpace.bounds.size)
        ] : [
            ("phone-375", CGSize(width: 375, height: 812)),
            ("ipad-744", CGSize(width: 744, height: 1133))
        ]
        for (name, size) in cases {
            let model = ScreenshotModel()
            let host = UIHostingController(rootView: ComposerScreenshotFixture(model: model))
            // Synthetic viewports exercise layout and focus independently of the
            // scene's physical keyboard. The native opt-in retains keyboard geometry.
            host.safeAreaRegions = inspectSoftwareKeyboard ? .all : .container
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: size)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 120_000_000)
            window.layoutIfNeeded()
            let input = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomMessageInput.InputView }.first)
            let probe = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomKeyboardDismissal.Probe }.first)
            let dismissal = try XCTUnwrap(probe.coordinator)
            XCTAssertEqual(host.view.bounds.size, size)
            XCTAssertGreaterThan(input.textView.bounds.width, 50)
            XCTAssertGreaterThanOrEqual(input.emojiButton.bounds.width, 40)
            XCTAssertFalse(input.textView.isFirstResponder)
            let idleFrame = input.convert(input.bounds, to: window)
            let inputIdentity = ObjectIdentifier(input)
            try captureInputScreenshot(name: device + "-composer-" + name + "-idle", window: window)

            model.focused = true
            try await waitFor { input.textView.isFirstResponder }
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            if inspectSoftwareKeyboard {
                let deadline = Date().addingTimeInterval(45)
                print("KikiRoomComposer waiting-for-software-keyboard maxSeconds=45")
                while host.view.keyboardLayoutGuide.layoutFrame.height <= 100, Date() < deadline {
                    window.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                window.layoutIfNeeded()
                let keyboardFrame = host.view.keyboardLayoutGuide.layoutFrame
                let inputFrame = input.convert(input.bounds, to: host.view)
                let gap = keyboardFrame.minY - inputFrame.maxY
                print("KikiRoomComposer software-keyboard guide=\(keyboardFrame) input=\(inputFrame) gap=\(gap)")
                XCTAssertGreaterThan(keyboardFrame.height, 100,
                                     "The opt-in software-keyboard preparation did not complete within 45 seconds")
                guard keyboardFrame.height > 100 else { return }
                XCTAssertGreaterThanOrEqual(gap, -1, "The composer must remain above the actual software keyboard")
                XCTAssertLessThanOrEqual(gap, 32, "The composer must stay next to the actual keyboard instead of floating above it")
            }
            XCTAssertTrue(model.focused)
            XCTAssertGreaterThan(input.textView.bounds.width, 120, "Collapsing the tools must widen the native composer")
            XCTAssertEqual(ObjectIdentifier(input), inputIdentity)
            XCTAssertFalse(dismissal.acceptsTap(from: input))
            XCTAssertFalse(dismissal.acceptsTap(from: input.textView))
            XCTAssertFalse(dismissal.acceptsTap(from: input.emojiButton))
            XCTAssertTrue(input.textView.isFirstResponder,
                          "The native field and Emoji button are excluded from outside dismissal")
            try captureInputScreenshot(name: device + "-composer-" + name + "-focused", window: window)
            XCTAssertTrue(dismissal.acceptsTap(from: host.view))
            // Exercise the same recognized-tap callback without fabricating a
            // UITouch or claiming an automated physical tap on the keyboard.
            dismissal.dismissAfterRecognizedTap()
            try await waitFor { !input.textView.isFirstResponder && !model.focused }
            XCTAssertEqual(model.dismissals, 1)
            if inspectSoftwareKeyboard {
                let deadline = Date().addingTimeInterval(10)
                while host.view.keyboardLayoutGuide.layoutFrame.height > 100, Date() < deadline {
                    window.layoutIfNeeded()
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                window.layoutIfNeeded()
                let height = host.view.keyboardLayoutGuide.layoutFrame.height
                print("KikiRoomComposer software-keyboard-dismissed guideHeight=\(height)")
                XCTAssertLessThanOrEqual(height, 100, "Outside dismissal must lower the actual software keyboard")
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            let restoredFrame = input.convert(input.bounds, to: window)
            XCTAssertEqual(restoredFrame.minX, idleFrame.minX, accuracy: 1)
            XCTAssertEqual(restoredFrame.maxY, idleFrame.maxY, accuracy: 1,
                           "Dismissal must return the composer to its original safe-area bottom")
            XCTAssertEqual(restoredFrame.width, idleFrame.width, accuracy: 1,
                           "The tools must recover their stable slot, without appearing at the top of the screen")
            XCTAssertEqual(ObjectIdentifier(input), inputIdentity)
            try captureInputScreenshot(name: device + "-composer-" + name + "-blurred", window: window)
            model.text += "，收起后保留"
            await settle()
            XCTAssertFalse(input.textView.isFirstResponder)
            XCTAssertEqual(input.textView.text, model.text)
            XCTAssertEqual(model.submissions, 0)
            host.view.endEditing(true)
        }
    }

    func testRealActiveEmojiModeSwitchesFromTextAndBackWithScreenshots() async throws {
        let modes = UITextInputMode.activeInputModes
        guard modes.contains(where: { $0.primaryLanguage == "emoji" }) else {
            throw XCTSkip("This simulator has no enabled system Emoji input mode; the separate missing-mode fallback test covers this environment")
        }
        guard modes.contains(where: { $0.primaryLanguage != "emoji" }) else {
            throw XCTSkip("This simulator has no enabled text input mode to restore")
        }
        let fixture = try Fixture(text: "系统键盘切换，不发送 😀")
        defer { fixture.close() }
        fixture.state.focused = true
        fixture.update()
        await settle()
        let field = fixture.input.textView
        XCTAssertTrue(field.isFirstResponder)
        let inspectSoftwareKeyboard = ProcessInfo.processInfo.environment["KIKI_ROOM_INPUT_WAIT_FOR_KEYBOARD"] == "1"
        if inspectSoftwareKeyboard {
            let controller = try XCTUnwrap(fixture.window.rootViewController)
            let deadline = Date().addingTimeInterval(45)
            print("KikiRoomInputMode waiting-for-software-keyboard maxSeconds=45")
            while controller.view.keyboardLayoutGuide.layoutFrame.height <= 100, Date() < deadline {
                controller.view.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let height = controller.view.keyboardLayoutGuide.layoutFrame.height
            print("KikiRoomInputMode software-keyboard-wait-finished guideHeight=\(height)")
            XCTAssertGreaterThan(height, 100, "The opt-in software-keyboard preparation did not complete within 45 seconds")
            guard height > 100 else { return }
        }
        logInputModeState("initial", fixture: fixture)
        if field.textInputMode?.primaryLanguage == "emoji" {
            fixture.input.emojiButton.sendActions(for: .touchUpInside)
            try await waitFor {
                if let language = field.textInputMode?.primaryLanguage { return language != "emoji" }
                return false
            }
        }
        let originalLanguage = try XCTUnwrap(field.textInputMode?.primaryLanguage)
        XCTAssertNotEqual(originalLanguage, "emoji")
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        try captureInputScreenshot(name: device + "-composer-real-mode-text", window: fixture.window)
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        logInputModeState("emoji-requested", fixture: fixture)
        if inspectSoftwareKeyboard {
            print("KikiRoomInputMode emoji-requested observationHoldSeconds=20")
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
        try await waitFor { field.textInputMode?.primaryLanguage == "emoji" }
        try await Task.sleep(nanoseconds: 350_000_000)
        for _ in 0..<4 { fixture.update() }
        await settle()
        logInputModeState("emoji-settled", fixture: fixture)
        XCTAssertEqual(field.textInputMode?.primaryLanguage, "emoji")
        XCTAssertEqual(field.preferredLanguage, "emoji", "Redraws cannot discard the explicitly selected active input mode")
        XCTAssertTrue(UITextInputMode.activeInputModes.contains { $0.primaryLanguage == field.textInputMode?.primaryLanguage })
        XCTAssertEqual(fixture.input.emojiButton.accessibilityLabel, "切回文字键盘")
        try captureInputScreenshot(name: device + "-composer-real-mode-emoji", window: fixture.window)
        fixture.input.emojiButton.sendActions(for: .touchUpInside)
        logInputModeState("text-requested", fixture: fixture)
        if inspectSoftwareKeyboard {
            print("KikiRoomInputMode text-requested observationHoldSeconds=20")
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
        try await waitFor { field.textInputMode?.primaryLanguage == originalLanguage }
        try await Task.sleep(nanoseconds: 350_000_000)
        for _ in 0..<4 { fixture.update() }
        await settle()
        logInputModeState("text-restored", fixture: fixture)
        XCTAssertEqual(field.textInputMode?.primaryLanguage, originalLanguage)
        XCTAssertEqual(field.preferredLanguage, originalLanguage)
        XCTAssertEqual(fixture.input.emojiButton.accessibilityLabel, "使用系统表情键盘")
        try captureInputScreenshot(name: device + "-composer-real-mode-restored", window: fixture.window)
        XCTAssertTrue(field.isFirstResponder)
        XCTAssertTrue(fixture.state.notices.isEmpty)
        if inspectSoftwareKeyboard {
            XCTAssertTrue(fixture.state.text.hasPrefix("系统键盘切换，不发送 😀"),
                          "Manual keyboard observation may append Emoji but must retain the original draft")
        } else {
            XCTAssertEqual(fixture.state.text, "系统键盘切换，不发送 😀")
        }
        XCTAssertEqual(fixture.state.text, field.text)
        XCTAssertEqual(fixture.state.submissions, 0)
        field.resignFirstResponder()
        XCTAssertNil(field.preferredLanguage)
    }

    private func logInputModeState(_ phase: String, fixture: Fixture) {
        let field = fixture.input.textView
        let guide = fixture.window.rootViewController?.view.keyboardLayoutGuide.layoutFrame ?? .zero
        let diagnostics: [String: Any] = [
            "phase": phase,
            "defaultLanguage": field.systemTextInputMode?.primaryLanguage ?? "nil",
            "specifiedLanguage": field.textInputMode?.primaryLanguage ?? "nil",
            "preferredLanguage": field.preferredLanguage ?? "nil",
            "firstResponder": field.isFirstResponder,
            "keyWindow": fixture.window.isKeyWindow,
            "keyboardGuideWidth": guide.width,
            "keyboardGuideHeight": guide.height,
            "activeLanguages": UITextInputMode.activeInputModes.map { $0.primaryLanguage ?? "nil" }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.sortedKeys]),
           let message = String(data: data, encoding: .utf8) {
            print("KikiRoomInputMode " + message)
        }
    }

    private func foregroundScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func descendants(of view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(predicate(), "UIKit did not complete the requested native input transition")
    }

    private func captureInputScreenshot(name: String, window: UIWindow) throws {
        window.layoutIfNeeded()
        // Some OS versions put the native keyboard in another scene window.
        // Include visible overlays through public UIWindow APIs only; never
        // inspect keyboard implementation classes or synthesize their touches.
        let overlays = window.windowScene?.windows.filter {
            $0 !== window && !$0.isHidden && $0.alpha > 0 && $0.windowLevel > window.windowLevel
        }.sorted { $0.windowLevel < $1.windowLevel } ?? []
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            for target in [window] + overlays {
                let frame = target.convert(target.bounds, to: window)
                guard frame.intersects(window.bounds) else { continue }
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: frame.minX, y: frame.minY)
                target.drawHierarchy(in: target.bounds, afterScreenUpdates: true)
                context.cgContext.restoreGState()
            }
        }
        let folder = URL(fileURLWithPath: "/tmp/kiki-room-message-input-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private final class ScreenshotModel: ObservableObject {
        @Published var text = "原生输入 😀 👩🏽‍💻"
        @Published var focused = false
        var dismissals = 0
        var submissions = 0
    }

    private struct ComposerScreenshotFixture: View {
        @ObservedObject var model: ScreenshotModel
        var body: some View {
            VStack(spacing: 20) {
                Text("房间输入框").font(.title2.bold()).foregroundStyle(.white)
                Text("系统 Emoji · 纯文本草稿").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Image(systemName: "person.crop.circle.fill").font(.system(size: 62)).foregroundStyle(.purple)
                Text("麦位与聊天背景可收起键盘").foregroundStyle(.white.opacity(0.7))
                Spacer()

            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.09, green: 0.06, blue: 0.16).ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                KikiRoomComposerBar(isComposing: model.focused) {
                    KikiRoomMessageInput(text: $model.text, isFocused: $model.focused,
                        placeholder: "说点什么…", isEnabled: true,
                        onSubmit: { model.submissions += 1 }, onNotice: { _ in })
                        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 21))
                        .overlay(RoundedRectangle(cornerRadius: 21).stroke(.white.opacity(0.2), lineWidth: 1))
                } send: {
                    Button {} label: { Image(systemName: "paperplane.fill").frame(width: 44, height: 44) }
                } controls: {
                    ForEach(["gift.fill", "mic.slash.fill", "figure.wave"], id: \.self) { symbol in
                        Button {} label: { Image(systemName: symbol).frame(width: 44, height: 44) }
                    }
                }
                .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 8)
            }
            .background(KikiRoomKeyboardDismissal(isEnabled: true) {
                model.dismissals += 1
                model.focused = false
            })
            .preferredColorScheme(.dark)
        }
    }

    private func settle() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    @MainActor
    private final class State {
        var text: String
        var focused = false
        var enabled = true
        var submissions = 0
        var notices: [String] = []
        init(text: String) { self.text = text }
    }

    @MainActor
    private final class Fixture {
        let state: State
        let window: UIWindow
        let input = KikiRoomMessageInput.InputView()
        let coordinator = KikiRoomMessageInput.Coordinator()
        private weak var previousKeyWindow: UIWindow?

        init(text: String) throws {
            state = State(text: text)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }, "Native input needs an actual foreground scene")
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view.backgroundColor = .black
            window.rootViewController = controller
            window.makeKeyAndVisible()
            input.frame = CGRect(x: 16, y: 80, width: max(200, window.bounds.width - 32), height: 52)
            controller.view.addSubview(input)
            update()
            window.layoutIfNeeded()
        }

        func update() {
            let state = state
            coordinator.update(view: input,
                text: Binding(get: { state.text }, set: { state.text = $0 }),
                isFocused: Binding(get: { state.focused }, set: { state.focused = $0 }),
                placeholder: "说点什么…", isEnabled: state.enabled,
                onSubmit: { state.submissions += 1 }, onNotice: { state.notices.append($0) })
        }

        func close() {
            coordinator.invalidate()
            window.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
    }
}
