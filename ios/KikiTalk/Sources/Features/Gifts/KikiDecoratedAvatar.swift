import SwiftUI

@available(iOS 16.0, *)
struct KikiDecoratedAvatar: View {
    @ObservedObject var gifts: KikiGiftStore
    let userID: String
    var index: Int
    var size: CGFloat = 40
    var customURL: String? = nil

    var body: some View {
        KikiAvatar(index: index, size: size, customURL: customURL)
            .overlay { KikiAvatarDecoration(decorationID: gifts.appearance(for: userID).avatarFrame, size: size) }
    }
}
