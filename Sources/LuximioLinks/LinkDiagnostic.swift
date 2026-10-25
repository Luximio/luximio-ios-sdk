import Foundation

public enum LinkDiagnostic: Equatable, Sendable {
    case idle, checking, held
    case retryAvailable(LinkFailure), rejected(LinkFailure)
    case acknowledgementPending(UUID), uncertainApplication(UUID), applied(UUID), suppressed(LinkFailure)
}
