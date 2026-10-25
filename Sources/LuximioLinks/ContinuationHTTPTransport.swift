import Foundation

/// An injectable transport seam. Implementations must bound the response while receiving it,
/// reject redirects and cooperate with task cancellation. Never log request headers or bodies.
@MainActor
public protocol ContinuationHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// A session owned by this request, with no shared cookies, cache or redirect authority.
@MainActor
public struct OwnedContinuationHTTPTransport: ContinuationHTTPTransport {
    public nonisolated static let maximumResponseBytes = 16_384
    public enum ResponseLimit: Sendable {
        case privateContinuation, customerRecovery

        var bytes: Int {
            switch self {
            case .privateContinuation: 16_384
            case .customerRecovery: 65_536
            }
        }
    }
    private let responseLimit: ResponseLimit

    public init(responseLimit: ResponseLimit = .privateContinuation) {
        self.responseLimit = responseLimit
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: RejectContinuationRedirects())
        try Task.checkCancellation()
        guard response.expectedContentLength <= Int64(responseLimit.bytes) else {
            throw LinkFailure.invalidData
        }
        var buffer = ContinuationResponseBuffer(responseLimit: responseLimit)
        for try await byte in bytes {
            try Task.checkCancellation()
            try buffer.append(byte)
        }
        try Task.checkCancellation()
        return (buffer.data, response)
    }
}

/// The same byte limit applies with an absent or dishonest Content-Length.
struct ContinuationResponseBuffer {
    private(set) var data = Data()
    private let maximumBytes: Int

    init(responseLimit: OwnedContinuationHTTPTransport.ResponseLimit = .privateContinuation) {
        maximumBytes = responseLimit.bytes
    }

    mutating func append(_ byte: UInt8) throws {
        guard data.count < maximumBytes else {
            throw LinkFailure.invalidData
        }
        data.append(byte)
    }
}

final class RejectContinuationRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
