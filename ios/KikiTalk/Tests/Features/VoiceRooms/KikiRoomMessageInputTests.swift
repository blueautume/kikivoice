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
        XCTAssertEqual(field.keyboardAppearance, .default)
        let textColor = try XCTUnwrap(field.textColor)
        let placeholderColor = try XCTUnwrap(fixture.input.placeholderLabel.textColor)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for traits in [light, dark] {
            XCTAssertEqual(textColor.resolvedColor(with: traits), UIColor(KikiPalette.text).resolvedColor(with: traits))
            XCTAssertEqual(placeholderColor.resolvedColor(with: traits), UIColor(KikiPalette.secondary).resolvedColor(with: traits))
        }
        XCTAssertNotEqual(textColor.resolvedColor(with: light), textColor.resolvedColor(with: dark),
                          "Native input text must use a genuinely adaptive color")
        XCTAssertNotEqual(placeholderColor.resolvedColor(with: light), placeholderColor.resolvedColor(with: dark))
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
        let longDraft = "第一行：保留草稿\n第二行：系统表情 😀\n第三行：继续输入\n第四行：等待发送"
        // Only the opt-in native viewport makes assertions about the physical
        // software keyboard. Synthetic short windows exercise the same layout.
        let cases: [(name: String, size: CGSize, draft: String, messages: Int, allSeats: Bool, scrolls: Bool, scheme: ColorScheme)] = inspectSoftwareKeyboard ? [
            ("phone-native", scene.coordinateSpace.bounds.size, "原生输入 😀 👩🏽‍💻", 2, true, false, .light),
            ("phone-native-four-lines", scene.coordinateSpace.bounds.size, longDraft, 1, false, false, .dark)
        ] : [
            ("phone-375-light", CGSize(width: 375, height: 812), "原生输入 😀 👩🏽‍💻", 3, true, false, .light),
            ("phone-375-dark", CGSize(width: 375, height: 812), "原生输入 😀 👩🏽‍💻", 3, true, false, .dark),
            ("phone-keyboard-window", CGSize(width: 375, height: 520), "原生输入 😀", 1, true, false, .light),
            ("phone-four-lines", CGSize(width: 375, height: 520), longDraft, 1, false, false, .dark),
            ("phone-tiny-window", CGSize(width: 375, height: 400), "小窗口草稿", 2, false, true, .light),
            ("phone-empty-chat", CGSize(width: 375, height: 520), "还没有消息", 0, true, false, .dark),
            ("ipad-wide", CGSize(width: 1133, height: 744), "原生输入 😀", 3, true, false, .light)
        ]
        for item in cases {
            let model = ScreenshotModel(text: item.draft, messageCount: item.messages, scheme: item.scheme)
            var expectedDraft = item.draft
            let host = UIHostingController(rootView: ComposerScreenshotFixture(model: model))
            host.safeAreaRegions = inspectSoftwareKeyboard ? .all : .container
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: item.size)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await Task.sleep(nanoseconds: 120_000_000)
            window.layoutIfNeeded()
            let input = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomMessageInput.InputView }.first)
            let probe = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomKeyboardDismissal.Probe }.first)
            let dismissal = try XCTUnwrap(probe.coordinator)
            try await waitFor { model.probes["seat.8"]?.window != nil && input.bounds.width > 0 }
            XCTAssertEqual(host.view.bounds.size, item.size)
            XCTAssertEqual(input.traitCollection.userInterfaceStyle, item.scheme == .dark ? .dark : .light)
            XCTAssertEqual(input.textView.textColor?.resolvedColor(with: input.traitCollection),
                           UIColor(KikiPalette.text).resolvedColor(with: input.traitCollection))
            XCTAssertNotNil(UIImage(named: "RaiseHand"), "The fixture must render the bundled hand icon used by the room")
            XCTAssertGreaterThan(input.textView.bounds.width, 120)
            XCTAssertGreaterThanOrEqual(input.emojiButton.bounds.width, 40)
            XCTAssertFalse(input.textView.isFirstResponder)
            let idleFrame = input.convert(input.bounds, to: window)
            let idleTextWidth = input.textView.bounds.width
            let inputIdentity = ObjectIdentifier(input)
            try await assertActionReachability(model: model, window: window)
            let idleActions = try assertActionColumn(model: model, input: input, window: window, phase: item.name + ".idle")
            try captureInputScreenshot(name: device + "-composer-" + item.name + "-idle", window: window)

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
                XCTAssertTrue(host.view.convert(keyboardFrame, to: window).intersects(idleActions.viewport),
                              "The real keyboard must cover the rail's original screen position instead of lifting it")
            }
            XCTAssertTrue(model.focused)
            XCTAssertEqual(input.convert(input.bounds, to: window).width, idleFrame.width, accuracy: 1,
                           "The action column must never borrow width from the input row")
            XCTAssertEqual(input.textView.bounds.width, idleTextWidth, accuracy: 1)
            XCTAssertEqual(ObjectIdentifier(input), inputIdentity)
            XCTAssertEqual(input.textView.text, item.draft)
            if item.draft == longDraft {
                XCTAssertGreaterThanOrEqual(input.bounds.height, (input.textView.font?.lineHeight ?? 18) * 3 + 22,
                                            "The four-line draft must exercise the expanded native input")
            }
            try assertActionColumn(model: model, input: input, window: window, anchoredTo: idleActions,
                                   phase: item.name + ".focused")
            try await assertSeatReachability(model: model, window: window,
                                            allVisible: item.allSeats, requiresScroll: item.scrolls)
            try await assertAudienceReachability(model: model, window: window)
            let inputDiagnostic = inputAncestorDiagnostic(input)
            print("KikiRoomComposer input-policy case=\(item.name) accepted=\(dismissal.acceptsTap(from: input)) \(inputDiagnostic)")
            XCTAssertFalse(dismissal.acceptsTap(from: input), inputDiagnostic)
            XCTAssertFalse(dismissal.acceptsTap(from: input.textView))
            XCTAssertFalse(dismissal.acceptsTap(from: input.emojiButton))
            XCTAssertTrue(input.textView.isFirstResponder)
            try captureInputScreenshot(name: device + "-composer-" + item.name + "-focused", window: window)
            if inspectSoftwareKeyboard, item.name == "phone-native" {
                let shortHeight = input.bounds.height
                model.text = longDraft
                expectedDraft = longDraft
                try await waitFor { input.textView.text == longDraft && input.bounds.height > shortHeight + 20 }
                window.layoutIfNeeded()
                let keyboardFrame = host.view.keyboardLayoutGuide.layoutFrame
                let inputFrame = input.convert(input.bounds, to: host.view)
                let gap = keyboardFrame.minY - inputFrame.maxY
                XCTAssertGreaterThanOrEqual(gap, -1)
                XCTAssertLessThanOrEqual(gap, 32, "A growing composer must remain next to the keyboard")
                XCTAssertTrue(input.textView.isFirstResponder)
                XCTAssertEqual(ObjectIdentifier(input), inputIdentity)
                try assertActionColumn(model: model, input: input, window: window, anchoredTo: idleActions,
                                       phase: item.name + ".grown")
                try await assertSeatReachability(model: model, window: window, allVisible: false, requiresScroll: false)
                try await assertAudienceReachability(model: model, window: window)
                try captureInputScreenshot(name: device + "-composer-" + item.name + "-grown-four-lines", window: window)
            }
            if inspectSoftwareKeyboard {
                // Leave a stable native scene for a simulator screenshot, which
                // also captures the keyboard owned by the system process.
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            XCTAssertTrue(dismissal.acceptsTap(from: host.view))
            // Invoke the recognized-tap callback without fabricating a UITouch.
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
                XCTAssertLessThanOrEqual(host.view.keyboardLayoutGuide.layoutFrame.height, 100,
                                         "Outside dismissal must lower the actual software keyboard")
            }
            try await Task.sleep(nanoseconds: 350_000_000)
            window.layoutIfNeeded()
            let restoredFrame = input.convert(input.bounds, to: window)
            XCTAssertEqual(restoredFrame.minX, idleFrame.minX, accuracy: 1)
            XCTAssertEqual(restoredFrame.maxY, idleFrame.maxY, accuracy: 1)
            XCTAssertEqual(restoredFrame.width, idleFrame.width, accuracy: 1)
            XCTAssertEqual(ObjectIdentifier(input), inputIdentity)
            XCTAssertEqual(input.textView.text, expectedDraft, "Outside dismissal must preserve the full draft")
            try await assertActionReachability(model: model, window: window)
            try assertActionColumn(model: model, input: input, window: window, anchoredTo: idleActions,
                                   phase: item.name + ".blurred")
            try captureInputScreenshot(name: device + "-composer-" + item.name + "-blurred", window: window)
            model.text += "，收起后保留"
            await settle()
            XCTAssertFalse(input.textView.isFirstResponder)
            XCTAssertEqual(input.textView.text, model.text)
            XCTAssertEqual(model.submissions, 0)
            host.view.endEditing(true)
        }
    }

    func testIncomingInvitationStaysAboveFixedActionsWithoutMovingComposer() async throws {
        let scene = try foregroundScene()
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.endEditing(true); window.isHidden = true; previous?.makeKeyAndVisible() }
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let cases: [(name: String, size: CGSize, scheme: ColorScheme, type: DynamicTypeSize, full: Bool)] = [
            ("phone-light", CGSize(width: 375, height: 812), .light, .large, false),
            ("phone-dark-full", CGSize(width: 375, height: 812), .dark, .large, true),
            ("phone-short", CGSize(width: 375, height: 600), .light, .large, false),
            ("phone-accessibility", CGSize(width: 375, height: 812), .dark, .accessibility1, true),
            ("ipad-wide", CGSize(width: 1133, height: 744), .light, .large, true)
        ]
        for item in cases {
            let model = ScreenshotModel(text: "邀请通知不会遮挡操作", messageCount: 1, scheme: item.scheme)
            model.dynamicTypeSize = item.type
            model.isRoomFull = item.full
            let host = UIHostingController(rootView: ComposerScreenshotFixture(model: model))
            host.safeAreaRegions = .container
            window.rootViewController = host
            window.frame = CGRect(origin: .zero, size: item.size)
            host.view.frame = window.bounds
            window.makeKeyAndVisible()
            try await waitFor { model.invitationPlacement.isReady && model.probes["action.1"]?.window != nil }
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
            let input = try XCTUnwrap(descendants(of: host.view).compactMap { $0 as? KikiRoomMessageInput.InputView }.first)
            let restingInput = input.convert(input.bounds, to: window)
            let restingActions = try assertActionColumn(model: model, input: input, window: window,
                                                       phase: item.name + ".without-invitation")
            model.hasInvitation = true
            try await waitFor {
                guard let card = model.probes["invitation"], card.window != nil, card.bounds.height > 0 else { return false }
                let cardFrame = card.convert(card.bounds, to: window)
                return cardFrame.maxY <= restingActions.viewport.minY - 7.5
            }
            window.layoutIfNeeded()
            let card = try layoutFrame("invitation", model: model, window: window)
            let composer = try layoutFrame("composerBar", model: model, window: window)
            let controls = try assertActionColumn(model: model, input: input, window: window,
                                                  anchoredTo: restingActions, phase: item.name + ".with-invitation")
            XCTAssertGreaterThan(card.height, 100, "The real card must include its text and both response buttons")
            XCTAssertGreaterThanOrEqual(card.minY, window.safeAreaInsets.top - 1)
            XCTAssertLessThanOrEqual(card.maxY, controls.viewport.minY - 7.5,
                                     "The entire invitation must be above both microphone and hand controls")
            for button in controls.buttons { XCTAssertFalse(card.intersects(button)) }
            XCTAssertFalse(card.intersects(composer))
            XCTAssertEqual(input.convert(input.bounds, to: window).maxY, restingInput.maxY, accuracy: 1,
                           "Receiving an invitation must not move the composer")
            XCTAssertEqual(input.convert(input.bounds, to: window).width, restingInput.width, accuracy: 1)
            try captureInputScreenshot(name: device + "-incoming-invitation-" + item.name, window: window)

            // A growing native draft changes the composer height. The shared
            // geometry must re-evaluate the card clearance while leaving the
            // action column in its original screen position.
            model.text = "第一行草稿\n第二行继续\n第三行保留\n第四行内容"
            try await waitFor { input.bounds.height > restingInput.height + 10 }
            try await Task.sleep(nanoseconds: 100_000_000)
            window.layoutIfNeeded()
            let grownCard = try layoutFrame("invitation", model: model, window: window)
            let grownComposer = try layoutFrame("composerBar", model: model, window: window)
            let grownControls = try assertActionColumn(model: model, input: input, window: window,
                anchoredTo: restingActions, phase: item.name + ".with-growing-draft")
            XCTAssertLessThanOrEqual(grownCard.maxY, min(grownComposer.minY, grownControls.viewport.minY) - 7.5)
            for button in grownControls.buttons { XCTAssertFalse(grownCard.intersects(button)) }

            model.hasInvitation = false
            model.text = "邀请通知不会遮挡操作"
            try await waitFor { abs(input.bounds.height - restingInput.height) < 1 }
            window.layoutIfNeeded()
            XCTAssertEqual(input.convert(input.bounds, to: window).maxY, restingInput.maxY, accuracy: 1)
            try assertActionColumn(model: model, input: input, window: window,
                                   anchoredTo: restingActions, phase: item.name + ".invitation-dismissed")
        }
    }

    private func layoutFrame(_ key: String, model: ScreenshotModel, window: UIWindow) throws -> CGRect {
        let probe = try XCTUnwrap(model.probes[key], "Missing fixture geometry: " + key)
        return probe.convert(probe.bounds, to: window)
    }

    private struct ActionColumnGeometry {
        let buttons: [CGRect]
        let viewport: CGRect
    }

    @discardableResult
    private func assertActionColumn(model: ScreenshotModel, input: UIView, window: UIWindow,
                                    anchoredTo initial: ActionColumnGeometry? = nil,
                                    phase: String) throws -> ActionColumnGeometry {
        let inputFrame = input.convert(input.bounds, to: window)
        let body = try layoutFrame("content", model: model, window: window)
        let buttons = try (0..<2).map { try layoutFrame("action.\($0)", model: model, window: window) }
        for (index, frame) in buttons.enumerated() {
            XCTAssertEqual(frame.width, 44, accuracy: 1)
            XCTAssertEqual(frame.height, 44, accuracy: 1)
            XCTAssertEqual(frame.maxX, body.maxX, accuracy: 1)
            if index > 0 {
                XCTAssertEqual(frame.midX, buttons[0].midX, accuracy: 1)
                XCTAssertEqual(frame.minY - buttons[index - 1].maxY, 6, accuracy: 1)
            }
        }
        let rail = try XCTUnwrap(scrollAncestor(of: try XCTUnwrap(model.probes["action.1"])))
        let nativeRail = rail.convert(rail.bounds, to: window)
        let visibleRail = rail.convert(rail.bounds.inset(by: rail.adjustedContentInset), to: window)
        print("KikiRoomActions phase=\(phase) buttons=\(buttons) scrollWindow=\(nativeRail) contentViewport=\(visibleRail) frame=\(rail.frame) bounds=\(rail.bounds) contentSize=\(rail.contentSize) contentOffset=\(rail.contentOffset) contentInset=\(rail.contentInset) adjustedInset=\(rail.adjustedContentInset) safeArea=\(rail.safeAreaInsets)")
        XCTAssertGreaterThan(visibleRail.height, 0)
        if rail.contentSize.height <= visibleRail.height + 1 {
            XCTAssertEqual(try XCTUnwrap(buttons.last).maxY, visibleRail.maxY, accuracy: 1,
                           "The final room action must meet the rail bottom without an obsolete empty control slot")
        }
        XCTAssertGreaterThanOrEqual(visibleRail.minY, window.bounds.minY - 1)
        XCTAssertLessThanOrEqual(visibleRail.maxY, window.bounds.maxY + 1)
        if let initial {
            for (index, frames) in zip(buttons, initial.buttons).enumerated() {
                XCTAssertEqual(frames.0.minX, frames.1.minX, accuracy: 1, "Action geometry \(index) must keep its window x coordinate")
                XCTAssertEqual(frames.0.minY, frames.1.minY, accuracy: 1, "Action geometry \(index) must not rise with the keyboard or a growing draft")
                XCTAssertEqual(frames.0.width, frames.1.width, accuracy: 1)
                XCTAssertEqual(frames.0.height, frames.1.height, accuracy: 1)
            }
            // Native backing bounds can include SwiftUI's extended bottom safe
            // area. Compare the content viewport after UIKit's adjusted insets.
            XCTAssertEqual(visibleRail.minX, initial.viewport.minX, accuracy: 1)
            XCTAssertEqual(visibleRail.minY, initial.viewport.minY, accuracy: 1)
            XCTAssertEqual(visibleRail.width, initial.viewport.width, accuracy: 1)
            XCTAssertEqual(visibleRail.height, initial.viewport.height, accuracy: 1)
        }
        let stageProbe = try XCTUnwrap(model.probes["stageContent"])
        let stageScroll = try XCTUnwrap(scrollAncestor(of: stageProbe))
        let stageViewport = stageScroll.convert(stageScroll.bounds, to: window)
        XCTAssertEqual(stageViewport.minX, body.minX, accuracy: 1)
        XCTAssertEqual(stageViewport.maxX, body.maxX, accuracy: 1,
                       "The eight-seat stage must keep the entire room width on iPhone and iPad")
        let audience = try layoutFrame("audience", model: model, window: window)
        XCTAssertEqual(audience.minX, body.minX, accuracy: 1)
        XCTAssertEqual(audience.maxX, body.maxX, accuracy: 1,
                       "The audience strip belongs to the full-width stage, without an action-column gutter")
        XCTAssertGreaterThan(audience.height, 40)
        XCTAssertGreaterThanOrEqual(visibleRail.minY, stageViewport.maxY - 1,
                                    "The room action hit areas must stay in the conversation area below the stage")
        XCTAssertLessThanOrEqual(stageViewport.maxY, inputFrame.minY + 1,
                                 "Keeping the action rail fixed must not disable keyboard avoidance for the stage")
        let chat = try layoutFrame("chat", model: model, window: window)
        XCTAssertGreaterThanOrEqual(chat.minY, stageViewport.maxY - 1,
                                    "Chat must stay below the stage even on a wide iPad")
        XCTAssertLessThanOrEqual(chat.maxX, buttons[0].minX - 11,
                                 "The action rail cannot cover the chat viewport")
        XCTAssertLessThanOrEqual(chat.maxY, inputFrame.minY + 1,
                                 "The chat viewport must continue to avoid the composer and keyboard")
        return ActionColumnGeometry(buttons: buttons, viewport: visibleRail)
    }

    private func inputAncestorDiagnostic(_ input: UIView) -> String {
        var chain: [String] = []
        var ancestor: UIView? = input
        while let view = ancestor {
            chain.append("\(String(describing: type(of: view))){id=\(view.accessibilityIdentifier ?? "nil"),textInput=\(view is UITextInput),frame=\(view.frame),bounds=\(view.bounds)}")
            ancestor = view.superview
        }
        return chain.joined(separator: " -> ")
    }

    private func assertSeatReachability(model: ScreenshotModel, window: UIWindow,
                                       allVisible: Bool, requiresScroll: Bool) async throws {
        let last = try XCTUnwrap(model.probes["seat.8"])
        let scroll = try XCTUnwrap(scrollAncestor(of: last), "The production stage must remain scrollable in a short window")
        let viewport = scroll.convert(scroll.bounds, to: window)
        if allVisible {
            for number in 1...8 {
                let seat = try layoutFrame("seat.\(number)", model: model, window: window)
                XCTAssertGreaterThanOrEqual(seat.minY, viewport.minY - 1, "Seat \(number) must be visible above the keyboard")
                XCTAssertLessThanOrEqual(seat.maxY, viewport.maxY + 1, "Seat \(number) must not be clipped by chat or the composer")
            }
        } else {
            if requiresScroll {
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1,
                                     "The tiny-window fixture must actually exercise stage overflow")
            }
            scroll.scrollRectToVisible(last.convert(last.bounds, to: scroll), animated: false)
            window.layoutIfNeeded()
            await settle()
            let seat = last.convert(last.bounds, to: window)
            XCTAssertGreaterThanOrEqual(seat.minY, viewport.minY - 1)
            XCTAssertLessThanOrEqual(seat.maxY, viewport.maxY + 1, "The eighth seat must be reachable by scrolling")
        }
    }

    private func assertAudienceReachability(model: ScreenshotModel, window: UIWindow) async throws {
        let audience = try XCTUnwrap(model.probes["audience"])
        let stageProbe = try XCTUnwrap(model.probes["stageContent"])
        let scroll = try XCTUnwrap(scrollAncestor(of: stageProbe))
        let previous = scroll.contentOffset
        scroll.scrollRectToVisible(audience.convert(audience.bounds, to: scroll), animated: false)
        window.layoutIfNeeded()
        await settle()
        let viewport = scroll.convert(scroll.bounds, to: window)
        let frame = audience.convert(audience.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1,
                                 "Online listeners must remain reachable while the input keeps keyboard focus")
        scroll.setContentOffset(previous, animated: false)
        window.layoutIfNeeded()
        await settle()
    }

    private func assertActionReachability(model: ScreenshotModel, window: UIWindow) async throws {
        let last = try XCTUnwrap(model.probes["action.1"])
        let scroll = try XCTUnwrap(scrollAncestor(of: last))
        let previous = scroll.contentOffset
        if scroll.bounds.height < 93 {
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 1,
                                 "A short resting window must let the two tools scroll independently")
        }
        scroll.scrollRectToVisible(last.convert(last.bounds, to: scroll), animated: false)
        window.layoutIfNeeded()
        await settle()
        let viewport = scroll.convert(scroll.bounds, to: window)
        let frame = last.convert(last.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.minY, viewport.minY - 1)
        XCTAssertLessThanOrEqual(frame.maxY, viewport.maxY + 1,
                                 "The room action must stay reachable when the keyboard is closed")
        scroll.setContentOffset(previous, animated: false)
        window.layoutIfNeeded()
        await settle()
    }

    private func scrollAncestor(of view: UIView) -> UIScrollView? {
        var parent = view.superview
        while let current = parent {
            if let scroll = current as? UIScrollView { return scroll }
            parent = current.superview
        }
        return nil
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
        @Published var text: String
        @Published var focused = false
        @Published var hasInvitation = false
        @Published var isRoomFull = false
        @Published var dynamicTypeSize: DynamicTypeSize = .large
        var invitationPlacement = KikiRoomInvitationPlacement.pending
        let messageCount: Int
        let scheme: ColorScheme
        var probes: [String: UIView] = [:]
        var dismissals = 0
        var submissions = 0
        init(text: String, messageCount: Int, scheme: ColorScheme) { self.text = text; self.messageCount = messageCount; self.scheme = scheme }
    }

    /// UIKit probes expose geometry even when SwiftUI omits virtual AX nodes.
    private struct LayoutProbe: UIViewRepresentable {
        let key: String
        let model: ScreenshotModel
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            model.probes[key] = view
            return view
        }
        func updateUIView(_ view: UIView, context: Context) { model.probes[key] = view }
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
            CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
    }

    private struct ComposerScreenshotFixture: View {
        @ObservedObject var model: ScreenshotModel
        @SwiftUI.State private var stageContentHeight: CGFloat = 0
        var body: some View {
            KikiRoomBottomLayout(hasChatContent: model.messageCount > 0,
                                 stageContentHeight: stageContentHeight, contentTopInset: 84) {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        KikiAvatar(index: 1, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("今晚一起聊聊").font(.system(size: 17, weight: .semibold))
                            Text("房主 小岛").font(.system(size: 11)).foregroundStyle(KikiPalette.secondary)
                        }
                        Spacer()
                        Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }.frame(height: 60)
                    KikiRoomContentLayout(hasChatContent: model.messageCount > 0,
                                         onStageHeightChange: { stageContentHeight = $0 }) { width, columns in
                        VStack(spacing: 14) {
                            seats(width: width, avatarSize: columns ? 68 : 55)
                            KikiRoomAudienceStrip(listeners: listeners, onOpenPerson: { _ in }) { member in
                                KikiAvatar(index: member.avatarIndex, size: 36)
                            }.background(LayoutProbe(key: "audience", model: model))
                        }
                        .frame(maxWidth: .infinity)
                        .background(LayoutProbe(key: "stageContent", model: model))
                    } chat: {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(0..<model.messageCount, id: \.self) { index in
                                    KikiRoomChatBubbleRow(id: "fixture-\(index)", senderName: index == 0 ? "小岛" : "同频朋友",
                                        text: index == 0 ? "大家晚上好，欢迎来聊天 😀" : "八个麦位和聊天都留在输入栏上方。",
                                        isLocal: false, onOpenSender: {}) {
                                            KikiAvatar(index: index + 1, size: 32)
                                        }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.background(LayoutProbe(key: "chat", model: model))
                    }.background(LayoutProbe(key: "content", model: model))
                }
                .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KikiPalette.background.ignoresSafeArea())
            } footer: { placement in
                KikiRoomComposerWithInvitation(hasInvitation: model.hasInvitation, placement: placement) {
                    KikiIncomingSeatInvitationCard(isBusy: false, isEnabled: true, isRoomFull: model.isRoomFull,
                        onAccept: { model.hasInvitation = false }, onDecline: { model.hasInvitation = false })
                        .background(LayoutProbe(key: "invitation", model: model))
                } composer: {
                    KikiRoomComposerBar {
                        KikiRoomMessageInput(text: $model.text, isFocused: $model.focused,
                            placeholder: "说点什么…", isEnabled: true,
                            onSubmit: { model.submissions += 1 }, onNotice: { _ in })
                            .background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 21))
                            .overlay(RoundedRectangle(cornerRadius: 21).stroke(KikiPalette.muted.opacity(0.3), lineWidth: 1))
                    } send: {
                        Button { model.submissions += 1 } label: { Image(systemName: "paperplane.fill").frame(width: 44, height: 44) }
                    }
                    .background(LayoutProbe(key: "composerBar", model: model))
                }
                .onChange(of: placement, initial: true) { _, value in model.invitationPlacement = value }
            } controls: {
                ForEach(0..<2, id: \.self) { index in
                    Button {} label: {
                        Group {
                            if index == 1 {
                                Image("RaiseHand").renderingMode(.template).resizable().scaledToFit()
                                    .frame(width: 21, height: 21)
                            } else {
                                Image(systemName: "mic.slash.fill")
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(KikiPalette.elevated, in: Circle())
                    }.background(LayoutProbe(key: "action.\(index)", model: model))
                }
            }
            .foregroundStyle(KikiPalette.text)
            .background(KikiRoomKeyboardDismissal(isEnabled: true) {
                model.dismissals += 1
                model.focused = false
            })
            .preferredColorScheme(model.scheme)
            .environment(\.dynamicTypeSize, model.dynamicTypeSize)
        }

        private var listeners: [KikiRoomMember] {
            (1...3).map { number in
                KikiRoomMember(userID: "fixture-listener-\(number)", name: "听众\(number)",
                    avatarIndex: number + 2, avatarURL: nil, role: .member, seatIndex: nil,
                    audioMuted: false, chatMuted: false, online: true,
                    canPublishAudio: false, canPublishData: true)
            }
        }

        private func seats(width: CGFloat, avatarSize: CGFloat) -> some View {
            let columns = max(2, min(4, Int((width + 8) / (avatarSize + 14))))
            let rows = (8 + columns - 1) / columns
            // Eager rows ensure all eight genuine seat views have geometry probes,
            // including the last row before scrolling a very short stage.
            return VStack(spacing: 14) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<columns, id: \.self) { column in
                            let number = row * columns + column + 1
                            if number <= 8 {
                                KikiRoomSeatTile(slot: KikiRoomSeat(index: number, userID: nil, locked: false, audioLocked: false),
                                    member: nil, participant: nil, localUserID: "fixture-owner",
                                    avatarSize: avatarSize)
                                    .background(LayoutProbe(key: "seat.\(number)", model: model))
                            } else { Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            }.padding(.top, 4).padding(.bottom, 2)
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
