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

/// Attach after the composer's safeAreaInset. Only this full-window overlay
/// ignores keyboard avoidance, leaving the composer and room content responsive.
struct KikiRoomActionRail<Controls: View>: View {
    var hasChatContent = true
    let stageContentHeight: CGFloat
    let contentTopInset: CGFloat
    // The resting send button is 44 pt, with 16 pt composer padding and a 2 pt gap.
    var bottomInset: CGFloat = 62
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let height = max(0, geometry.size.height - contentTopInset - bottomInset)
            let metrics = KikiRoomContentMetrics(height: height, stageContentHeight: stageContentHeight,
                                                hasChatContent: hasChatContent)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                ScrollView {
                    VStack(spacing: 6) { controls() }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 44, height: min(194, metrics.conversationHeight))
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
