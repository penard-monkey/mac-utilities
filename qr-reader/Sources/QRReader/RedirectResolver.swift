import Foundation

/// Follows a URL's redirect chain on explicit request only.
///
/// This is the one thing in QR Reader that touches the network, so it is
/// deliberately bare: an ephemeral session (no cookies, no credential store, no
/// cache), a short timeout, a hop limit, and no automatic invocation anywhere.
final class RedirectResolver: NSObject, URLSessionTaskDelegate {
    private static let maximumHops = 10
    private var chain: [String] = []
    private var session: URLSession?
    private var completion: ((String) -> Void)?

    static func resolve(_ url: URL, completion: @escaping (String) -> Void) {
        let resolver = RedirectResolver()
        resolver.start(url, completion: completion)
    }

    private func start(_ url: URL, completion: @escaping (String) -> Void) {
        self.completion = completion
        chain = [url.absoluteString]

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            // Some servers refuse HEAD; one cheap GET of a single byte settles it.
            if let http = response as? HTTPURLResponse, [405, 501, 403].contains(http.statusCode) {
                self.retryWithRangedGet(url)
                return
            }
            self.finish(response: response, error: error)
        }.resume()
    }

    private func retryWithRangedGet(_ url: URL) {
        var request = URLRequest(url: chain.last.flatMap(URL.init(string:)) ?? url)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        session?.dataTask(with: request) { [weak self] _, response, error in
            self?.finish(response: response, error: error)
        }.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let next = request.url?.absoluteString, chain.last != next { chain.append(next) }
        completionHandler(chain.count > Self.maximumHops ? nil : request)
    }

    private func finish(response: URLResponse?, error: Error?) {
        session?.finishTasksAndInvalidate()
        let summary: String
        if chain.count <= 1 {
            if let error {
                summary = "Could not resolve: \(error.localizedDescription)"
            } else if let http = response as? HTTPURLResponse {
                summary = "No redirect (HTTP \(http.statusCode))."
            } else {
                summary = "No redirect."
            }
        } else {
            var lines = chain.enumerated().map { index, step in
                (index == 0 ? "  " : "→ ") + step
            }
            if chain.count > Self.maximumHops {
                lines.append("→ stopped after \(Self.maximumHops) hops")
            } else if let host = chain.last.flatMap(URL.init(string:))?.host {
                lines.append("Ends at: \(host)")
            }
            summary = lines.joined(separator: "\n")
        }
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(summary) }
    }
}
