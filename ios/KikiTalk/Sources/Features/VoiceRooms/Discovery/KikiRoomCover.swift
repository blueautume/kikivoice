import SwiftUI

/// Five room-owned styles share the same lightweight drawing in the picker and
/// the room. The system appearance chooses a separate, readable color palette.
enum KikiRoomBackgroundStyle: Int, CaseIterable, Identifiable {
    case mist, daylight, sky, dusk, mint

    var id: Int { rawValue }
    init(theme: Int) { self = Self(rawValue: theme) ?? .mist }

    var title: String {
        switch self {
        case .mist: return "简约"
        case .daylight: return "晨光"
        case .sky: return "晴空"
        case .dusk: return "暮色"
        case .mint: return "薄荷"
        }
    }

    func colors(dark: Bool) -> [Color] {
        let values: [UInt]
        switch (self, dark) {
        case (.mist, false): values = [0xF6F6F8, 0xECEEF4, 0xE3E6EF]
        case (.mist, true): values = [0x111216, 0x1C1E27, 0x292D3C]
        case (.daylight, false): values = [0xFFF8F2, 0xF8E9DD, 0xF6DBD1]
        case (.daylight, true): values = [0x191416, 0x302129, 0x482C31]
        case (.sky, false): values = [0xF4F9FF, 0xE5EFFD, 0xC9DFF7]
        case (.sky, true): values = [0x101720, 0x17283B, 0x243F58]
        case (.dusk, false): values = [0xFBF6FF, 0xEFE5F7, 0xDCCCF0]
        case (.dusk, true): values = [0x181320, 0x2B203D, 0x403055]
        case (.mint, false): values = [0xF4FAF7, 0xE1F0E9, 0xCBE2DA]
        case (.mint, true): values = [0x111A19, 0x1D302D, 0x2D4940]
        }
        return values.map { Color(hex: $0) }
    }
}

struct KikiRoomBackground: View {
    let theme: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = KikiRoomBackgroundStyle(theme: theme).colors(dark: colorScheme == .dark)
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [colors[0], colors[1]], startPoint: .top, endPoint: .bottomTrailing)
                RadialGradient(colors: [colors[2].opacity(0.72), colors[2].opacity(0)],
                               center: .topTrailing, startRadius: 0,
                               endRadius: max(geometry.size.width, geometry.size.height) * 0.85)
                Path { path in
                    let width = geometry.size.width, height = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: height * 0.68))
                    path.addCurve(to: CGPoint(x: width, y: height * 0.38),
                                  control1: CGPoint(x: width * 0.35, y: height * 0.1),
                                  control2: CGPoint(x: width * 0.65, y: height * 0.96))
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [colors[2].opacity(0.24), colors[0].opacity(0.1)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipped().accessibilityHidden(true)
    }
}

struct KikiCover: View {
    var theme: Int
    var body: some View { KikiRoomBackground(theme: theme) }
}

struct KikiRoomBackgroundPicker: View {
    @Binding var theme: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(KikiRoomBackgroundStyle.allCases) { style in
                Button { theme = style.rawValue } label: {
                    VStack(spacing: 7) {
                        KikiRoomBackground(theme: style.rawValue)
                            .frame(height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme == style.rawValue ? KikiPalette.purple : KikiPalette.text.opacity(0.12), lineWidth: theme == style.rawValue ? 2 : 0.5)
                            }
                            .overlay {
                                if theme == style.rawValue {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18)).foregroundStyle(.white, KikiPalette.purple)
                                }
                            }
                        Text(style.title).font(.caption).foregroundStyle(KikiPalette.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(style.title)背景")
                .accessibilityAddTraits(theme == style.rawValue ? .isSelected : [])
            }
        }
    }
}
