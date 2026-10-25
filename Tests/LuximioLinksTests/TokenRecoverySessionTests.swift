import Foundation
import Testing
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TokenRecoverySessionTests {
    @Test func tokenJournalIsSeparateAndOldAttestedStateCannotReachTheNewEndpoint() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let old = try ContinuationJournal(containerURL: fixture.directory)
        let invocation = try fixture.wire.invocation()
        try old.capture(invocation)
        let oldBytes = try Data(contentsOf: fixture.directory.appendingPathComponent("SDKPrototype-v2/journal-v2.json"))
        let vault = fixture.directory.appendingPathComponent("CustomerRecovery-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false)
        let sentinel = vault.appendingPathComponent("key-vault.json")
        try Data("existing-attested-vault".utf8).write(to: sentinel)

        let session = try fixture.session()
        #expect(try session.journal.pending() == nil)
        await #expect(throws: LinkFailure.unverifiedContext) { try await session.backend.create(invocation) }
        #expect(fixture.server.requests.isEmpty)
        #expect(try Data(contentsOf: sentinel) == Data("existing-attested-vault".utf8))
        #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("SDKPrototype-v2/journal-v2.json")) == oldBytes)
    }

    @Test func actualTokenAdapterPreservesHoldsAcrossRestartThenAppliesAcknowledgesAndDoesNotReplay() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let clipSession = try fixture.session()
        let clip = try LuximioClipLinks(configuration: fixture.configuration(), journal: clipSession.journal,
            backend: clipSession.backend, bundleIdentifier: fixture.wire.configuration.scope.clipBundleID,
            now: { fixture.wire.now })
        let captured = try await clip.capture(fixture.url())
        let readiness = TokenReadiness()
        let first = try fixture.parent(readiness: readiness)
        first.resume(.activation)
        await first.waitUntilIdle()
        #expect(try clipSession.journal.pending()?.phase == .held)
        readiness.onboarding = true
        first.resume(.readinessChanged)
        await first.waitUntilIdle()
        #expect(readiness.deliveries.isEmpty)
        let restarted = try fixture.parent(readiness: readiness)
        restarted.resume(.activation)
        await restarted.waitUntilIdle()
        #expect(try clipSession.journal.pending()?.phase == .held)
        readiness.account = true
        restarted.resume(.readinessChanged)
        await restarted.waitUntilIdle()
        #expect(readiness.deliveries.map(\.id) == [captured.deliveryID])
        #expect(readiness.deliveries.first?.originalURL == captured.invocation.originalURL)
        #expect(try clipSession.journal.pending() == nil)
        #expect(try clipSession.journal.acknowledgements().isEmpty)
        #expect(fixture.server.terminalOutcomes == [.applied])
        let completed = try fixture.parent(readiness: readiness)
        completed.resume(.activation)
        await completed.waitUntilIdle()
        #expect(readiness.deliveries.count == 1)
        #expect(fixture.server.requests.allSatisfy { ["/api/v1/token-recovery", "/api/v1/token-recovery/resolve", "/api/v1/token-recovery/acknowledge"].contains($0.url?.path ?? "") })
    }

    @Test func aLostCreateResponseRetainsTheSameCapabilityOperationAndDeadline() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let clip = try LuximioClipLinks(configuration: fixture.configuration(), journal: session.journal,
            backend: session.backend, bundleIdentifier: fixture.wire.configuration.scope.clipBundleID,
            now: { fixture.wire.now })
        fixture.server.loseNextCreate = true
        await #expect(throws: LinkFailure.network) { try await clip.capture(fixture.url()) }
        let saved = try #require(try session.journal.pending())
        let firstRequest = try #require(fixture.server.requests.first)
        let receipt = try await clip.retryCapture()
        #expect(receipt.invocation == saved.invocation)
        #expect(fixture.server.requests.count == 2)
        #expect(fixture.server.requests.last?.httpBody == firstRequest.httpBody)
        #expect(fixture.server.requests.last?.allHTTPHeaderFields == firstRequest.allHTTPHeaderFields)
        #expect(fixture.server.createdCount == 1)
    }

    @Test func offlineResolveAndManualCancellationKeepTheOriginalTokenAndNeverReviveARejectedAction() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let clip = try LuximioClipLinks(configuration: fixture.configuration(), journal: session.journal,
            backend: session.backend, bundleIdentifier: fixture.wire.configuration.scope.clipBundleID,
            now: { fixture.wire.now })
        let captured = try await clip.capture(fixture.url())
        let readiness = TokenReadiness()
        readiness.onboarding = true
        readiness.account = true
        fixture.server.offline = true
        let parent = try fixture.parent(readiness: readiness)
        parent.resume(.activation)
        await parent.waitUntilIdle()
        #expect(readiness.deliveries.isEmpty)
        #expect(try session.journal.pending()?.receipt == captured)
        fixture.server.offline = false
        parent.resume(.userRetry)
        await parent.waitUntilIdle()
        #expect(readiness.deliveries.map(\.id) == [captured.deliveryID])
        let next = try await clip.capture(fixture.url())
        try parent.cancelPending()
        await parent.waitUntilIdle()
        let reopened = try fixture.parent(readiness: readiness)
        reopened.resume(.activation)
        await reopened.waitUntilIdle()
        #expect(readiness.deliveries.count == 1)
        #expect(try session.journal.entry(id: next.invocation.id)?.phase == .discarded)
        #expect(fixture.server.terminalOutcomes == [.applied, .discarded])
    }

    @Test(arguments: ["changed", "revoked"])
    func changedOrRevokedContextsRemainTerminalEvenWhenServerConfigurationReturns(reason: String) async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let clip = try LuximioClipLinks(configuration: fixture.configuration(), journal: session.journal,
            backend: session.backend, bundleIdentifier: fixture.wire.configuration.scope.clipBundleID,
            now: { fixture.wire.now })
        let captured = try await clip.capture(fixture.url())
        fixture.server.resolveRejection = reason
        let readiness = TokenReadiness()
        readiness.onboarding = true
        readiness.account = true
        let parent = try fixture.parent(readiness: readiness)
        parent.resume(.activation)
        await parent.waitUntilIdle()
        #expect(readiness.deliveries.isEmpty)
        #expect(try session.journal.entry(id: captured.invocation.id)?.phase == .discarded)
        fixture.server.resolveRejection = nil
        parent.resume(.userRetry)
        await parent.waitUntilIdle()
        #expect(readiness.deliveries.isEmpty)
        #expect(fixture.server.terminalOutcomes == [.discarded])
    }

    @Test func everyRequestUsesTheNewOriginAndNullProofWithHeaderOnlyCanonicalBearer() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let invocation = try fixture.wire.invocation()
        try session.journal.capture(invocation)
        _ = try await session.backend.create(invocation)
        let request = try #require(fixture.server.requests.first)
        #expect(request.url?.absoluteString == fixture.wire.origin.absoluteString + "/api/v1/token-recovery")
        #expect(request.timeoutInterval == 10)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        let body = try #require(request.httpBody)
        #expect(body.range(of: Data(invocation.token.utf8)) == nil)
        let envelope = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(envelope.keys) == ["payload", "proof"])
        #expect(envelope["proof"] is NSNull)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + invocation.token)
    }

    @Test(arguments: ["unknown-field", "oversize", "redirect", "wrong-mime", "wrong-ack"])
    func malformedResponsesCannotBecomeTrustedReceiptsOrCompletions(fault: String) async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let invocation = try fixture.wire.invocation()
        try session.journal.capture(invocation)
        if fault == "wrong-ack" {
            let receipt = try await session.backend.create(invocation)
            _ = try session.journal.pin(receipt)
            _ = try session.journal.transition(id: invocation.id, from: .pinned, to: .applying)
            _ = try session.journal.transition(id: invocation.id, from: .applying, to: .applied)
            let acknowledgement = try #require(try session.journal.acknowledgements().first)
            fixture.server.responseFault = fault
            await #expect(throws: LinkFailure.invalidData) { try await session.backend.acknowledge(acknowledgement, receipt: receipt) }
            #expect(try session.journal.acknowledgements().count == 1)
        } else {
            fixture.server.responseFault = fault
            await #expect(throws: LinkFailure.invalidData) { try await session.backend.create(invocation) }
            #expect(try session.journal.pending()?.phase == .captured)
        }
    }

    @Test func wrongScopeAndNoncanonicalBearersAreRejectedBeforeTransport() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let value = try fixture.wire.invocation()
        let wrong = CapturedInvocation(id: value.id, operationID: value.operationID, token: value.token,
            originalURL: value.originalURL, capturedAt: value.capturedAt, expiresAt: value.expiresAt,
            scope: LinkScope(projectID: "other-project", fullAppBundleID: value.scope.fullAppBundleID,
                             clipBundleID: value.scope.clipBundleID))
        await #expect(throws: LinkFailure.wrongScope) { try await session.backend.create(wrong) }
        let malformed = CapturedInvocation(id: value.id, operationID: value.operationID,
            token: String(repeating: "_", count: 43), originalURL: value.originalURL,
            capturedAt: value.capturedAt, expiresAt: value.expiresAt, scope: value.scope)
        await #expect(throws: LinkFailure.invalidData) { try await session.backend.create(malformed) }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func cancellationIsPreservedAndAnotherProjectGetsItsOwnJournal() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let invocation = try fixture.wire.invocation()
        try session.journal.capture(invocation)
        fixture.server.cancelRequests = true
        await #expect(throws: CancellationError.self) { try await session.backend.create(invocation) }
        #expect(try session.journal.pending()?.invocation == invocation)
        let scope = LinkScope(projectID: "another-project", fullAppBundleID: invocation.scope.fullAppBundleID,
                              clipBundleID: invocation.scope.clipBundleID)
        let configuration = LinksConfiguration(scope: scope, role: .fullApp,
            trustedHosts: fixture.wire.configuration.trustedHosts, appGroupIdentifier: fixture.wire.configuration.appGroupIdentifier)
        let other = try TokenRecoverySession(configuration: configuration, containerURL: fixture.directory,
            transport: fixture.server, now: { fixture.wire.now })
        #expect(try other.journal.pending() == nil)
        #expect(try session.journal.pending()?.invocation == invocation)
    }

    @Test func unsupportedOrLinkedStorageFailsWithoutOpeningTheOldRoot() throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let invalid = LinksConfiguration(scope: fixture.wire.configuration.scope, role: .appClip,
            trustedHosts: ["UPPER.example.com"], appGroupIdentifier: fixture.wire.configuration.appGroupIdentifier)
        #expect(throws: LinkFailure.configuration) {
            try TokenRecoverySession(configuration: invalid, containerURL: fixture.directory,
                                     transport: fixture.server, now: { fixture.wire.now })
        }
        #expect(throws: LinkFailure.configuration) {
            try TokenRecoverySession(configuration: fixture.configuration(), containerURL: nil,
                                     transport: fixture.server, now: { fixture.wire.now })
        }
        let alias = fixture.directory.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        #expect(throws: LinkFailure.configuration) {
            try TokenRecoverySession(configuration: fixture.configuration(), containerURL: alias,
                                     transport: fixture.server, now: { fixture.wire.now })
        }
        let root = fixture.directory.appendingPathComponent("TokenRecovery-v1", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: fixture.directory)
        #expect(throws: LinkFailure.storage) { try fixture.session() }
        #expect(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("SDKPrototype-v2").path) == false)
    }

    @Test func aChangedHostPolicyGetsSeparateStateButHostOrderingDoesNot() throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let original = try fixture.session()
        let invocation = try fixture.wire.invocation()
        try original.journal.capture(invocation)
        let host = try #require(fixture.wire.origin.host)
        func configured(_ hosts: [String]) throws -> TokenRecoverySession {
            let configuration = LinksConfiguration(scope: fixture.wire.configuration.scope, role: .fullApp,
                trustedHosts: hosts, appGroupIdentifier: fixture.wire.configuration.appGroupIdentifier)
            return try TokenRecoverySession(configuration: configuration, containerURL: fixture.directory,
                transport: fixture.server, now: { fixture.wire.now })
        }
        let expanded = try configured([host, "additional.example.com"])
        #expect(try expanded.journal.pending() == nil)
        try expanded.journal.capture(invocation)
        let reordered = try configured(["additional.example.com", host])
        #expect(try reordered.journal.pending()?.invocation == invocation)
        let removed = try configured(["additional.example.com"])
        #expect(try removed.journal.pending() == nil)
        #expect(try original.journal.pending()?.invocation == invocation)
        #expect(fixture.server.requests.isEmpty)
    }

    @Test func noncanonicalOrUntrustedInvocationOriginsCannotSendCapabilities() async throws {
        let fixture = try TokenSessionFixture()
        defer { fixture.cleanup() }
        let session = try fixture.session()
        let base = try fixture.wire.invocation()
        let host = try #require(fixture.wire.origin.host)
        let urls = ["http://\(host)/north", "https://evil.example.com/north", "https://user@\(host)/north",
                    "https://\(host):443/north", "https://\(host)/north#fragment",
                    "https://\(host)/api/v1/token-recovery", "https://\(host)/a/%2e%2e/b", "https://\(host)//north"]
        for url in urls {
            let invocation = CapturedInvocation(id: UUID(), operationID: UUID(), token: base.token,
                originalURL: url, capturedAt: base.capturedAt, expiresAt: base.expiresAt, scope: base.scope)
            // Structurally invalid URLs can already be rejected by the durable
            // journal. The adapter must also refuse them without transport.
            do { try session.journal.capture(invocation) }
            catch LinkFailure.invalidData { }
            await #expect(throws: LinkFailure.self) { try await session.backend.create(invocation) }
            if let entry = try session.journal.entry(id: invocation.id) { #expect(entry.phase == .captured) }
        }
        #expect(fixture.server.requests.isEmpty)
    }
}

@MainActor
private final class TokenReadiness {
    var onboarding = false
    var account = false
    var deliveries: [LinkDelivery] = []
}

@MainActor
private struct TokenSessionFixture {
    let directory: URL
    let wire: RecoveryWireTestFixture
    let server: TokenPairTransport

    init() throws {
        wire = try RecoveryWireTestFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("token-session-" + UUID().uuidString,
                                                                                 isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        server = TokenPairTransport(wire: wire)
    }

    func configuration(full: Bool = false) -> LinksConfiguration {
        LinksConfiguration(scope: wire.configuration.scope, role: full ? .fullApp : .appClip,
            trustedHosts: wire.configuration.trustedHosts, appGroupIdentifier: wire.configuration.appGroupIdentifier)
    }

    func session(full: Bool = false) throws -> TokenRecoverySession {
        try TokenRecoverySession(configuration: configuration(full: full), containerURL: directory,
                                 transport: server, now: { wire.now })
    }

    func url() throws -> URL { try #require(URL(string: wire.invocation().originalURL)) }

    func parent(readiness: TokenReadiness) throws -> LuximioLinks {
        let paired = try session(full: true)
        return try LuximioLinks(configuration: configuration(full: true), journal: paired.journal,
            backend: paired.backend, bundleIdentifier: wire.configuration.scope.fullAppBundleID,
            now: { wire.now }, route: { delivery in
                guard readiness.onboarding, readiness.account else { return .hold }
                readiness.deliveries.append(delivery)
                return .applied
            })
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Exercises the paired v1 envelope and stable capability/terminal semantics;
/// there is intentionally no native identity provider in this transport.
@MainActor
private final class TokenPairTransport: ContinuationHTTPTransport {
    let wire: RecoveryWireTestFixture
    private(set) var requests: [URLRequest] = []
    private(set) var createdCount = 0
    private(set) var terminalOutcomes: [Acknowledgement.Outcome] = []
    private var receipts: [String: [String: Any]] = [:]
    private var terminal: [String: [String: Any]] = [:]
    var loseNextCreate = false
    var offline = false
    var cancelRequests = false
    var resolveRejection: String?
    var responseFault: String?

    init(wire: RecoveryWireTestFixture) { self.wire = wire }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if cancelRequests { throw CancellationError() }
        if offline { throw URLError(.notConnectedToInternet) }
        let url = try #require(request.url)
        try #require(url.scheme == "https" && url.host == wire.origin.host)
        try #require(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let envelope = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        try #require(Set(envelope.keys) == ["payload", "proof"] && envelope["proof"] is NSNull)
        let payload = try #require(envelope["payload"] as? [String: Any])
        let bearer = try #require(request.value(forHTTPHeaderField: "Authorization"))
        try #require(bearer.hasPrefix("Bearer ") && body.range(of: Data(bearer.dropFirst(7).utf8)) == nil)
        let scope = try #require(payload["scope"] as? [String: String])
        try #require(scope == ["projectID": wire.configuration.scope.projectID, "channel": "ios_app_clip"])
        var response: [String: Any]
        var status = 200
        switch url.path {
        case "/api/v1/token-recovery":
            if let saved = receipts[bearer] { response = saved }
            else {
                let template = try #require(wire.object["prepared"] as? [String: Any])
                var receipt = try #require(template["receipt"] as? [String: Any])
                let invocation = try #require(payload["invocation"] as? [String: Any])
                createdCount += 1
                receipt["id"] = UUID().uuidString.lowercased()
                receipt["deliveryID"] = UUID().uuidString.lowercased()
                receipt["scope"] = scope
                receipt["invocation"] = invocation
                receipt["expiresAt"] = invocation["expiresAt"]
                response = ["version": 1, "result": "prepared", "receipt": receipt]
                receipts[bearer] = response
            }
            status = 201
            if loseNextCreate { loseNextCreate = false; throw URLError(.networkConnectionLost) }
        case "/api/v1/token-recovery/resolve":
            response = try #require(receipts[bearer])
            let receipt = try #require(response["receipt"] as? [String: Any])
            try #require(payload["receiptID"] as? String == receipt["id"] as? String)
            try #require(payload["deliveryID"] as? String == receipt["deliveryID"] as? String)
            if let reason = resolveRejection {
                response = ["version": 1, "result": "rejected", "reason": reason == "changed" ? "changedDestination" : "wrongScope"]
                status = reason == "changed" ? 409 : 403
            }
        case "/api/v1/token-recovery/acknowledge":
            let saved = try #require(receipts[bearer])
            let receipt = try #require(saved["receipt"] as? [String: Any])
            try #require(payload["receiptID"] as? String == receipt["id"] as? String)
            try #require(payload["deliveryID"] as? String == receipt["deliveryID"] as? String)
            response = payload
            response["scope"] = nil
            response["result"] = "acknowledged"
            if terminal[bearer] == nil {
                terminal[bearer] = response
                let outcome = try #require(payload["outcome"] as? String)
                terminalOutcomes.append(try #require(Acknowledgement.Outcome(rawValue: outcome)))
            }
        default:
            Issue.record("The token adapter attempted an unsupported protocol path")
            throw LinkFailure.invalidData
        }
        if responseFault == "unknown-field" { response["unexpectedAuthority"] = true }
        if responseFault == "wrong-ack" { response["operationID"] = UUID().uuidString.lowercased() }
        let data = responseFault == "oversize" ? Data(repeating: 0x20, count: 65_537)
            : try JSONSerialization.data(withJSONObject: response)
        let responseURL = responseFault == "redirect" ? try #require(URL(string: "https://other.example.com/redirect")) : url
        let mime = responseFault == "wrong-mime" ? "text/plain" : "application/json"
        return (data, try #require(HTTPURLResponse(url: responseURL, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime])))
    }
}
