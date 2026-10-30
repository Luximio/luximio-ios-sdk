import Foundation
import Testing
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalErasureRaceTests {
    @Test func anOldClipCreateResponseCannotRepinAnEntryErasedByTheOtherRole() async throws {
        let fixture = try ErasureRaceFixture()
        defer { fixture.cleanup() }
        let neighbor = try fixture.seedCompletedNeighbor()
        let backend = ErasureRaceBackend(suspending: .create)
        defer { backend.releaseUnfinished() }
        let clip = try LuximioClipLinks(configuration: fixture.configuration(role: .appClip),
            journal: fixture.journal, backend: backend,
            bundleIdentifier: fixture.scope.clipBundleID, now: { fixture.now })
        let capture = Task { try await clip.capture(fixture.url("selected")) }
        await backend.waitUntilSuspended()
        let invocation = try #require(backend.createdInvocation)
        let receipt = fixture.receipt(invocation)
        let writer = try fixture.reopenedJournal()

        // The second role has obtained the same idempotent server receipt.
        // Captured-only work is not eligible for erasure; pin and confirm its
        // discard before removing the readable local entry.
        #expect(throws: LinkFailure.busy) {
            try writer.eraseCompleted(invocationID: invocation.id, scope: fixture.scope)
        }
        try #require(try writer.pin(receipt))
        try writer.cancelPending()
        let acknowledgement = try #require(try writer.acknowledgements().first)
        try writer.completeAcknowledgement(acknowledgement)
        #expect(try writer.eraseCompleted(invocationID: invocation.id, scope: fixture.scope) == .erased)

        backend.releaseReceipt(receipt)
        await #expect(throws: LinkFailure.superseded) { try await capture.value }

        try fixture.expectErased(invocation, preserving: neighbor)
        #expect(try fixture.journal.pin(receipt) == false)
        #expect(throws: LinkFailure.conflict) { try fixture.journal.capture(invocation) }
        #expect(backend.createdInvocation == invocation)
        #expect(backend.resolveCalls == 0)
    }

    @Test func anOldFullAppResolveResponseCannotRouteOrRecreateAnErasedEntry() async throws {
        let fixture = try ErasureRaceFixture()
        defer { fixture.cleanup() }
        let neighbor = try fixture.seedCompletedNeighbor()
        let receipt = try fixture.seedPending()
        let backend = ErasureRaceBackend(suspending: .resolve)
        defer { backend.releaseUnfinished() }
        var routed: [LinkDelivery] = []
        let client = try fixture.client(backend: backend) { routed.append($0); return .applied }
        let oldWork = try #require(client.resume(.activation))
        await backend.waitUntilSuspended()
        let writer = try fixture.reopenedJournal()
        try writer.cancelPending()
        let acknowledgement = try #require(try writer.acknowledgements().first)
        try writer.completeAcknowledgement(acknowledgement)
        #expect(try writer.eraseCompleted(invocationID: receipt.invocation.id, scope: fixture.scope) == .erased)

        backend.releaseReceipt(receipt)
        await oldWork.value
        await client.waitUntilIdle()

        #expect(routed.isEmpty)
        try fixture.expectErased(receipt.invocation, preserving: neighbor)
        let restarted = try fixture.client(journal: fixture.reopenedJournal(), backend: backend) {
            routed.append($0); return .applied
        }
        await restarted.resume(.activation)?.value
        await restarted.waitUntilIdle()
        #expect(routed.isEmpty)
        #expect(backend.resolveCalls == 1)
        #expect(throws: LinkFailure.conflict) { try writer.capture(receipt.invocation) }
    }

    @Test func acknowledgementInFlightBlocksErasureAndItsLateSuccessCannotRestoreAnErasedEntry() async throws {
        let fixture = try ErasureRaceFixture()
        defer { fixture.cleanup() }
        let neighbor = try fixture.seedCompletedNeighbor()
        let receipt = try fixture.seedPending()
        try fixture.journal.cancelPending()
        let acknowledgement = try #require(try fixture.journal.acknowledgements().first)
        let backend = ErasureRaceBackend(suspending: .acknowledge)
        defer { backend.releaseUnfinished() }
        var routed: [LinkDelivery] = []
        let client = try fixture.client(backend: backend) { routed.append($0); return .applied }
        client.resume(.activation)
        await backend.waitUntilSuspended()
        let writer = try fixture.reopenedJournal()

        #expect(throws: LinkFailure.busy) {
            try writer.eraseCompleted(invocationID: receipt.invocation.id, scope: fixture.scope)
        }
        #expect(try writer.entry(id: receipt.invocation.id)?.acknowledgement == acknowledgement)
        // Another role confirms that exact operation first. The delayed caller
        // still owns its original receipt, but cannot reinsert it after erasure.
        try writer.completeAcknowledgement(acknowledgement)
        #expect(try writer.eraseCompleted(invocationID: receipt.invocation.id, scope: fixture.scope) == .erased)
        backend.releaseAcknowledgement()
        await client.waitUntilIdle()

        #expect(backend.acknowledgeCalls == 1)
        #expect(routed.isEmpty)
        try fixture.expectErased(receipt.invocation, preserving: neighbor)
        #expect(try writer.eraseCompleted(invocationID: receipt.invocation.id, scope: fixture.scope) == .alreadyErased)
        let restarted = try fixture.client(journal: fixture.reopenedJournal(), backend: backend) {
            routed.append($0); return .applied
        }
        await restarted.resume(.activation)?.value
        await restarted.waitUntilIdle()
        #expect(backend.acknowledgeCalls == 1)
        #expect(routed.isEmpty)
    }
}

@MainActor
private struct ErasureRaceFixture {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = LinkScope(projectID: "project-erasure-races", fullAppBundleID: "app.example.erasure",
                          clipBundleID: "app.example.erasure.Clip")
    let directory: URL
    let journal: ContinuationJournal

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("luximio-erasure-race-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        journal = try ContinuationJournal(containerURL: directory)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func configuration(role: LinksConfiguration.Role = .fullApp) -> LinksConfiguration {
        LinksConfiguration(scope: scope, role: role, trustedHosts: ["erasure.links.example.com"],
                           appGroupIdentifier: "group.app.example.erasure")
    }

    func url(_ path: String) throws -> URL { try #require(URL(string: "https://erasure.links.example.com/" + path)) }

    func receipt(_ invocation: CapturedInvocation) -> PinnedReceipt {
        PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: invocation,
                      canonicalLinkID: "synthetic-erasure-link", destination: LinkDestination(route: "public/detail", data: [:]),
                      expiresAt: invocation.expiresAt)
    }

    func seedPending(_ label: String = "selected") throws -> PinnedReceipt {
        let invocation = try CapturedInvocation.capture(url: url(label), configuration: configuration(), at: now)
        try journal.capture(invocation)
        let value = receipt(invocation)
        try #require(try journal.pin(value))
        return value
    }

    func seedCompletedNeighbor() throws -> JournalEntry {
        let value = try seedPending("unrelated-neighbor")
        try #require(try journal.transition(id: value.invocation.id, from: .pinned, to: .applying))
        try #require(try journal.transition(id: value.invocation.id, from: .applying, to: .applied))
        let operation = try #require(try journal.acknowledgements().first)
        try journal.completeAcknowledgement(operation)
        return try #require(try journal.entry(id: value.invocation.id))
    }

    func reopenedJournal() throws -> ContinuationJournal { try ContinuationJournal(containerURL: directory) }

    func client(journal supplied: ContinuationJournal? = nil, backend: ErasureRaceBackend,
                route: @escaping @MainActor (LinkDelivery) -> LinkDisposition) throws -> LuximioLinks {
        try LuximioLinks(configuration: configuration(), journal: supplied ?? journal, backend: backend,
                         bundleIdentifier: scope.fullAppBundleID, now: { now }, route: route)
    }

    func expectErased(_ invocation: CapturedInvocation, preserving neighbor: JournalEntry) throws {
        let reopened = try reopenedJournal()
        #expect(try reopened.entry(id: invocation.id) == nil)
        #expect(try reopened.pending() == nil)
        #expect(try reopened.acknowledgements().isEmpty)
        #expect(try reopened.entry(id: neighbor.invocation.id) == neighbor)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("SDKPrototype-v2/journal-v2.json"))
        #expect(bytes.range(of: Data(invocation.originalURL.utf8)) == nil)
        #expect(bytes.range(of: Data(invocation.token.utf8)) == nil)
    }
}

@MainActor
private final class ErasureRaceBackend: ContinuationBackend {
    enum Operation { case create, resolve, acknowledge }
    let suspending: Operation
    var createdInvocation: CapturedInvocation?
    var resolveCalls = 0
    var acknowledgeCalls = 0
    private var receiptContinuation: CheckedContinuation<PinnedReceipt, any Error>?
    private var acknowledgementContinuation: CheckedContinuation<Void, any Error>?
    private var suspensionObserver: CheckedContinuation<Void, Never>?

    init(suspending: Operation) { self.suspending = suspending }

    func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        createdInvocation = invocation
        return try await withCheckedThrowingContinuation {
            receiptContinuation = $0
            resumeObserver()
        }
    }

    func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt {
        resolveCalls += 1
        guard suspending == .resolve else { return receipt }
        return try await withCheckedThrowingContinuation {
            receiptContinuation = $0
            resumeObserver()
        }
    }

    func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        acknowledgeCalls += 1
        guard suspending == .acknowledge else { return }
        try await withCheckedThrowingContinuation {
            acknowledgementContinuation = $0
            resumeObserver()
        }
    }

    func resolveDirect(_ url: URL) async throws -> LinkDestination { throw LinkFailure.unavailable }

    func waitUntilSuspended() async {
        if receiptContinuation != nil || acknowledgementContinuation != nil { return }
        await withCheckedContinuation { suspensionObserver = $0 }
    }

    func releaseReceipt(_ receipt: PinnedReceipt) {
        let continuation = receiptContinuation
        receiptContinuation = nil
        continuation?.resume(returning: receipt)
    }

    func releaseAcknowledgement() {
        let continuation = acknowledgementContinuation
        acknowledgementContinuation = nil
        continuation?.resume()
    }

    func releaseUnfinished() {
        let receipt = receiptContinuation
        receiptContinuation = nil
        receipt?.resume(throwing: LinkFailure.network)
        let acknowledgement = acknowledgementContinuation
        acknowledgementContinuation = nil
        acknowledgement?.resume(throwing: LinkFailure.network)
        resumeObserver()
    }

    private func resumeObserver() {
        suspensionObserver?.resume()
        suspensionObserver = nil
    }
}
