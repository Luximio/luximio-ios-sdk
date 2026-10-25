import Foundation

/// A pinned proposal, not identity, reward or authorization evidence.
public struct PinnedReceipt: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    public let id: UUID
    public let deliveryID: UUID
    public let invocation: CapturedInvocation
    public let canonicalLinkID: String
    public let destination: LinkDestination
    public let expiresAt: Date

    public var debugDescription: String {
        "PinnedReceipt(id: \(id), deliveryID: \(deliveryID), invocation: <redacted>, destination: <redacted>)"
    }

    public init(id: UUID, deliveryID: UUID, invocation: CapturedInvocation,
                canonicalLinkID: String, destination: LinkDestination, expiresAt: Date) {
        self.id = id
        self.deliveryID = deliveryID
        self.invocation = invocation
        self.canonicalLinkID = canonicalLinkID
        self.destination = destination
        self.expiresAt = expiresAt
    }

    public func validate(configuration: LinksConfiguration, now: Date) throws {
        try invocation.validate(configuration: configuration, now: now)
        try validate(scope: configuration.scope, now: now)
    }

    public func validate(scope: LinkScope, now: Date) throws {
        try invocation.validate(scope: scope, now: now)
        try destination.validate()
        guard !canonicalLinkID.isEmpty, canonicalLinkID.utf8.count <= 1_024,
              !canonicalLinkID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              expiresAt.timeIntervalSince1970.isFinite, expiresAt > invocation.capturedAt,
              expiresAt <= invocation.expiresAt else { throw LinkFailure.invalidData }
        guard expiresAt > now else { throw LinkFailure.expired }
    }
}
