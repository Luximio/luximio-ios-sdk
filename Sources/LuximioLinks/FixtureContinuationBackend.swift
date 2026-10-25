import CryptoKit
import Foundation

/// Deterministic, in-process prototype fixtures. This backend never sends HTTP, checks a published
/// link, or provides production receipt authority. Its `fixture:` pins must not be used by a pilot.
@MainActor
public final class FixtureContinuationBackend: ContinuationBackend {
    public var destinations: [String: LinkDestination]
    public var isAvailable = true
    public private(set) var acknowledgements: [UUID: Acknowledgement] = [:]
    private let configuration: LinksConfiguration
    private let now: @MainActor () -> Date
    private var creates: [UUID: PinnedReceipt] = [:]

    public init(configuration: LinksConfiguration, destinations: [String: LinkDestination],
                now: @escaping @MainActor () -> Date = { Date() }) throws {
        let expectedBundle = configuration.role == .fullApp
            ? configuration.scope.fullAppBundleID : configuration.scope.clipBundleID
        try configuration.validate(bundleIdentifier: expectedBundle)
        for destination in destinations.values { try destination.validate() }
        self.configuration = configuration
        self.destinations = destinations
        self.now = now
    }

    public func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        try checkAvailability()
        try invocation.validate(configuration: configuration, now: now())
        if let existing = creates[invocation.operationID] {
            guard existing.invocation == invocation else { throw LinkFailure.conflict }
            return try await resolve(existing)
        }
        guard let url = URL(string: invocation.originalURL) else { throw LinkFailure.untrustedURL }
        let destination = try currentDestination(url)
        let receipt = PinnedReceipt(
            id: stableUUID("receipt", invocation: invocation),
            deliveryID: stableUUID("delivery", invocation: invocation),
            invocation: invocation, canonicalLinkID: canonicalID(for: url),
            destination: destination, expiresAt: invocation.expiresAt
        )
        try receipt.validate(configuration: configuration, now: now())
        creates[invocation.operationID] = receipt
        return receipt
    }

    public func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        try checkAvailability()
        try receipt.validate(configuration: configuration, now: now())
        guard let url = URL(string: receipt.invocation.originalURL),
              receipt.id == stableUUID("receipt", invocation: receipt.invocation),
              receipt.deliveryID == stableUUID("delivery", invocation: receipt.invocation),
              receipt.canonicalLinkID == canonicalID(for: url) else { throw LinkFailure.unverifiedContext }
        guard try currentDestination(url) == receipt.destination else { throw LinkFailure.changedDestination }
        return receipt
    }

    public func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try checkAvailability()
        try receipt.validate(configuration: configuration, now: now())
        guard acknowledgement.receiptID == receipt.id,
              acknowledgement.deliveryID == receipt.deliveryID else { throw LinkFailure.conflict }
        if let existing = acknowledgements[acknowledgement.receiptID] {
            guard existing == acknowledgement else { throw LinkFailure.conflict }
            return
        }
        guard !acknowledgements.values.contains(where: {
            $0.operationID == acknowledgement.operationID && $0 != acknowledgement
        }) else { throw LinkFailure.conflict }
        acknowledgements[acknowledgement.receiptID] = acknowledgement
    }

    public func resolveDirect(_ url: URL) async throws -> LinkDestination {
        try checkAvailability()
        return try currentDestination(url)
    }

    private func checkAvailability() throws {
        try Task.checkCancellation()
        guard isAvailable else { throw LinkFailure.network }
    }

    private func currentDestination(_ url: URL) throws -> LinkDestination {
        try configuration.validateURL(url)
        guard let destination = destinations[url.path] else { throw LinkFailure.unavailable }
        try destination.validate()
        return destination
    }

    private func canonicalID(for url: URL) -> String {
        "fixture:\(configuration.scope.projectID):\(configuration.scope.fullAppBundleID):\(url.path)"
    }

    private func stableUUID(_ kind: String, invocation: CapturedInvocation) -> UUID {
        let seed = "fixture:\(kind):\(invocation.scope.projectID):\(invocation.scope.fullAppBundleID):" +
                   "\(invocation.scope.clipBundleID):\(invocation.id.uuidString):\(invocation.operationID.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
