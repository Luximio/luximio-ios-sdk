import Foundation

/// Private package prototype. A backend is explicit until the receipt HTTP slice exists.
@MainActor
public final class LuximioLinks {
    private let configuration: LinksConfiguration
    private let journal: ContinuationJournal
    private let backend: any ContinuationBackend
    private let now: @MainActor () -> Date
    private let route: @MainActor (LinkDelivery) -> LinkDisposition
    private let diagnostic: @MainActor (LinkDiagnostic) -> Void
    private var generation = UUID()
    private var workID: UUID?
    private var work: Task<Void, Never>?
    private var acknowledgementWork: Task<Void, Never>?
    private var activeInvocationID: UUID?
    private var retryInvocationID: UUID?
    private var cancellationNeedsRetry = false
    private var directURL: URL?
    private var directDeliveryID: UUID?

    public init(configuration: LinksConfiguration, journal: ContinuationJournal,
                backend: any ContinuationBackend, bundleIdentifier: String? = nil,
                now: @escaping @MainActor () -> Date = Date.init,
                route: @escaping @MainActor (LinkDelivery) -> LinkDisposition,
                diagnostic: @escaping @MainActor (LinkDiagnostic) -> Void = { _ in }) throws {
        try configuration.validate(bundleIdentifier: bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "")
        guard configuration.role == .fullApp else { throw LinkFailure.configuration }
        self.configuration = configuration
        self.journal = journal
        self.backend = backend
        self.now = now
        self.route = route
        self.diagnostic = diagnostic
    }

    public func receive(_ url: URL) throws {
        try cancelPending()
        do { try configuration.validateURL(url) }
        catch {
            diagnostic(.rejected(.untrustedURL))
            throw error
        }
        directURL = url
        directDeliveryID = UUID()
        startDirect()
    }

    @discardableResult
    public func resume(_ trigger: ResumeTrigger) -> Task<Void, Never>? {
        if cancellationNeedsRetry {
            guard trigger == .userRetry else {
                diagnostic(.suppressed(.storage))
                return nil
            }
            do { try cancelPending() }
            catch { return nil }
            return nil
        }
        scheduleAcknowledgements()
        if directURL != nil {
            if case .confirmedContinue = trigger { return nil }
            if trigger != .activation, work == nil { startDirect() }
            return work
        }
        var pending: JournalEntry?
        do {
            guard let entry = try journal.pending() else {
                if work == nil { diagnostic(.idle) }
                return work
            }
            pending = entry
            try entry.invocation.validate(configuration: configuration, now: now())
            guard let receipt = entry.receipt else {
                diagnostic(.rejected(.unverifiedContext))
                return nil
            }
            try receipt.validate(configuration: configuration, now: now())
            if entry.phase == .applying {
                guard trigger == .confirmedContinue(receipt.deliveryID) else {
                    diagnostic(.uncertainApplication(receipt.deliveryID))
                    return nil
                }
                guard try journal.transition(id: entry.invocation.id, from: .applying, to: .pinned) else {
                    return nil
                }
                retryInvocationID = nil
            } else if case .confirmedContinue = trigger {
                return nil // Confirmation must select the current uncertain entry.
            }
            if work != nil, activeInvocationID == entry.invocation.id { return work }
            if entry.phase == .held, trigger == .activation {
                diagnostic(.held)
                return nil
            }
            if retryInvocationID == entry.invocation.id, trigger != .userRetry { return nil }
            invalidateWork()
            activeInvocationID = entry.invocation.id
            retryInvocationID = nil
            let requestGeneration = generation
            let id = UUID()
            workID = id
            diagnostic(.checking)
            let task = Task { [weak self] in
                guard let self else { return }
                await self.recover(receipt, generation: requestGeneration)
                self.finishWork(id)
            }
            work = task
            return task
        } catch {
            let reason = failure(error)
            switch reason {
            case .storage, .busy, .network: diagnostic(.retryAvailable(reason))
            default:
                if let pending { reject(pending, reason: reason) }
                else { diagnostic(.rejected(reason)) }
            }
            return nil
        }
    }

    public func cancelPending() throws {
        invalidateWork()
        directURL = nil
        directDeliveryID = nil
        retryInvocationID = nil
        do {
            try journal.cancelPending()
            cancellationNeedsRetry = false
            diagnostic(.idle)
            scheduleAcknowledgements()
        } catch {
            cancellationNeedsRetry = true
            diagnostic(.suppressed(failure(error)))
            throw error
        }
    }

    /// Deterministic completion seam for private integration tests and prototype harnesses.
    public func waitUntilIdle() async {
        while let task = work { await task.value }
        while let task = acknowledgementWork { await task.value }
    }

    private func invalidateWork() {
        generation = UUID()
        work?.cancel()
        work = nil
        workID = nil
        activeInvocationID = nil
    }

    private func finishWork(_ id: UUID) {
        guard workID == id else { return }
        work = nil
        workID = nil
        activeInvocationID = nil
    }

    private func startDirect() {
        guard let url = directURL, let deliveryID = directDeliveryID else { return }
        invalidateWork()
        let requestGeneration = generation
        let id = UUID()
        workID = id
        diagnostic(.checking)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let destination = try await self.backend.resolveDirect(url)
                try Task.checkCancellation()
                guard self.generation == requestGeneration else { return }
                try destination.validate()
                let delivery = LinkDelivery(id: deliveryID, destination: destination,
                                            originalURL: url.absoluteString, source: .direct)
                let disposition = self.route(delivery)
                guard self.generation == requestGeneration else { return }
                switch disposition {
                case .applied:
                    self.directURL = nil
                    self.directDeliveryID = nil
                    self.diagnostic(.applied(deliveryID))
                case .hold: self.diagnostic(.held)
                case .discard:
                    self.directURL = nil
                    self.directDeliveryID = nil
                    self.diagnostic(.rejected(.unavailable))
                }
            } catch {
                if !Task.isCancelled, self.generation == requestGeneration {
                    self.diagnostic(.retryAvailable(self.failure(error)))
                }
            }
            self.finishWork(id)
        }
    }

    private func recover(_ receipt: PinnedReceipt, generation requestGeneration: UUID) async {
        let invocationID = receipt.invocation.id
        var applicationCommitted = false
        do {
            let prepared = try await backend.resolve(receipt)
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }
            try prepared.validate(configuration: configuration, now: now())
            guard prepared == receipt else { throw LinkFailure.changedDestination }
            guard let entry = try journal.pending(), entry.invocation.id == invocationID,
                  entry.receipt == receipt else { throw LinkFailure.superseded }
            guard entry.phase == .pinned || entry.phase == .held else { throw LinkFailure.conflict }
            guard try journal.transition(id: invocationID, from: entry.phase, to: .applying) else {
                throw LinkFailure.superseded
            }
            applicationCommitted = true
            // No await between the durable commitment and this synchronous customer callback.
            let disposition = route(LinkDelivery(id: receipt.deliveryID, destination: prepared.destination,
                originalURL: receipt.invocation.originalURL, source: .appClip(receipt)))
            guard generation == requestGeneration else { return }
            switch disposition {
            case .hold:
                if try journal.transition(id: invocationID, from: .applying, to: .held) {
                    diagnostic(.held)
                } else {
                    _ = try journal.transition(id: invocationID, from: .applying, to: .discarded,
                                                acknowledgement: acknowledgement(receipt, outcome: .discarded))
                }
            case .applied:
                guard try journal.transition(id: invocationID, from: .applying, to: .applied,
                    acknowledgement: acknowledgement(receipt, outcome: .applied)) else {
                    throw LinkFailure.conflict
                }
                diagnostic(.applied(receipt.deliveryID))
            case .discard:
                _ = try journal.transition(id: invocationID, from: .applying, to: .discarded,
                    acknowledgement: acknowledgement(receipt, outcome: .discarded))
                diagnostic(.rejected(.unavailable))
            }
            scheduleAcknowledgements()
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            retryInvocationID = invocationID
            if applicationCommitted {
                diagnostic(.uncertainApplication(receipt.deliveryID))
            } else {
                let reason = failure(error)
                switch reason {
                case .network, .busy, .storage: diagnostic(.retryAvailable(reason))
                default:
                    if let entry = try? journal.entry(id: invocationID) { reject(entry, reason: reason) }
                    else { diagnostic(.rejected(reason)) }
                }
            }
        }
    }

    private func acknowledgement(_ receipt: PinnedReceipt, outcome: Acknowledgement.Outcome) -> Acknowledgement {
        Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                        operationID: UUID(), outcome: outcome)
    }

    private func reject(_ entry: JournalEntry, reason: LinkFailure) {
        do {
            if entry.phase != .applied, entry.phase != .discarded {
                _ = try journal.transition(id: entry.invocation.id, from: entry.phase, to: .discarded)
            }
            diagnostic(.rejected(reason))
            scheduleAcknowledgements()
        } catch {
            cancellationNeedsRetry = true
            diagnostic(.suppressed(failure(error)))
        }
    }

    private func scheduleAcknowledgements() {
        guard acknowledgementWork == nil else { return }
        acknowledgementWork = Task { [weak self] in
            guard let self else { return }
            defer { self.acknowledgementWork = nil }
            do {
                // Current recovery owns priority over older completion work.
                // Both operations may require the same serialized native proof
                // lease, so an old outbox retry must not starve a new action.
                guard try self.acknowledgementsMayProceed() else { return }
                try self.journal.purge(at: self.now())
                var attemptedOperations = Set<UUID>()
                while attemptedOperations.count < ContinuationJournal.maximumEntries {
                    guard try self.acknowledgementsMayProceed() else { return }
                    let pending = try self.journal.acknowledgements().filter {
                        !attemptedOperations.contains($0.operationID)
                    }
                    guard !pending.isEmpty else { break }
                    for acknowledgement in pending {
                        guard try self.acknowledgementsMayProceed() else { return }
                        attemptedOperations.insert(acknowledgement.operationID)
                        do {
                            guard let receipt = try self.journal.acknowledgementReceipt(acknowledgement),
                                  receipt.invocation.scope == self.configuration.scope else { continue }
                            try receipt.validate(configuration: self.configuration, now: self.now())
                            try await self.backend.acknowledge(acknowledgement, receipt: receipt)
                            try self.journal.completeAcknowledgement(acknowledgement)
                        } catch {
                            self.diagnostic(.acknowledgementPending(acknowledgement.deliveryID))
                        }
                        // A Clip can capture another action while the previous
                        // proof is in flight. Finish that operation normally,
                        // then yield priority before starting another one.
                        guard try self.acknowledgementsMayProceed() else { return }
                    }
                }
            } catch { self.diagnostic(.retryAvailable(self.failure(error))) }
        }
    }

    private func acknowledgementsMayProceed() throws -> Bool {
        guard try journal.pending() != nil else { return true }
        // Keep queued completion visible while waiting for the customer. An
        // active attempt may finish and drain it, so do not reintroduce a stale
        // warning after that attempt has cleared its previous notice.
        if work == nil, let queued = try journal.acknowledgements().first {
            diagnostic(.acknowledgementPending(queued.deliveryID))
        }
        return false
    }

    private func failure(_ error: any Error) -> LinkFailure {
        (error as? LinkFailure) ?? .storage
    }
}
