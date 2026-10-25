import Foundation

public enum ResumeTrigger: Equatable, Sendable {
    case activation, readinessChanged, userRetry, confirmedContinue(UUID)
}
