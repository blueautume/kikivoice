import SwiftUI

/// Seats and listeners use the full room width. The conversation reserves the
/// fixed action column's width while continuing to avoid the keyboard.
struct KikiRoomContentLayout<Stage: View, Chat: View>: View {
    var hasChatContent = true
    var onStageHeightChange: (CGFloat) -> Void = { _ in }
    @ViewBuilder var stage: (_ width: CGFloat, _ usesColumns: Bool) -> Stage
    @ViewBuilder var chat: () -> Chat
    @State private var stageContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let height = max(0, geometry.size.height)
            let metrics = KikiRoomContentMetrics(height: height, stageContentHeight: stageContentHeight,
                                                hasChatContent: hasChatContent)
            VStack(spacing: 14) {
                ScrollView {
                    stage(width, width >= 720)
                        .frame(maxWidth: .infinity)
                        .background {
                            GeometryReader { stageGeometry in
                                Color.clear.preference(key: KikiRoomStageHeightKey.self,
                                                       value: stageGeometry.size.height)
                            }
                        }
                }
                .scrollDismissesKeyboard(.interactively)
                .frame(height: metrics.stageHeight, alignment: .top)
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

/// Keeps the composer keyboard-aware and the action rail in its resting window
/// position. Incoming invitations reserve the rail's actual visible height above
/// the composer, without guessing the card height or lifting the controls.
struct KikiRoomBottomLayout<Content: View, Footer: View, Controls: View>: View {
    var hasChatContent = true
    let stageContentHeight: CGFloat
    let contentTopInset: CGFloat
    var showsControls = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: (KikiRoomInvitationPlacement) -> Footer
    @ViewBuilder var controls: () -> Controls
    @Namespace private var layoutSpace
    @State private var composerFrame = CGRect.zero
    @State private var controlsFrame = CGRect.zero

    var body: some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                footer(invitationPlacement)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .frame(maxWidth: 1180).frame(maxWidth: .infinity)
            }
            .overlay {
                if showsControls {
                    KikiRoomActionRail(hasChatContent: hasChatContent,
                                       stageContentHeight: stageContentHeight,
                                       contentTopInset: contentTopInset, controls: controls)
                }
            }
            .environment(\.kikiRoomBottomGeometry,
                         KikiRoomBottomGeometry(space: layoutSpace, onFrameChange: recordFrame))
            .coordinateSpace(name: layoutSpace)
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
    case composer, controls
}

private struct KikiRoomBottomGeometry {
    let space: Namespace.ID
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

/// safeAreaInset is a separate layout branch: report each frame directly from
/// its geometry instead of depending on anchor-preference propagation through it.
private struct KikiRoomBottomFrameProbe: View {
    let element: KikiRoomBottomElement
    @Environment(\.kikiRoomBottomGeometry) private var layout

    var body: some View {
        GeometryReader { geometry in
            let frame = layout.map { geometry.frame(in: .named($0.space)) } ?? .zero
            Color.clear
                .onChange(of: frame, initial: true) { _, frame in
                    layout?.onFrameChange(element, frame)
                }
                .onDisappear { layout?.onFrameChange(element, .zero) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
            let height = max(0, geometry.size.height - contentTopInset - bottomInset)
            let metrics = KikiRoomContentMetrics(height: height, stageContentHeight: stageContentHeight,
                                                hasChatContent: hasChatContent)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ScrollView {
                    VStack(spacing: 6) { controls() }
                        .background {
                            GeometryReader { controlsGeometry in
                                Color.clear.preference(key: KikiRoomControlsHeightKey.self,
                                                       value: controlsGeometry.size.height)
                            }
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 44, height: min(controlsHeight, metrics.conversationHeight))
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

private struct KikiRoomContentMetrics {
    let stageHeight: CGFloat
    let conversationHeight: CGFloat

    init(height: CGFloat, stageContentHeight: CGFloat, hasChatContent: Bool) {
        let minimum = min(max(0, height - 14), max(44, min(hasChatContent ? 64 : 44, height * 0.25)))
        stageHeight = min(stageContentHeight, max(0, height - minimum - 14))
        conversationHeight = max(0, height - stageHeight - 14)
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
