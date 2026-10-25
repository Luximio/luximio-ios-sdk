import Foundation

public struct LinkDelivery: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case direct, appClip(PinnedReceipt) }
    public let id: UUID
    public let destination: LinkDestination
    public let originalURL: String
    public let source: Source

    public init(id: UUID, destination: LinkDestination, originalURL: String, source: Source) {
        self.id = id
        self.destination = destination
        self.originalURL = originalURL
        self.source = source
    }
}
