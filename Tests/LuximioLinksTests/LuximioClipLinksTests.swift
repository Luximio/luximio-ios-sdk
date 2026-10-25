import Foundation
import Testing
@testable import LuximioLinks

@MainActor
struct LuximioClipLinksTests {
    private let scope = LinkScope(projectID: "project-test", fullAppBundleID: "app.test.full",
                                  clipBundleID: "app.test.full.Clip")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let destinations = [
        "/north": LinkDestination(route: "places/detail", data: ["id": .string("north")]),
        "/canal": LinkDestination(route: "places/detail", data: ["id": .string("canal")])
    ]

    private var configuration: LinksConfiguration {
        LinksConfiguration(scope: scope, role: .appClip, trustedHosts: ["links.example.com"],
                           appGroupIdentifier: "group.app.test.full")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    @Test func lostCreateResponseRetainsCaptureAndColdRetryPinsSameAction() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ContinuationJournal(containerURL: directory)
        let date = now
        let fixture = try FixtureContinuationBackend(configuration: configuration, destinations: destinations, now: { date })
        let backend = LostClipResponseBackend(fixture: fixture)
        let clip = try LuximioClipLinks(configuration: configuration, journal: journal, backend: backend,
                                        bundleIdentifier: scope.clipBundleID, now: { date })
        let url = try #require(URL(string: "https://links.example.com/north?utm_source=test&future=x%2By"))
        await #expect(throws: LinkFailure.network) { try await clip.capture(url) }
        let captured = try #require(try journal.pending())
        #expect(captured.phase == .captured)
        #expect(captured.receipt == nil)
        let reloadedJournal = try ContinuationJournal(containerURL: directory)
        let coldClip = try LuximioClipLinks(configuration: configuration, journal: reloadedJournal, backend: backend,
                                            bundleIdentifier: scope.clipBundleID, now: { date })
        let receipt = try await coldClip.retryCapture()
        #expect(receipt.invocation.id == captured.invocation.id)
        #expect(receipt.invocation.operationID == captured.invocation.operationID)
        #expect(receipt.invocation.expiresAt == captured.invocation.expiresAt)
        #expect(receipt.invocation.originalURL == url.absoluteString)
        #expect(receipt.id == backend.createdReceipt?.id)
        #expect(try reloadedJournal.pending()?.phase == .pinned)
    }

    @Test func aNewCaptureSupersedesDelayedOlderCreateBeforePinning() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ContinuationJournal(containerURL: directory)
        let date = now
        let fixture = try FixtureContinuationBackend(configuration: configuration, destinations: destinations, now: { date })
        let backend = DelayedClipBackend(fixture: fixture)
        let clip = try LuximioClipLinks(configuration: configuration, journal: journal, backend: backend,
                                        bundleIdentifier: scope.clipBundleID, now: { date })
        let north = try #require(URL(string: "https://links.example.com/north"))
        let canal = try #require(URL(string: "https://links.example.com/canal"))
        let first = Task { try await clip.capture(north) }
        let delayed = await backend.waitForFirstCreate()
        #expect(try journal.pending()?.invocation.id == delayed.id, "Capture must be durable before backend suspension.")
        let current = try await clip.capture(canal)
        await backend.releaseFirstCreate()
        await #expect(throws: LinkFailure.superseded) { try await first.value }
        #expect(try journal.pending()?.receipt?.id == current.id)
        #expect(current.destination.data["id"] == .string("canal"))
    }

    @Test func unpinnedCaptureExpiresRatherThanRenewingDuringRetry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ContinuationJournal(containerURL: directory)
        let clock = ClipTestClock(date: now)
        let fixture = try FixtureContinuationBackend(configuration: configuration, destinations: destinations, now: { clock.date })
        fixture.isAvailable = false
        let clip = try LuximioClipLinks(configuration: configuration, journal: journal, backend: fixture,
                                        bundleIdentifier: scope.clipBundleID, now: { clock.date })
        let url = try #require(URL(string: "https://links.example.com/north"))
        await #expect(throws: LinkFailure.network) { try await clip.capture(url) }
        clock.date = now.addingTimeInterval(CapturedInvocation.lifetime)
        fixture.isAvailable = true
        await #expect(throws: LinkFailure.expired) { try await clip.retryCapture() }
    }

    @Test func invalidNewInvocationCancelsOlderPinInsteadOfLeavingStaleHandoff() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ContinuationJournal(containerURL: directory)
        let date = now
        let fixture = try FixtureContinuationBackend(configuration: configuration, destinations: destinations, now: { date })
        let clip = try LuximioClipLinks(configuration: configuration, journal: journal, backend: fixture,
                                        bundleIdentifier: scope.clipBundleID, now: { date })
        let north = try #require(URL(string: "https://links.example.com/north"))
        let invalid = try #require(URL(string: "https://untrusted.example.com/canal"))
        let old = try await clip.capture(north)
        await #expect(throws: LinkFailure.untrustedURL) { try await clip.capture(invalid) }
        #expect(try journal.pending() == nil)
        #expect(try journal.entry(id: old.invocation.id)?.phase == .discarded)
    }

    @Test func aNewCaptureAlsoSuppressesDelayedOlderBackendErrors() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = try ContinuationJournal(containerURL: directory)
        let date = now
        let fixture = try FixtureContinuationBackend(configuration: configuration, destinations: destinations, now: { date })
        let backend = DelayedClipBackend(fixture: fixture)
        let clip = try LuximioClipLinks(configuration: configuration, journal: journal, backend: backend,
                                        bundleIdentifier: scope.clipBundleID, now: { date })
        let north = try #require(URL(string: "https://links.example.com/north"))
        let canal = try #require(URL(string: "https://links.example.com/canal"))
        let first = Task { try await clip.capture(north) }
        _ = await backend.waitForFirstCreate()
        let current = try await clip.capture(canal)
        await backend.releaseFirstCreate(error: .network)
        await #expect(throws: LinkFailure.superseded) { try await first.value }
        #expect(try journal.pending()?.receipt?.id == current.id)
    }
}

@MainActor
private final class ClipTestClock {
    var date: Date
    init(date: Date) { self.date = date }
}

@MainActor
private final class LostClipResponseBackend: ContinuationBackend {
    let fixture: FixtureContinuationBackend
    var createdReceipt: PinnedReceipt?
    private var firstResponse = true
    init(fixture: FixtureContinuationBackend) { self.fixture = fixture }

    func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        let receipt = try await fixture.create(invocation)
        createdReceipt = receipt
        if firstResponse {
            firstResponse = false
            throw LinkFailure.network
        }
        return receipt
    }
    func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt { try await fixture.resolve(receipt) }
    func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try await fixture.acknowledge(acknowledgement, receipt: receipt)
    }
    func resolveDirect(_ url: URL) async throws -> LinkDestination { try await fixture.resolveDirect(url) }
}

@MainActor
private final class DelayedClipBackend: ContinuationBackend {
    let fixture: FixtureContinuationBackend
    private var firstInvocation: CapturedInvocation?
    private var waiter: CheckedContinuation<CapturedInvocation, Never>?
    private var firstResponse: CheckedContinuation<PinnedReceipt, any Error>?
    init(fixture: FixtureContinuationBackend) { self.fixture = fixture }

    func create(_ invocation: CapturedInvocation) async throws -> PinnedReceipt {
        if firstInvocation == nil {
            firstInvocation = invocation
            waiter?.resume(returning: invocation)
            waiter = nil
            return try await withCheckedThrowingContinuation { firstResponse = $0 }
        }
        return try await fixture.create(invocation)
    }

    func waitForFirstCreate() async -> CapturedInvocation {
        if let firstInvocation { return firstInvocation }
        return await withCheckedContinuation { waiter = $0 }
    }

    func releaseFirstCreate(error: LinkFailure? = nil) async {
        guard let firstInvocation, let firstResponse else { return }
        self.firstResponse = nil
        if let error {
            firstResponse.resume(throwing: error)
            return
        }
        do { firstResponse.resume(returning: try await fixture.create(firstInvocation)) }
        catch { firstResponse.resume(throwing: error) }
    }

    func resolve(_ receipt: PinnedReceipt) async throws -> PinnedReceipt { try await fixture.resolve(receipt) }
    func acknowledge(_ acknowledgement: Acknowledgement, receipt: PinnedReceipt) async throws {
        try await fixture.acknowledge(acknowledgement, receipt: receipt)
    }
    func resolveDirect(_ url: URL) async throws -> LinkDestination { try await fixture.resolveDirect(url) }
}
