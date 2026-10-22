import Foundation
import Kingfisher

/// AtomicX and TUILiveKit load avatars with Kingfisher. Keep its challenge
/// callbacks on standard system trust, including after public CA renewal.
final class KikiSDKAvatarTrust: AuthenticationChallengeResponsable {
    private static let responder = KikiSDKAvatarTrust()

    static func install() {
        KingfisherManager.shared.downloader.authenticationChallengeResponder = responder
    }

    static func clearPrivateImages() {
        KingfisherManager.shared.downloader.cancelAll()
        KingfisherManager.shared.cache.clearMemoryCache()
        KingfisherManager.shared.cache.clearDiskCache()
    }

    func downloader(_ downloader: ImageDownloader,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    func downloader(_ downloader: ImageDownloader, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }

    private func respond(to challenge: URLAuthenticationChallenge,
                         completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }
}
