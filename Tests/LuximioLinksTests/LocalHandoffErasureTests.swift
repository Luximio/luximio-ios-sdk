import Foundation
import Testing
@testable import LuximioLinks

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct LocalHandoffErasureTests {
    @Test(arguments: [JournalPhase.applied, .discarded])
    func terminalErasureRemovesOnlySelectedPayloadAndSurvivesReopen(phase: JournalPhase) throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let neighbor = try f.terminal("neighbor")
        let outside = try f.terminal("outside", scope: f.otherScope)
        let selected = try f.terminal("selected", phase: phase)
        let preserved = [try f.journal.entry(id: neighbor.invocation.id), try f.journal.entry(id: outside.invocation.id)]
        #expect(try f.snapshot()["schemaVersion"] as? Int == 2)

        #expect(try f.journal.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .erased)
        let reopened = try ContinuationJournal(containerURL: f.directory)
        #expect(try reopened.entry(id: selected.invocation.id) == nil)
        #expect(try reopened.pending() == nil)
        #expect(try reopened.acknowledgements().isEmpty)
        #expect([try reopened.entry(id: neighbor.invocation.id), try reopened.entry(id: outside.invocation.id)] == preserved)
        let text = String(decoding: try f.bytes(), as: UTF8.self)
        #expect(text.contains(selected.invocation.originalURL) == false)
        #expect(text.contains(selected.invocation.token) == false)
        #expect(text.contains("private_selected_payload") == false)
        #expect(text.contains(neighbor.invocation.originalURL))
        #expect(try f.snapshot()["schemaVersion"] as? Int == 3)
        let before = try f.bytes()
        #expect(try reopened.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .alreadyErased)
        #expect(try f.bytes() == before)
        #expect(try reopened.pin(selected) == false)
        #expect(try reopened.transition(id: selected.invocation.id, from: .discarded, to: .applied) == false)
        #expect(try f.bytes() == before)
    }

    @Test(arguments: ["captured", "pinned", "held", "applying", "unacknowledged", "unpinned-discarded"])
    func incompleteOrUnacknowledgedEntriesCannotBeErased(kind: String) throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let receipt = f.receipt("not-ready")
        try f.journal.capture(receipt.invocation)
        if kind != "captured" && kind != "unpinned-discarded" { try #require(try f.journal.pin(receipt)) }
        switch kind {
        case "held": try #require(try f.journal.transition(id: receipt.invocation.id, from: .pinned, to: .held))
        case "applying": try #require(try f.journal.transition(id: receipt.invocation.id, from: .pinned, to: .applying))
        case "unacknowledged": try f.journal.cancelPending()
        case "unpinned-discarded": try f.journal.cancelPending()
        default: break
        }
        let before = try f.bytes()
        let failure: LinkFailure = kind == "unpinned-discarded" ? .unverifiedContext : .busy
        #expect(throws: failure) { try f.journal.eraseCompleted(invocationID: receipt.invocation.id, scope: f.scope) }
        #expect(try f.bytes() == before)
    }

    @Test func wrongScopeAndUnknownIdentifiersNeverMutateTheJournal() throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        #expect(try f.journal.eraseCompleted(invocationID: UUID(), scope: f.scope) == .notFound)
        #expect(FileManager.default.fileExists(atPath: f.file.path) == false)
        let receipt = try f.terminal("selected")
        let before = try f.bytes()
        #expect(throws: LinkFailure.wrongScope) {
            try f.journal.eraseCompleted(invocationID: receipt.invocation.id, scope: f.otherScope)
        }
        #expect(try f.bytes() == before)
        #expect(try f.journal.eraseCompleted(invocationID: UUID(), scope: f.scope) == .notFound)
        #expect(try f.bytes() == before)
        try #require(try f.journal.eraseCompleted(invocationID: receipt.invocation.id, scope: f.scope) == .erased)
        let erased = try f.bytes()
        #expect(throws: LinkFailure.wrongScope) {
            try f.journal.eraseCompleted(invocationID: receipt.invocation.id, scope: f.otherScope)
        }
        #expect(try f.bytes() == erased)
    }

    @Test(arguments: ["exact", "same-id", "same-operation", "same-capability"])
    func replayCannotReintroduceContextOrDisplaceANewerCapture(kind: String) throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let selected = try f.terminal("selected")
        try #require(try f.journal.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .erased)
        let fresh = f.receipt("fresh").invocation
        try f.journal.capture(fresh)
        let original = selected.invocation
        let replay = kind == "exact" ? original : CapturedInvocation(
            id: kind == "same-id" ? original.id : UUID(),
            operationID: kind == "same-operation" ? original.operationID : UUID(),
            token: kind == "same-capability" ? original.token : fresh.token,
            originalURL: original.originalURL + "&changed=true", capturedAt: original.capturedAt,
            expiresAt: original.expiresAt, scope: original.scope)
        let before = try f.bytes()
        #expect(throws: LinkFailure.conflict) { try f.journal.capture(replay) }
        #expect(try f.bytes() == before)
        #expect(try f.journal.pending()?.invocation == fresh)
        #expect(try f.journal.acknowledgements().isEmpty)
    }

    @Test func markerUsesOriginalCaptureExpiryAndNeverDowngradesSchema() throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let selected = try f.terminal("short-receipt", receiptLifetime: 60)
        try #require(try f.journal.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .erased)
        let reopened = try ContinuationJournal(containerURL: f.directory)
        try reopened.purge(at: selected.expiresAt)
        #expect(try reopened.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .alreadyErased)
        try reopened.purge(at: selected.invocation.expiresAt.addingTimeInterval(-1))
        #expect(try reopened.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .alreadyErased)
        try reopened.purge(at: selected.invocation.expiresAt)
        #expect(try reopened.eraseCompleted(invocationID: selected.invocation.id, scope: f.scope) == .notFound)
        #expect(try f.snapshot()["schemaVersion"] as? Int == 3)
        #expect((try f.snapshot()["erasures"] as? [Any])?.isEmpty == true)
    }

    @Test func markersConsumeCapacityAndCannotBeEvictedToAdmitNewContext() throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        for number in 0..<ContinuationJournal.maximumEntries {
            let entry = try f.terminal("entry-\(number)")
            try #require(try f.journal.eraseCompleted(invocationID: entry.invocation.id, scope: f.scope) == .erased)
        }
        let before = try f.bytes()
        #expect(throws: LinkFailure.storage) { try f.journal.capture(f.receipt("over-capacity").invocation) }
        #expect(try f.bytes() == before)
        #expect((try f.snapshot()["erasures"] as? [Any])?.count == ContinuationJournal.maximumEntries)
    }

    @Test func aSharedLegacyCapabilityDoesNotAllowErasureOfAnotherEntry() throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let first = try f.terminal("first")
        let candidate = f.receipt("second")
        let reused = CapturedInvocation(id: candidate.invocation.id, operationID: candidate.invocation.operationID,
            token: first.invocation.token, originalURL: candidate.invocation.originalURL,
            capturedAt: candidate.invocation.capturedAt, expiresAt: candidate.invocation.expiresAt, scope: f.scope)
        try f.journal.capture(reused)
        let receipt = PinnedReceipt(id: candidate.id, deliveryID: candidate.deliveryID, invocation: reused,
            canonicalLinkID: candidate.canonicalLinkID, destination: candidate.destination, expiresAt: candidate.expiresAt)
        try #require(try f.journal.pin(receipt))
        try f.journal.cancelPending()
        for operation in try f.journal.acknowledgements() { try f.journal.completeAcknowledgement(operation) }
        let before = try f.bytes()
        #expect(throws: LinkFailure.conflict) { try f.journal.eraseCompleted(invocationID: first.invocation.id, scope: f.scope) }
        #expect(try f.bytes() == before)
    }

    @Test(arguments: ["missing-list", "v2-markers", "bad-hash", "bad-date", "bad-scope", "duplicate-marker", "duplicate-operation", "duplicate-capability", "raw-collision", "unknown-marker-field"])
    func malformedMarkersFailClosedAndPreserveEvidence(kind: String) throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let receipt = try f.terminal("selected")
        let original = try f.snapshot()
        try #require(try f.journal.eraseCompleted(invocationID: receipt.invocation.id, scope: f.scope) == .erased)
        var snapshot = try f.snapshot()
        var markers = try #require(snapshot["erasures"] as? [[String: Any]])
        switch kind {
        case "missing-list": snapshot.removeValue(forKey: "erasures")
        case "v2-markers": snapshot["schemaVersion"] = 2
        case "bad-hash": markers[0]["capabilityHash"] = "not-a-hash"
        case "bad-date": markers[0]["expiresAt"] = markers[0]["capturedAt"]
        case "bad-scope": markers[0]["scope"] = ["projectID": "missing-bundle-identities"]
        case "duplicate-marker": markers.append(markers[0])
        case "duplicate-operation", "duplicate-capability":
            var duplicate = markers[0]
            duplicate["invocationID"] = UUID().uuidString
            if kind == "duplicate-operation" { duplicate["capabilityHash"] = String(repeating: "b", count: 64) }
            else { duplicate["operationID"] = UUID().uuidString }
            markers.append(duplicate)
        case "raw-collision": snapshot["entries"] = original["entries"]
        case "unknown-marker-field": markers[0]["secretPayload"] = "should-not-be-accepted"
        default: Issue.record("Unknown malformed marker case")
        }
        if kind != "missing-list" { snapshot["erasures"] = markers }
        try JSONSerialization.data(withJSONObject: snapshot).write(to: f.file)
        let evidence = try f.bytes()
        #expect(throws: LinkFailure.invalidData) { try f.journal.pending() }
        #expect(try f.bytes() == evidence)
    }

    @Test func tokenSessionScopesErasureAndClipAndFullAppReadTheSameMarker() throws {
        let f = try ErasureFixture()
        defer { f.cleanup() }
        let config = f.configuration()
        let full = try TokenRecoverySession(configuration: config, containerURL: f.directory)
        let selected = try f.terminal("selected", journal: full.journal)
        let other = try TokenRecoverySession(configuration: f.configuration(scope: f.otherScope), containerURL: f.directory)
        let untouched = try f.terminal("other-project", scope: f.otherScope, journal: other.journal)
        #expect(try other.eraseCompleted(invocationID: selected.invocation.id) == .notFound)
        let clip = try TokenRecoverySession(configuration: f.configuration(role: .appClip), containerURL: f.directory)
        #expect(try clip.eraseCompleted(invocationID: selected.invocation.id) == .erased)
        #expect(try full.journal.entry(id: selected.invocation.id) == nil)
        #expect(try full.eraseCompleted(invocationID: selected.invocation.id) == .alreadyErased)
        #expect(try other.journal.entry(id: untouched.invocation.id)?.receipt == untouched)
    }
}

@MainActor
private struct ErasureFixture {
    let directory: URL
    let journal: ContinuationJournal
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let scope = LinkScope(projectID: "project_erasure", fullAppBundleID: "app.example.erase", clipBundleID: "app.example.erase.Clip")
    let otherScope = LinkScope(projectID: "project_other", fullAppBundleID: "app.example.erase", clipBundleID: "app.example.erase.Clip")
    var file: URL { directory.appendingPathComponent("SDKPrototype-v2/journal-v2.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        journal = try ContinuationJournal(containerURL: directory)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func bytes() throws -> Data { try Data(contentsOf: file) }
    func snapshot() throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: bytes()) as? [String: Any]) }
    func configuration(scope selected: LinkScope? = nil, role: LinksConfiguration.Role = .fullApp) -> LinksConfiguration {
        LinksConfiguration(scope: selected ?? scope, role: role, trustedHosts: ["erasure.example.com"], appGroupIdentifier: "group.app.example.erase")
    }
    func receipt(_ label: String, scope selected: LinkScope? = nil, receiptLifetime: TimeInterval = 600) -> PinnedReceipt {
        let invocation = CapturedInvocation(id: UUID(), operationID: UUID(),
            token: Data(UUID().uuidString.utf8.prefix(32)).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
            originalURL: "https://erasure.example.com/detail?synthetic=" + label, capturedAt: now,
            expiresAt: now.addingTimeInterval(3600), scope: selected ?? scope)
        return PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: invocation,
            canonicalLinkID: "link_" + label, destination: LinkDestination(route: "public/detail", data: ["label": .string("private_" + label + "_payload")]),
            expiresAt: now.addingTimeInterval(receiptLifetime))
    }
    func terminal(_ label: String, phase: JournalPhase = .applied, scope selected: LinkScope? = nil,
                  receiptLifetime: TimeInterval = 600, journal selectedJournal: ContinuationJournal? = nil) throws -> PinnedReceipt {
        let target = selectedJournal ?? journal
        let receipt = receipt(label, scope: selected, receiptLifetime: receiptLifetime)
        try target.capture(receipt.invocation)
        try #require(try target.pin(receipt))
        if phase == .applied { try #require(try target.transition(id: receipt.invocation.id, from: .pinned, to: .applying)) }
        try #require(try target.transition(id: receipt.invocation.id, from: phase == .applied ? .applying : .pinned, to: phase))
        let acknowledgement = try #require(try target.acknowledgements().first { $0.receiptID == receipt.id })
        try target.completeAcknowledgement(acknowledgement)
        return receipt
    }
}
