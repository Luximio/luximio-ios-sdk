/// Temporary, opt-in inspection for the private customer SDK prototype. These
/// closed stages carry no invocation, key, challenge or request information.
@_spi(PrivatePrototype)
public enum CustomerRecoveryProofStage: String, Sendable {
    case challenge, pin, registration, assertion, operation
}

/// An in-memory observation only. The SDK does not log, persist or transmit it.
@_spi(PrivatePrototype)
public struct CustomerRecoveryProofDiagnostic: Equatable, Sendable {
    public let purpose: String
    public let stage: CustomerRecoveryProofStage
    public let failure: LinkFailure?
    public let nativeFailure: RecoveryAppAttestFailure?

    init(purpose: CustomerRecoveryPurpose, stage: CustomerRecoveryProofStage,
         failure: LinkFailure? = nil, nativeFailure: RecoveryAppAttestFailure? = nil) {
        self.purpose = purpose.rawValue
        self.stage = stage
        self.failure = failure
        self.nativeFailure = nativeFailure
    }
}
