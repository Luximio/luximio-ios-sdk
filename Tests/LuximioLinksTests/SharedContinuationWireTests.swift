import Foundation
import Testing
@testable import LuximioLinks

/// Vitest parses this same file, so neither runtime can silently change its v1 codec.
@MainActor
struct SharedContinuationWireTests {
    @Test func sharedV1FixtureTraversesTheActualCreateResolveAndAcknowledgementCodecs() async throws {
        let url = try #require(Bundle.module.url(forResource: "continuation-v1", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let bytes = try Data(contentsOf: url)
        let fixture = try JSONDecoder().decode(SharedWireFixture.self, from: bytes)
        let objects = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let prepared = try JSONSerialization.data(withJSONObject: #require(objects["prepared"]))
        let acknowledged = try JSONSerialization.data(withJSONObject: #require(objects["acknowledged"]))
        let transport = SharedWireTransport(prepared: prepared, acknowledged: acknowledged)
        let wire = fixture.create.invocation
        let invocation = CapturedInvocation(
            id: wire.id, operationID: wire.operationID, token: fixture.token, originalURL: wire.originalURL,
            capturedAt: Date(timeIntervalSince1970: Double(wire.capturedAt) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(wire.expiresAt) / 1_000), scope: wire.scope)
        let configuration = LinksConfiguration(scope: wire.scope, role: .fullApp,
                                                trustedHosts: ["sdk-wire.links.example.com"],
                                                appGroupIdentifier: "group.app.sdk.customer")
        let now = invocation.capturedAt
        let backend = try HTTPContinuationBackend(configuration: configuration, transport: transport, now: { now })

        let receipt = try await backend.create(invocation)
        let expected = fixture.prepared.receipt
        #expect(receipt.invocation == invocation)
        #expect(receipt.id == expected.id)
        #expect(receipt.deliveryID == expected.deliveryID)
        #expect(receipt.canonicalLinkID == expected.canonicalLinkID)
        #expect(receipt.destination == expected.destination)
        #expect(receipt.expiresAt == Date(timeIntervalSince1970: Double(expected.expiresAt) / 1_000))
        #expect(try await backend.resolve(receipt) == receipt)
        try await backend.acknowledge(fixture.acknowledge, receipt: receipt)

        try #require(transport.requests.count == 3)
        let fixtures = ["create", "resolve", "acknowledge"]
        let endpoints = ["/api/v1/continuations", "/api/v1/continuations/resolve", "/api/v1/continuations/acknowledge"]
        for index in fixtures.indices {
            let request = transport.requests[index]
            let body = try #require(request.httpBody)
            let expectedObject = try #require(objects[fixtures[index]])
            let expectedBody = try JSONSerialization.data(withJSONObject: expectedObject)
            let actualValue = try JSONDecoder().decode(LinkValue.self, from: body)
            let expectedValue = try JSONDecoder().decode(LinkValue.self, from: expectedBody)
            #expect(normalizedUUIDs(actualValue) == normalizedUUIDs(expectedValue))
            #expect(request.url?.host == "sdk-wire.links.example.com")
            #expect(request.url?.path == endpoints[index])
            #expect(request.url?.query == nil)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixture.token)
            #expect(body.range(of: Data(fixture.token.utf8)) == nil)
        }
    }

    private func normalizedUUIDs(_ value: LinkValue, key: String? = nil) -> LinkValue {
        switch value {
        case .object(let object):
            var normalized: [String: LinkValue] = [:]
            for (key, value) in object { normalized[key] = normalizedUUIDs(value, key: key) }
            return .object(normalized)
        case .array(let array): return .array(array.map { normalizedUUIDs($0) })
        case .string(let string):
            if let key, ["id", "operationID", "receiptID", "deliveryID"].contains(key),
               let uuid = UUID(uuidString: string) { return .string(uuid.uuidString.lowercased()) }
            return value
        default: return value
        }
    }
}

private struct SharedWireFixture: Decodable {
    let token: String
    let create: Create
    let prepared: Prepared
    let acknowledge: Acknowledgement

    struct Create: Decodable {
        let invocation: Invocation
    }

    struct Invocation: Decodable {
        let id: UUID
        let operationID: UUID
        let originalURL: String
        let capturedAt: Int64
        let expiresAt: Int64
        let scope: LinkScope
    }

    struct Prepared: Decodable {
        let receipt: Receipt
    }

    struct Receipt: Decodable {
        let id: UUID
        let deliveryID: UUID
        let canonicalLinkID: String
        let destination: LinkDestination
        let expiresAt: Int64
    }
}

@MainActor
private final class SharedWireTransport: ContinuationHTTPTransport {
    private let prepared: Data
    private let acknowledged: Data
    private(set) var requests: [URLRequest] = []

    init(prepared: Data, acknowledged: Data) {
        self.prepared = prepared
        self.acknowledged = acknowledged
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let endpoint = try #require(request.url)
        let body: Data
        let status: Int
        switch endpoint.path {
        case "/api/v1/continuations": body = prepared; status = 201
        case "/api/v1/continuations/resolve": body = prepared; status = 200
        case "/api/v1/continuations/acknowledge": body = acknowledged; status = 200
        default: throw LinkFailure.invalidData
        }
        let response = try #require(HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: "HTTP/1.1",
                                                    headerFields: ["Content-Type": "application/json"]))
        return (body, response)
    }
}
