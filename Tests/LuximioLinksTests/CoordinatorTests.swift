import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoordinatorTests {
    @Test func anUncertainCurrentReceiptKeepsDeferredCompletionVisibleWithoutStartingItsProof() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let older = try fixture.seed("canal-house")
        try fixture.journal.cancelPending()
        let queued = try fixture.journal.acknowledgements()
        try #require(queued.count == 1)
        let current = try fixture.seed("north-studio")
        try #require(try fixture.journal.transition(id: current.invocation.id, from: .pinned, to: .applying))
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)

        #expect(probe.diagnostics.contains(.uncertainApplication(current.deliveryID)))
        #expect(probe.diagnostics.contains(.acknowledgementPending(older.deliveryID)),
                "Deferring a queued completion must retain its separate pending notice.")
        #expect(backend.acknowledgementCalls.isEmpty, "Reporting queued work cannot start a competing proof.")
        #expect(backend.resolveCalls.isEmpty, "Completion status cannot confirm an uncertain application.")
        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.acknowledgements() == queued)
        #expect(try fixture.journal.pending()?.phase == .applying)

        probe.diagnostics.removeAll()
        await drive(client, .confirmedContinue(current.deliveryID))

        #expect(probe.applied.map(\.id) == [current.deliveryID])
        #expect(try fixture.journal.acknowledgements().isEmpty)
        #expect(probe.diagnostics.contains(.acknowledgementPending(older.deliveryID)) == false,
                "An active confirmed attempt must not replace a cleared warning with a transient deferral notice.")
    }

    @Test func heldOnboardingSurvivesAReopenedJournalAndAppliesOnceWhenReady() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe(disposition: .hold)
        let first = try fixture.client(backend: backend, probe: probe)

        await drive(first, .activation)
        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .held)

        let reopened = try ContinuationJournal(containerURL: fixture.directory)
        let second = try fixture.client(journal: reopened, backend: backend, probe: probe)
        probe.disposition = .applied
        await drive(second, .readinessChanged)
        await drive(second, .activation)

        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(try reopened.entry(id: receipt.invocation.id)?.phase == .applied)
        #expect(backend.createCalls.isEmpty, "A full app must never issue a fresh receipt for held context.")
    }

    @Test func switchingToAnUnauthorizedAccountDiscardsHeldContextAndCannotReviveItAfterRestart() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        let gate = CoordinatorSessionGate()
        let probe = CoordinatorProbe()
        // This customer-owned gate checks the current session at each synchronous
        // proposal. Neither the destination nor carried query fields authorize access.
        probe.routingPolicy = { _ in gate.disposition }
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)
        try #require(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .held)
        #expect(probe.applied.isEmpty)

        gate.currentAccountID = "synthetic-account-b"
        gate.isReady = true
        await drive(client, .readinessChanged)

        #expect(probe.applied.isEmpty)
        #expect(probe.proposed.map(\.id) == [receipt.deliveryID, receipt.deliveryID])
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .discarded)
        #expect(try fixture.journal.pending() == nil)

        gate.currentAccountID = "synthetic-account-a"
        let reopened = try ContinuationJournal(containerURL: fixture.directory)
        let restarted = try fixture.client(journal: reopened, backend: backend, probe: probe)
        await drive(restarted, .activation)
        await drive(restarted, .readinessChanged)
        await drive(restarted, .userRetry)

        #expect(probe.applied.isEmpty)
        #expect(probe.proposed.count == 2,
                "Returning to an authorized account requires a fresh invocation after terminal denial.")
        #expect(backend.resolveCalls.count == 2)
        #expect(try reopened.entry(id: receipt.invocation.id)?.phase == .discarded)
        #expect(try reopened.pending() == nil)
    }

    @Test func deliveryPreservesQueryOrderingDuplicateKeysEncodingAndUnknownFields() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let url = try fixture.url("north-studio?z=last&campaign=one&future_context=hello%20world&campaign=two&encoded=%2F")
        let receipt = try fixture.seed(url: url, place: "north-studio")
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)

        let delivery = try #require(probe.applied.first)
        #expect(delivery.originalURL == url.absoluteString)
        #expect(delivery.source == .appClip(receipt))
        #expect(backend.resolveCalls.first?.invocation.originalURL == url.absoluteString)
        #expect(delivery.destination == fixture.destination("north-studio"))
    }

    @Test func activationDoesNotRetryAnOfflineReceiptUntilTheUserRequestsIt() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.resolveFailure = .network
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)
        for _ in 0..<3 { await drive(client, .activation) }

        #expect(backend.resolveCalls.count == 1)
        #expect(probe.applied.isEmpty)
        #expect(probe.diagnostics.contains(.retryAvailable(.network)))
        #expect(try fixture.journal.pending()?.receipt == receipt)

        backend.resolveFailure = nil
        await drive(client, .userRetry)
        #expect(backend.resolveCalls.count == 2)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(backend.resolveCalls.allSatisfy { $0 == receipt })
    }

    @Test func repeatedActivationCoalescesAnInFlightResolution() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.suspendNextResolution = true
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let first = try #require(client.resume(.activation))
        await backend.waitForSuspendedResolution()

        for _ in 0..<3 { client.resume(.activation) }
        backend.releaseResolution(with: receipt)
        await first.value
        await client.waitUntilIdle()

        #expect(backend.resolveCalls.count == 1)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
    }

    @Test func aNewDirectLinkWinsOverADelayedContinuationAndCancelsItAcrossRestart() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.suspendNextResolution = true
        backend.directDestination = fixture.destination("canal-house")
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let oldTask = try #require(client.resume(.activation))
        await backend.waitForSuspendedResolution()

        let directURL = try fixture.url("canal-house?utm_source=manual-link")
        try client.receive(directURL)
        backend.releaseResolution(with: receipt)
        await oldTask.value
        await client.waitUntilIdle()

        #expect(probe.applied.count == 1)
        #expect(probe.applied.first?.destination == fixture.destination("canal-house"))
        #expect(probe.applied.first?.source == .direct)
        #expect(probe.applied.first?.originalURL == directURL.absoluteString)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .discarded)

        let restarted = try fixture.client(journal: ContinuationJournal(containerURL: fixture.directory),
                                           backend: backend, probe: probe)
        await drive(restarted, .activation)
        #expect(probe.applied.count == 1, "The superseded continuation cannot reopen after restart.")
    }

    @Test func manualNavigationCancelsADelayedContinuationDurably() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.suspendNextResolution = true
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let oldTask = try #require(client.resume(.activation))
        await backend.waitForSuspendedResolution()

        try client.cancelPending()
        backend.releaseResolution(with: receipt)
        await oldTask.value
        await client.waitUntilIdle()
        await drive(client, .activation)

        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .discarded)

        let restarted = try fixture.client(journal: ContinuationJournal(containerURL: fixture.directory),
                                           backend: backend, probe: probe)
        await drive(restarted, .activation)
        #expect(probe.applied.isEmpty)
    }

    @Test func aLostAcknowledgementRetriesTheSameOperationWithoutReapplyingNavigation() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.acknowledgementFailure = .network
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)
        let firstAcknowledgement = try #require(backend.acknowledgementCalls.first)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(probe.diagnostics.contains(.acknowledgementPending(receipt.deliveryID)))
        #expect(try fixture.journal.acknowledgements().count == 1)

        backend.acknowledgementFailure = nil
        let restarted = try fixture.client(journal: ContinuationJournal(containerURL: fixture.directory),
                                           backend: backend, probe: probe)
        await drive(restarted, .activation)

        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(backend.resolveCalls.count == 1)
        #expect(backend.acknowledgementCalls == [firstAcknowledgement, firstAcknowledgement])
        #expect(backend.acknowledgementReceipts == [receipt, receipt],
                "A reopened client must recover the original scoped bearer with its acknowledgement.")
        #expect(firstAcknowledgement.outcome == .applied)
        #expect(try fixture.journal.acknowledgements().isEmpty)
    }

    @Test func anApplyingEntryNeedsTheMatchingExplicitConfirmationBeforeRecovery() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        try #require(try fixture.journal.transition(id: receipt.invocation.id, from: .pinned, to: .applying))
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let reopened = try ContinuationJournal(containerURL: fixture.directory)
        let client = try fixture.client(journal: reopened, backend: backend, probe: probe)

        await drive(client, .activation)
        await drive(client, .readinessChanged)
        await drive(client, .userRetry)
        await drive(client, .confirmedContinue(UUID()))

        #expect(probe.applied.isEmpty)
        #expect(backend.resolveCalls.isEmpty)
        #expect(probe.diagnostics.contains(.uncertainApplication(receipt.deliveryID)))
        #expect(try reopened.entry(id: receipt.invocation.id)?.phase == .applying)

        await drive(client, .confirmedContinue(receipt.deliveryID))
        await drive(client, .activation)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(backend.resolveCalls.count == 1, "Explicit Continue must freshly validate the same proposal.")
        #expect(try reopened.entry(id: receipt.invocation.id)?.phase == .applied)
    }

    @Test func aBlockedCompletionWriteReportsUncertaintyAndRequiresExplicitContinue() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        var heldLock: CoordinatorHeldLock?
        var lockError: String?
        defer { heldLock?.release() }
        // Navigation is installed synchronously. A separate descriptor then prevents
        // both the completion write and the catch path's journal read from succeeding.
        probe.beforeReturning = { _ in
            do { heldLock = try CoordinatorHeldLock(directory: fixture.directory) }
            catch { lockError = String(describing: error) }
        }
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)
        try #require(lockError == nil)
        try #require(heldLock != nil)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(probe.diagnostics.contains(.uncertainApplication(receipt.deliveryID)),
                "An unreadable journal after navigation cannot safely be reported as a network retry.")

        heldLock?.release()
        heldLock = nil
        probe.beforeReturning = nil
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .applying)
        await drive(client, .activation)
        await drive(client, .userRetry)
        #expect(probe.applied.map(\.id) == [receipt.deliveryID])
        #expect(backend.resolveCalls.count == 1)

        await drive(client, .confirmedContinue(receipt.deliveryID))
        #expect(probe.applied.map(\.id) == [receipt.deliveryID, receipt.deliveryID])
        #expect(backend.resolveCalls.count == 2)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .applied)
    }

    @Test func aConfirmationForASupersededUncertainDeliveryCannotApplyTheNewPendingReceipt() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let older = try fixture.seed("north-studio")
        try #require(try fixture.journal.transition(id: older.invocation.id, from: .pinned, to: .applying))
        let newer = try fixture.seed("canal-house")
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .confirmedContinue(older.deliveryID))
        #expect(probe.applied.isEmpty)
        #expect(backend.resolveCalls.isEmpty)
        #expect(try fixture.journal.pending()?.receipt == newer)

        await drive(client, .activation)
        #expect(probe.applied.map(\.id) == [newer.deliveryID])
        #expect(probe.applied.first?.destination == fixture.destination("canal-house"))
    }

    @Test func anOldContinueConfirmationCannotRetryANewerHeldDirectLink() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let uncertain = try fixture.seed("north-studio")
        try #require(try fixture.journal.transition(id: uncertain.invocation.id, from: .pinned, to: .applying))
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe(disposition: .hold)
        let client = try fixture.client(backend: backend, probe: probe)
        await drive(client, .activation)
        try #require(probe.diagnostics.contains(.uncertainApplication(uncertain.deliveryID)))

        let directURL = try fixture.url("canal-house?source=newer-direct")
        try client.receive(directURL)
        await client.waitUntilIdle()
        let heldDirect = try #require(probe.proposed.first)
        try #require(heldDirect.source == .direct)
        try #require(backend.directCalls == [directURL])

        await drive(client, .confirmedContinue(uncertain.deliveryID))

        #expect(backend.directCalls == [directURL])
        #expect(backend.resolveCalls.isEmpty)
        #expect(probe.proposed == [heldDirect])
        #expect(probe.applied.isEmpty)

        probe.disposition = .applied
        await drive(client, .readinessChanged)
        #expect(probe.applied.map(\.id) == [heldDirect.id],
                "Ignoring an obsolete confirmation must preserve the legitimate direct proposal.")
        #expect(probe.applied.first?.destination == fixture.destination("canal-house"))
    }

    @Test func expiredContextNeverReachesTheBackendOrRouter() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        fixture.clock.date = receipt.expiresAt
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)

        #expect(probe.applied.isEmpty)
        #expect(backend.createCalls.isEmpty)
        #expect(backend.resolveCalls.isEmpty)
        #expect(probe.diagnostics.contains(.rejected(.expired)))
    }

    @Test func anUnpinnedClipCaptureCannotBePromotedByTheFullApp() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let invocation = try CapturedInvocation.capture(url: fixture.url("north-studio"),
                                                        configuration: fixture.configuration,
                                                        at: fixture.clock.date)
        try fixture.journal.capture(invocation)
        let backend = CoordinatorBackend()
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)

        #expect(probe.applied.isEmpty)
        #expect(backend.createCalls.isEmpty)
        #expect(backend.resolveCalls.isEmpty)
        #expect(probe.diagnostics.contains(.rejected(.unverifiedContext)))
    }

    @Test(arguments: CoordinatorChangedPin.allCases)
    fileprivate func aChangedServerPinCannotReplaceTheCapturedDestination(change: CoordinatorChangedPin) async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.resolutionOverride = change.replacing(receipt, with: fixture.destination("canal-house"))
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)

        #expect(probe.applied.isEmpty)
        #expect(probe.hasRejection)
        #expect(backend.resolveCalls.count == 1)
    }

    @Test func aChangedTargetRejectionSurvivesRestartEvenIfTheOldTargetReturns() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.resolutionOverride = CoordinatorChangedPin.destination.replacing(
            receipt, with: fixture.destination("canal-house"))
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)

        await drive(client, .activation)
        #expect(probe.diagnostics.contains(.rejected(.changedDestination)))
        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .discarded)
        #expect(try fixture.journal.pending() == nil)

        backend.resolutionOverride = nil
        let restarted = try fixture.client(journal: ContinuationJournal(containerURL: fixture.directory),
                                           backend: backend, probe: probe)
        await drive(restarted, .activation)
        await drive(restarted, .userRetry)

        #expect(probe.applied.isEmpty)
        #expect(backend.resolveCalls.count == 1,
                "A terminal rejection needs a fresh invocation, even after a link changes back.")
        #expect(try fixture.journal.pending() == nil)
    }

    @Test func cancellationPersistenceFailureSuppressesRecoveryUntilCancellationCanBeSaved() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let receipt = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.suspendNextResolution = true
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let oldTask = try #require(client.resume(.activation))
        await backend.waitForSuspendedResolution()
        let lock = try CoordinatorHeldLock(directory: fixture.directory)

        #expect(throws: LinkFailure.busy) { try client.cancelPending() }
        backend.releaseResolution(with: receipt)
        await oldTask.value
        lock.release()
        await client.waitUntilIdle()
        await drive(client, .activation)
        await drive(client, .userRetry)

        #expect(probe.applied.isEmpty)
        #expect(probe.hasSuppression)
        #expect(backend.resolveCalls.count == 1, "Releasing the file lock does not authorize automatic replay.")

        try client.cancelPending()
        let restarted = try fixture.client(journal: ContinuationJournal(containerURL: fixture.directory),
                                           backend: backend, probe: probe)
        await drive(restarted, .activation)
        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.entry(id: receipt.invocation.id)?.phase == .discarded)
    }

    @Test func aNewClipCaptureDuringResolutionCannotBeErasedByTheOldResponse() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let older = try fixture.seed("north-studio")
        let backend = CoordinatorBackend()
        backend.suspendNextResolution = true
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let oldTask = try #require(client.resume(.activation))
        await backend.waitForSuspendedResolution()

        let newer = try fixture.seed("canal-house")
        backend.releaseResolution(with: older)
        await oldTask.value
        await client.waitUntilIdle()

        #expect(probe.applied.isEmpty)
        #expect(try fixture.journal.pending()?.receipt == newer)

        await drive(client, .activation)
        #expect(probe.applied.map(\.id) == [newer.deliveryID])
        #expect(probe.applied.first?.destination == fixture.destination("canal-house"))
        #expect(try fixture.journal.entry(id: newer.invocation.id)?.phase == .applied)
    }

    @Test func directLinksUseOnlyOrdinaryResolutionAndCarryNoDeferredMetadata() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let backend = CoordinatorBackend()
        backend.directDestination = fixture.destination("canal-house")
        let probe = CoordinatorProbe()
        let client = try fixture.client(backend: backend, probe: probe)
        let url = try fixture.url("canal-house?future=direct&campaign=one&campaign=two")

        try client.receive(url)
        await client.waitUntilIdle()
        await drive(client, .activation)

        #expect(probe.applied.count == 1)
        #expect(probe.applied.first?.source == .direct)
        #expect(probe.applied.first?.originalURL == url.absoluteString)
        #expect(backend.directCalls == [url])
        #expect(backend.createCalls.isEmpty)
        #expect(backend.resolveCalls.isEmpty)
        #expect(backend.acknowledgementCalls.isEmpty)
        #expect(try fixture.journal.pending() == nil)
    }

    private func drive(_ client: LuximioLinks, _ trigger: ResumeTrigger) async {
        let task = client.resume(trigger)
        await task?.value
        await client.waitUntilIdle()
    }
}

@MainActor
private struct CoordinatorFixture {
    let directory: URL
    let journal: ContinuationJournal
    let clock = CoordinatorClock()
    let configuration = LinksConfiguration(
        scope: LinkScope(projectID: "project-coordinator-tests",
                         fullAppBundleID: "app.example.coordinator",
                         clipBundleID: "app.example.coordinator.Clip"),
        role: .fullApp,
        trustedHosts: ["coordinator.links.example.com"],
        appGroupIdentifier: "group.app.example.coordinator"
    )

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("luximio-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try ContinuationJournal(containerURL: directory)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func url(_ path: String) throws -> URL {
        try #require(URL(string: "https://coordinator.links.example.com/\(path)"))
    }

    func destination(_ place: String) -> LinkDestination {
        LinkDestination(route: "places/detail", data: ["id": .string(place)])
    }

    @discardableResult
    func seed(_ place: String) throws -> PinnedReceipt {
        try seed(url: url(place), place: place)
    }

    @discardableResult
    func seed(url: URL, place: String) throws -> PinnedReceipt {
        let invocation = try CapturedInvocation.capture(url: url, configuration: configuration, at: clock.date)
        try journal.capture(invocation)
        let receipt = PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: invocation,
                                    canonicalLinkID: "published-\(place)", destination: destination(place),
                                    expiresAt: invocation.expiresAt)
        try #require(try journal.pin(receipt))
        return receipt
    }

    func client(journal suppliedJournal: ContinuationJournal? = nil,
                backend: CoordinatorBackend, probe: CoordinatorProbe) throws -> LuximioLinks {
        try LuximioLinks(configuration: configuration, journal: suppliedJournal ?? journal,
                         backend: backend, bundleIdentifier: configuration.scope.fullAppBundleID,
                         now: { clock.date }, route: { probe.route($0) },
                         diagnostic: { probe.diagnostics.append($0) })
    }
}

@MainActor
private final class CoordinatorClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private final class CoordinatorProbe {
    var disposition: LinkDisposition
    var proposed: [LinkDelivery] = []
    var applied: [LinkDelivery] = []
    var diagnostics: [LinkDiagnostic] = []
    var beforeReturning: (@MainActor (LinkDelivery) -> Void)?
    var routingPolicy: (@MainActor (LinkDelivery) -> LinkDisposition)?

    init(disposition: LinkDisposition = .applied) { self.disposition = disposition }

    func route(_ delivery: LinkDelivery) -> LinkDisposition {
        proposed.append(delivery)
        let currentDisposition = routingPolicy?(delivery) ?? disposition
        if currentDisposition == .applied { applied.append(delivery) }
        beforeReturning?(delivery)
        return currentDisposition
    }

    var hasRejection: Bool {
        diagnostics.contains { if case .rejected = $0 { return true }; return false }
    }

    var hasSuppression: Bool {
        diagnostics.contains { if case .suppressed = $0 { return true }; return false }
    }
}

@MainActor
private final class CoordinatorSessionGate {
    var currentAccountID = "synthetic-account-a"
    var isReady = false
    private let authorizedAccountID = "synthetic-account-a"

    var disposition: LinkDisposition {
        guard isReady else { return .hold }
        guard currentAccountID == authorizedAccountID else { return .discard }
        return .applied
    }
}

@MainActor
private final class CoordinatorBackend: ContinuationBackend {
    var createCalls: [CapturedInvocation] = []
    var resolveCalls: [PinnedReceipt] = []
    var acknowledgementCalls: [Acknowledgement] = []
    var acknowledgementReceipts: [PinnedReceipt] = []
    var directCalls: [URL] = []
    var resolveFailure: LinkFailure?
    var acknowledgementFailure: LinkFailure?
    var resolutionOverride: PinnedReceipt?
    var directDestination = LinkDestination(route: "places/detail", data: ["id": .string("canal-house")])
    var suspendNextResolution = false
    private var suspendedResolution: CheckedContinuation<PinnedReceipt, any Error>?
    private var resolutionObserver: CheckedContinuation<Void, Never>?

    func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        createCalls.append(invocation)
        throw LinkFailure.unverifiedContext
    }

    func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        resolveCalls.append(receipt)
        if suspendNextResolution {
            suspendNextResolution = false
            return try await withCheckedThrowingContinuation { continuation in
                suspendedResolution = continuation
                resolutionObserver?.resume()
                resolutionObserver = nil
            }
        }
        if let resolveFailure { throw resolveFailure }
        return resolutionOverride ?? receipt
    }

    func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        acknowledgementCalls.append(acknowledgement)
        acknowledgementReceipts.append(receipt)
        if let acknowledgementFailure { throw acknowledgementFailure }
    }

    func resolveDirect(_ url: URL) async throws -> LinkDestination {
        directCalls.append(url)
        return directDestination
    }

    func waitForSuspendedResolution() async {
        if suspendedResolution != nil { return }
        await withCheckedContinuation { resolutionObserver = $0 }
    }

    func releaseResolution(with receipt: PinnedReceipt) {
        let continuation = suspendedResolution
        suspendedResolution = nil
        continuation?.resume(returning: receipt)
    }
}

fileprivate enum CoordinatorChangedPin: CaseIterable, Equatable, Sendable {
    case canonicalLink, destination, receiptID, deliveryID

    func replacing(_ receipt: PinnedReceipt, with destination: LinkDestination) -> PinnedReceipt {
        PinnedReceipt(id: self == .receiptID ? UUID() : receipt.id,
                      deliveryID: self == .deliveryID ? UUID() : receipt.deliveryID,
                      invocation: receipt.invocation,
                      canonicalLinkID: self == .canonicalLink ? "reused-path-with-new-link" : receipt.canonicalLinkID,
                      destination: self == .destination ? destination : receipt.destination,
                      expiresAt: receipt.expiresAt)
    }
}

@MainActor
private final class CoordinatorHeldLock {
    private var descriptor: Int32

    init(directory: URL) throws {
        let path = directory.appendingPathComponent("SDKPrototype-v2/record.lock").path()
        descriptor = open(path, O_RDWR | O_CREAT, 0o600)
        guard descriptor >= 0 else { throw LinkFailure.storage }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            throw LinkFailure.busy
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        if descriptor >= 0 {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}
