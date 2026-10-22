import Foundation

protocol OpsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class RedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class SecureOpsTransport: OpsTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard OpsIdentityEndpoint.permits(request) else { throw OpsError.unsafeEndpoint }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OpsError.invalidResponse }
        guard response.url == request.url else { throw OpsError.redirected }
        guard !(300...399).contains(response.statusCode) else { throw OpsError.redirected }
        guard data.count <= 2 * 1024 * 1024 else { throw OpsError.invalidResponse }
        return (data, response)
    }
}
