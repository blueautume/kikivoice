import Foundation

/// Do not override server-trust challenges: URLSession validates the public CA
/// chain, hostname and validity dates, so routine certificate renewal works.
final class KikiHTTPSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Authenticated JSON endpoints have no redirects. Do not carry a
        // bearer credential to an alternate host or downgrade to HTTP.
        completionHandler(nil)
    }
}
