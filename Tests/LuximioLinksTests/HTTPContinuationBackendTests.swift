import Foundation
import Testing
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTTPContinuationBackendTests {
    private let scope = LinkScope(projectID: "project-test", fullAppBundleID: "app.test.full",
                                  clipBundleID: "app.test.full.Clip")
    private let now = Date(timeIntervalSince1970: 1_800_000_000.123456)
    private let destination = LinkDestination(route: "places/detail", data: ["id": .string("north")])

    private var configuration: LinksConfiguration {
        LinksConfiguration(scope: scope, role: .appClip, trustedHosts: ["links.example.com", "other.example.com"],
                           appGroupIdentifier: "group.app.test.full")
    }

    @Test func createUsesOnlyTheTrustedInvocationOriginAndHeaderBearer() async throws {
        let invocation = try capture("https://other.example.com/north?future=%2F&campaign=one&campaign=two#context")
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: try self.prepared(invocation), status: 201)
        }
        let receipt = try await backend(transport).create(invocation)
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://other.example.com/api/v1/continuations")
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 10)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(!request.httpShouldHandleCookies)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + invocation.token)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try #require(request.httpBody)
        #expect(body.range(of: Data(invocation.token.utf8)) == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try #require(object["invocation"] as? [String: Any])
        #expect(Set(object.keys) == ["version", "invocation"])
        #expect(Set(wire.keys) == ["id", "operationID", "originalURL", "capturedAt", "expiresAt", "scope"])
        #expect(wire["originalURL"] as? String == invocation.originalURL)
        #expect(wire["capturedAt"] as? Int64 == 1_800_000_000_123)
        #expect(wire["expiresAt"] as? Int64 == 1_800_604_800_123)
        #expect(receipt.invocation == invocation, "Wire precision must not rewrite the durable local invocation.")
        #expect(receipt.invocation.capturedAt == now)
        #expect(receipt.expiresAt == Date(timeIntervalSince1970: 1_800_604_800.123))
    }

    @Test func frozenV1CreateBodyMatchesTheSharedWireContract() async throws {
        let invocation = CapturedInvocation(
            id: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            operationID: try #require(UUID(uuidString: "22222222-2222-4222-8222-222222222222")),
            token: Data(repeating: 0, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            originalURL: "https://links.example.com/north?utm_source=clip&future_context=survives",
            capturedAt: now, expiresAt: now.addingTimeInterval(CapturedInvocation.lifetime), scope: scope)
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation), status: 201) }
        _ = try await backend(transport).create(invocation)
        let body = try #require(transport.requests.first?.httpBody)
        let expected = #"{"invocation":{"capturedAt":1800000000123,"expiresAt":1800604800123,"id":"11111111-1111-4111-8111-111111111111","operationID":"22222222-2222-4222-8222-222222222222","originalURL":"https://links.example.com/north?utm_source=clip&future_context=survives","scope":{"clipBundleID":"app.test.full.Clip","fullAppBundleID":"app.test.full","projectID":"project-test"}},"version":1}"#
        #expect(String(data: body, encoding: .utf8) == expected)
    }

    @Test func createRetrySendsTheIdenticalOperationAndTokenWithoutMutatingDates() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let first = try await client.create(invocation)
        let second = try await client.create(invocation)
        #expect(first == second)
        #expect(transport.requests.count == 2)
        #expect(transport.requests[0].httpBody == transport.requests[1].httpBody)
        #expect(transport.requests[0].allHTTPHeaderFields == transport.requests[1].allHTTPHeaderFields)
        #expect(first.invocation.capturedAt == invocation.capturedAt)
    }

    @Test(arguments: InvocationMutation.allCases)
    fileprivate func mismatchedInvocationEchoCannotProduceAReceipt(_ mutation: InvocationMutation) async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: try self.prepared(invocation, mutate: { object in
                var receipt = try #require(object["receipt"] as? [String: Any])
                var echo = try #require(receipt["invocation"] as? [String: Any])
                mutation.apply(to: &echo)
                receipt["invocation"] = echo
                object["receipt"] = receipt
            }))
        }
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).create(invocation) }
    }

    @Test(arguments: ReceiptMutation.allCases)
    fileprivate func resolveRequiresEveryImmutableReceiptFieldToMatch(_ mutation: ReceiptMutation) async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let receipt = try await client.create(invocation)
        transport.handler = { request in
            try self.response(request, body: try self.prepared(invocation, mutate: { object in
                var wire = try #require(object["receipt"] as? [String: Any])
                mutation.apply(to: &wire)
                object["receipt"] = wire
            }))
        }
        await #expect(throws: LinkFailure.changedDestination) { try await client.resolve(receipt) }
        let request = try #require(transport.requests.last)
        #expect(request.url?.absoluteString == "https://links.example.com/api/v1/continuations/resolve")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["version", "receiptID", "deliveryID"])
    }

    @Test func resolveRoundTripsTheExactReceiptWithMillisecondServerExpiry() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let receipt = try await client.create(invocation)
        #expect(try await client.resolve(receipt) == receipt)
    }

    @Test func expiredServerReceiptCannotBecomeReady() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: try self.prepared(invocation, mutate: { object in
                var wire = try #require(object["receipt"] as? [String: Any])
                wire["expiresAt"] = 1_800_000_001_123
                object["receipt"] = wire
            }))
        }
        let later = now.addingTimeInterval(2)
        let client = try HTTPContinuationBackend(configuration: configuration, transport: transport, now: { later })
        await #expect(throws: LinkFailure.expired) { try await client.create(invocation) }
    }

    @Test func serverReceiptCannotExtendTheCapturedDeadline() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: try self.prepared(invocation, mutate: { object in
                var wire = try #require(object["receipt"] as? [String: Any])
                wire["expiresAt"] = 1_800_604_801_123
                object["receipt"] = wire
            }))
        }
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).create(invocation) }
    }

    @Test(arguments: InvalidResponse.allCases)
    fileprivate func rejectsMalformedContentHeadersStatusAndRedirects(_ invalid: InvalidResponse) async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            let body = try self.prepared(invocation, mutate: { object in
                if invalid == .version { object["version"] = 2 }
                if invalid == .result { object["result"] = "acknowledged" }
            })
            switch invalid {
            case .html: return try self.response(request, body: Data("<html>error</html>".utf8), mime: "text/html")
            case .largeBody: return try self.response(request, body: Data(repeating: 32, count: 16_385))
            case .largeLength: return try self.response(request, body: body, extraHeaders: ["Content-Length": "16385"])
            case .redirect: return try self.response(request, body: body, status: 302)
            case .differentURL:
                return try self.response(request, body: body, responseURL: try #require(URL(string: "https://other.example.com/api/v1/continuations")))
            case .badJSON: return try self.response(request, body: Data("{".utf8))
            case .unexpectedSuccess: return try self.response(request, body: body, status: 202)
            case .version, .result: return try self.response(request, body: body)
            }
        }
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).create(invocation) }
    }

    @Test(arguments: RejectedCase.allCases)
    fileprivate func structuredFailuresRemainTypedAndRetriable(_ failure: RejectedCase) async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data("{\"version\":1,\"result\":\"rejected\",\"reason\":\"\(failure.rawValue)\"}".utf8),
                          status: failure.status)
        }
        await #expect(throws: failure.expected) { try await backend(transport).create(invocation) }
    }

    @Test func completedReceiptCannotBeResolvedIntoAnotherDelivery() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"version":1,"result":"rejected","reason":"completed"}"#.utf8), status: 409)
        }
        await #expect(throws: LinkFailure.conflict) { try await backend(transport).create(invocation) }
    }

    @Test func unknownOrMalformedFailureCannotBecomeARetry() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"version":1,"result":"rejected","reason":"pleaseRetry"}"#.utf8), status: 503)
        }
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).create(invocation) }
    }

    @Test func lostAcknowledgementRetriesTheSameBodyAndChecksTheServerEcho() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let receipt = try await client.create(invocation)
        let acknowledgement = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                               operationID: UUID(), outcome: .applied)
        transport.handler = { _ in throw URLError(.timedOut) }
        await #expect(throws: LinkFailure.network) { try await client.acknowledge(acknowledgement, receipt: receipt) }
        transport.handler = { request in try self.response(request, body: try self.acknowledged(acknowledgement)) }
        try await client.acknowledge(acknowledgement, receipt: receipt)
        #expect(transport.requests[1].httpBody == transport.requests[2].httpBody)
        #expect(transport.requests[2].url?.absoluteString == "https://links.example.com/api/v1/continuations/acknowledge")
        let body = try #require(transport.requests[2].httpBody)
        #expect(body.range(of: Data(invocation.token.utf8)) == nil)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == ["version", "receiptID", "deliveryID", "operationID", "outcome"])
        #expect(object["outcome"] as? String == "applied")
    }

    @Test(arguments: AcknowledgementMutation.allCases)
    fileprivate func acknowledgementCannotConfirmAnotherOperation(_ mutation: AcknowledgementMutation) async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let receipt = try await client.create(invocation)
        let acknowledgement = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                               operationID: UUID(), outcome: .discarded)
        transport.handler = { request in
            try self.response(request, body: try self.acknowledged(acknowledgement, mutate: { object in
                mutation.apply(to: &object)
            }))
        }
        await #expect(throws: LinkFailure.invalidData) { try await client.acknowledge(acknowledgement, receipt: receipt) }
    }

    @Test func mismatchedLocalAcknowledgementAndUntrustedCaptureSendNothing() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in try self.response(request, body: try self.prepared(invocation)) }
        let client = try backend(transport)
        let receipt = try await client.create(invocation)
        let acknowledgement = Acknowledgement(receiptID: UUID(), deliveryID: receipt.deliveryID,
                                               operationID: UUID(), outcome: .applied)
        await #expect(throws: LinkFailure.conflict) { try await client.acknowledge(acknowledgement, receipt: receipt) }
        let untrusted = CapturedInvocation(id: invocation.id, operationID: invocation.operationID, token: invocation.token,
                                           originalURL: "https://untrusted.example.com/north", capturedAt: invocation.capturedAt,
                                           expiresAt: invocation.expiresAt, scope: invocation.scope)
        await #expect(throws: LinkFailure.untrustedURL) { try await client.create(untrusted) }
        #expect(transport.requests.count == 1)
    }

    @Test func directLinkHasNoBearerAndNoReceiptRoundTrip() async throws {
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"path":"north","destination":{"app":{"route":"places/detail","data":{"id":"north"}}}}"#.utf8))
        }
        let url = try #require(URL(string: "https://links.example.com/north?campaign=one&campaign=two"))
        let result = try await backend(transport).resolveDirect(url)
        #expect(result == destination)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let endpoint = try #require(request.url)
        let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        #expect(components.path == "/api/resolve")
        #expect(components.queryItems == [URLQueryItem(name: "url", value: url.absoluteString)])
    }

    @Test func directResolutionCannotSubstituteAnotherPathOrInvalidDestination() async throws {
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"path":"canal","destination":{"app":{"route":"places/detail","data":{"id":"north"}}}}"#.utf8))
        }
        let url = try #require(URL(string: "https://links.example.com/north"))
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).resolveDirect(url) }
        transport.handler = { request in
            try self.response(request, body: Data(#"{"path":"north","destination":{"app":{"route":"../escape","data":{}}}}"#.utf8))
        }
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).resolveDirect(url) }
    }

    @Test func directResolutionWithoutAnAppDestinationIsUnavailable() async throws {
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"path":"north","destination":{"web":"https://example.com"}}"#.utf8))
        }
        let url = try #require(URL(string: "https://links.example.com/north"))
        await #expect(throws: LinkFailure.unavailable) { try await backend(transport).resolveDirect(url) }
    }

    @Test(arguments: DirectPathCase.allCases)
    fileprivate func directPathUsesTheServerOnePassPercentDecodingAndEdgeSlashRules(_ path: DirectPathCase) async throws {
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "path": path.expected,
                "destination": ["app": ["route": "places/detail", "data": ["id": "north"]]]
            ])
            return try self.response(request, body: data)
        }
        let url = try #require(URL(string: "https://links.example.com/" + path.rawValue))
        #expect(try await backend(transport).resolveDirect(url) == destination)
    }

    @Test func directPathDoesNotDecodePercentEscapesTwice() async throws {
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            try self.response(request, body: Data(#"{"path":"nested/north","destination":{"app":{"route":"places/detail","data":{"id":"north"}}}}"#.utf8))
        }
        let url = try #require(URL(string: "https://links.example.com/nested%252Fnorth"))
        await #expect(throws: LinkFailure.invalidData) { try await backend(transport).resolveDirect(url) }
    }

    @Test func cancellationBeforeSendMakesNoRequest() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        let client = try backend(transport)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.create(invocation)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.isEmpty)
    }

    @Test func cancellationAfterTransportResponseCannotYieldAReceipt() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return try self.response(request, body: try self.prepared(invocation))
        }
        let client = try backend(transport)
        let task = Task { @MainActor in try await client.create(invocation) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(transport.requests.count == 1)
    }

    @Test func urlSessionCancellationDoesNotBecomeANetworkRetry() async throws {
        let invocation = try capture()
        let transport = ControlledContinuationTransport()
        transport.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await backend(transport).create(invocation) }
    }

    @Test func streamedBufferRefusesTheFirstExcessByteWithoutGrowing() throws {
        var buffer = ContinuationResponseBuffer()
        for _ in 0..<OwnedContinuationHTTPTransport.maximumResponseBytes { try buffer.append(32) }
        #expect(buffer.data.count == 16_384)
        #expect(throws: LinkFailure.invalidData) { try buffer.append(32) }
        #expect(buffer.data.count == 16_384)
    }

    @Test func theOwnedSessionDelegateRefusesEvenSameOriginRedirects() async throws {
        let url = try #require(URL(string: "https://links.example.com/api/v1/continuations"))
        let request = URLRequest(url: url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Location": "/api/v1/continuations/resolve"]))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let redirected = await RejectContinuationRedirects().urlSession(session, task: task,
                                                                        willPerformHTTPRedirection: response,
                                                                        newRequest: request)
        #expect(redirected == nil)
        // This task is never resumed: the test exercises the delegate without network I/O.
    }

    private func capture(_ value: String = "https://links.example.com/north?future=context") throws -> CapturedInvocation {
        try CapturedInvocation.capture(url: #require(URL(string: value)), configuration: configuration, at: now)
    }

    private func backend(_ transport: ControlledContinuationTransport) throws -> HTTPContinuationBackend {
        let date = now
        return try HTTPContinuationBackend(configuration: configuration, transport: transport, now: { date })
    }

    private func prepared(_ invocation: CapturedInvocation,
                          mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        let encodedDestination = try JSONEncoder().encode(destination)
        var object: [String: Any] = [
            "version": 1, "result": "prepared", "receipt": [
                "id": "33333333-3333-4333-8333-333333333333",
                "deliveryID": "44444444-4444-4444-8444-444444444444",
                "invocation": ["id": invocation.id.uuidString, "operationID": invocation.operationID.uuidString,
                               "originalURL": invocation.originalURL,
                               "capturedAt": Int64(floor(invocation.capturedAt.timeIntervalSince1970 * 1_000)),
                               "expiresAt": Int64(floor(invocation.expiresAt.timeIntervalSince1970 * 1_000)),
                               "scope": ["projectID": scope.projectID, "fullAppBundleID": scope.fullAppBundleID,
                                         "clipBundleID": scope.clipBundleID]],
                "canonicalLinkID": "published:project-test:north",
                "destination": try JSONSerialization.jsonObject(with: encodedDestination),
                "expiresAt": Int64(floor(invocation.expiresAt.timeIntervalSince1970 * 1_000))
            ]
        ]
        try mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func acknowledged(_ acknowledgement: Acknowledgement,
                              mutate: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        var object: [String: Any] = ["version": 1, "result": "acknowledged", "receiptID": acknowledgement.receiptID.uuidString,
                                     "deliveryID": acknowledgement.deliveryID.uuidString,
                                     "operationID": acknowledgement.operationID.uuidString,
                                     "outcome": acknowledgement.outcome.rawValue]
        try mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func response(_ request: URLRequest, body: Data, status: Int = 200,
                          mime: String = "application/json", responseURL: URL? = nil,
                          extraHeaders: [String: String] = [:]) throws -> (Data, URLResponse) {
        var headers = extraHeaders
        headers["Content-Type"] = mime
        let url = try #require(responseURL ?? request.url)
        let response = try #require(HTTPURLResponse(url: url, statusCode: status,
                                                    httpVersion: "HTTP/1.1", headerFields: headers))
        return (body, response)
    }
}

@MainActor
private final class ControlledContinuationTransport: ContinuationHTTPTransport {
    var requests: [URLRequest] = []
    var handler: @MainActor (URLRequest) async throws -> (Data, URLResponse) = { _ in throw LinkFailure.network }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        return try await handler(request)
    }
}

fileprivate enum InvocationMutation: CaseIterable, Sendable {
    case id, operationID, originalURL, capturedAt, expiresAt, scope
    func apply(to object: inout [String: Any]) {
        switch self {
        case .id: object["id"] = UUID().uuidString
        case .operationID: object["operationID"] = UUID().uuidString
        case .originalURL: object["originalURL"] = "https://links.example.com/canal"
        case .capturedAt: object["capturedAt"] = 1_800_000_000_124
        case .expiresAt: object["expiresAt"] = 1_800_604_800_124
        case .scope: object["scope"] = ["projectID": "other", "fullAppBundleID": "app.test.full", "clipBundleID": "app.test.full.Clip"]
        }
    }
}

fileprivate enum ReceiptMutation: CaseIterable, Sendable {
    case id, deliveryID, canonicalLinkID, destination, expiresAt
    func apply(to object: inout [String: Any]) {
        switch self {
        case .id: object["id"] = UUID().uuidString
        case .deliveryID: object["deliveryID"] = UUID().uuidString
        case .canonicalLinkID: object["canonicalLinkID"] = "different-published-link"
        case .destination: object["destination"] = ["route": "places/detail", "data": ["id": "canal"]]
        case .expiresAt: object["expiresAt"] = 1_800_604_799_123
        }
    }
}

fileprivate enum AcknowledgementMutation: CaseIterable, Sendable {
    case version, result, receiptID, deliveryID, operationID, outcome
    func apply(to object: inout [String: Any]) {
        switch self {
        case .version: object["version"] = 2
        case .result: object["result"] = "prepared"
        case .receiptID: object["receiptID"] = UUID().uuidString
        case .deliveryID: object["deliveryID"] = UUID().uuidString
        case .operationID: object["operationID"] = UUID().uuidString
        case .outcome: object["outcome"] = "applied"
        }
    }
}

fileprivate enum InvalidResponse: CaseIterable, Sendable {
    case html, largeBody, largeLength, redirect, differentURL, badJSON, version, result, unexpectedSuccess
}

fileprivate enum DirectPathCase: String, CaseIterable, Sendable {
    case escapedHyphen = "north%2Dstudio"
    case escapedLetter = "%6Eorth-studio"
    case escapedSlash = "nested%2Fnorth-studio"
    case trailingSlashes = "north-studio///"
    case leadingSlashes = "//north-studio"

    var expected: String {
        self == .escapedSlash ? "nested/north-studio" : "north-studio"
    }
}

fileprivate enum RejectedCase: String, CaseIterable, Sendable {
    case invalidData, expired, unavailable, changedDestination, wrongScope, conflict
    case network, busy, storage, configuration, unverifiedContext

    var status: Int {
        switch self {
        case .busy: 429
        case .network, .storage: 503
        case .expired: 410
        case .unavailable: 404
        default: 409
        }
    }

    var expected: LinkFailure {
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
        }
    }
}
