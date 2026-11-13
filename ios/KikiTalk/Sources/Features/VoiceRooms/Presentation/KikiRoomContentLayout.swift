import SwiftUI
import UIKit

/// A fixed stage and a separately scrolling conversation share the resting
/// canvas. Stage sizing never depends on keyboard or draft height.
struct KikiRoomContentLayout<Stage: View, Chat: View>: View {
    var hasChatContent = true
    var onStageHeightChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var stage: (_ width: CGFloat, _ availableHeight: CGFloat, _ usesColumns: Bool) -> Stage
    @ViewBuilder var chat: () -> Chat
    @State private var stageContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let height = max(0, geometry.size.height)
            let stageBudget = max(0, height - 44 - 6)
            VStack(spacing: 6) {
                stage(width, stageBudget, width >= 720)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { stageGeometry in
                            Color.clear.preference(key: KikiRoomStageHeightKey.self,
                                                   value: stageGeometry.size.height)
                        }
                    }
                .onPreferenceChange(KikiRoomStageHeightKey.self) {
                    stageContentHeight = $0
                    onStageHeightChange($0)
                }
                .accessibilityIdentifier("livekit.room.stage")
                HStack(alignment: .bottom, spacing: 12) {
                    chat()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Color.clear.frame(width: 44).accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// One resting canvas ignores keyboard resizing. Only the independent native
/// footer host follows keyboardLayoutGuide, without reserving moving blank space.
struct KikiRoomBottomLayout<Content: View, Footer: View, Controls: View>: View {
    var hasChatContent = true
    let stageContentHeight: CGFloat
    let contentTopInset: CGFloat
    var showsControls = true
    var invitation: AnyView? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: (KikiRoomInvitationPlacement) -> Footer
    @ViewBuilder var controls: () -> Controls
    @State private var composerFrame = CGRect.zero
    @State private var controlsFrame = CGRect.zero
    @State private var invitationFrame = CGRect.zero

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .bottom) {
                content()
                    // A single-line resting composer band stays constant when
                    // typing, growing a draft or receiving an invitation.
                    .padding(.bottom, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsControls {
                    KikiRoomActionRail(hasChatContent: hasChatContent,
                                       stageContentHeight: stageContentHeight,
                                       contentTopInset: contentTopInset, controls: controls)
                }
                if let invitation {
                    invitation
                        .frame(maxWidth: 600).frame(maxWidth: .infinity)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 62 + (showsControls ? 94 : 0) + 8)
                }
                KikiRoomKeyboardFooter {
                    footer(invitationPlacement)
                        .background(KikiRoomBottomFrameProbe(element: .composer))
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .frame(maxWidth: 1180).frame(maxWidth: .infinity)
                }
            }
            .environment(\.kikiRoomBottomGeometry, KikiRoomBottomGeometry(onFrameChange: recordFrame))
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var invitationPlacement: KikiRoomInvitationPlacement {
        guard composerFrame.height > 0 else { return .pending }
        guard showsControls else { return .init(bottomSpacing: 0, isReady: true) }
        guard controlsFrame.height > 0 else { return .pending }
        // Both frames resolve in one coordinate space. When the keyboard raises
        // the composer above the fixed controls this spacing naturally becomes 0.
        return .init(bottomSpacing: max(0, composerFrame.minY - controlsFrame.minY), isReady: true)
    }

    private func recordFrame(_ element: KikiRoomBottomElement, _ frame: CGRect) {
        switch element {
        case .composer:
            if composerFrame != frame { composerFrame = frame }
        case .controls:
            if controlsFrame != frame { controlsFrame = frame }
        case .invitation:
            if invitationFrame != frame { invitationFrame = frame }
        }
    }
}

struct KikiRoomInvitationPlacement: Equatable {
    let bottomSpacing: CGFloat
    let isReady: Bool
    static let pending = Self(bottomSpacing: 0, isReady: false)
}

/// Shared by the room and its layout fixtures so the invitation, actual native
/// composer, and action rail are verified together rather than in isolation.
struct KikiRoomComposerWithInvitation<Invitation: View, Composer: View>: View {
    let hasInvitation: Bool
    let placement: KikiRoomInvitationPlacement
    @ViewBuilder var invitation: () -> Invitation
    @ViewBuilder var composer: () -> Composer

    var body: some View {
        VStack(spacing: 8) {
            if hasInvitation {
                invitation()
                    .frame(maxWidth: 600).frame(maxWidth: .infinity)
                    .background(KikiRoomBottomFrameProbe(element: .invitation))
                    .padding(.bottom, placement.bottomSpacing)
                    // Keep the card's intrinsic layout size on the first pass,
                    // but never flash or accept a touch underneath the controls.
                    .opacity(placement.isReady ? 1 : 0)
                    .allowsHitTesting(placement.isReady)
                    .accessibilityHidden(!placement.isReady)
            }
            composer()
                .background(KikiRoomBottomFrameProbe(element: .composer))
        }
    }
}

private enum KikiRoomBottomElement {
    case composer, controls, invitation
}

private struct KikiRoomBottomGeometry {
    let onFrameChange: (KikiRoomBottomElement, CGRect) -> Void
}

private struct KikiRoomBottomGeometryKey: EnvironmentKey {
    static let defaultValue: KikiRoomBottomGeometry? = nil
}

private extension EnvironmentValues {
    var kikiRoomBottomGeometry: KikiRoomBottomGeometry? {
        get { self[KikiRoomBottomGeometryKey.self] }
        set { self[KikiRoomBottomGeometryKey.self] = newValue }
    }
}

/// Native window coordinates work across the canvas and footer hosting roots.
private struct KikiRoomBottomFrameProbe: UIViewRepresentable {
    let element: KikiRoomBottomElement
    @Environment(\.kikiRoomBottomGeometry) private var layout

    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {
        view.report = { frame in layout?.onFrameChange(element, frame) }
        view.publish()
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.report?(.zero); view.report = nil }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
    final class Probe: UIView {
        var report: ((CGRect) -> Void)?
        private var lastFrame = CGRect.null
        override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); publish() }
        override func didMoveToWindow() { super.didMoveToWindow(); publish() }
        func publish() {
            guard let window else { return }
            let frame = convert(bounds, to: window)
            guard frame != lastFrame else { return }
            lastFrame = frame
            DispatchQueue.main.async { [weak self] in self?.report?(frame) }
        }
    }
}

/// The footer uses native keyboard geometry once. Its SwiftUI subtree receives
/// the caller's environment but disables its own second keyboard avoidance.
private struct KikiRoomKeyboardFooter<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        // Copy values, never the complete parent EnvironmentValues graph:
        // carrying its internal graph links into another hosting root creates
        // AttributeGraph cycles and can drop later focus/binding updates.
        controller.host.rootView = AnyView(content()
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
            .environment(\.locale, context.environment.locale)
            .environment(\.layoutDirection, context.environment.layoutDirection)
            .environment(\.isEnabled, context.environment.isEnabled)
            .environment(\.scenePhase, context.environment.scenePhase)
            .environment(\.kikiRoomBottomGeometry, context.environment.kikiRoomBottomGeometry)
            .tint(KikiPalette.purple))
    }
    final class Controller: UIViewController {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let passthrough = PassthroughView()
        override func loadView() { view = passthrough }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.accessibilityIdentifier = "livekit.room.keyboardFooterHost"
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            host.sizingOptions = [.intrinsicContentSize]
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            host.didMove(toParent: self)
            passthrough.footer = host.view
            let fillWidth = host.view.widthAnchor.constraint(equalTo: view.widthAnchor)
            fillWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                fillWidth, host.view.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
                host.view.widthAnchor.constraint(lessThanOrEqualToConstant: 1180),
                host.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
            ])
        }
    }
    final class PassthroughView: UIView {
        weak var footer: UIView?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let footer else { return nil }
            // Convert against the live native frame after every keyboard move;
            // cached window rectangles can lag a translated hosting root.
            let local = convert(point, to: footer)
            guard footer.bounds.contains(local) else { return nil }
            return footer.hitTest(local, with: event)
        }
    }
}

/// Attach after the composer's safeAreaInset. Only this full-window overlay
/// ignores keyboard avoidance, leaving the composer and room content responsive.
struct KikiRoomActionRail<Controls: View>: View {
    var hasChatContent = true
    let stageContentHeight: CGFloat
    let contentTopInset: CGFloat
    // The resting send button is 44 pt, with 16 pt composer padding and a 2 pt gap.
    var bottomInset: CGFloat = 62
    @ViewBuilder var controls: () -> Controls
    @State private var controlsHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let availableHeight = max(0, geometry.size.height - contentTopInset - bottomInset)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ScrollView {
                    VStack(spacing: 6) { controls() }
                        .fixedSize(horizontal: false, vertical: true)
                        .background {
                            GeometryReader { controlsGeometry in
                                Color.clear.preference(key: KikiRoomControlsHeightKey.self,
                                                       value: controlsGeometry.size.height)
                            }
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                // The rail owns its intrinsic height. A tall relationship ring
                // or an empty conversation must never crop its second button.
                .frame(width: 44, height: min(controlsHeight, availableHeight))
                .background(KikiRoomBottomFrameProbe(element: .controls))
                .onPreferenceChange(KikiRoomControlsHeightKey.self) { controlsHeight = $0 }
                .accessibilityIdentifier("livekit.room.actions")
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, bottomInset)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct KikiRoomStageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct KikiRoomControlsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
