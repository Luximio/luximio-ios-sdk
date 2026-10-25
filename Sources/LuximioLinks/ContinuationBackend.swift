import Foundation

@MainActor
public protocol ContinuationBackend: AnyObject {
    func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt
    func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt
    func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws
    func resolveDirect(_ url: URL) async throws -> LinkDestination
}
