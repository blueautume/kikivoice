import Foundation
import Kingfisher
import Security

/// AtomicX and TUILiveKit load avatars with Kingfisher. Give those image
/// requests the same pinned trust anchor as the business API, so uploaded
/// avatars work in seats, audience lists, chat messages and video rooms.
final class KikiSDKAvatarTrust: AuthenticationChallengeResponsable {
    private static let responder = KikiSDKAvatarTrust()

    static func install() {
        KingfisherManager.shared.downloader.authenticationChallengeResponder = responder
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
        guard challenge.protectionSpace.host == KikiAPIClient.endpoint.host,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let url = Bundle.main.url(forResource: "KikiServerCertificate", withExtension: "cer"),
              let pinnedData = try? Data(contentsOf: url),
              let certificate = SecCertificateCreateWithData(nil, pinnedData as CFData),
              let peer = SecTrustGetCertificateAtIndex(trust, 0),
              SecCertificateCopyData(peer) as Data == pinnedData else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        guard SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
