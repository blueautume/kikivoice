import SwiftUI

/// Gifts remain visibly unavailable until the independent service implements them.
/// This object deliberately has no networking, wallet balance or polling timer.
@MainActor
final class KikiGiftStore: ObservableObject {
    let isAvailable = false
    func reset() { }
}

@available(iOS 16.0, *)
struct KikiGiftWalletCard: View {
    @ObservedObject var gifts: KikiGiftStore
    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "gift.fill").font(.system(size: 23)).foregroundStyle(KikiPalette.lavender)
            VStack(alignment: .leading, spacing: 7) {
                Text("礼物暂未开放").font(.system(size: 14, weight: .semibold))
                Text("实验版先验证语音与文字消息，不提供充值或赠送。")
                    .font(.system(size: 11)).lineSpacing(4).foregroundStyle(KikiPalette.secondary)
            }
            Spacer(minLength: 0)
        }.padding(19).background(KikiPalette.surface, in: RoundedRectangle(cornerRadius: 21))
            .accessibilityIdentifier("profile.giftsUnavailable")
    }
}
