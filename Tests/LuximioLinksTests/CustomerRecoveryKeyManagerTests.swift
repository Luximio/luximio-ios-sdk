import CryptoKit
import Foundation
import Testing
@testable import LuximioLinks

@MainActor
struct CustomerRecoveryKeyManagerTests {
    @Test func aRestartedFullAppUsesTheExactClipCaptureKey() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let invocation = try f.invocation()
        let key = try await f.proof(invocation)
        let fullApp = try f.manager(role: .fullApp)
        let restored = try await f.proof(invocation, purpose: .resolve, manager: fullApp)
        #expect(restored == key)
        #expect(f.provider.generated == 1)
        #expect(f.client.submissions.count == 1)
        #expect(f.provider.assertedKeys == [key, key])
        let raw = try String(contentsOf: f.recordURL, encoding: .utf8)
        #expect(raw.contains(invocation.token) == false)
        #expect(raw.contains(invocation.originalURL) == false)
    }

    @Test func rotationCannotChangeTheKeyOfAnUncertainCreate() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let originalKey = try await f.proof(try f.invocation())
        f.clock.date.addTimeInterval(22 * 86_400)
        let pending = try f.invocation()
        await #expect(throws: LinkFailure.network) {
            try await f.manager().withProof(purpose: .create, invocation: pending, payload: Data(), client: f.client) { _ in
                throw LinkFailure.network
            }
        }
        f.clock.date.addTimeInterval(86_400 + 3_600)
        let replacementKey = try await f.proof(try f.invocation())
        #expect(replacementKey != originalKey)
        let restoredKey = try await f.proof(pending, manager: f.manager())
        #expect(restoredKey == originalKey)
        #expect(f.provider.generated == 2)
    }

    @Test func aLostRegistrationResponseReplaysTheExactSavedEvidenceAndIndependentBearer() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        f.client.loseNextRegistrationResponse = true
        let first = try f.invocation()
        await #expect(throws: LinkFailure.network) { try await f.proof(first) }
        let second = try f.invocation()
        let key = try await f.proof(second, manager: f.manager())
        #expect(f.provider.generated == 1)
        #expect(f.provider.attestations.count == 1)
        #expect(f.client.registrationChallenges == 1)
        let submissions = f.client.submissions
        #expect(submissions.count == 2)
        #expect(submissions.first == submissions.last)
        #expect(submissions.first?.bearer != first.token)
        #expect(submissions.first?.bearer != second.token)
        let stored = try #require(try f.vault().read { $0.keys.first { $0.keyID == key } })
        #expect(stored.expiresAt == f.clock.date.addingTimeInterval(30 * 86_400))
        #expect(stored.registrationBearer == nil)
        #expect(stored.evidence == nil)
    }

    @Test func anAppleServerOutageRetriesTheSameKeyAndClientDataHash() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        f.provider.attestHook = { _, _ in
            if f.provider.attestations.count == 1 { throw RecoveryAppAttestFailure.unavailable }
            return Data([1, 2, 3])
        }
        await #expect(throws: LinkFailure.network) { try await f.proof(try f.invocation()) }
        _ = try await f.proof(try f.invocation(), manager: f.manager())
        #expect(f.provider.generated == 1)
        #expect(f.provider.attestations.count == 2)
        #expect(f.provider.attestations.first == f.provider.attestations.last)
        #expect(f.client.registrationChallenges == 1)
    }

    @Test(arguments: [RecoveryAppAttestFailure.invalidKey, .rejected])
    func aNonretryableNativeAttestationFailureAllowsANewCaptureToGenerateAnotherKey(failure: RecoveryAppAttestFailure) async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        f.provider.attestHook = { _, _ in throw failure }
        await #expect(throws: LinkFailure.unverifiedContext) { try await f.proof(try f.invocation()) }
        #expect(try f.vault().read { $0.keys.first?.state } == .quarantined)
        f.provider.attestHook = nil
        _ = try await f.proof(try f.invocation(), manager: f.manager())
        #expect(f.provider.generated == 2)
        #expect(f.client.submissions.count == 1)
    }

    @Test(arguments: [RecoveryAppAttestFailure.invalidKey, .rejected])
    func aNativeKeyFailureRetiresOnlyFutureSelectionAndNeverChangesAnExistingPin(failure: RecoveryAppAttestFailure) async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let pinned = try f.invocation()
        let failedKey = try await f.proof(pinned)
        f.provider.assertionHook = { keyID, _ in
            if keyID == failedKey { throw failure }
            return Data([9, 9, 9])
        }
        await #expect(throws: LinkFailure.unverifiedContext) { try await f.proof(pinned, purpose: .resolve) }
        let retired = try #require(try f.vault().read { $0.keys.first { $0.keyID == failedKey } })
        #expect(retired.state == .registered)
        #expect(retired.retired == true)
        let replacement = try await f.proof(try f.invocation(), manager: f.manager())
        #expect(replacement != failedKey)
        await #expect(throws: LinkFailure.unverifiedContext) { try await f.proof(pinned, purpose: .resolve) }
        #expect(f.provider.generated == 2)
        #expect(f.provider.assertedKeys.last == failedKey)
    }

    @Test func anExpiredUnknownRegistrationIsQuarantinedBeforeANewCaptureKey() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        f.client.loseNextRegistrationResponse = true
        await #expect(throws: LinkFailure.network) { try await f.proof(try f.invocation()) }
        f.clock.date.addTimeInterval(301)
        _ = try await f.proof(try f.invocation(), manager: f.manager())
        let snapshot = try f.vault().read { $0 }
        #expect(f.provider.generated == 2)
        #expect(snapshot.keys.filter { $0.state == .quarantined }.count == 1)
        #expect(snapshot.keys.first { $0.state == .quarantined }?.evidence != nil)
    }

    @Test(arguments: [CustomerRecoveryPurpose.resolve, .acknowledge])
    func recoveryCannotManufactureAReplacementKeyWithoutAnInvocationPin(purpose: CustomerRecoveryPurpose) async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        await #expect(throws: LinkFailure.unverifiedContext) {
            try await f.proof(try f.invocation(), purpose: purpose)
        }
        #expect(f.provider.generated == 0)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationAfterNativeAttestationPreservesItsEvidenceForRestart() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let gate = RecoveryKeyGate()
        f.provider.attestHook = { _, _ in
            await gate.suspend()
            return Data([7, 8, 9])
        }
        let invocation = try f.invocation()
        let manager = try f.manager()
        let task = Task { try await f.proof(invocation, manager: manager) }
        await gate.waitUntilEntered()
        task.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let candidate = try #require(try f.vault().read { $0.keys.first })
        #expect(candidate.evidence?.attestationObject == Data([7, 8, 9]))
        #expect(f.client.submissions.isEmpty)
        _ = try await f.proof(invocation, manager: f.manager())
        #expect(f.provider.attestations.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aStaleNativeCompletionCannotPromoteOrEraseANewerGeneration() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let gate = RecoveryKeyGate()
        f.provider.attestHook = { _, _ in
            if f.provider.attestations.count == 1 { await gate.suspend() }
            return Data([1, 2, 3])
        }
        let first = try f.invocation()
        let manager = try f.manager()
        let old = Task { try await f.proof(first, manager: manager) }
        await gate.waitUntilEntered()
        f.clock.date.addTimeInterval(CustomerRecoveryKeyVault.leaseLifetime + 1)
        let newKey = try await f.proof(try f.invocation(), manager: f.manager())
        gate.release()
        await #expect(throws: LinkFailure.superseded) { try await old.value }
        let snapshot = try f.vault().read { $0 }
        let active = try #require(snapshot.activeKeys.values.first)
        #expect(snapshot.keys.first { $0.generation == active }?.keyID == newKey)
        #expect(snapshot.keys.first { $0.keyID != newKey }?.evidence != nil)
        #expect(snapshot.pins.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func theFinalHTTPClosureKeepsBothProcessAndSharedVaultReservations() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let gate = RecoveryKeyGate()
        let manager = try f.manager()
        let invocation = try f.invocation()
        let task = Task {
            try await manager.withProof(purpose: .create, invocation: invocation, payload: Data(), client: f.client) { proof in
                await gate.suspend()
                return proof.keyID
            }
        }
        await gate.waitUntilEntered()
        await #expect(throws: LinkFailure.busy) { try await f.proof(try f.invocation(), manager: manager) }
        await #expect(throws: LinkFailure.busy) { try await f.proof(try f.invocation(), manager: f.manager()) }
        gate.release()
        _ = try await task.value
        #expect(f.provider.assertedKeys.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func aStaleAcceptedRegistrationIsRetainedWithoutReplacingTheActiveKey() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let gate = RecoveryKeyGate()
        f.client.submissionHook = { submission in
            if submission.keyID == Data(repeating: 1, count: 32).base64EncodedString() {
                await gate.suspend()
            }
        }
        let invocation = try f.invocation()
        let manager = try f.manager()
        let task = Task { try await f.proof(invocation, manager: manager) }
        await gate.waitUntilEntered()
        f.clock.date.addTimeInterval(CustomerRecoveryKeyVault.leaseLifetime + 1)
        let newerKey = try await f.proof(try f.invocation(), manager: f.manager())
        gate.release()
        await #expect(throws: LinkFailure.superseded) { try await task.value }
        let snapshot = try f.vault().read { $0 }
        #expect(snapshot.keys.filter { $0.state == .registered }.count == 2)
        let active = try #require(snapshot.activeKeys.values.first)
        #expect(snapshot.keys.first { $0.generation == active }?.keyID == newerKey)
        #expect(snapshot.keys.allSatisfy { $0.registrationBearer == nil && $0.evidence == nil })
    }

    @Test(.timeLimit(.minutes(1)), arguments: [3, 16_384])
    func repeatedOutagesEvictUnpinnedQuarantinesAndALateAcceptanceCannotResurrectOne(evidenceBytes: Int) async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let gate = RecoveryKeyGate()
        let firstKey = Data(repeating: 1, count: 32).base64EncodedString()
        f.provider.attestHook = { _, _ in Data(repeating: 8, count: evidenceBytes) }
        f.client.submissionHook = { submission in
            if submission.keyID == firstKey { await gate.suspend() }
        }
        let invocation = try f.invocation()
        let manager = try f.manager()
        let task = Task { try await f.proof(invocation, manager: manager) }
        await gate.waitUntilEntered()
        f.clock.date.addTimeInterval(CustomerRecoveryKeyVault.leaseLifetime + 1)
        for _ in 0..<CustomerRecoveryKeyVault.maximumKeys {
            f.client.loseNextRegistrationResponse = true
            await #expect(throws: LinkFailure.network) {
                try await f.proof(try f.invocation(), manager: f.manager())
            }
            f.clock.date.addTimeInterval(301)
        }
        let activeKey = try await f.proof(try f.invocation(), manager: f.manager())
        gate.release()
        await #expect(throws: LinkFailure.superseded) { try await task.value }
        let snapshot = try f.vault().read { $0 }
        #expect(snapshot.keys.count <= CustomerRecoveryKeyVault.maximumKeys)
        if evidenceBytes == 3 { #expect(snapshot.keys.count == CustomerRecoveryKeyVault.maximumKeys) }
        else { #expect(snapshot.keys.count < CustomerRecoveryKeyVault.maximumKeys) }
        #expect(snapshot.keys.contains { $0.keyID == firstKey } == false)
        #expect(snapshot.pins.count == 1)
        let generation = try #require(snapshot.activeKeys.values.first)
        #expect(snapshot.keys.first { $0.generation == generation }?.keyID == activeKey)
        #expect(f.provider.generated > CustomerRecoveryKeyVault.maximumKeys)
        #expect(try Data(contentsOf: f.recordURL).count <= CustomerRecoveryKeyVault.maximumSnapshotBytes)
    }

    @Test(.timeLimit(.minutes(1))) func maximumSizeEvidenceOutagesRespectTheByteBudgetAndPreservePinnedKeysAndReplayableCandidates() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        f.provider.attestHook = { _, _ in Data(repeating: 8, count: 16_384) }
        let firstKey = try await f.proof(try f.invocation())
        f.clock.date.addTimeInterval(22 * 86_400)
        let pinned = try f.invocation()
        #expect(try await f.proof(pinned) == firstKey)
        // The registered key remains needed by this pin, but is now too close
        // to its fixed expiry to use for any new seven-day capture.
        f.clock.date.addTimeInterval(2 * 86_400)
        for attempt in 0..<(CustomerRecoveryKeyVault.maximumKeys + 3) {
            if attempt > 0 { f.clock.date.addTimeInterval(301) }
            f.client.loseNextRegistrationResponse = true
            do {
                _ = try await f.proof(try f.invocation(), manager: f.manager())
                Issue.record("The fixture must lose each initial registration response.")
            } catch let failure as LinkFailure {
                try #require(failure == .network, "After outage \(attempt), the bounded vault must still admit native evidence.")
            }
            #expect(try Data(contentsOf: f.recordURL).count <= CustomerRecoveryKeyVault.maximumSnapshotBytes)
        }
        let generated = f.provider.generated
        let submission = try #require(f.client.submissions.last)
        let recovered = try await f.proof(try f.invocation(), manager: f.manager())
        #expect(recovered == submission.keyID)
        #expect(f.client.submissions.last == submission)
        #expect(f.provider.generated == generated, "Byte-budget eviction must preserve an unexpired registration replay.")
        let snapshot = try f.vault().read { $0 }
        #expect(snapshot.keys.count < CustomerRecoveryKeyVault.maximumKeys)
        #expect(snapshot.keys.contains { $0.keyID == firstKey && $0.state == .registered })
        #expect(snapshot.pins.contains { $0.invocationID == pinned.id })
        #expect(try Data(contentsOf: f.recordURL).count <= CustomerRecoveryKeyVault.maximumSnapshotBytes)
    }

    @Test func aCounterOrderingRejectionUsesANewChallengeAndAssertionWithTheSamePinnedKey() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let invocation = try f.invocation()
        var proofs: [CustomerRecoveryAssertion] = []
        let key = try await f.manager().withProof(purpose: .create, invocation: invocation, payload: Data(), client: f.client) { proof in
            proofs.append(proof)
            if proofs.count == 1 { throw LinkFailure.unverifiedContext }
            return proof.keyID
        }
        #expect(proofs.count == 2)
        #expect(proofs.first?.challengeID != proofs.last?.challengeID)
        #expect(proofs.allSatisfy { $0.keyID == key })
        #expect(f.provider.assertedKeys.count == 2)
        #expect(f.provider.generated == 1)
    }

    @Test func changedTokenOrServerIdentityCannotReuseAnExistingPin() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let invocation = try f.invocation()
        _ = try await f.proof(invocation)
        let altered = CapturedInvocation(id: invocation.id, operationID: invocation.operationID,
            token: Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""),
            originalURL: invocation.originalURL, capturedAt: invocation.capturedAt,
            expiresAt: invocation.expiresAt, scope: invocation.scope)
        await #expect(throws: LinkFailure.wrongScope) { try await f.proof(altered, purpose: .resolve) }
        f.client.identityHash = String(repeating: "b", count: 64)
        await #expect(throws: LinkFailure.wrongScope) { try await f.proof(invocation, purpose: .resolve) }
        #expect(f.provider.generated == 1)
    }

    @Test func terminalRetriesRetainTheSameKeyWithoutRenewingItsFixedExpiry() async throws {
        let f = try RecoveryKeyFixture()
        defer { f.cleanup() }
        let invocation = try f.invocation()
        let key = try await f.proof(invocation)
        let expiry = try #require(try f.vault().read { $0.keys.first?.expiresAt })
        f.clock.date.addTimeInterval(8 * 86_400)
        let terminalKey = try await f.proof(invocation, purpose: .acknowledge, manager: f.manager(role: .fullApp))
        #expect(terminalKey == key)
        #expect(try f.vault().read { $0.keys.first?.expiresAt } == expiry)
        let pin = try #require(try f.vault().read { $0.pins.first })
        #expect(pin.retainUntil > f.clock.date)
        #expect(pin.retainUntil <= expiry)
        #expect(f.client.submissions.count == 1)
    }
}

@MainActor
private final class RecoveryKeyClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class RecoveryKeyProvider: RecoveryAppAttestProviding {
    struct Attestation: Equatable { let key: String; let hash: Data }
    var isSupported = true
    var generated = 0
    var attestations: [Attestation] = []
    var assertedKeys: [String] = []
    var attestHook: (@MainActor (String, Data) async throws -> Data)?
    var assertionHook: (@MainActor (String, Data) async throws -> Data)?

    func generateKey() async throws -> String {
        generated += 1
        return Data(repeating: UInt8(generated), count: 32).base64EncodedString()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestations.append(.init(key: keyID, hash: clientDataHash))
        return try await attestHook?(keyID, clientDataHash) ?? Data([1, 2, 3])
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertedKeys.append(keyID)
        return try await assertionHook?(keyID, clientDataHash) ?? Data([UInt8(assertedKeys.count), 4, 5])
    }
}

@MainActor
private final class RecoveryKeyProofClient: CustomerRecoveryProofClient {
    struct Submission: Equatable {
        let keyID: String
        let evidence: CustomerRecoveryRegistrationEvidence
        let bearer: String
        let origin: URL
    }
    let clock: RecoveryKeyClock
    var identityHash = String(repeating: "a", count: 64)
    var operationChallenges = 0
    var registrationChallenges = 0
    var submissions: [Submission] = []
    var accepted: [String: CustomerRecoveryRegisteredKey] = [:]
    var loseNextRegistrationResponse = false
    var submissionHook: (@MainActor (Submission) async throws -> Void)?

    init(clock: RecoveryKeyClock) { self.clock = clock }

    func operationChallenge(purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation,
                            payload: Data) async throws -> CustomerRecoveryChallenge {
        operationChallenges += 1
        return challenge("operation-\(operationChallenges)-\(purpose.rawValue)")
    }

    func registrationChallenge(keyID: String, bearer: String, origin: URL) async throws -> CustomerRecoveryChallenge {
        registrationChallenges += 1
        return challenge("registration-\(registrationChallenges)")
    }

    func submitRegistration(keyID: String, evidence: CustomerRecoveryRegistrationEvidence,
                            bearer: String, origin: URL) async throws -> CustomerRecoveryRegisteredKey {
        let submission = Submission(keyID: keyID, evidence: evidence, bearer: bearer, origin: origin)
        submissions.append(submission)
        let result = accepted[keyID] ?? CustomerRecoveryRegisteredKey(
            keyID: keyID, expiresAt: clock.date.addingTimeInterval(30 * 86_400))
        accepted[keyID] = result
        try await submissionHook?(submission)
        if loseNextRegistrationResponse {
            loseNextRegistrationResponse = false
            throw LinkFailure.network
        }
        return result
    }

    private func challenge(_ value: String) -> CustomerRecoveryChallenge {
        .init(id: UUID(), identityHash: identityHash, clientData: Data(value.utf8),
              createdAt: clock.date, expiresAt: clock.date.addingTimeInterval(300))
    }
}

@MainActor
private final class RecoveryKeyGate {
    private var entered = false
    private var entering: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        let waiters = entering
        entering.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entering.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private struct RecoveryKeyFixture {
    let directory: URL
    let clock = RecoveryKeyClock()
    let provider = RecoveryKeyProvider()
    let client: RecoveryKeyProofClient
    let scope = LinkScope(projectID: "customer-project", fullAppBundleID: "app.customer.demo",
                          clipBundleID: "app.customer.demo.Clip")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        client = RecoveryKeyProofClient(clock: clock)
    }

    var recordURL: URL {
        directory.appendingPathComponent(CustomerRecoveryKeyVault.directoryName).appendingPathComponent("keys-v1.json")
    }

    func configuration(_ role: LinksConfiguration.Role = .appClip) -> LinksConfiguration {
        .init(scope: scope, role: role, trustedHosts: ["go.customer.example"], appGroupIdentifier: "group.customer.demo")
    }

    func manager(role: LinksConfiguration.Role = .appClip) throws -> CustomerRecoveryKeyManager {
        try .init(configuration: configuration(role), containerURL: directory, provider: provider, now: { clock.date })
    }

    func invocation() throws -> CapturedInvocation {
        try .capture(url: #require(URL(string: "https://go.customer.example/place?campaign=private")),
                     configuration: configuration(), at: clock.date)
    }

    func proof(_ invocation: CapturedInvocation, purpose: CustomerRecoveryPurpose = .create,
               manager: CustomerRecoveryKeyManager? = nil) async throws -> String {
        let manager = try manager ?? self.manager()
        return try await manager.withProof(purpose: purpose, invocation: invocation, payload: Data(), client: client) { $0.keyID }
    }

    func vault() throws -> CustomerRecoveryKeyVault { try .init(containerURL: directory) }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
