import SwiftUI
import UIKit

/// The optional tools retain their identity while editing. Their clipped slot
/// collapses in place instead of removing and reinserting UIKit/SwiftUI controls.
struct KikiRoomComposerBar<Composer: View, Send: View, Controls: View>: View {
    let isComposing: Bool
    @ViewBuilder var composer: () -> Composer
    @ViewBuilder var send: () -> Send
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            composer().layoutPriority(1)
            send()
            HStack(spacing: 7) { controls() }
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: isComposing ? 0 : 146, alignment: .trailing)
                .clipped().opacity(isComposing ? 0 : 1)
                .allowsHitTesting(!isComposing).accessibilityHidden(isComposing)
        }
        .accessibilityIdentifier("livekit.room.inputBar")
    }
}

/// A plain-text composer that asks UIKit to use the person's system Emoji
/// keyboard. The input mode remains a system choice, including the globe key.
struct KikiRoomMessageInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onNotice: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InputView {
        let view = InputView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: InputView, context: Context) {
        context.coordinator.update(view: view, text: $text, isFocused: $isFocused,
                                   placeholder: placeholder, isEnabled: isEnabled,
                                   onSubmit: onSubmit, onNotice: onNotice)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: InputView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return CGSize(width: width, height: uiView.fittingHeight(width: width))
    }

    static func dismantleUIView(_ view: InputView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class InputView: UIView {
        let textView = TextView()
        let placeholderLabel = UILabel()
        var maximumNumberOfLines = 4
        let emojiButton = UIButton(type: .system)
        weak var coordinator: Coordinator?

        override init(frame: CGRect) {
            super.init(frame: frame)
            accessibilityIdentifier = "livekit.room.composer"
            isAccessibilityElement = false
            backgroundColor = .clear

            textView.accessibilityIdentifier = "livekit.room.message"
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            textView.textContainer.lineFragmentPadding = 0
            textView.isScrollEnabled = false
            textView.keyboardType = .default
            textView.returnKeyType = .default
            textView.keyboardAppearance = .dark
            textView.textColor = .white
            textView.tintColor = .white
            textView.allowsEditingTextAttributes = false
            if #available(iOS 18.0, *) { textView.supportsAdaptiveImageGlyph = false }
            textView.adjustsFontForContentSizeCategory = true
            textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            emojiButton.accessibilityIdentifier = "livekit.room.emoji"
            emojiButton.tintColor = UIColor.white.withAlphaComponent(0.85)
            emojiButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 19), forImageIn: .normal)
            emojiButton.accessibilityHint = "切换系统文字和表情键盘"
            updateEmojiButton(isEmoji: false)

            [textView, emojiButton].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                addSubview($0)
            }
            NSLayoutConstraint.activate([
                textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                textView.trailingAnchor.constraint(equalTo: emojiButton.leadingAnchor, constant: -2),
                textView.topAnchor.constraint(equalTo: topAnchor, constant: 3),
                textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
                emojiButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                emojiButton.topAnchor.constraint(equalTo: topAnchor),
                emojiButton.bottomAnchor.constraint(equalTo: bottomAnchor),
                emojiButton.widthAnchor.constraint(equalToConstant: 40)
            ])
            placeholderLabel.textColor = UIColor.white.withAlphaComponent(0.46)
            placeholderLabel.isUserInteractionEnabled = false
            placeholderLabel.isAccessibilityElement = false
            textView.addSubview(placeholderLabel)
            updateFont()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: fittingHeight(width: bounds.width > 0 ? bounds.width : 280))
        }

        func fittingHeight(width: CGFloat) -> CGFloat {
            let textWidth = max(1, width - 14 - 2 - 40 - 5)
            let natural = textView.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height
            let maximum = ceil((textView.font?.lineHeight ?? 18) * CGFloat(maximumNumberOfLines) + 22)
            return min(maximum, max(42, ceil(natural + 6)))
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            placeholderLabel.frame = CGRect(x: 0, y: textView.textContainerInset.top,
                                             width: textView.bounds.width, height: textView.font?.lineHeight ?? 18)
            let natural = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
            let scrolls = natural > textView.bounds.height + 1
            if textView.isScrollEnabled != scrolls { textView.isScrollEnabled = scrolls }
        }

        func refreshSizing() {
            placeholderLabel.isHidden = !textView.text.isEmpty
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.viewDidMoveToWindow()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
                updateFont()
            }
        }

        func updateFont() {
            textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
                for: UIFont.systemFont(ofSize: 13), maximumPointSize: 28,
                compatibleWith: traitCollection)
            placeholderLabel.font = textView.font
            refreshSizing()
        }

        func updateEmojiButton(isEmoji: Bool) {
            emojiButton.setImage(UIImage(systemName: isEmoji ? "keyboard" : "face.smiling"), for: .normal)
            emojiButton.accessibilityLabel = isEmoji ? "切回文字键盘" : "使用系统表情键盘"
            emojiButton.accessibilityValue = isEmoji ? "系统 Emoji" : "文字输入"
        }
    }

    final class TextView: UITextView {
        /// An explicit preference for this editing session. UIKit still permits
        /// the person to select another keyboard while the field is active.
        fileprivate var preferredInputMode: UITextInputMode?
        var onSubmit: (() -> Void)?
        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submitShortcut))]
        }
        @objc private func submitShortcut() { onSubmit?() }
        var systemTextInputMode: UITextInputMode? { super.textInputMode }
        var preferredLanguage: String? { preferredInputMode?.primaryLanguage }

        override var textInputContextIdentifier: String? { "com.kikitalk.room-message-input" }

        override var textInputMode: UITextInputMode? {
            preferredInputMode ?? super.textInputMode
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        /// Inject only the query in offline tests; never manufacture an input mode.
        var inputModes: () -> [UITextInputMode] = { UITextInputMode.activeInputModes }
        private(set) var isObservingInputModes = false
        private(set) var isInvalidated = false
        private weak var view: InputView?
        private var text: Binding<String>?
        private var focus: Binding<Bool>?
        private var onSubmit: () -> Void = {}
        private var onNotice: (String) -> Void = { _ in }
        private var enabled = false
        private var lastObservedFocus: Bool?
        private var pendingFocus = false
        private var pendingEmojiToggle = false
        private var lastTextMode: UITextInputMode?
        private var lastKnownMode: UITextInputMode?
        private var isSelectingMode = false
        private var focusWork: DispatchWorkItem?
        private var compositionWork: DispatchWorkItem?
        private var focusRevision = 0
        private var compositionRevision = 0

        deinit {
            NotificationCenter.default.removeObserver(self)
            focusWork?.cancel()
            compositionWork?.cancel()
        }

        func update(view: InputView, text: Binding<String>, isFocused: Binding<Bool>,
                    placeholder: String, isEnabled: Bool,
                    onSubmit: @escaping () -> Void, onNotice: @escaping (String) -> Void) {
            guard !isInvalidated else { return }
            if self.view !== view {
                self.view = view
                view.coordinator = self
                view.textView.delegate = self
                view.textView.onSubmit = { [weak self] in self?.submitConfirmedText() }
                view.emojiButton.addTarget(self, action: #selector(toggleEmoji), for: .touchUpInside)
            }
            self.text = text
            focus = isFocused
            self.onSubmit = onSubmit
            self.onNotice = onNotice
            enabled = isEnabled
            if !isObservingInputModes {
                NotificationCenter.default.addObserver(self, selector: #selector(inputModeDidChange(_:)),
                    name: UITextInputMode.currentInputModeDidChangeNotification, object: nil)
                isObservingInputModes = true
            }

            let field = view.textView
            field.accessibilityLabel = placeholder
            view.placeholderLabel.text = placeholder
            field.isEditable = isEnabled
            field.isSelectable = isEnabled
            view.maximumNumberOfLines = isFocused.wrappedValue ? 4 : 2
            view.emojiButton.isEnabled = isEnabled
            // SwiftUI redraws and server state updates must not replace an IME's
            // provisional selection, nor reset the caret for identical text.
            if field.markedTextRange == nil, field.text != text.wrappedValue {
                field.text = text.wrappedValue
            }
            view.refreshSizing()

            let focusChanged = lastObservedFocus != isFocused.wrappedValue
            lastObservedFocus = isFocused.wrappedValue
            if !isEnabled {
                cancelDeferredInput()
                field.resignFirstResponder()
                synchronizeFocusBinding()
            } else if focusChanged {
                if isFocused.wrappedValue { requestFocus() }
                else {
                    cancelDeferredInput()
                    field.resignFirstResponder()
                }
            }
        }

        func viewDidMoveToWindow() {
            guard !isInvalidated, let field = view?.textView else { return }
            if view?.window != nil {
                if pendingFocus, enabled { requestFocus() }
            } else {
                cancelDeferredInput()
                field.resignFirstResponder()
            }
        }

        private func requestFocus() {
            guard !isInvalidated, enabled, let view else { return }
            guard view.window != nil else { pendingFocus = true; return }
            pendingFocus = false
            if !view.textView.isFirstResponder { view.textView.becomeFirstResponder() }
            synchronizeFocusBinding()
        }

        private func synchronizeFocusBinding() {
            focusWork?.cancel()
            focusRevision += 1
            let revision = focusRevision
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isInvalidated, self.focusRevision == revision,
                      let field = self.view?.textView, let focus = self.focus else { return }
                let actual = self.enabled && field.isFirstResponder
                if focus.wrappedValue != actual { focus.wrappedValue = actual }
            }
            focusWork = work
            DispatchQueue.main.async(execute: work)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            guard !isInvalidated else { return }
            updateModeUI(textView.textInputMode)
            synchronizeFocusBinding()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard !isInvalidated else { return }
            cancelDeferredInput()
            synchronizeFocusBinding()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isInvalidated else { return }
            finishPendingEmojiToggleAfterComposition()
        }

        func textViewDidChange(_ textView: UITextView) { textDidChange() }

        @objc func textDidChange() {
            guard !isInvalidated, enabled, let field = view?.textView else { return }
            if text?.wrappedValue != field.text { text?.wrappedValue = field.text ?? "" }
            view?.refreshSizing()
            finishPendingEmojiToggleAfterComposition()
        }

        func submitConfirmedText() {
            guard !isInvalidated, enabled, let field = view?.textView,
                  field.markedTextRange == nil else { return }
            textDidChange()
            onSubmit()
        }

        @objc func toggleEmoji() {
            guard !isInvalidated, enabled, let view else { return }
            guard view.textView.markedTextRange == nil else {
                pendingEmojiToggle = true
                return
            }
            pendingEmojiToggle = false
            let field = view.textView
            let current = field.textInputMode ?? lastKnownMode
            rememberTextMode(current)
            let modes = inputModes()
            let emojiMode = modes.first { $0.primaryLanguage == "emoji" }
            guard let emojiMode else {
                onNotice("请在系统“设置 → 通用 → 键盘 → 键盘”中添加“表情符号”键盘。")
                // No input-mode request or reload: a missing Emoji keyboard is
                // not permission to change the person's current text language.
                if !field.isFirstResponder { requestFocus() }
                return
            }
            let target: UITextInputMode?
            if current?.primaryLanguage == "emoji" {
                target = lastTextMode.flatMap { remembered in
                    modes.contains(where: { $0 === remembered || $0.isEqual(remembered) }) ? remembered : nil
                } ?? modes.first { $0.primaryLanguage != "emoji" }
            } else {
                target = emojiMode
            }
            guard let target else {
                if !field.isFirstResponder { requestFocus() }
                return
            }
            field.preferredInputMode = target
            updateModeUI(target)
            // reloadInputViews can synchronously post a nil input-mode change.
            // It belongs to our selection, not a globe-key override by the user.
            isSelectingMode = true
            defer { isSelectingMode = false }
            if field.isFirstResponder { field.reloadInputViews() }
            else { requestFocus() }
        }

        @objc private func inputModeDidChange(_ notification: Notification) {
            guard !isInvalidated, !isSelectingMode,
                  let field = view?.textView, field.isFirstResponder else { return }
            let mode = notification.object as? UITextInputMode ?? field.systemTextInputMode
            // A subsequent system/globe selection takes precedence. Releasing
            // our preference must not reload and reassert the old keyboard.
            field.preferredInputMode = nil
            updateModeUI(mode)
        }

        private func updateModeUI(_ mode: UITextInputMode?) {
            guard let mode else { return }
            lastKnownMode = mode
            rememberTextMode(mode)
            view?.updateEmojiButton(isEmoji: mode.primaryLanguage == "emoji")
        }

        private func rememberTextMode(_ mode: UITextInputMode?) {
            if let mode, mode.primaryLanguage != "emoji" { lastTextMode = mode }
        }

        private func finishPendingEmojiToggleAfterComposition() {
            guard pendingEmojiToggle, let field = view?.textView, field.markedTextRange == nil else { return }
            compositionWork?.cancel()
            compositionRevision += 1
            let revision = compositionRevision
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isInvalidated, self.compositionRevision == revision,
                      self.pendingEmojiToggle, self.view?.textView.markedTextRange == nil else { return }
                self.textDidChange()
                self.toggleEmoji()
            }
            compositionWork = work
            DispatchQueue.main.async(execute: work)
        }

        private func cancelDeferredInput() {
            pendingFocus = false
            pendingEmojiToggle = false
            compositionRevision += 1
            compositionWork?.cancel()
            view?.textView.preferredInputMode = nil
        }

        func invalidate() {
            guard !isInvalidated else { return }
            isInvalidated = true
            focusRevision += 1
            focusWork?.cancel()
            cancelDeferredInput()
            NotificationCenter.default.removeObserver(self)
            isObservingInputModes = false
            if let view {
                view.textView.delegate = nil
                view.textView.onSubmit = nil
                view.emojiButton.removeTarget(self, action: #selector(toggleEmoji), for: .touchUpInside)
                view.coordinator = nil
                view.textView.resignFirstResponder()
            }
            view = nil
            text = nil
            focus = nil
            lastTextMode = nil
            lastKnownMode = nil
            onSubmit = {}
            onNotice = { _ in }
        }
    }
}
