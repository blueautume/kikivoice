import SwiftUI
import UIKit

enum KikiAvatarAppearance {
    static let placeholderSymbolName = "person.crop.circle.fill"
    static let backgroundColor = UIColor.tertiarySystemFill
    static let foregroundColor = UIColor.secondaryLabel
}

@available(iOS 16.0, *)
struct KikiAvatar: View {
    // Retained for older account and room payloads; default avatars are uniform.
    var index: Int
    var size: CGFloat = 40
    var customURL: String? = nil
    @State private var customImage: UIImage?
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
        .background(Color(uiColor: KikiAvatarAppearance.backgroundColor))
        .clipShape(Circle())
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
        Image(systemName: KikiAvatarAppearance.placeholderSymbolName)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color(uiColor: KikiAvatarAppearance.foregroundColor))
    }
}
