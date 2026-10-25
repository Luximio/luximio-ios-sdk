import Foundation

/// Captures an App Clip invocation before backend work and reports readiness only after durable pinning.
@MainActor
public final class LuximioClipLinks {
    private let configuration: LinksConfiguration
    private let journal: ContinuationJournal
    private let backend: any ContinuationBackend
    private let now: @MainActor () -> Date
    private var generation = UUID()

    public init(configuration: LinksConfiguration, journal: ContinuationJournal,
                backend: any ContinuationBackend, bundleIdentifier: String? = nil,
                now: @escaping @MainActor () -> Date = { Date() }) throws {
        guard configuration.role == .appClip else { throw LinkFailure.configuration }
        try configuration.validate(bundleIdentifier: bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "")
        self.configuration = configuration
        self.journal = journal
        self.backend = backend
        self.now = now
    }

    public func capture(_ url: URL) async throws -> PinnedReceipt {
        generation = UUID()
        let attempt = generation
        try Task.checkCancellation()
        do {
            try configuration.validateURL(url)
        } catch {
            try journal.cancelPending()
            throw error
        }
        let date = now()
        try journal.purge(at: date)
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: date)
        try journal.capture(invocation)
        return try await finish(invocation, existingReceipt: nil, generation: attempt)
    }

    /// Retries the retained action; never recaptures it or extends its original deadline.
    public func retryCapture() async throws -> PinnedReceipt {
        generation = UUID()
        let attempt = generation
        try Task.checkCancellation()
        guard let entry = try journal.pending(),
              entry.phase == .captured || entry.phase == .pinned || entry.phase == .held else {
            throw LinkFailure.unverifiedContext
        }
        try entry.invocation.validate(configuration: configuration, now: now())
        return try await finish(entry.invocation, existingReceipt: entry.receipt, generation: attempt)
    }

    private func finish(_ invocation: CapturedInvocation, existingReceipt: PinnedReceipt?,
                        generation attempt: UUID) async throws -> PinnedReceipt {
        let receipt: PinnedReceipt
        do {
            if let existingReceipt {
                try existingReceipt.validate(configuration: configuration, now: now())
                receipt = try await backend.resolve(existingReceipt)
            } else {
                receipt = try await backend.create(invocation)
            }
        } catch {
            try Task.checkCancellation()
            guard generation == attempt,
                  let current = try journal.pending(), current.invocation == invocation,
                  current.phase == .captured || current.phase == .pinned || current.phase == .held else {
                throw LinkFailure.superseded
            }
            throw error
        }
        try Task.checkCancellation()
        guard generation == attempt,
              let current = try journal.pending(), current.invocation == invocation,
              current.phase == .captured || current.phase == .pinned || current.phase == .held else {
            throw LinkFailure.superseded
        }
        try receipt.validate(configuration: configuration, now: now())
        guard receipt.invocation == invocation else { throw LinkFailure.wrongScope }
        if let existingReceipt {
            guard current.receipt == existingReceipt else { throw LinkFailure.superseded }
            guard receipt == existingReceipt else { throw LinkFailure.changedDestination }
        }
        guard try journal.pin(receipt) else { throw LinkFailure.superseded }
        return receipt
    }
}
