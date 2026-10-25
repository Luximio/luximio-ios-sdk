import Foundation

public struct Acknowledgement: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Equatable, Sendable { case applied, discarded }
    public let receiptID: UUID
    public let deliveryID: UUID
    public let operationID: UUID
    public let outcome: Outcome

    public init(receiptID: UUID, deliveryID: UUID, operationID: UUID, outcome: Outcome) {
        self.receiptID = receiptID
        self.deliveryID = deliveryID
        self.operationID = operationID
        self.outcome = outcome
    }
}
