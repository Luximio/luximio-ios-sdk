import Foundation

/// Private v1 receipt transport. A carried URL and receipt never authorize customer resources.
/// Each request stays on the captured URL's trusted HTTPS origin; the bearer is header-only.
@MainActor
public final class HTTPContinuationBackend: ContinuationBackend {
    private let configuration: LinksConfiguration
    private let transport: any ContinuationHTTPTransport
    private let now: @MainActor () -> Date

    public init(configuration: LinksConfiguration,
                transport: any ContinuationHTTPTransport = OwnedContinuationHTTPTransport(),
                now: @escaping @MainActor () -> Date = { Date() }) throws {
        let expectedBundle = configuration.role == .fullApp
            ? configuration.scope.fullAppBundleID : configuration.scope.clipBundleID
        try configuration.validate(bundleIdentifier: expectedBundle)
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try invocation.validate(configuration: configuration, now: now())
        let wireInvocation = try WireInvocation(invocation)
        let request = try authenticatedRequest(path: "/api/v1/continuations", invocation: invocation,
                                               body: CreateBody(invocation: wireInvocation))
        let data = try await send(request, successStatuses: [200, 201])
        return try preparedReceipt(data, invocation: invocation, expected: nil)
    }

    public func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        let request = try authenticatedRequest(path: "/api/v1/continuations/resolve",
                                               invocation: receipt.invocation,
                                               body: ResolveBody(receiptID: receipt.id, deliveryID: receipt.deliveryID))
        let data = try await send(request, successStatuses: [200])
        return try preparedReceipt(data, invocation: receipt.invocation, expected: receipt)
    }

    public func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try Task.checkCancellation()
        try receipt.validate(configuration: configuration, now: now())
        guard acknowledgement.receiptID == receipt.id,
              acknowledgement.deliveryID == receipt.deliveryID else { throw LinkFailure.conflict }
        let request = try authenticatedRequest(path: "/api/v1/continuations/acknowledge",
                                               invocation: receipt.invocation,
                                               body: AcknowledgeBody(acknowledgement))
        let data = try await send(request, successStatuses: [200])
        let response: AcknowledgeResponse = try decode(data)
        guard response.version == 1, response.result == "acknowledged",
              response.receiptID == acknowledgement.receiptID,
              response.deliveryID == acknowledgement.deliveryID,
              response.operationID == acknowledgement.operationID,
              response.outcome == acknowledgement.outcome else { throw LinkFailure.invalidData }
    }

    public func resolveDirect(_ url: URL) async throws -> LinkDestination {
        try Task.checkCancellation()
        try configuration.validateURL(url)
        var components = try originComponents(url, path: "/api/resolve")
        components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let endpoint = components.url else { throw LinkFailure.untrustedURL }
        let request = baseRequest(endpoint)
        let data = try await send(request, successStatuses: [200], direct: true)
        let response: DirectResponse = try decode(data)
        guard let expectedPath = normalizedDirectPath(url), response.path == expectedPath else {
            throw LinkFailure.invalidData
        }
        guard let destination = response.destination.app else { throw LinkFailure.unavailable }
        try destination.validate()
        return destination
    }

    private func normalizedDirectPath(_ url: URL) -> String? {
        guard let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let decoded = encoded.removingPercentEncoding else { return nil }
        let path = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty, path.utf16.count <= 200, !path.contains("//"),
              path.range(of: #"^[A-Za-z0-9][A-Za-z0-9/_-]*\z"#, options: .regularExpression) != nil,
              path != "api", path != "healthz", !path.hasPrefix("api/") else { return nil }
        return path
    }

    private func preparedReceipt(_ data: Data, invocation: CapturedInvocation,
                                 expected: PinnedReceipt?) throws -> PinnedReceipt {
        let response: PreparedResponse = try decode(data)
        guard response.version == 1, response.result == "prepared",
              response.receipt.invocation == (try WireInvocation(invocation)) else {
            throw LinkFailure.invalidData
        }
        let wire = response.receipt
        guard WireInvocation.acceptsMilliseconds(wire.expiresAt) else { throw LinkFailure.invalidData }
        let receipt = PinnedReceipt(id: wire.id, deliveryID: wire.deliveryID, invocation: invocation,
                                    canonicalLinkID: wire.canonicalLinkID, destination: wire.destination,
                                    expiresAt: Date(timeIntervalSince1970: Double(wire.expiresAt) / 1_000))
        try receipt.validate(configuration: configuration, now: now())
        if let expected {
            guard receipt == expected else { throw LinkFailure.changedDestination }
        }
        return receipt
    }

    private func authenticatedRequest<Body: Encodable>(path: String, invocation: CapturedInvocation,
                                                        body: Body) throws -> URLRequest {
        guard let originalURL = URL(string: invocation.originalURL) else { throw LinkFailure.untrustedURL }
        let components = try originComponents(originalURL, path: path)
        guard let endpoint = components.url else { throw LinkFailure.untrustedURL }
        var request = baseRequest(endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + invocation.token, forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func originComponents(_ url: URL, path: String) throws -> URLComponents {
        try configuration.validateURL(url)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw LinkFailure.untrustedURL
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components
    }

    private func baseRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest, successStatuses: Set<Int>, direct: Bool = false) async throws -> Data {
        do {
            try Task.checkCancellation()
            let (data, response) = try await transport.send(request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.mimeType == "application/json",
                  data.count <= OwnedContinuationHTTPTransport.maximumResponseBytes,
                  response.expectedContentLength <= Int64(OwnedContinuationHTTPTransport.maximumResponseBytes) else {
                throw LinkFailure.invalidData
            }
            if successStatuses.contains(response.statusCode) { return data }
            guard response.statusCode >= 400, response.statusCode <= 599 else { throw LinkFailure.invalidData }
            if direct {
                if response.statusCode == 429 { throw LinkFailure.busy }
                if response.statusCode >= 500 { throw LinkFailure.network }
                throw LinkFailure.unavailable
            }
            let failure: RejectedResponse = try decode(data)
            guard failure.version == 1 else { throw LinkFailure.invalidData }
            guard failure.result == "rejected", let reason = failure.reason else { throw LinkFailure.invalidData }
            guard reason != .completed || response.statusCode == 409 else { throw LinkFailure.invalidData }
            throw reason.failure
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let failure = error as? LinkFailure { throw failure }
            throw LinkFailure.network
        }
    }

    private func decode<Value: Decodable>(_ data: Data) throws -> Value {
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw LinkFailure.invalidData }
    }
}

private struct WireInvocation: Codable, Equatable {
    let id: UUID
    let operationID: UUID
    let originalURL: String
    let capturedAt: Int64
    let expiresAt: Int64
    let scope: LinkScope

    init(_ invocation: CapturedInvocation) throws {
        id = invocation.id
        operationID = invocation.operationID
        originalURL = invocation.originalURL
        capturedAt = try Self.milliseconds(invocation.capturedAt)
        expiresAt = try Self.milliseconds(invocation.expiresAt)
        scope = invocation.scope
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        let value = floor(date.timeIntervalSince1970 * 1_000)
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991 else {
            throw LinkFailure.invalidData
        }
        return Int64(value)
    }

    static func acceptsMilliseconds(_ value: Int64) -> Bool {
        value >= 0 && value <= 9_007_199_254_740_991
    }
}

private struct CreateBody: Encodable {
    let version = 1
    let invocation: WireInvocation
}

private struct ResolveBody: Encodable {
    let version = 1
    let receiptID: UUID
    let deliveryID: UUID
}

private struct AcknowledgeBody: Encodable {
    let version = 1
    let receiptID: UUID
    let deliveryID: UUID
    let operationID: UUID
    let outcome: Acknowledgement.Outcome

    init(_ acknowledgement: Acknowledgement) {
        receiptID = acknowledgement.receiptID
        deliveryID = acknowledgement.deliveryID
        operationID = acknowledgement.operationID
        outcome = acknowledgement.outcome
    }
}

private struct PreparedResponse: Decodable {
    let version: Int
    let result: String
    let receipt: WireReceipt
}

private struct WireReceipt: Decodable {
    let id: UUID
    let deliveryID: UUID
    let invocation: WireInvocation
    let canonicalLinkID: String
    let destination: LinkDestination
    let expiresAt: Int64
}

private struct AcknowledgeResponse: Decodable {
    let version: Int
    let result: String
    let receiptID: UUID
    let deliveryID: UUID
    let operationID: UUID
    let outcome: Acknowledgement.Outcome
}

private struct RejectedResponse: Decodable {
    let version: Int
    let result: String
    let reason: WireFailure?
}

private enum WireFailure: String, Decodable {
    case invalidData, expired, unavailable, changedDestination, wrongScope, conflict
    case network, busy, storage, configuration, unverifiedContext
    case completed

    var failure: LinkFailure {
        switch self {
        case .invalidData: .invalidData
        case .expired: .expired
        case .unavailable: .unavailable
        case .changedDestination: .changedDestination
        case .wrongScope: .wrongScope
        case .conflict: .conflict
        case .network: .network
        case .busy: .busy
        case .storage: .storage
        case .configuration: .configuration
        case .unverifiedContext: .unverifiedContext
        case .completed: .conflict
        }
    }
}

private struct DirectResponse: Decodable {
    let path: String
    let destination: Destination

    struct Destination: Decodable {
        let app: LinkDestination?
    }
}
