import Foundation
import Testing
@testable import LuximioLinks

@MainActor
struct CustomerRecoveryWireTests {
    @Test func canonicalCodecMatchesJavaScriptSharedVectors() throws {
        let fixture = try RecoveryWireTestFixture()
        let cases = try #require(fixture.object["canonicalCases"] as? [[String: Any]])
        for item in cases {
            let input = try JSONSerialization.data(withJSONObject: #require(item["payload"]))
            let encoded = try JSONDecoder().decode(CustomerRecoveryJSON.self, from: input).encoded()
            #expect(String(data: encoded, encoding: .utf8) == item["canonical"] as? String)
            #expect(CustomerRecoveryWire.hash(encoded) == item["sha256"] as? String)
        }
        for invalid in ["true", "1.5", "9007199254740992", "-9007199254740992", "[1]"] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(CustomerRecoveryJSON.self, from: Data(invalid.utf8)) }
        }
    }

    @Test func sharedRequestAndReceiptFixturesTraverseRealCodecWithoutRewritingLocalDates() throws {
        let fixture = try RecoveryWireTestFixture()
        let invocation = try fixture.invocation()
        #expect(try CustomerRecoveryWire.createPayload(invocation: invocation) == fixture.canonical("create"))
        let receipt = try fixture.receipt(invocation: invocation)
        #expect(receipt.invocation == invocation)
        #expect(receipt.invocation.capturedAt == invocation.capturedAt)
        #expect(try CustomerRecoveryWire.resolvePayload(receipt: receipt) == fixture.canonical("resolve"))
        let acknowledgement = try fixture.acknowledgement()
        #expect(try CustomerRecoveryWire.acknowledgementPayload(acknowledgement, scope: fixture.configuration.scope) == fixture.canonical("acknowledge"))
        #expect(try CustomerRecoveryWire.registrationPayload(keyID: fixture.keyID, scope: fixture.configuration.scope) == fixture.canonical("register"))
        try CustomerRecoveryWire.validateAcknowledgement(fixture.data("acknowledged"), expected: acknowledgement)
        let body = try CustomerRecoveryWire.envelope(payload: fixture.canonical("create"), proof: .null)
        #expect(body.range(of: Data(fixture.bearer.utf8)) == nil)
    }

    @Test func challengeValidationReturnsOriginalCanonicalBytes() throws {
        let fixture = try RecoveryWireTestFixture()
        let payload = try fixture.canonical("create")
        let data = try fixture.challenge(purpose: "create", payload: payload, bearer: fixture.bearer)
        let challenge = try CustomerRecoveryWire.validateChallenge(data, purpose: "create", payload: payload,
            bearer: fixture.bearer, origin: fixture.origin, scope: fixture.configuration.scope, now: fixture.now)
        let response = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(challenge.clientData == Data(base64Encoded: try #require(response["clientData"] as? String)))
        #expect(challenge.identityHash == String(repeating: "a", count: 64))
    }

    @Test(arguments: ["version", "challengeID", "challenge", "projectID", "hostname", "channel", "identityHash",
                      "origin", "method", "path", "purpose", "payloadHash", "tokenHash", "createdAt", "expiresAt", "extra"])
    func everyBindingFieldIsValidated(_ field: String) throws {
        let fixture = try RecoveryWireTestFixture()
        let payload = try fixture.canonical("create")
        let data = try fixture.challenge(purpose: "create", payload: payload, bearer: fixture.bearer, mutateBinding: { value in
            switch field {
            case "version": value[field] = 2
            case "createdAt": value[field] = Int64(1)
            case "expiresAt": value[field] = fixture.nowMS - 1
            default: value[field] = "wrong"
            }
        })
        #expect(throws: LinkFailure.invalidData) {
            try CustomerRecoveryWire.validateChallenge(data, purpose: "create", payload: payload, bearer: fixture.bearer,
                origin: fixture.origin, scope: fixture.configuration.scope, now: fixture.now)
        }
    }

    @Test(arguments: ["base64", "noncanonical", "duplicate", "expiry", "nonce", "result", "extra"])
    func malformedChallengeEnvelopeAndEncodingAreRejected(_ mutation: String) throws {
        let fixture = try RecoveryWireTestFixture()
        let payload = try fixture.canonical("create")
        let data = try fixture.challenge(purpose: "create", payload: payload, bearer: fixture.bearer, mutateResponse: { value in
            switch mutation {
            case "base64": value["clientData"] = "????"
            case "noncanonical", "duplicate":
                let encoded = try #require(value["clientData"] as? String)
                let source = try #require(Data(base64Encoded: encoded))
                let original = try #require(String(data: source, encoding: .utf8))
                let changed = mutation == "noncanonical" ? " " + original : "{\"version\":1," + original.dropFirst()
                value["clientData"] = Data(changed.utf8).base64EncodedString()
            case "expiry": value["expiresAt"] = fixture.nowMS + 300_001
            case "nonce": value["challenge"] = String(repeating: "A", count: 42) + "B"
            case "result": value["result"] = "prepared"
            default: value["unexpected"] = true
            }
        })
        #expect(throws: LinkFailure.invalidData) {
            try CustomerRecoveryWire.validateChallenge(data, purpose: "create", payload: payload, bearer: fixture.bearer,
                origin: fixture.origin, scope: fixture.configuration.scope, now: fixture.now)
        }
    }

    @Test func changedPinnedReceiptAndWrongInvocationCannotPass() throws {
        let fixture = try RecoveryWireTestFixture()
        let invocation = try fixture.invocation()
        let receipt = try fixture.receipt(invocation: invocation)
        var prepared = try #require(fixture.object["prepared"] as? [String: Any])
        var wire = try #require(prepared["receipt"] as? [String: Any])
        wire["canonicalLinkID"] = "different-link"
        prepared["receipt"] = wire
        #expect(throws: LinkFailure.changedDestination) {
            try CustomerRecoveryWire.preparedReceipt(JSONSerialization.data(withJSONObject: prepared), invocation: invocation,
                configuration: fixture.configuration, expected: receipt, now: fixture.now)
        }
        var echo = try #require(wire["invocation"] as? [String: Any])
        echo["operationID"] = UUID().uuidString.lowercased()
        wire["invocation"] = echo
        prepared["receipt"] = wire
        #expect(throws: LinkFailure.invalidData) {
            try CustomerRecoveryWire.preparedReceipt(JSONSerialization.data(withJSONObject: prepared), invocation: invocation,
                configuration: fixture.configuration, expected: nil, now: fixture.now)
        }
    }

    @Test func customerStreamLimitIsBoundedWithoutChangingPrivateLimit() throws {
        var buffer = ContinuationResponseBuffer(responseLimit: .customerRecovery)
        for _ in 0..<65_536 { try buffer.append(32) }
        #expect(buffer.data.count == 65_536)
        #expect(throws: LinkFailure.invalidData) { try buffer.append(32) }
        #expect(buffer.data.count == 65_536)
        #expect(OwnedContinuationHTTPTransport.maximumResponseBytes == 16_384)
    }

    @Test func encodedRequestLimitAndCanonicalBase64AreEnforced() throws {
        let payload = try CustomerRecoveryJSON.object(["oversized": .string(String(repeating: "x", count: 65_536))]).encoded()
        #expect(throws: LinkFailure.invalidData) { try CustomerRecoveryWire.envelope(payload: payload, proof: .null) }
        #expect(throws: LinkFailure.invalidData) {
            try CustomerRecoveryWire.base64("AA==\n", maximumBytes: 32)
        }
        #expect(throws: LinkFailure.invalidData) {
            try CustomerRecoveryWire.base64("AB==", maximumBytes: 32)
        }
    }

    @Test(arguments: [("unverified", 401, LinkFailure.unverifiedContext), ("expired", 410, .expired),
                      ("completed", 409, .conflict), ("network", 503, .network), ("busy", 429, .busy),
                      ("wrongScope", 403, .wrongScope), ("changedDestination", 409, .changedDestination)])
    func customerFailuresMapToExistingCoordinatorReasons(_ reason: String, _ status: Int, _ expected: LinkFailure) throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "result": "rejected", "reason": reason])
        #expect(try CustomerRecoveryWire.rejection(data, status: status) == expected)
        #expect(throws: LinkFailure.invalidData) { try CustomerRecoveryWire.rejection(data, status: 400) }
    }
}

@MainActor
struct RecoveryWireTestFixture {
    let object: [String: Any]
    let configuration: LinksConfiguration
    let origin: URL
    let nowMS: Int64
    var now: Date { Date(timeIntervalSince1970: Double(nowMS) / 1_000) }
    let bearer = Data(repeating: 17, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let keyID: String

    init() throws {
        let url = try #require(Bundle.module.url(forResource: "customer-recovery-v1", withExtension: "json", subdirectory: "Fixtures"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        self.object = object
        let originString = try #require(object["origin"] as? String)
        origin = try #require(URL(string: originString))
        nowMS = try #require(object["now"] as? Int64)
        let metadata = try #require(object["configuration"] as? [String: String])
        let create = try #require(object["create"] as? [String: Any])
        let scope = try #require(create["scope"] as? [String: String])
        let linkScope = LinkScope(projectID: try #require(scope["projectID"]),
            fullAppBundleID: try #require(metadata["fullAppBundleID"]), clipBundleID: try #require(metadata["clipBundleID"]))
        configuration = LinksConfiguration(scope: linkScope, role: .appClip,
            trustedHosts: [try #require(origin.host)], appGroupIdentifier: try #require(metadata["appGroupIdentifier"]))
        let registration = try #require(object["register"] as? [String: Any])
        keyID = try #require(registration["keyID"] as? String)
    }

    func data(_ key: String) throws -> Data { try JSONSerialization.data(withJSONObject: #require(object[key])) }
    func canonical(_ key: String) throws -> Data { try JSONDecoder().decode(CustomerRecoveryJSON.self, from: data(key)).encoded() }

    func invocation() throws -> CapturedInvocation {
        let create = try #require(object["create"] as? [String: Any])
        let value = try #require(create["invocation"] as? [String: Any])
        let id = try #require(value["id"] as? String)
        let operationID = try #require(value["operationID"] as? String)
        return CapturedInvocation(id: try #require(UUID(uuidString: id)),
            operationID: try #require(UUID(uuidString: operationID)), token: bearer,
            originalURL: try #require(value["originalURL"] as? String),
            capturedAt: Date(timeIntervalSince1970: Double(try #require(value["capturedAt"] as? Int64)) / 1_000 + 0.000456),
            expiresAt: Date(timeIntervalSince1970: Double(try #require(value["expiresAt"] as? Int64)) / 1_000 + 0.000456),
            scope: configuration.scope)
    }

    func receipt(invocation: CapturedInvocation) throws -> PinnedReceipt {
        try CustomerRecoveryWire.preparedReceipt(data("prepared"), invocation: invocation,
            configuration: configuration, expected: nil, now: now)
    }

    func acknowledgement() throws -> Acknowledgement { try JSONDecoder().decode(Acknowledgement.self, from: data("acknowledge")) }

    func challenge(purpose: String, payload: Data, bearer: String,
                   mutateBinding: (inout [String: Any]) throws -> Void = { _ in },
                   mutateResponse: (inout [String: Any]) throws -> Void = { _ in }) throws -> Data {
        let id = "66666666-6666-4666-8666-666666666666"
        let nonce = Data(repeating: 0, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        var binding: [String: Any] = ["version": 1, "challengeID": id, "challenge": nonce,
            "projectID": configuration.scope.projectID, "hostname": try #require(origin.host), "channel": "ios_app_clip",
            "identityHash": String(repeating: "a", count: 64), "origin": origin.absoluteString, "method": "POST",
            "path": purpose == "create" ? "/api/v1/recovery" : "/api/v1/recovery/" + purpose,
            "purpose": purpose, "payloadHash": CustomerRecoveryWire.hash(payload),
            "tokenHash": CustomerRecoveryWire.hash(Data(bearer.utf8)), "createdAt": nowMS, "expiresAt": nowMS + 300_000]
        try mutateBinding(&binding)
        let raw = try JSONSerialization.data(withJSONObject: binding)
        let canonical = try JSONDecoder().decode(CustomerRecoveryJSON.self, from: raw).encoded()
        var response: [String: Any] = ["version": 1, "result": "challenge", "challengeID": id,
            "challenge": nonce, "clientData": canonical.base64EncodedString(), "expiresAt": nowMS + 300_000]
        try mutateResponse(&response)
        return try JSONSerialization.data(withJSONObject: response)
    }
}
