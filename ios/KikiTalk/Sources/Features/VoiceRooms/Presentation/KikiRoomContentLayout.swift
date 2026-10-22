import SwiftUI

/// The action column has its own hit area; it never covers seats or messages,
/// and never consumes the keyboard-safe input row's width or height.
struct KikiRoomContentLayout<Stage: View, Chat: View, Controls: View>: View {
    var hasChatContent = true
    @ViewBuilder var stage: (_ width: CGFloat, _ usesColumns: Bool) -> Stage
    @ViewBuilder var chat: () -> Chat
    @ViewBuilder var controls: () -> Controls
    @State private var stageContentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 56)
            let usesColumns = contentWidth >= 720
            let stageWidth = usesColumns ? min(500, max(300, (contentWidth - 24) * 0.48)) : contentWidth
            // Empty chat must not squeeze the eight seats when the keyboard opens.
            // In a short window each pane can still scroll independently.
            let chatReservation = hasChatContent ? min(80, geometry.size.height * 0.25) : 0
            let stageLimit = max(0, geometry.size.height - chatReservation - 14)
            let layout = usesColumns
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                : AnyLayout(VStackLayout(spacing: 14))
            HStack(alignment: .bottom, spacing: 12) {
                layout {
                    ScrollView {
                        stage(stageWidth, usesColumns)
                            .frame(maxWidth: .infinity)
                            .background {
                                GeometryReader { stageGeometry in
                                    Color.clear.preference(key: KikiRoomStageHeightKey.self,
                                                           value: stageGeometry.size.height)
                                }
                            }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .frame(width: usesColumns ? stageWidth : nil,
                           height: usesColumns ? nil : min(stageContentHeight, stageLimit))
                    .frame(maxHeight: usesColumns ? .infinity : nil, alignment: .top)
                    .onPreferenceChange(KikiRoomStageHeightKey.self) { stageContentHeight = $0 }
                    .accessibilityIdentifier("livekit.room.stage")
                    chat()
                        .padding(usesColumns ? 16 : 0)
                        .background(.white.opacity(usesColumns ? 0.035 : 0), in: RoundedRectangle(cornerRadius: 20))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: contentWidth, height: max(0, geometry.size.height))
                ScrollView {
                    VStack(spacing: 6) { controls() }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(width: 44, height: min(144, max(0, geometry.size.height)))
                .accessibilityIdentifier("livekit.room.actions")
            }
        }
    }
}

private struct KikiRoomStageHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
