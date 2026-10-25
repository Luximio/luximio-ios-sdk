import CryptoKit
import Foundation
import Testing
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CustomerRecoveryBackendTests {
    @Test func anOlderUnfinishableAcknowledgementCannotStarveANewCustomerRecovery() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = fixture.now
        let nativeKeys = RecoveryJourneyNativeKeys(keyID: fixture.keyID)
        let provider = RecoveryJourneyTestProvider(keys: nativeKeys)
        let server = RecoveryJourneyTestTransport(fixture: fixture, now: now)
        let journal = try ContinuationJournal(containerURL: directory)
        let clipBackend = try CustomerRecoveryBackend(configuration: fixture.configuration, containerURL: directory,
            appAttest: provider, transport: server, now: { now })
        let clip = try LuximioClipLinks(configuration: fixture.configuration, journal: journal, backend: clipBackend,
            bundleIdentifier: fixture.configuration.scope.clipBundleID, now: { now })
        let url = try #require(URL(string: fixture.invocation().originalURL))
        let oldReceipt = try await clip.capture(url)
        try journal.cancelPending()
        let oldAcknowledgement = try #require(try journal.acknowledgements().first)
        let parentConfiguration = LinksConfiguration(scope: fixture.configuration.scope, role: .fullApp,
            trustedHosts: fixture.configuration.trustedHosts, appGroupIdentifier: fixture.configuration.appGroupIdentifier)
        let parentBackend = try CustomerRecoveryBackend(configuration: parentConfiguration, containerURL: directory,
            appAttest: provider, transport: server, now: { now })
        nativeKeys.rejectedKeys.insert(fixture.keyID)
        await #expect(throws: LinkFailure.unverifiedContext) {
            try await parentBackend.acknowledge(oldAcknowledgement, receipt: oldReceipt)
        }
        let currentReceipt = try await clip.capture(url)
        try #require(nativeKeys.generated == 2, "The new capture must have a different usable native key.")
        let gate = RecoveryJourneyRequestGate()
        server.gatedAcknowledgementBearer = oldReceipt.invocation.token
        server.acknowledgementGate = gate
        let readiness = RecoveryJourneyReadiness()
        let parent = try LuximioLinks(configuration: parentConfiguration, journal: journal, backend: parentBackend,
            bundleIdentifier: parentConfiguration.scope.fullAppBundleID, now: { now }, route: { delivery in
                guard readiness.accountSelected else { return .hold }
                readiness.deliveries.append(delivery)
                return .applied
            }, diagnostic: { readiness.diagnostics.append($0) })

        let heldWork = try #require(parent.resume(.activation))
        await heldWork.value
        #expect(try journal.pending()?.phase == .held,
                "A current receipt must reach its readiness hold while an older completion cannot finish.")
        #expect(readiness.diagnostics.contains(.retryAvailable(.busy)) == false,
                "An old completion must not take the shared proof lease ahead of current recovery.")
        gate.release()
        await parent.waitUntilIdle()
        #expect(try journal.acknowledgements().contains(oldAcknowledgement))

        gate.reset()
        readiness.accountSelected = true
        let appliedWork = try #require(parent.resume(.userRetry))
        await appliedWork.value
        #expect(readiness.deliveries.map(\.id) == [currentReceipt.deliveryID],
                "Retry must apply the current action without requiring the old completion to clear first.")
        #expect(try journal.entry(id: currentReceipt.invocation.id)?.phase == .applied)
        gate.release()
        await parent.waitUntilIdle()
        #expect(try journal.acknowledgements() == [oldAcknowledgement],
                "Keep the old operation queued, but clear the current delivery's successful completion.")
    }

    @Test func aNewCaptureDuringAnAcknowledgementStopsTheNextOldOperationWithoutCancellingTheInflightProof() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = fixture.now
        let keys = RecoveryJourneyNativeKeys(keyID: fixture.keyID)
        let provider = RecoveryJourneyTestProvider(keys: keys)
        let server = RecoveryJourneyTestTransport(fixture: fixture, now: now)
        let journal = try ContinuationJournal(containerURL: directory)
        let clipBackend = try CustomerRecoveryBackend(configuration: fixture.configuration, containerURL: directory,
            appAttest: provider, transport: server, now: { now })
        let clip = try LuximioClipLinks(configuration: fixture.configuration, journal: journal, backend: clipBackend,
            bundleIdentifier: fixture.configuration.scope.clipBundleID, now: { now })
        let url = try #require(URL(string: fixture.invocation().originalURL))
        let firstReceipt = try await clip.capture(url)
        try journal.cancelPending()
        _ = try await clip.capture(url)
        try journal.cancelPending()
        let olderOperations = try journal.acknowledgements()
        try #require(olderOperations.count == 2)
        let gate = RecoveryJourneyRequestGate()
        server.gatedAcknowledgementBearer = firstReceipt.invocation.token
        server.acknowledgementGate = gate
        let parentConfiguration = LinksConfiguration(scope: fixture.configuration.scope, role: .fullApp,
            trustedHosts: fixture.configuration.trustedHosts, appGroupIdentifier: fixture.configuration.appGroupIdentifier)
        let backend = try CustomerRecoveryBackend(configuration: parentConfiguration, containerURL: directory,
            appAttest: provider, transport: server, now: { now })
        var deliveries: [LinkDelivery] = []
        let parent = try LuximioLinks(configuration: parentConfiguration, journal: journal, backend: backend,
            bundleIdentifier: parentConfiguration.scope.fullAppBundleID, now: { now }, route: {
                deliveries.append($0)
                return .applied
            })

        parent.resume(.activation)
        await gate.waitUntilEntered()
        // The Clip saves its invocation before requesting the same proof lease.
        // That already-started old operation keeps its lease until it finishes.
        await #expect(throws: LinkFailure.busy) { try await clip.capture(url) }
        let current = try #require(try journal.pending())
        try #require(current.phase == .captured)
        gate.release()
        await parent.waitUntilIdle()

        #expect(server.acknowledgementCount == 1, "Finish the in-flight proof, but defer the next old operation.")
        #expect(try journal.acknowledgements() == [olderOperations[1]])
        #expect(try journal.pending()?.invocation == current.invocation)
        let receipt = try await clip.retryCapture()
        #expect(receipt.invocation == current.invocation)
        parent.resume(.userRetry)
        await parent.waitUntilIdle()
        #expect(deliveries.map(\.id) == [receipt.deliveryID])
        #expect(try journal.acknowledgements().isEmpty,
                "The early-return cleanup must permit later serial completion of old and current operations.")
        #expect(server.acknowledgementCount == 3)
    }

    @Test(arguments: [0.123456, 0.123456789, 0.999999])
    func aRealCustomerAdapterRecoversHeldContextAfterReadinessAndParentRestart(fractionalSeconds: Double) async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_800_000_000 + fractionalSeconds)
        let nativeKeys = RecoveryJourneyNativeKeys(keyID: fixture.keyID)
        let server = RecoveryJourneyTestTransport(fixture: fixture, now: now)
        let clipJournal = try ContinuationJournal(containerURL: directory)
        let clipBackend = try CustomerRecoveryBackend(configuration: fixture.configuration, containerURL: directory,
            appAttest: RecoveryJourneyTestProvider(keys: nativeKeys), transport: server, now: { now })
        let clip = try LuximioClipLinks(configuration: fixture.configuration, journal: clipJournal,
            backend: clipBackend, bundleIdentifier: fixture.configuration.scope.clipBundleID, now: { now })
        let originalURL = try #require(URL(string: fixture.invocation().originalURL))
        let captured = try await clip.capture(originalURL)
        let parentConfiguration = LinksConfiguration(scope: fixture.configuration.scope, role: .fullApp,
            trustedHosts: fixture.configuration.trustedHosts, appGroupIdentifier: fixture.configuration.appGroupIdentifier)
        let readiness = RecoveryJourneyReadiness()

        func parent() throws -> LuximioLinks {
            // New objects model a new parent process; only the persisted journal,
            // shared vault and explicitly fake native key service survive.
            let backend = try CustomerRecoveryBackend(configuration: parentConfiguration, containerURL: directory,
                appAttest: RecoveryJourneyTestProvider(keys: nativeKeys), transport: server, now: { now })
            return try LuximioLinks(configuration: parentConfiguration,
                journal: ContinuationJournal(containerURL: directory), backend: backend,
                bundleIdentifier: parentConfiguration.scope.fullAppBundleID, now: { now },
                route: { delivery in
                    guard readiness.onboardingComplete, readiness.accountSelected else { return .hold }
                    readiness.deliveries.append(delivery)
                    return .applied
                }, diagnostic: { readiness.diagnostics.append($0) })
        }

        let first = try parent()
        first.resume(.activation)
        await first.waitUntilIdle()
        try #require(try clipJournal.pending()?.phase == .held)
        readiness.onboardingComplete = true
        first.resume(.readinessChanged)
        await first.waitUntilIdle()
        try #require(try clipJournal.pending()?.phase == .held)
        first.resume(.activation)
        await first.waitUntilIdle()
        #expect(readiness.deliveries.isEmpty)

        readiness.onboardingComplete = false
        let restarted = try parent()
        restarted.resume(.activation)
        await restarted.waitUntilIdle()
        try #require(try clipJournal.pending()?.phase == .held)
        readiness.onboardingComplete = true
        restarted.resume(.readinessChanged)
        await restarted.waitUntilIdle()
        try #require(try clipJournal.pending()?.phase == .held)
        readiness.accountSelected = true
        restarted.resume(.readinessChanged)
        await restarted.waitUntilIdle()

        #expect(readiness.deliveries.map(\.id) == [captured.deliveryID],
                "The held customer receipt must navigate after restart, onboarding and account selection.")
        #expect(readiness.deliveries.first?.originalURL == originalURL.absoluteString)
        #expect(readiness.deliveries.first?.destination == captured.destination)
        #expect(try clipJournal.entry(id: captured.invocation.id)?.phase == .applied)
        #expect(try clipJournal.acknowledgements().isEmpty)
        #expect(nativeKeys.generated == 1, "A parent restart must retain the exact Clip capture key.")
        #expect(server.resolveCount == 4)
        #expect(server.acknowledgementCount == 1)

        let completed = try parent()
        completed.resume(.activation)
        await completed.waitUntilIdle()
        #expect(readiness.deliveries.count == 1, "A completed continuation must not replay on another launch.")
    }

    @Test func actualAdapterRegistersSignsPinsAndAcknowledgesAcrossParentRestart() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        let invocation = try fixture.invocation()
        let clip = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let receipt = try await clip.create(invocation)
        #expect(receipt.invocation == invocation)
        #expect(provider.generated == 1)
        #expect(provider.attestations.count == 1)
        let parentConfiguration = LinksConfiguration(scope: fixture.configuration.scope, role: .fullApp,
            trustedHosts: fixture.configuration.trustedHosts, appGroupIdentifier: fixture.configuration.appGroupIdentifier)
        let now = fixture.now
        let parent = try CustomerRecoveryBackend(configuration: parentConfiguration, containerURL: directory,
            appAttest: provider, transport: server, now: { now })
        #expect(try await parent.resolve(receipt) == receipt)
        try await parent.acknowledge(fixture.acknowledgement(), receipt: receipt)
        #expect(provider.generated == 1, "The parent must recover the Clip's immutable key pin.")
        #expect(provider.assertions.count == 3)
        #expect(provider.assertions == server.operationClientData.map { Data(SHA256.hash(data: $0)) })
        let registration = try #require(server.requests.first { $0.url?.path == "/api/v1/recovery/register" })
        #expect(registration.value(forHTTPHeaderField: "Authorization") != "Bearer " + fixture.bearer)
        for request in server.requests {
            #expect(request.url?.host == fixture.origin.host)
            #expect(request.url?.query == nil)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.httpShouldHandleCookies == false)
            let body = try #require(request.httpBody)
            #expect(body.count <= 65_536)
            #expect(body.range(of: Data(fixture.bearer.utf8)) == nil)
        }
    }

    @Test func maliciousChallengeCannotReachDeviceAttestation() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        server.badChallenge = true
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        await #expect(throws: LinkFailure.invalidData) { try await client.create(fixture.invocation()) }
        #expect(provider.attestations.isEmpty)
        #expect(provider.assertions.isEmpty)
        #expect(server.requests.allSatisfy { $0.url?.path == "/api/v1/recovery/challenges" })
    }

    @Test func changedReceiptIsRejectedAfterProofAndExactCreateRetryKeepsKey() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let invocation = try fixture.invocation()
        let receipt = try await client.create(invocation)
        #expect(try await client.create(invocation) == receipt)
        #expect(provider.generated == 1)
        server.changedReceipt = true
        await #expect(throws: LinkFailure.changedDestination) { try await client.resolve(receipt) }
    }

    @Test func serverUnverifiedAndExpiredMapWithoutSilentlyReplacingPinnedKey() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let receipt = try await client.create(fixture.invocation())
        server.rejection = ("unverified", 401)
        await #expect(throws: LinkFailure.unverifiedContext) { try await client.resolve(receipt) }
        server.rejection = ("expired", 410)
        await #expect(throws: LinkFailure.expired) { try await client.resolve(receipt) }
        #expect(provider.generated == 1)
    }

    @Test func cancellationAfterChallengeResponseDoesNotContinueToProvider() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        server.cancelAfterResponse = true
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let task = Task { @MainActor in try await client.create(fixture.invocation()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.attestations.isEmpty)
        #expect(provider.assertions.isEmpty)
    }

    @Test func directLinksUseExistingResolverWithoutAppAttest() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let destination = try await client.resolveDirect(#require(URL(string: fixture.invocation().originalURL)))
        #expect(destination.route == "catalog/detail")
        #expect(provider.generated == 0)
        #expect(server.requests.count == 1)
        #expect(server.requests[0].httpMethod == "GET")
        #expect(server.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func invalidInvocationIsRejectedBeforeAnyNativeOrNetworkWork() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        let invocation = try fixture.invocation()
        let invalid = CapturedInvocation(id: invocation.id, operationID: invocation.operationID, token: invocation.token,
            originalURL: invocation.originalURL + "#fragment", capturedAt: invocation.capturedAt,
            expiresAt: invocation.expiresAt, scope: invocation.scope)
        await #expect(throws: LinkFailure.wrongScope) { try await client.create(invalid) }
        #expect(server.requests.isEmpty)
        #expect(provider.generated == 0)
    }

    @Test(arguments: ["oversized", "contentLength", "differentURL", "mime", "redirect", "badJSON"])
    func invalidTransportResponseCannotReachNativeEvidence(_ mutation: String) async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        server.responseMutation = mutation
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        await #expect(throws: LinkFailure.invalidData) { try await client.create(fixture.invocation()) }
        #expect(provider.generated == 0)
        #expect(provider.assertions.isEmpty)
    }

    @Test func customerAcceptsBoundedResponsesAbovePrivateLimit() async throws {
        let fixture = try RecoveryWireTestFixture()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = RecoveryBackendTestProvider(keyID: fixture.keyID)
        let server = RecoveryBackendTestTransport(fixture: fixture)
        server.paddingBytes = 16_384
        let client = try backend(fixture: fixture, directory: directory, provider: provider, transport: server)
        #expect(try await client.create(fixture.invocation()).canonicalLinkID == "link_customer_recovery_wire_v1")
    }

    private func backend(fixture: RecoveryWireTestFixture, directory: URL, provider: RecoveryBackendTestProvider,
                         transport: RecoveryBackendTestTransport) throws -> CustomerRecoveryBackend {
        let date = fixture.now
        return try CustomerRecoveryBackend(configuration: fixture.configuration, containerURL: directory,
            appAttest: provider, transport: transport, now: { date })
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("customer-backend-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

@MainActor
private final class RecoveryJourneyReadiness {
    var onboardingComplete = false
    var accountSelected = false
    var deliveries: [LinkDelivery] = []
    var diagnostics: [LinkDiagnostic] = []
}

/// These wrappers deliberately model process recreation around one fake native
/// key service. They do not claim to validate Apple's real key migration.
@MainActor
private final class RecoveryJourneyNativeKeys {
    let keyID: String
    var generated = 0
    var generatedKeys: Set<String> = []
    var rejectedKeys: Set<String> = []
    var assertionCounters: [String: UInt32] = [:]
    init(keyID: String) { self.keyID = keyID }
}

@MainActor
private final class RecoveryJourneyTestProvider: RecoveryAppAttestProviding {
    let isSupported = true
    let keys: RecoveryJourneyNativeKeys
    init(keys: RecoveryJourneyNativeKeys) { self.keys = keys }
    func generateKey() async throws -> String {
        keys.generated += 1
        let keyID = keys.generated == 1 ? keys.keyID : Data(repeating: UInt8(keys.generated), count: 32).base64EncodedString()
        keys.generatedKeys.insert(keyID)
        return keyID
    }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try #require(keys.generatedKeys.contains(keyID))
        return Data([1, 2, 3])
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try #require(keys.generatedKeys.contains(keyID))
        if keys.rejectedKeys.contains(keyID) { throw RecoveryAppAttestFailure.rejected }
        let next = (keys.assertionCounters[keyID] ?? 0) + 1
        keys.assertionCounters[keyID] = next
        var counter = next.bigEndian
        return withUnsafeBytes(of: &counter) { Data($0) } + clientDataHash
    }
}

/// A bounded, deterministic protocol fake: unique challenges are consumed once,
/// assertion hashes and monotonically increasing counters are checked, and the
/// receipt echoes the actual Clip capture rather than a preselected invocation.
@MainActor
private final class RecoveryJourneyTestTransport: ContinuationHTTPTransport {
    private struct Challenge {
        let purpose: String
        let payloadHash: String
        let tokenHash: String
        let clientData: Data
    }
    let fixture: RecoveryWireTestFixture
    let now: Date
    private var challenges: [String: Challenge] = [:]
    private var nextChallenge = 0
    private var serverCounters: [String: UInt32] = [:]
    private var registeredKeys: Set<String> = []
    private var prepared: [String: [String: Any]] = [:]
    private var createdReceipts = 0
    var gatedAcknowledgementBearer: String?
    var acknowledgementGate: RecoveryJourneyRequestGate?
    private(set) var resolveCount = 0
    private(set) var acknowledgementCount = 0

    init(fixture: RecoveryWireTestFixture, now: Date) { self.fixture = fixture; self.now = now }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let body = try #require(request.httpBody)
        let envelope = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let payload = try #require(envelope["payload"] as? [String: Any])
        let bearer = try #require(request.value(forHTTPHeaderField: "Authorization")).replacingOccurrences(of: "Bearer ", with: "")
        let nowMS = try CustomerRecoveryWire.milliseconds(now)
        let response: [String: Any]
        var status = 200
        if url.path.hasSuffix("/challenges") {
            nextChallenge += 1
            let id = String(format: "66666666-6666-4666-8666-%012d", nextChallenge)
            let purpose = try #require(payload["purpose"] as? String)
            if purpose == "acknowledge", bearer == gatedAcknowledgementBearer {
                await acknowledgementGate?.suspend()
            }
            let payloadHash = try #require(payload["payloadHash"] as? String)
            let nonce = Data(repeating: 0, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let binding: [String: Any] = ["version": 1, "challengeID": id, "challenge": nonce,
                "projectID": fixture.configuration.scope.projectID, "hostname": try #require(fixture.origin.host),
                "channel": "ios_app_clip", "identityHash": String(repeating: "a", count: 64),
                "origin": fixture.origin.absoluteString, "method": "POST",
                "path": purpose == "create" ? "/api/v1/recovery" : "/api/v1/recovery/" + purpose,
                "purpose": purpose, "payloadHash": payloadHash,
                "tokenHash": CustomerRecoveryWire.hash(Data(bearer.utf8)), "createdAt": nowMS, "expiresAt": nowMS + 300_000]
            let data = try canonical(binding)
            challenges[id] = Challenge(purpose: purpose, payloadHash: payloadHash,
                tokenHash: CustomerRecoveryWire.hash(Data(bearer.utf8)), clientData: data)
            response = ["version": 1, "result": "challenge", "challengeID": id,
                "challenge": nonce, "clientData": data.base64EncodedString(), "expiresAt": nowMS + 300_000]
            status = 201
        } else {
            let proof = try #require(envelope["proof"] as? [String: Any])
            let challengeID = try #require(proof["challengeID"] as? String)
            let issued = challenges.removeValue(forKey: challengeID)
            let challenge = try #require(issued, "Challenges are single-use.")
            let payloadHash = try CustomerRecoveryWire.hash(canonical(payload))
            try #require(challenge.payloadHash == payloadHash)
            try #require(challenge.tokenHash == CustomerRecoveryWire.hash(Data(bearer.utf8)))
            if url.path.hasSuffix("/register") {
                try #require(challenge.purpose == "register")
                let keyID = try #require(payload["keyID"] as? String)
                registeredKeys.insert(keyID)
                response = ["version": 1, "result": "registered", "keyID": keyID,
                    "expiresAt": nowMS + 30 * 24 * 60 * 60 * 1_000]
                status = 201
            } else {
                let keyID = try #require(proof["keyID"] as? String)
                try #require(registeredKeys.contains(keyID))
                let encodedAssertion = try #require(proof["assertionObject"] as? String)
                let assertion = try #require(Data(base64Encoded: encodedAssertion))
                try #require(assertion.count == 36)
                let counter = assertion.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                try #require(counter > (serverCounters[keyID] ?? 0))
                try #require(assertion.dropFirst(4) == Data(SHA256.hash(data: challenge.clientData)))
                serverCounters[keyID] = counter
                if url.path.hasSuffix("/acknowledge") {
                    try #require(challenge.purpose == "acknowledge")
                    acknowledgementCount += 1
                    var echoed = payload
                    echoed["scope"] = nil
                    echoed["result"] = "acknowledged"
                    response = echoed
                } else if url.path.hasSuffix("/resolve") {
                    try #require(challenge.purpose == "resolve")
                    resolveCount += 1
                    let receiptID = try #require(payload["receiptID"] as? String)
                    response = try #require(prepared[receiptID])
                } else {
                    try #require(challenge.purpose == "create")
                    var value = try #require(fixture.object["prepared"] as? [String: Any])
                    var receipt = try #require(value["receipt"] as? [String: Any])
                    createdReceipts += 1
                    let receiptID = String(format: "33333333-3333-4333-8333-%012d", createdReceipts)
                    receipt["id"] = receiptID
                    receipt["deliveryID"] = String(format: "44444444-4444-4444-8444-%012d", createdReceipts)
                    let invocation = try #require(payload["invocation"] as? [String: Any])
                    receipt["invocation"] = invocation
                    let expiry = try #require(invocation["expiresAt"] as? Int64)
                    receipt["expiresAt"] = expiry
                    value["receipt"] = receipt
                    prepared[receiptID] = value
                    response = value
                    status = 201
                }
            }
        }
        return (try JSONSerialization.data(withJSONObject: response),
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])))
    }

    private func canonical(_ object: [String: Any]) throws -> Data {
        try JSONDecoder().decode(CustomerRecoveryJSON.self, from: JSONSerialization.data(withJSONObject: object)).encoded()
    }
}

@MainActor
private final class RecoveryJourneyRequestGate {
    private var isOpen = false
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func suspend() async {
        guard !isOpen else { return }
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { waiting = $0 }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        isOpen = true
        let continuation = waiting
        waiting = nil
        continuation?.resume()
    }

    func reset() {
        precondition(waiting == nil)
        isOpen = false
        entered = false
    }
}

@MainActor
private final class RecoveryBackendTestProvider: RecoveryAppAttestProviding {
    var isSupported = true
    let keyID: String
    var generated = 0
    var attestations: [Data] = []
    var assertions: [Data] = []
    init(keyID: String) { self.keyID = keyID }
    func generateKey() async throws -> String { generated += 1; return keyID }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        #expect(keyID == self.keyID)
        attestations.append(clientDataHash)
        return Data([1, 2, 3])
    }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        #expect(keyID == self.keyID)
        assertions.append(clientDataHash)
        return Data([4, 5, UInt8(assertions.count)])
    }
}

@MainActor
private final class RecoveryBackendTestTransport: ContinuationHTTPTransport {
    let fixture: RecoveryWireTestFixture
    var requests: [URLRequest] = []
    var operationClientData: [Data] = []
    var badChallenge = false
    var changedReceipt = false
    var cancelAfterResponse = false
    var responseMutation: String?
    var paddingBytes = 0
    var rejection: (String, Int)?
    init(fixture: RecoveryWireTestFixture) { self.fixture = fixture }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let url = try #require(request.url)
        var status = 200
        var body: Data
        if url.path == "/api/resolve" {
            let prepared = try #require(fixture.object["prepared"] as? [String: Any])
            let receipt = try #require(prepared["receipt"] as? [String: Any])
            body = try JSONSerialization.data(withJSONObject: ["path": "catalog/item", "destination": ["app": #require(receipt["destination"])]])
        } else {
            let requestBody = try #require(request.httpBody)
            let envelope = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
            let payload = try #require(envelope["payload"] as? [String: Any])
            if url.path.hasSuffix("/challenges") {
                let purpose = try #require(payload["purpose"] as? String)
                let payloadHash = try #require(payload["payloadHash"] as? String)
                let bearer = try #require(request.value(forHTTPHeaderField: "Authorization")).replacingOccurrences(of: "Bearer ", with: "")
                body = try fixture.challenge(purpose: purpose, payload: Data(), bearer: bearer, mutateBinding: { binding in
                    binding["payloadHash"] = self.badChallenge ? String(repeating: "f", count: 64) : payloadHash
                })
                if purpose != "register" {
                    let response = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let encoded = try #require(response["clientData"] as? String)
                    operationClientData.append(try #require(Data(base64Encoded: encoded)))
                }
                status = 201
            } else if url.path.hasSuffix("/register") {
                body = try JSONSerialization.data(withJSONObject: ["version": 1, "result": "registered",
                    "keyID": #require(payload["keyID"] as? String), "expiresAt": fixture.nowMS + 30 * 24 * 60 * 60 * 1_000])
                status = 201
            } else if let rejection {
                body = try JSONSerialization.data(withJSONObject: ["version": 1, "result": "rejected", "reason": rejection.0])
                status = rejection.1
            } else if url.path.hasSuffix("/acknowledge") {
                body = try fixture.data("acknowledged")
            } else {
                var prepared = try #require(fixture.object["prepared"] as? [String: Any])
                if changedReceipt {
                    var receipt = try #require(prepared["receipt"] as? [String: Any])
                    receipt["canonicalLinkID"] = "different-link"
                    prepared["receipt"] = receipt
                }
                body = try JSONSerialization.data(withJSONObject: prepared)
            }
        }
        var responseURL = url
        var headers = ["Content-Type": "application/json"]
        switch responseMutation {
        case "oversized": body = Data(repeating: 32, count: 65_537)
        case "contentLength": headers["Content-Length"] = "65537"
        case "differentURL": responseURL = try #require(URL(string: "https://wrong.example.com/api/v1/recovery/challenges"))
        case "mime": headers["Content-Type"] = "text/html"
        case "redirect": status = 307
        case "badJSON": body = Data("{".utf8)
        default: break
        }
        body.append(Data(repeating: 32, count: paddingBytes))
        if cancelAfterResponse { withUnsafeCurrentTask { $0?.cancel() } }
        return (body, try #require(HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)))
    }
}
