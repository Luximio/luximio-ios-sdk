import Foundation
#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif

/// Uses Apple's asynchronous APIs directly. Cancellation cannot undo a native
/// key operation; the key manager persists successful results before exiting.
@MainActor
public final class SystemRecoveryAppAttestProvider: RecoveryAppAttestProviding {
    public init() {}

    public var isSupported: Bool {
        #if os(iOS) && canImport(DeviceCheck)
        DCAppAttestService.shared.isSupported
        #else
        false
        #endif
    }

    public func generateKey() async throws -> String {
        guard isSupported else { throw RecoveryAppAttestFailure.unsupported }
        #if os(iOS) && canImport(DeviceCheck)
        do { return try await DCAppAttestService.shared.generateKey() }
        catch is CancellationError { throw CancellationError() }
        catch { throw classify(error) }
        #else
        throw RecoveryAppAttestFailure.unsupported
        #endif
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw RecoveryAppAttestFailure.unsupported }
        guard clientDataHash.count == 32 else { throw RecoveryAppAttestFailure.rejected }
        #if os(iOS) && canImport(DeviceCheck)
        do { return try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) }
        catch is CancellationError { throw CancellationError() }
        catch { throw classify(error, attestation: true) }
        #else
        throw RecoveryAppAttestFailure.unsupported
        #endif
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        guard isSupported else { throw RecoveryAppAttestFailure.unsupported }
        guard clientDataHash.count == 32 else { throw RecoveryAppAttestFailure.rejected }
        #if os(iOS) && canImport(DeviceCheck)
        do { return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) }
        catch is CancellationError { throw CancellationError() }
        catch { throw classify(error) }
        #else
        throw RecoveryAppAttestFailure.unsupported
        #endif
    }

    #if os(iOS) && canImport(DeviceCheck)
    private func classify(_ error: any Error, attestation: Bool = false) -> RecoveryAppAttestFailure {
        // Apple's one-time attestation retry exception is specifically
        // serverUnavailable. Other attestation failures must retire that
        // candidate, rather than repeatedly attesting the same native key.
        let unknownFailure: RecoveryAppAttestFailure = attestation ? .rejected : .unavailable
        guard let error = error as? DCError else { return unknownFailure }
        switch error.code {
        case .featureUnsupported: return .unsupported
        case .invalidKey: return .invalidKey
        case .serverUnavailable: return .unavailable
        case .unknownSystemFailure: return unknownFailure
        case .invalidInput: return .rejected
        @unknown default: return unknownFailure
        }
    }
    #endif
}
