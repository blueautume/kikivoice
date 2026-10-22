import SwiftUI

/// Seats and listeners use the full room width. Only the conversation reserves
/// a separate action column, above the keyboard-safe input row.
struct KikiRoomContentLayout<Stage: View, Chat: View, Controls: View>: View {
    var hasChatContent = true
    @ViewBuilder var stage: (_ width: CGFloat, _ usesColumns: Bool) -> Stage
    @ViewBuilder var chat: () -> Chat
    @ViewBuilder var controls: () -> Controls
    @State private var stageContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width)
            let height = max(0, geometry.size.height)
            // Do not reserve the entire four-button rail when the keyboard opens:
            // the rail scrolls in a short conversation area instead of covering seats.
            let conversationMinimum = min(max(0, height - 14), max(44, min(hasChatContent ? 64 : 44, height * 0.25)))
            let stageLimit = max(0, height - conversationMinimum - 14)
            let stageHeight = min(stageContentHeight, stageLimit)
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
                .frame(height: stageHeight, alignment: .top)
                .onPreferenceChange(KikiRoomStageHeightKey.self) { stageContentHeight = $0 }
                .accessibilityIdentifier("livekit.room.stage")
                HStack(alignment: .bottom, spacing: 12) {
                    chat()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(spacing: 6) { controls() }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: 44, height: min(194, max(0, height - stageHeight - 14)))
                    .accessibilityIdentifier("livekit.room.actions")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct KikiRoomStageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
