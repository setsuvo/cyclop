import Foundation

/// The two optional network features use public, fixed destinations. This
/// policy is also applied to every redirect so a trusted CDN cannot bounce an
/// untrusted URL into localhost, a file URL, or an attacker-controlled host.
enum NetworkPolicy {
    struct Destination: Sendable {
        let host: String
        let allowsSubdomains: Bool
        let pathPrefix: String

        init(host: String, allowsSubdomains: Bool = false, pathPrefix: String = "/") {
            self.host = host.lowercased()
            self.allowsSubdomains = allowsSubdomains
            self.pathPrefix = pathPrefix
        }

        func allows(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let candidate = url.host?.lowercased() else { return false }
            let hostMatches = candidate == host || (allowsSubdomains && candidate.hasSuffix(".\(host)"))
            return hostMatches && url.path.hasPrefix(pathPrefix)
        }
    }

    enum Failure: LocalizedError, Sendable {
        case disallowedURL
        case invalidResponse
        case responseTooLarge
        case unexpectedContentType

        var errorDescription: String? {
            switch self {
            case .disallowedURL: return "The server address is not allowed."
            case .invalidResponse: return "The server returned an invalid response."
            case .responseTooLarge: return "The server response is too large."
            case .unexpectedContentType: return "The server returned an unexpected content type."
            }
        }
    }

    /// Convenience used by tests and callers with a simple host-suffix policy.
    static func allows(_ url: URL, hosts: Set<String>) -> Bool {
        hosts.contains { Destination(host: $0, allowsSubdomains: true).allows(url) }
    }

    static func load(
        _ request: URLRequest,
        destinations: [Destination],
        maxBytes: Int,
        contentTypes: Set<String>
    ) async throws -> Data {
        guard maxBytes > 0,
              let url = request.url,
              destinations.contains(where: { $0.allows(url) }) else {
            throw Failure.disallowedURL
        }
        let loader = BoundedHTTPSLoader(
            destinations: destinations,
            maxBytes: maxBytes,
            contentTypes: contentTypes
        )
        return try await loader.load(request)
    }

    static func canAppend(chunkBytes: Int, accumulatedBytes: Int, maxBytes: Int) -> Bool {
        guard chunkBytes >= 0, accumulatedBytes >= 0,
              accumulatedBytes <= maxBytes else { return false }
        return chunkBytes <= maxBytes - accumulatedBytes
    }
}

/// A data delegate is used instead of `URLSession.data(for:)`: checking the
/// size after `data(for:)` returns is too late because an unbounded allocation
/// has already happened. This loader cancels on the first byte past the cap.
private final class BoundedHTTPSLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destinations: [NetworkPolicy.Destination]
    private let maxBytes: Int
    private let contentTypes: Set<String>
    private let delegateQueue: OperationQueue

    private var body = Data()
    private var acceptedResponse = false
    private var finished = false
    private var continuation: CheckedContinuation<Data, any Error>?
    private var dataTask: URLSessionDataTask?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()

    init(destinations: [NetworkPolicy.Destination], maxBytes: Int, contentTypes: Set<String>) {
        self.destinations = destinations
        self.maxBytes = maxBytes
        self.contentTypes = contentTypes
        let queue = OperationQueue()
        queue.name = "com.cyclop.bounded-network"
        queue.maxConcurrentOperationCount = 1
        delegateQueue = queue
    }

    func load(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Keep setup on the same serial queue as delegate callbacks
                // and cancellation. Cancellation can otherwise race the
                // continuation assignment and strand a hidden tab's request.
                delegateQueue.addOperation { [self] in
                    guard !finished else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let task = session.dataTask(with: request)
                    dataTask = task
                    task.resume()
                }
            }
        } onCancel: {
            delegateQueue.addOperation { [self] in
                dataTask?.cancel()
                finish(.failure(CancellationError()))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              destinations.contains(where: { $0.allows(url) }) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let finalURL = http.url,
              destinations.contains(where: { $0.allows(finalURL) }) else {
            completionHandler(.cancel)
            finish(.failure(NetworkPolicy.Failure.invalidResponse))
            return
        }
        if !contentTypes.isEmpty {
            guard let mime = http.mimeType?.lowercased(), contentTypes.contains(mime) else {
                completionHandler(.cancel)
                finish(.failure(NetworkPolicy.Failure.unexpectedContentType))
                return
            }
        }
        if response.expectedContentLength > Int64(maxBytes) {
            completionHandler(.cancel)
            finish(.failure(NetworkPolicy.Failure.responseTooLarge))
            return
        }
        acceptedResponse = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard NetworkPolicy.canAppend(
            chunkBytes: data.count,
            accumulatedBytes: body.count,
            maxBytes: maxBytes
        ) else {
            dataTask.cancel()
            finish(.failure(NetworkPolicy.Failure.responseTooLarge))
            return
        }
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !finished else { return }
        if let error {
            finish(.failure(error))
        } else if acceptedResponse {
            finish(.success(body))
        } else {
            finish(.failure(NetworkPolicy.Failure.invalidResponse))
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !finished else { return }
        finished = true
        dataTask = nil
        let continuation = continuation
        self.continuation = nil
        session.invalidateAndCancel()
        switch result {
        case .success(let data): continuation?.resume(returning: data)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
