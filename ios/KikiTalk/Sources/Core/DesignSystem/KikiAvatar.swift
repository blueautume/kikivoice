import SwiftUI
import UIKit

@available(iOS 16.0, *)
struct KikiAvatar: View {
    var index: Int
    var size: CGFloat = 40
    var customURL: String? = nil
    @State private var customImage: UIImage?
    private let faces = ["🧑🏻‍🚀", "👩🏻", "🧑🏼", "👩🏽‍🦱", "🧑🏻‍🎨", "👩🏼‍🦰", "🧑🏽‍🎤", "👨🏻‍🦱", "👩🏻‍🎤", "🧑🏼‍🚀", "👩🏾", "👨🏼"]
    private let colors: [Color] = [Color(hex: 0x6351A4), Color(hex: 0x958392), Color(hex: 0x758779), Color(hex: 0xAD796A), Color(hex: 0x6B8F9B)]
    var body: some View {
        Group {
            if let customURL {
                if let image = customImage ?? KikiAccountAPIClient.shared.cachedAvatar(customURL) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [colors[abs(index) % colors.count].opacity(0.8), colors[abs(index) % colors.count].opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: customURL) {
            customImage = nil
            guard let customURL else { return }
            do {
                let loaded = try await KikiAccountAPIClient.shared.loadAvatar(customURL)
                try Task.checkCancellation()
                customImage = loaded
            } catch { /* Keep a stable avatar fallback when offline. */ }
        }
    }
    private var placeholder: some View {
        Text(faces[abs(index) % faces.count]).font(.system(size: size * 0.62))
    }
}
