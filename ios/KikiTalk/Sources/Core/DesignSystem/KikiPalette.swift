import SwiftUI
import UIKit

enum KikiPalette {
    private static func adaptive(_ light: UInt, _ dark: UInt) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive(0xF7F7FA, 0x131318)
    static let surface = adaptive(0xFFFFFF, 0x1E1E26)
    static let elevated = adaptive(0xEBEAF0, 0x2B2A35)
    static let purple = adaptive(0x7456CC, 0xA78AEF)
    static let lavender = adaptive(0x7355BA, 0xC6B5EF)
    static let action = adaptive(0x7456CC, 0x7456CC)
    static let roleBadgeBackground = adaptive(0xEEE7FA, 0x51336E)
    static let roleBadgeText = adaptive(0x5C3A99, 0xF1E7FF)
    static let text = adaptive(0x25232B, 0xF4F2F8)
    static let secondary = adaptive(0x6D6878, 0xBAB5C5)
    static let muted = adaptive(0x88838F, 0x928D9D)
    static let mint = adaptive(0x397C68, 0xA8D6C1)
    static let warning = adaptive(0x8C4C17, 0xEAC6A3)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}
