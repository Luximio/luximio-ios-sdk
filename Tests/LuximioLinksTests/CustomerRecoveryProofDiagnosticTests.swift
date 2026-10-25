import Foundation
import Testing
@_spi(PrivatePrototype) @testable import LuximioLinks

@MainActor
struct CustomerRecoveryProofDiagnosticTests {
    @Test func aMissingPinAndAnInvalidNativeKeyHaveDifferentSafeStages() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.wire.invocation()
        await #expect(throws: LinkFailure.unverifiedContext) {
            try await fixture.proof(.resolve, invocation: invocation)
        }
        #expect(fixture.events.last == .init(purpose: .resolve, stage: .pin, failure: .unverifiedContext))
        #expect(fixture.provider.assertionCalls == 0)

        try await fixture.proof(.create, invocation: invocation)
        fixture.events.removeAll()
        fixture.provider.assertionFailure = .invalidKey
        await #expect(throws: LinkFailure.unverifiedContext) {
            try await fixture.proof(.resolve, invocation: invocation)
        }
        #expect(fixture.events.last == .init(purpose: .resolve, stage: .assertion,
            failure: .unverifiedContext, nativeFailure: .invalidKey))
        #expect(fixture.operationCalls == 1, "The failed native assertion cannot reach the resolve operation.")
    }

    @Test func anAlteredPinnedInvocationReportsPinFailureWithoutNativeEvidence() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.wire.invocation()
        try await fixture.proof(.create, invocation: invocation)
        fixture.events.removeAll()
        let altered = CapturedInvocation(id: invocation.id, operationID: invocation.operationID,
            token: invocation.token, originalURL: invocation.originalURL + "&altered=1",
            capturedAt: invocation.capturedAt, expiresAt: invocation.expiresAt, scope: invocation.scope)

        await #expect(throws: LinkFailure.wrongScope) {
            try await fixture.proof(.resolve, invocation: altered)
        }
        #expect(fixture.events.last == .init(purpose: .resolve, stage: .pin, failure: .wrongScope))
        #expect(fixture.provider.assertionCalls == 1)
        #expect(fixture.operationCalls == 1)
    }

    @Test func registrationAndOperationFailuresKeepTheirExistingMappings() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        let invocation = try fixture.wire.invocation()
        fixture.provider.attestationFailure = .unavailable
        await #expect(throws: LinkFailure.network) {
            try await fixture.proof(.create, invocation: invocation)
        }
        #expect(fixture.events.last == .init(purpose: .create, stage: .registration,
            failure: .network, nativeFailure: .unavailable))
        #expect(fixture.operationCalls == 0)

        fixture.provider.attestationFailure = nil
        fixture.events.removeAll()
        fixture.operationError = LinkFailure.network
        await #expect(throws: LinkFailure.network) {
            try await fixture.proof(.create, invocation: invocation)
        }
        #expect(fixture.events.last == .init(purpose: .create, stage: .operation, failure: .network))
        #expect(fixture.provider.generated == 1, "Observing a failure cannot replace the retained native key.")
        #expect(fixture.operationCalls == 1)
    }

    @Test func theBackendObserverReportsAnInvalidChallengeAndCanBeReplaced() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        let backend = try CustomerRecoveryBackend(configuration: fixture.wire.configuration,
            containerURL: fixture.directory, appAttest: fixture.provider,
            transport: InvalidDiagnosticChallengeTransport(), now: { fixture.wire.now })
        var previousEvents: [CustomerRecoveryProofDiagnostic] = []
        backend.observeProofDiagnostics { previousEvents.append($0) }
        backend.observeProofDiagnostics { fixture.events.append($0) }

        await #expect(throws: LinkFailure.invalidData) { try await backend.create(fixture.wire.invocation()) }

        #expect(previousEvents.isEmpty)
        #expect(fixture.events == [
            .init(purpose: .create, stage: .challenge),
            .init(purpose: .create, stage: .challenge, failure: .invalidData)
        ])
        #expect(fixture.provider.generated == 0)
        #expect(fixture.provider.assertionCalls == 0)
    }

    @Test(arguments: [false, true])
    func observationDoesNotChangeSuccessfulProofWork(observed: Bool) async throws {
        let fixture = try ProofDiagnosticFixture(observed: observed)
        defer { fixture.cleanup() }
        try await fixture.proof(.create, invocation: fixture.wire.invocation())

        #expect(fixture.provider.generated == 1)
        #expect(fixture.provider.attestationCalls == 1)
        #expect(fixture.provider.assertionCalls == 1)
        #expect(fixture.operationCalls == 1)
        if observed {
            #expect(fixture.events.map(\.stage) == [.challenge, .pin, .registration, .pin, .assertion, .operation])
            #expect(fixture.events.allSatisfy { $0.purpose == "create" && $0.failure == nil && $0.nativeFailure == nil })
            let fields = Mirror(reflecting: try #require(fixture.events.first)).children.compactMap(\.label)
            #expect(Set(fields) == ["purpose", "stage", "failure", "nativeFailure"],
                    "The temporary observation cannot acquire request or invocation fields.")
        } else {
            #expect(fixture.events.isEmpty)
        }
    }

    @Test func cancellationIsNotReclassifiedByObservation() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        fixture.client.cancelChallenge = true
        await #expect(throws: CancellationError.self) {
            try await fixture.proof(.create, invocation: fixture.wire.invocation())
        }
        #expect(fixture.events == [.init(purpose: .create, stage: .challenge)])
        #expect(fixture.provider.generated == 0)
        #expect(fixture.operationCalls == 0)
    }

    @Test func anUnknownFailureUsesABoundedDiagnosticWithoutChangingTheThrownError() async throws {
        let fixture = try ProofDiagnosticFixture()
        defer { fixture.cleanup() }
        fixture.operationError = UnclassifiedProofFailure.synthetic
        await #expect(throws: UnclassifiedProofFailure.synthetic) {
            try await fixture.proof(.create, invocation: fixture.wire.invocation())
        }
        #expect(fixture.events.last == .init(purpose: .create, stage: .operation, failure: .storage))
        #expect(fixture.operationCalls == 1)
    }
}

private enum UnclassifiedProofFailure: Error, Equatable { case synthetic }

@MainActor
private final class ProofDiagnosticFixture {
    let wire: RecoveryWireTestFixture
    let directory: URL
    let provider = ProofDiagnosticProvider()
    let client: ProofDiagnosticClient
    let observed: Bool
    var events: [CustomerRecoveryProofDiagnostic] = []
    var operationCalls = 0
    var operationError: (any Error)?

    init(observed: Bool = true) throws {
        wire = try RecoveryWireTestFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("proof-diagnostic-" + UUID().uuidString,
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        client = ProofDiagnosticClient(now: wire.now)
        self.observed = observed
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func proof(_ purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation) async throws {
        let now = wire.now
        let observer: (@MainActor (CustomerRecoveryProofDiagnostic) -> Void)?
        if observed { observer = { self.events.append($0) } }
        else { observer = nil }
        let manager = try CustomerRecoveryKeyManager(configuration: wire.configuration, containerURL: directory,
            provider: provider, now: { now }, proofObserver: observer)
        try await manager.withProof(purpose: purpose, invocation: invocation, payload: Data(), client: client) { _ in
            self.operationCalls += 1
            if let error = self.operationError { throw error }
        }
    }
}

@MainActor
private final class ProofDiagnosticProvider: RecoveryAppAttestProviding {
    let isSupported = true
    var generated = 0
    var attestationCalls = 0
    var assertionCalls = 0
    var attestationFailure: RecoveryAppAttestFailure?
    var assertionFailure: RecoveryAppAttestFailure?

    func generateKey() async throws -> String {
        generated += 1
        return Data(repeating: 1, count: 32).base64EncodedString()
    }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        attestationCalls += 1
        if let attestationFailure { throw attestationFailure }
        return Data([1, 2, 3])
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionCalls += 1
        if let assertionFailure { throw assertionFailure }
        return Data([4, 5, 6])
    }
}

@MainActor
private final class ProofDiagnosticClient: CustomerRecoveryProofClient {
    let now: Date
    var cancelChallenge = false
    init(now: Date) { self.now = now }

    func operationChallenge(purpose: CustomerRecoveryPurpose, invocation: CapturedInvocation,
                            payload: Data) async throws -> CustomerRecoveryChallenge {
        if cancelChallenge { throw CancellationError() }
        return challenge()
    }
    func registrationChallenge(keyID: String, bearer: String, origin: URL) async throws -> CustomerRecoveryChallenge {
        challenge()
    }
    func submitRegistration(keyID: String, evidence: CustomerRecoveryRegistrationEvidence,
                            bearer: String, origin: URL) async throws -> CustomerRecoveryRegisteredKey {
        .init(keyID: keyID, expiresAt: now.addingTimeInterval(30 * 86_400))
    }
    private func challenge() -> CustomerRecoveryChallenge {
        .init(id: UUID(), identityHash: String(repeating: "a", count: 64), clientData: Data([7, 8, 9]),
            createdAt: now, expiresAt: now.addingTimeInterval(300))
    }
}

@MainActor
private final class InvalidDiagnosticChallengeTransport: ContinuationHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        return (Data("{}".utf8), try #require(HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])))
    }
}
