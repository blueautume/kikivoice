import SwiftUI

@available(iOS 16.0, *)
struct KikiCover: View {
    var theme: Int
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(colors.last!.opacity(0.7)).frame(width: 200, height: 200).blur(radius: 26).offset(x: geo.size.width * 0.3, y: -40)
                ForEach(0..<5) { i in
                    Ellipse().stroke(.white.opacity(0.07), lineWidth: 1)
                        .frame(width: 170 + CGFloat(i * 44), height: 85 + CGFloat(i * 30))
                        .rotationEffect(.degrees(-35)).offset(x: geo.size.width * 0.32, y: 30)
                }
                Image(systemName: ["moon.stars.fill", "globe.asia.australia.fill", "music.note", "sparkles", "leaf.fill"][abs(theme) % 5])
                    .font(.system(size: 96, weight: .ultraLight)).foregroundStyle(.white.opacity(0.1))
                    .rotationEffect(.degrees(-12)).offset(x: geo.size.width * 0.33, y: -3)
                ForEach(0..<12) { i in
                    Circle().fill(.white.opacity(i % 3 == 0 ? 0.35 : 0.12)).frame(width: i % 3 == 0 ? 3 : 2)
                        .position(x: geo.size.width * CGFloat((i * 37 + 13) % 100) / 100,
                                  y: geo.size.height * CGFloat((i * 23 + 7) % 100) / 100)
                }
            }
        }.clipped().accessibilityHidden(true)
    }
    private var colors: [Color] {
        [[Color(hex: 0x292244), Color(hex: 0x49406B)],
         [Color(hex: 0x12353A), Color(hex: 0x316363)],
         [Color(hex: 0x472D3C), Color(hex: 0x8A5B50)],
         [Color(hex: 0x21233D), Color(hex: 0x474C78)],
         [Color(hex: 0x333A32), Color(hex: 0x66705A)]][abs(theme) % 5]
    }
}
