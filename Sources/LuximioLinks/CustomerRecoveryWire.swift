import CryptoKit
import Foundation

/// The signed request domain is deliberately closed: no floating point, dates,
/// destination JSON, or platform-dependent dictionary/string serialization.
indirect enum CustomerRecoveryJSON: Equatable, Decodable {
    case object([String: CustomerRecoveryJSON])
    case string(String)
    case integer(Int64)
    case null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let integer = try? value.decode(Int64.self), integer >= -CustomerRecoveryWire.maximumInteger,
                integer <= CustomerRecoveryWire.maximumInteger {
            self = .integer(integer)
        } else if let object = try? value.decode([String: Self].self) { self = .object(object) }
        else { throw LinkFailure.invalidData }
    }

    func encoded() throws -> Data { Data(try canonical().utf8) }

    private func canonical() throws -> String {
        switch self {
        case .null: return "null"
        case .integer(let number):
            guard number >= -CustomerRecoveryWire.maximumInteger, number <= CustomerRecoveryWire.maximumInteger else { throw LinkFailure.invalidData }
            return String(number)
        case .string(let string): return Self.quote(string)
        case .object(let object):
            let keys = object.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { Self.quote($0) + ":" + (try object[$0]!.canonical()) }).joined(separator: ",") + "}"
        }
    }

    /// JSON.stringify's escaping for valid Unicode strings. Swift String cannot
    /// contain unpaired UTF-16 surrogates; decoded clientData must round-trip.
    private static func quote(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0a: output += "\\n"
            case 0x0c: output += "\\f"
            case 0x0d: output += "\\r"
            case 0..<0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }
}

enum CustomerRecoveryWire {
    static let maximumInteger: Int64 = 9_007_199_254_740_991
    static let maximumBodyBytes = 65_536
    static let rootPath = "/api/v1/recovery"

    static func milliseconds(_ date: Date) throws -> Int64 {
        let value = floor(date.timeIntervalSince1970 * 1_000)
        guard value.isFinite, value >= 0, value <= Double(maximumInteger) else { throw LinkFailure.invalidData }
        return Int64(value)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func scope(_ scope: LinkScope) -> CustomerRecoveryJSON {
        .object(["projectID": .string(scope.projectID), "channel": .string("ios_app_clip")])
    }

    static func createPayload(invocation: CapturedInvocation) throws -> Data {
        try CustomerRecoveryJSON.object(["version": .integer(1), "scope": scope(invocation.scope),
            "invocation": .object(["id": .string(invocation.id.uuidString.lowercased()),
                "operationID": .string(invocation.operationID.uuidString.lowercased()),
                "originalURL": .string(invocation.originalURL),
                "capturedAt": .integer(try milliseconds(invocation.capturedAt)),
                "expiresAt": .integer(try milliseconds(invocation.expiresAt))])]).encoded()
    }

    static func resolvePayload(receipt: PinnedReceipt) throws -> Data {
        try CustomerRecoveryJSON.object(["version": .integer(1), "scope": scope(receipt.invocation.scope),
            "receiptID": .string(receipt.id.uuidString.lowercased()),
            "deliveryID": .string(receipt.deliveryID.uuidString.lowercased())]).encoded()
    }

    static func acknowledgementPayload(_ acknowledgement: Acknowledgement, scope linkScope: LinkScope) throws -> Data {
        try CustomerRecoveryJSON.object(["version": .integer(1), "scope": scope(linkScope),
            "receiptID": .string(acknowledgement.receiptID.uuidString.lowercased()),
            "deliveryID": .string(acknowledgement.deliveryID.uuidString.lowercased()),
            "operationID": .string(acknowledgement.operationID.uuidString.lowercased()),
            "outcome": .string(acknowledgement.outcome.rawValue)]).encoded()
    }

    static func registrationPayload(keyID: String, scope linkScope: LinkScope) throws -> Data {
        _ = try base64(keyID, maximumBytes: 32, exactBytes: 32)
        return try CustomerRecoveryJSON.object(["version": .integer(1), "scope": scope(linkScope),
            "keyID": .string(keyID)]).encoded()
    }

    static func challengePayload(purpose: String, payload: Data, scope linkScope: LinkScope) throws -> Data {
        try CustomerRecoveryJSON.object(["version": .integer(1), "scope": scope(linkScope),
            "purpose": .string(purpose), "payloadHash": .string(hash(payload))]).encoded()
    }

    static func envelope(payload: Data, proof: CustomerRecoveryJSON) throws -> Data {
        let value = try JSONDecoder().decode(CustomerRecoveryJSON.self, from: payload)
        guard try value.encoded() == payload else { throw LinkFailure.invalidData }
        let body = try CustomerRecoveryJSON.object(["payload": value, "proof": proof]).encoded()
        guard body.count <= maximumBodyBytes else { throw LinkFailure.invalidData }
        return body
    }

    static func assertion(_ assertion: CustomerRecoveryAssertion) throws -> CustomerRecoveryJSON {
        _ = try base64(assertion.keyID, maximumBytes: 32, exactBytes: 32)
        guard !assertion.assertionObject.isEmpty, assertion.assertionObject.count <= 4_096 else { throw LinkFailure.invalidData }
        return .object(["kind": .string("app_attest"),
            "challengeID": .string(assertion.challengeID.uuidString.lowercased()),
            "keyID": .string(assertion.keyID), "assertionObject": .string(assertion.assertionObject.base64EncodedString())])
    }

    static func validateChallenge(_ data: Data, purpose: String, payload: Data, bearer: String,
                                  origin: URL, scope linkScope: LinkScope, now: Date) throws -> CustomerRecoveryChallenge {
        try keys(data, expected: ["version", "result", "challengeID", "challenge", "clientData", "expiresAt"])
        let response = try decode(ChallengeResponse.self, data)
        guard response.version == 1, response.result == "challenge", validUUID(response.challengeID),
              let id = UUID(uuidString: response.challengeID) else { throw LinkFailure.invalidData }
        let nonce = try base64URL(response.challenge, exactBytes: 32)
        let clientData = try base64(response.clientData, maximumBytes: 8_192)
        try keys(clientData, expected: ["version", "challengeID", "challenge", "projectID", "hostname", "channel",
                                      "identityHash", "origin", "method", "path", "purpose", "payloadHash", "tokenHash", "createdAt", "expiresAt"])
        let binding = try decode(ChallengeBinding.self, clientData)
        let value = try decode(CustomerRecoveryJSON.self, clientData)
        let nowMilliseconds = try milliseconds(now)
        let path = purpose == "register" ? rootPath + "/register" :
            (purpose == "create" ? rootPath : rootPath + "/" + purpose)
        guard ["register", "create", "resolve", "acknowledge"].contains(purpose),
              binding.version == 1, binding.challengeID == response.challengeID,
              binding.challenge == response.challenge, nonce.count == 32,
              binding.projectID == linkScope.projectID, binding.channel == "ios_app_clip",
              binding.hostname == origin.host, binding.origin == origin.absoluteString,
              binding.method == "POST", binding.path == path, binding.purpose == purpose,
              isHash(binding.identityHash), binding.payloadHash == hash(payload),
              binding.tokenHash == hash(Data(bearer.utf8)),
              binding.createdAt >= 0, binding.expiresAt <= maximumInteger,
              binding.createdAt <= maximumInteger - 300_000,
              binding.expiresAt == binding.createdAt + 300_000,
              binding.createdAt <= nowMilliseconds + min(300_000, maximumInteger - nowMilliseconds),
              binding.expiresAt > nowMilliseconds, response.expiresAt == binding.expiresAt,
              try value.encoded() == clientData else { throw LinkFailure.invalidData }
        return CustomerRecoveryChallenge(id: id, identityHash: binding.identityHash, clientData: clientData,
            createdAt: Date(timeIntervalSince1970: Double(binding.createdAt) / 1_000),
            expiresAt: Date(timeIntervalSince1970: Double(binding.expiresAt) / 1_000))
    }

    static func preparedReceipt(_ data: Data, invocation: CapturedInvocation,
                                configuration: LinksConfiguration, expected: PinnedReceipt?, now: Date) throws -> PinnedReceipt {
        try keys(data, expected: ["version", "result", "receipt"])
        let response = try decode(PreparedResponse.self, data)
        let wire = response.receipt
        let expectedInvocation = try JSONDecoder().decode(CreatePayload.self, from: createPayload(invocation: invocation)).invocation
        guard response.version == 1, response.result == "prepared", wire.scope.projectID == invocation.scope.projectID,
              wire.scope.channel == "ios_app_clip", wire.invocation == expectedInvocation,
              validUUID(wire.id), validUUID(wire.deliveryID),
              let id = UUID(uuidString: wire.id), let deliveryID = UUID(uuidString: wire.deliveryID),
              wire.expiresAt >= 0, wire.expiresAt <= maximumInteger else { throw LinkFailure.invalidData }
        // Validate nested schema as well as typed fields. A server must not grow
        // authority-bearing fields that this adapter silently ignores.
        let object = try object(data)
        let receiptObject = try nested(object, key: "receipt", expected: ["id", "deliveryID", "scope", "invocation", "canonicalLinkID", "destination", "expiresAt"])
        _ = try nested(receiptObject, key: "scope", expected: ["projectID", "channel"])
        _ = try nested(receiptObject, key: "invocation", expected: ["id", "operationID", "originalURL", "capturedAt", "expiresAt"])
        let receipt = PinnedReceipt(id: id, deliveryID: deliveryID, invocation: invocation,
                                    canonicalLinkID: wire.canonicalLinkID, destination: wire.destination,
                                    expiresAt: Date(timeIntervalSince1970: Double(wire.expiresAt) / 1_000))
        try receipt.validate(configuration: configuration, now: now)
        if let expected, receipt != expected { throw LinkFailure.changedDestination }
        return receipt
    }

    static func registeredKey(_ data: Data, keyID: String, now: Date) throws -> CustomerRecoveryRegisteredKey {
        try keys(data, expected: ["version", "result", "keyID", "expiresAt"])
        let response = try decode(RegisteredResponse.self, data)
        let nowMS = try milliseconds(now)
        guard response.version == 1, response.result == "registered", response.keyID == keyID,
              response.expiresAt > nowMS, response.expiresAt <= maximumInteger,
              response.expiresAt - nowMS <= 30 * 24 * 60 * 60 * 1_000 + 300_000 else { throw LinkFailure.invalidData }
        return CustomerRecoveryRegisteredKey(keyID: keyID, expiresAt: Date(timeIntervalSince1970: Double(response.expiresAt) / 1_000))
    }

    static func validateAcknowledgement(_ data: Data, expected: Acknowledgement) throws {
        try keys(data, expected: ["version", "result", "receiptID", "deliveryID", "operationID", "outcome"])
        let response = try decode(AcknowledgedResponse.self, data)
        guard response.version == 1, response.result == "acknowledged",
              validUUID(response.receiptID), validUUID(response.deliveryID), validUUID(response.operationID),
              UUID(uuidString: response.receiptID) == expected.receiptID,
              UUID(uuidString: response.deliveryID) == expected.deliveryID,
              UUID(uuidString: response.operationID) == expected.operationID,
              response.outcome == expected.outcome else { throw LinkFailure.invalidData }
    }

    static func rejection(_ data: Data, status: Int) throws -> LinkFailure {
        try keys(data, expected: ["version", "result", "reason"])
        let response = try decode(RejectedResponse.self, data)
        guard response.version == 1, response.result == "rejected" else { throw LinkFailure.invalidData }
        switch (response.reason, status) {
        case ("invalidData", 400), ("invalidData", 405): return .invalidData
        case ("unavailable", 404): return .unavailable
        case ("wrongScope", 403): return .wrongScope
        case ("expired", 410): return .expired
        case ("conflict", 409), ("completed", 409): return .conflict
        case ("changedDestination", 409): return .changedDestination
        case ("busy", 429): return .busy
        case ("network", 503): return .network
        case ("unverified", 401): return .unverifiedContext
        default: throw LinkFailure.invalidData
        }
    }

    static func base64(_ string: String, maximumBytes: Int, exactBytes: Int? = nil) throws -> Data {
        guard !string.isEmpty, string.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              let data = Data(base64Encoded: string), data.count <= maximumBytes,
              exactBytes == nil || data.count == exactBytes,
              data.base64EncodedString() == string else { throw LinkFailure.invalidData }
        return data
    }

    private static func base64URL(_ string: String, exactBytes: Int) throws -> Data {
        let encoded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        let data = try base64(encoded + padding, maximumBytes: exactBytes, exactBytes: exactBytes)
        guard data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == string else { throw LinkFailure.invalidData }
        return data
    }

    private static func validUUID(_ string: String) -> Bool {
        string.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z"#,
                     options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isHash(_ string: String) -> Bool {
        string.range(of: #"^[0-9a-f]{64}\z"#, options: .regularExpression) != nil
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw LinkFailure.invalidData }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LinkFailure.invalidData }
            return object
        } catch { throw LinkFailure.invalidData }
    }

    private static func keys(_ data: Data, expected: Set<String>) throws {
        guard Set(try object(data).keys) == expected else { throw LinkFailure.invalidData }
    }

    private static func nested(_ object: [String: Any], key: String, expected: Set<String>) throws -> [String: Any] {
        guard let child = object[key] as? [String: Any], Set(child.keys) == expected else { throw LinkFailure.invalidData }
        return child
    }
}

private struct ChallengeResponse: Decodable {
    let version: Int; let result: String; let challengeID: String; let challenge: String; let clientData: String; let expiresAt: Int64
}
private struct ChallengeBinding: Decodable {
    let version: Int; let challengeID: String; let challenge: String; let projectID: String; let hostname: String; let channel: String
    let identityHash: String; let origin: String; let method: String; let path: String; let purpose: String; let payloadHash: String
    let tokenHash: String; let createdAt: Int64; let expiresAt: Int64
}
private struct RecoveryWireScope: Decodable { let projectID: String; let channel: String }
private struct RecoveryWireInvocation: Decodable, Equatable {
    let id: String; let operationID: String; let originalURL: String; let capturedAt: Int64; let expiresAt: Int64
}
private struct CreatePayload: Decodable { let invocation: RecoveryWireInvocation }
private struct PreparedResponse: Decodable { let version: Int; let result: String; let receipt: RecoveryWireReceipt }
private struct RecoveryWireReceipt: Decodable {
    let id: String; let deliveryID: String; let scope: RecoveryWireScope; let invocation: RecoveryWireInvocation
    let canonicalLinkID: String; let destination: LinkDestination; let expiresAt: Int64
}
private struct RegisteredResponse: Decodable { let version: Int; let result: String; let keyID: String; let expiresAt: Int64 }
private struct AcknowledgedResponse: Decodable {
    let version: Int; let result: String; let receiptID: String; let deliveryID: String; let operationID: String
    let outcome: Acknowledgement.Outcome
}
private struct RejectedResponse: Decodable { let version: Int; let result: String; let reason: String }
