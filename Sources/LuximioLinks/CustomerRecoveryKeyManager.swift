import CryptoKit
import Foundation
import Security

/// Coordinates native proof work through the final HTTP request. An actor alone
/// cannot order App Clip/full-app processes or prevent actor reentrancy at await.
@MainActor
final class CustomerRecoveryKeyManager {
    private static let recoveryWindow: TimeInterval = 7 * 86_400
    private static let clockAndRequestMargin: TimeInterval = 360
    private let configuration: LinksConfiguration
    private let vault: CustomerRecoveryKeyVault
    private let provider: any RecoveryAppAttestProviding
    private let now: @MainActor () -> Date
    private var isBusy = false
    private var proofObserver: (@MainActor (CustomerRecoveryProofDiagnostic) -> Void)?

    init(configuration: LinksConfiguration, containerURL: URL?,
         provider: any RecoveryAppAttestProviding,
         now: @escaping @MainActor () -> Date = Date.init,
         proofObserver: (@MainActor (CustomerRecoveryProofDiagnostic) -> Void)? = nil) throws {
        let bundle = configuration.role == .fullApp
            ? configuration.scope.fullAppBundleID : configuration.scope.clipBundleID
        try configuration.validate(bundleIdentifier: bundle)
        self.configuration = configuration
        self.vault = try CustomerRecoveryKeyVault(containerURL: containerURL)
        self.provider = provider
        self.now = now
        self.proofObserver = proofObserver
    }

    func observeProofDiagnostics(_ observer: @escaping @MainActor (CustomerRecoveryProofDiagnostic) -> Void) {
        proofObserver = observer
    }

    func withProof<Result>(purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation,
                           payload: Data, client: any CustomerRecoveryProofClient,
                           operation: @MainActor (CustomerRecoveryAssertion) async throws -> Result) async throws -> Result {
        try Task.checkCancellation()
        guard !isBusy else { throw LinkFailure.busy }
        guard provider.isSupported else { throw LinkFailure.unverifiedContext }
        guard invocation.scope == configuration.scope,
              let original = URL(string: invocation.originalURL) else { throw LinkFailure.wrongScope }
        try configuration.validateURL(original)
        guard var components = URLComponents(url: original, resolvingAgainstBaseURL: false) else {
            throw LinkFailure.untrustedURL
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let origin = components.url else { throw LinkFailure.untrustedURL }
        let lease = try vault.acquireLease(at: now())
        isBusy = true
        defer {
            try? vault.releaseLease(lease)
            isBusy = false
        }
        var stage = CustomerRecoveryProofStage.challenge
        do {
            observe(purpose, stage: stage)
            var challenge = try await client.operationChallenge(purpose: purpose, invocation: invocation, payload: payload)
            try check(lease)
            stage = .pin
            observe(purpose, stage: stage)
            let namespace = try namespace(origin: origin, identityHash: challenge.identityHash)
            let fingerprint = try fingerprint(invocation)
            let key: CustomerRecoveryKeyVault.Key
            let existing = try vault.read { $0.pins.first { $0.invocationID == invocation.id } }
            if let existing {
                guard existing.namespace == namespace, existing.fingerprint == fingerprint else {
                    throw LinkFailure.wrongScope
                }
                key = try vault.read { snapshot in
                    guard let key = snapshot.keys.first(where: { $0.generation == existing.keyGeneration }),
                          key.state == .registered, let expiry = key.expiresAt, expiry > now() else {
                        throw LinkFailure.unverifiedContext
                    }
                    return key
                }
            } else {
                guard purpose == .create else { throw LinkFailure.unverifiedContext }
                guard invocation.expiresAt > now() else { throw LinkFailure.expired }
                let minimumExpiry = max(
                    challenge.createdAt.addingTimeInterval(Self.recoveryWindow + Self.clockAndRequestMargin),
                    invocation.expiresAt.addingTimeInterval(Self.clockAndRequestMargin)
                )
                stage = .registration
                observe(purpose, stage: stage)
                key = try await captureKey(namespace: namespace, identityHash: challenge.identityHash,
                                           minimumExpiry: minimumExpiry, origin: origin,
                                           client: client, lease: lease)
                stage = .pin
                observe(purpose, stage: stage)
                try check(lease)
                guard let expiry = key.expiresAt, expiry >= minimumExpiry else { throw LinkFailure.expired }
                // This commitment precedes create, including an HTTP response that is lost.
                try vault.update(lease: lease, at: now()) { snapshot in
                    guard !snapshot.pins.contains(where: { $0.invocationID == invocation.id }),
                          snapshot.pins.count < CustomerRecoveryKeyVault.maximumPins else {
                        throw LinkFailure.storage
                    }
                    let retainUntil = min(expiry, invocation.expiresAt.addingTimeInterval(
                        Self.recoveryWindow + Self.clockAndRequestMargin))
                    snapshot.pins.append(.init(invocationID: invocation.id, fingerprint: fingerprint,
                                              namespace: namespace, keyGeneration: key.generation,
                                              retainUntil: retainUntil))
                }
            }

            guard let keyID = key.keyID else { throw LinkFailure.invalidData }
            // Registration can take most of the original operation challenge's life.
            if challenge.expiresAt <= now().addingTimeInterval(15) {
                stage = .challenge
                observe(purpose, stage: stage)
                challenge = try await client.operationChallenge(purpose: purpose, invocation: invocation, payload: payload)
                try check(lease)
                stage = .pin
                observe(purpose, stage: stage)
            }
            try validate(challenge, identityHash: key.identityHash)
            for attempt in 0..<2 {
                let object: Data
                do {
                    stage = .assertion
                    observe(purpose, stage: stage)
                    object = try await provider.generateAssertion(keyID, clientDataHash: Self.digest(challenge.clientData))
                } catch let failure as RecoveryAppAttestFailure where failure == .invalidKey || failure == .rejected {
                    try vault.update(lease: lease, at: now()) { snapshot in
                        guard let index = snapshot.keys.firstIndex(where: { $0.generation == key.generation }) else {
                            throw LinkFailure.superseded
                        }
                        snapshot.keys[index].retired = true
                        if snapshot.activeKeys[namespace] == key.generation {
                            snapshot.activeKeys[namespace] = nil
                        }
                    }
                    throw failure
                }
                try check(lease)
                guard !object.isEmpty, object.count <= 4_096 else { throw LinkFailure.invalidData }
                let proof = CustomerRecoveryAssertion(challengeID: challenge.id, keyID: keyID, assertionObject: object)
                do {
                    stage = .operation
                    observe(purpose, stage: stage)
                    let result = try await operation(proof)
                    try check(lease)
                    return result
                } catch LinkFailure.unverifiedContext where attempt == 0 {
                    // A previous process's late request can advance the monotonic
                    // server counter. Retry the same operation with fresh evidence.
                    stage = .challenge
                    observe(purpose, stage: stage)
                    challenge = try await client.operationChallenge(purpose: purpose, invocation: invocation, payload: payload)
                    try check(lease)
                    stage = .pin
                    observe(purpose, stage: stage)
                    try validate(challenge, identityHash: key.identityHash)
                }
            }
            throw LinkFailure.unverifiedContext
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            observe(purpose, stage: stage, error: error)
            switch error {
            case RecoveryAppAttestFailure.unsupported, RecoveryAppAttestFailure.invalidKey,
                 RecoveryAppAttestFailure.rejected:
                throw LinkFailure.unverifiedContext
            case RecoveryAppAttestFailure.unavailable:
                throw LinkFailure.network
            default:
                throw error
            }
        }
    }

    private func observe(_ purpose: CustomerRecoveryPurpose, stage: CustomerRecoveryProofStage,
                         error: (any Error)? = nil) {
        guard let proofObserver else { return }
        let native = error as? RecoveryAppAttestFailure
        let failure: LinkFailure?
        switch native {
        case .unsupported, .invalidKey, .rejected: failure = .unverifiedContext
        case .unavailable: failure = .network
        case nil: failure = error.map { ($0 as? LinkFailure) ?? .storage }
        }
        proofObserver(CustomerRecoveryProofDiagnostic(purpose: purpose, stage: stage,
            failure: failure, nativeFailure: native))
    }

    private func captureKey(namespace: String, identityHash: String, minimumExpiry: Date,
                            origin: URL, client: any CustomerRecoveryProofClient,
                            lease: UUID) async throws -> CustomerRecoveryKeyVault.Key {
        if let key = try vault.read({ snapshot -> CustomerRecoveryKeyVault.Key? in
            guard let generation = snapshot.activeKeys[namespace] else { return nil }
            return snapshot.keys.first {
                $0.generation == generation && $0.state == .registered
                    && $0.retired == false
                    && ($0.expiresAt ?? .distantPast) >= minimumExpiry
            }
        }) { return key }

        var key = try vault.update(lease: lease, at: now()) { snapshot in
            for index in snapshot.keys.indices where snapshot.keys[index].namespace == namespace
                && snapshot.keys[index].state == .candidate {
                if let expiry = snapshot.keys[index].challenge?.expiresAt, expiry <= now() {
                    snapshot.keys[index].state = .quarantined
                }
            }
            if let candidate = snapshot.keys.last(where: { $0.namespace == namespace && $0.state == .candidate }) {
                return candidate
            }
            if snapshot.keys.count >= CustomerRecoveryKeyVault.maximumKeys {
                snapshot.evictOldestUnpinnedQuarantine()
            }
            guard snapshot.keys.count < CustomerRecoveryKeyVault.maximumKeys else { throw LinkFailure.storage }
            let candidate = CustomerRecoveryKeyVault.Key(generation: UUID(), namespace: namespace,
                identityHash: identityHash, createdAt: now(), registrationBearer: try Self.randomBearer())
            snapshot.keys.append(candidate)
            return candidate
        }
        let generation = key.generation
        if key.keyID == nil {
            let keyID = try await provider.generateKey()
            guard CustomerRecoveryKeyVault.isKeyID(keyID) else { throw LinkFailure.invalidData }
            // Native work may finish despite cancellation or an expired lease. Save
            // it by generation, without changing a newer active key or reservation.
            key = try vault.update { snapshot in
                guard let index = snapshot.keys.firstIndex(where: { $0.generation == generation }),
                      snapshot.keys[index].keyID == nil else { throw LinkFailure.superseded }
                snapshot.keys[index].keyID = keyID
                return snapshot.keys[index]
            }
            try check(lease)
        }
        guard let keyID = key.keyID, let bearer = key.registrationBearer else { throw LinkFailure.invalidData }
        if key.challenge == nil {
            let challenge = try await client.registrationChallenge(keyID: keyID, bearer: bearer, origin: origin)
            try check(lease)
            try validate(challenge, identityHash: identityHash)
            key = try vault.update(lease: lease, at: now()) { snapshot in
                guard let index = snapshot.keys.firstIndex(where: {
                    $0.generation == generation && $0.state == .candidate && $0.keyID == keyID
                }) else { throw LinkFailure.superseded }
                snapshot.keys[index].challenge = .init(challenge)
                return snapshot.keys[index]
            }
        }
        guard let registrationChallenge = key.challenge, registrationChallenge.expiresAt > now() else {
            throw LinkFailure.expired
        }
        if key.evidence == nil {
            let object: Data
            do {
                object = try await provider.attestKey(keyID, clientDataHash: Self.digest(registrationChallenge.clientData))
            } catch let failure as RecoveryAppAttestFailure where failure != .unavailable {
                try vault.update(lease: lease, at: now()) { snapshot in
                    if let index = snapshot.keys.firstIndex(where: { $0.generation == generation }) {
                        snapshot.keys[index].state = .quarantined
                    }
                }
                throw failure
            }
            guard !object.isEmpty, object.count <= 16_384 else { throw LinkFailure.invalidData }
            let evidence = CustomerRecoveryRegistrationEvidence(challengeID: registrationChallenge.id,
                identityHash: registrationChallenge.identityHash, clientData: registrationChallenge.clientData,
                challengeExpiresAt: registrationChallenge.expiresAt, attestationObject: object)
            key = try vault.update { snapshot in
                guard let index = snapshot.keys.firstIndex(where: {
                    $0.generation == generation && $0.keyID == keyID
                        && $0.challenge?.id == registrationChallenge.id
                }), snapshot.keys[index].evidence == nil || snapshot.keys[index].evidence == evidence else {
                    throw LinkFailure.superseded
                }
                snapshot.keys[index].evidence = evidence
                return snapshot.keys[index]
            }
            try check(lease)
        }
        guard let evidence = key.evidence, evidence.challengeExpiresAt > now() else { throw LinkFailure.expired }
        let accepted = try await client.submitRegistration(keyID: keyID, evidence: evidence, bearer: bearer, origin: origin)
        guard accepted.keyID == keyID, accepted.expiresAt > now(),
              accepted.expiresAt <= registrationChallenge.createdAt.addingTimeInterval(30 * 86_400 + 360) else {
            throw LinkFailure.invalidData
        }
        key = try vault.update { snapshot in
            guard let index = snapshot.keys.firstIndex(where: {
                $0.generation == generation && $0.keyID == keyID
            }) else { throw LinkFailure.superseded }
            if snapshot.keys[index].state == .registered,
               snapshot.keys[index].expiresAt != accepted.expiresAt { throw LinkFailure.conflict }
            // Even a stale successful HTTP callback is useful recoverable state.
            // Only the current owner may promote it to the namespace's active key.
            snapshot.keys[index].state = .registered
            snapshot.keys[index].expiresAt = accepted.expiresAt
            snapshot.keys[index].registrationBearer = nil
            snapshot.keys[index].challenge = nil
            snapshot.keys[index].evidence = nil
            if snapshot.lease?.id == lease, (snapshot.lease?.expiresAt ?? .distantPast) > now() {
                snapshot.activeKeys[namespace] = generation
            }
            return snapshot.keys[index]
        }
        try check(lease)
        return key
    }

    private func check(_ lease: UUID) throws {
        try vault.checkLease(lease, at: now())
        try Task.checkCancellation()
    }

    private func validate(_ challenge: CustomerRecoveryChallenge, identityHash: String) throws {
        guard CustomerRecoveryKeyVault.isHash(challenge.identityHash), challenge.identityHash == identityHash,
              !challenge.clientData.isEmpty, challenge.clientData.count <= 16_384,
              challenge.createdAt.timeIntervalSince1970.isFinite,
              challenge.expiresAt.timeIntervalSince1970.isFinite,
              challenge.expiresAt > challenge.createdAt, challenge.expiresAt > now() else {
            throw LinkFailure.unverifiedContext
        }
    }

    private func namespace(origin: URL, identityHash: String) throws -> String {
        guard CustomerRecoveryKeyVault.isHash(identityHash) else { throw LinkFailure.invalidData }
        let fields = [configuration.scope.projectID, configuration.scope.fullAppBundleID,
                      configuration.scope.clipBundleID, configuration.appGroupIdentifier,
                      origin.absoluteString, identityHash]
        return Self.hexDigest(try JSONEncoder().encode(fields))
    }

    private func fingerprint(_ invocation: CapturedInvocation) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Self.hexDigest(try encoder.encode(invocation))
    }

    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    private static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBearer() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let pointer = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, pointer)
        }
        guard status == errSecSuccess else { throw LinkFailure.storage }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
