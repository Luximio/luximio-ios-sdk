import Foundation
import Testing
@testable import LuximioLinks

@MainActor
struct FixtureContinuationBackendTests {
    private let scope = LinkScope(projectID: "project-test", fullAppBundleID: "app.test.full",
                                  clipBundleID: "app.test.full.Clip")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let destination = LinkDestination(route: "places/detail", data: ["id": .string("north")])

    private var configuration: LinksConfiguration {
        LinksConfiguration(scope: scope, role: .appClip, trustedHosts: ["links.example.com"],
                           appGroupIdentifier: "group.app.test.full")
    }

    @Test func retriesAndRecreatedFixtureKeepSeparateStableIdentities() async throws {
        let date = now
        let first = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination],
                                                   now: { date })
        let second = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination],
                                                    now: { date })
        let url = try #require(URL(string: "https://links.example.com/north?future=context"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        let receipt = try await first.create(invocation)
        let retry = try await first.create(invocation)
        let recreated = try await second.create(invocation)
        #expect(receipt.id == retry.id)
        #expect(receipt.deliveryID == recreated.deliveryID)
        #expect(receipt.id != receipt.deliveryID)
        #expect(receipt.id != invocation.id)
        #expect(receipt.canonicalLinkID.hasPrefix("fixture:"))
        let resolved = try await second.resolve(receipt)
        #expect(resolved.id == receipt.id)
    }

    @Test func changedOrMissingFixturesCannotUseOldPin() async throws {
        let date = now
        let backend = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination],
                                                     now: { date })
        let url = try #require(URL(string: "https://links.example.com/north"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        let receipt = try await backend.create(invocation)
        backend.destinations["/north"] = LinkDestination(route: "places/detail", data: ["id": .string("canal")])
        await #expect(throws: LinkFailure.changedDestination) { try await backend.resolve(receipt) }
        backend.destinations.removeValue(forKey: "/north")
        await #expect(throws: LinkFailure.unavailable) { try await backend.resolve(receipt) }
    }

    @Test func conflictingAcknowledgementsAreRejectedWithoutOverwriting() async throws {
        let date = now
        let backend = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination],
                                                     now: { date })
        let url = try #require(URL(string: "https://links.example.com/north"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        let receipt = try await backend.create(invocation)
        let acknowledgement = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                               operationID: UUID(), outcome: .applied)
        try await backend.acknowledge(acknowledgement, receipt: receipt)
        try await backend.acknowledge(acknowledgement, receipt: receipt)
        let conflict = Acknowledgement(receiptID: acknowledgement.receiptID, deliveryID: acknowledgement.deliveryID,
                                       operationID: UUID(), outcome: .discarded)
        await #expect(throws: LinkFailure.conflict) { try await backend.acknowledge(conflict, receipt: receipt) }
        #expect(backend.acknowledgements.count == 1)
        #expect(backend.acknowledgements[acknowledgement.receiptID]?.outcome == .applied)
    }

    @Test func acknowledgementMustMatchReceiptAndConfiguredScope() async throws {
        let date = now
        let backend = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination],
                                                     now: { date })
        let url = try #require(URL(string: "https://links.example.com/north"))
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: now)
        let receipt = try await backend.create(invocation)
        let wrongDelivery = Acknowledgement(receiptID: receipt.id, deliveryID: UUID(), operationID: UUID(), outcome: .applied)
        await #expect(throws: LinkFailure.conflict) { try await backend.acknowledge(wrongDelivery, receipt: receipt) }
        let otherScope = LinkScope(projectID: "another-project", fullAppBundleID: scope.fullAppBundleID,
                                   clipBundleID: scope.clipBundleID)
        let otherConfiguration = LinksConfiguration(scope: otherScope, role: .fullApp,
                                                    trustedHosts: configuration.trustedHosts,
                                                    appGroupIdentifier: configuration.appGroupIdentifier)
        let otherBackend = try FixtureContinuationBackend(configuration: otherConfiguration, destinations: [:], now: { date })
        let acknowledgement = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                               operationID: UUID(), outcome: .applied)
        await #expect(throws: LinkFailure.wrongScope) {
            try await otherBackend.acknowledge(acknowledgement, receipt: receipt)
        }
        #expect(backend.acknowledgements.isEmpty)
    }

    @Test func directResolutionUsesNoCaptureOrReceipt() async throws {
        let backend = try FixtureContinuationBackend(configuration: configuration, destinations: ["/north": destination])
        let url = try #require(URL(string: "https://links.example.com/north"))
        let result = try await backend.resolveDirect(url)
        #expect(result == destination)
        #expect(backend.acknowledgements.isEmpty)
        backend.isAvailable = false
        await #expect(throws: LinkFailure.network) { try await backend.resolveDirect(url) }
    }
}
