
public enum LinkFailure: Error, Equatable, Sendable {
    case configuration, untrustedURL, invalidData, expired, unavailable, changedDestination, wrongScope
    case busy, storage, network, conflict, superseded, unverifiedContext
}
