import Foundation

/// DeviceCheck owns the private key. This seam never exports key material or
/// substitutes an installation identifier for native evidence.
@MainActor
public protocol RecoveryAppAttestProviding: AnyObject {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

public enum RecoveryAppAttestFailure: Error, Equatable, Sendable {
    case unsupported, invalidKey, unavailable, rejected
}

enum CustomerRecoveryPurpose: String, Sendable {
    case create, resolve, acknowledge

    var path: String {
        switch self {
        case .create: "/api/v1/recovery"
        case .resolve: "/api/v1/recovery/resolve"
        case .acknowledge: "/api/v1/recovery/acknowledge"
        }
    }
}

/// Constructed only after the HTTP adapter validates the complete binding. Sign
/// these original decoded bytes; reconstructing their JSON can change the hash.
struct CustomerRecoveryChallenge: Equatable, Sendable {
    let id: UUID
    let identityHash: String
    let clientData: Data
    let createdAt: Date
    let expiresAt: Date
}

struct CustomerRecoveryRegisteredKey: Equatable, Sendable {
    let keyID: String
    let expiresAt: Date
}

struct CustomerRecoveryAssertion: Equatable, Sendable {
    let challengeID: UUID
    let keyID: String
    let assertionObject: Data
}

struct CustomerRecoveryRegistrationEvidence: Codable, Equatable, Sendable {
    let challengeID: UUID
    let identityHash: String
    let clientData: Data
    let challengeExpiresAt: Date
    let attestationObject: Data
}

/// Registration uses its own persisted, random capability so a different capture
/// can finish an interrupted registration without replacing its token or proof.
@MainActor
protocol CustomerRecoveryProofClient: AnyObject {
    func operationChallenge(purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation,
                            payload: Data) async throws -> CustomerRecoveryChallenge
    func registrationChallenge(keyID: String, bearer: String, origin: URL) async throws -> CustomerRecoveryChallenge
    func submitRegistration(keyID: String, evidence: CustomerRecoveryRegistrationEvidence,
                            bearer: String, origin: URL) async throws -> CustomerRecoveryRegisteredKey
}
