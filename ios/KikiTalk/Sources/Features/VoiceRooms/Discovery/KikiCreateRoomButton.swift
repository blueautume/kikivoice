import SwiftUI

struct KikiCreateRoomButton: View {
    static let capsuleHeight = KikiDiscoveryActionButton.capsuleHeight
    static let touchHeight = KikiDiscoveryActionButton.touchHeight
    static let symbolSize: CGFloat = 20
    var widthToHeightRatio: CGFloat = 1.6
    var isVisible: Bool = true
    let action: () -> Void

    var body: some View {
        KikiDiscoveryActionButton(systemImage: "mic.fill", symbolSize: Self.symbolSize,
                                  widthToHeightRatio: widthToHeightRatio, isVisible: isVisible, action: action)
            .accessibilityLabel("创建语聊房")
            .accessibilityHint("设置房间名称并开始语聊")
            .accessibilityIdentifier("createRoom")
    }
}

struct KikiFindPeopleButton: View {
    var isVisible: Bool = true
    let action: () -> Void

    var body: some View {
        KikiDiscoveryActionButton(systemImage: "person.badge.plus", symbolSize: 22,
                                  isVisible: isVisible, action: action)
            .accessibilityLabel("找朋友")
            .accessibilityIdentifier("social.people")
    }
}

/// Both discovery actions share their visual dimensions, touch area and brief
/// highlight. There is no persistent timer or idle animation loop.
private struct KikiDiscoveryActionButton: View {
    static let capsuleHeight: CGFloat = 36
    static let touchHeight: CGFloat = 44
    let systemImage: String
    let symbolSize: CGFloat
    var widthToHeightRatio: CGFloat = 1.6
    var isVisible: Bool = true
    let action: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var highlight: CGFloat = 0

    private var animatesHighlight: Bool { isVisible && scenePhase == .active && !reduceMotion && isEnabled }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Self.capsuleHeight * widthToHeightRatio, height: Self.capsuleHeight)
                .background {
                    Capsule().fill(LinearGradient(colors: [Color(hex: 0xA177FF), Color(hex: 0x7446EE)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    GeometryReader { geometry in
                        LinearGradient(colors: [.clear, .white.opacity(0.26), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: 24)
                            .rotationEffect(.degrees(20))
                            .offset(x: -30 + (geometry.size.width + 60) * highlight)
                            .opacity(highlight == 0 ? 0 : 1)
                    }
                    .clipShape(Capsule()).allowsHitTesting(false).accessibilityHidden(true)
                }
                .overlay(Capsule().strokeBorder(.white.opacity(0.30), lineWidth: 1))
                .shadow(color: Color(hex: 0x8656EF).opacity(0.24), radius: 7, x: 0, y: 3)
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(Capsule())
                .frame(height: Self.touchHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: animatesHighlight) {
            resetHighlight()
            guard animatesHighlight else { return }
            // Two passes only; leaving the screen, backgrounding, Reduce Motion,
            // or disabling the control cancels the remaining work immediately.
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                for pass in 0..<2 {
                    try Task.checkCancellation()
                    withAnimation(.easeInOut(duration: 1.3)) { highlight = 1 }
                    try await Task.sleep(nanoseconds: 1_300_000_000)
                    resetHighlight()
                    if pass == 0 { try await Task.sleep(nanoseconds: 2_800_000_000) }
                }
            } catch { resetHighlight() }
        }
    }

    private func resetHighlight() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { highlight = 0 }
    }
}
