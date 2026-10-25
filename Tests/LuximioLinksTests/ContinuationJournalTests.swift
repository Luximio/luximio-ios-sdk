import Foundation
import Darwin
import Testing
@testable import LuximioLinks

@MainActor
struct ContinuationJournalTests {
    @Test func aMissingOrNonDirectoryContainerFailsWithoutFallback() throws {
        #expect(throws: LinkFailure.configuration) { try ContinuationJournal(containerURL: nil) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: LinkFailure.configuration) { try ContinuationJournal(containerURL: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func anotherInstanceReadsExactContextWithoutChangingIdentifiersOrExpiry() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio?campaign=one&campaign=two&future=x%20y")
        try fixture.journal.capture(invocation)
        let reader = try ContinuationJournal(containerURL: fixture.directory)
        let restored = try #require(try reader.pending())

        #expect(restored.invocation == invocation)
        #expect(restored.phase == .captured)
        #expect(restored.receipt == nil)
        #expect(try reader.pending() == restored)
        let values = try fixture.storageDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.recordURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func newCaptureDiscardsAnUncommittedReceiptAndRetainsItsOutbox() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let first = fixture.invocation(path: "north-studio")
        let second = fixture.invocation(path: "canal-house")
        let receipt = fixture.receipt(first)
        try fixture.journal.capture(first)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: first.id, from: .pinned, to: .held))
        try fixture.journal.capture(second)

        #expect(try fixture.journal.pending()?.invocation == second)
        #expect(try fixture.journal.entry(id: first.id)?.phase == .discarded)
        let acknowledgement = try #require(try fixture.journal.acknowledgements().first)
        #expect(acknowledgement.receiptID == receipt.id)
        #expect(acknowledgement.outcome == .discarded)
        #expect(try fixture.journal.transition(id: first.id, from: .held, to: .applying) == false)
    }

    @Test func oldApplyingCompletionCannotEraseANewerPendingCapture() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let first = fixture.invocation(path: "north-studio")
        let second = fixture.invocation(path: "canal-house")
        let receipt = fixture.receipt(first)
        try fixture.journal.capture(first)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: first.id, from: .pinned, to: .applying))
        try fixture.journal.capture(second)
        #expect(try fixture.journal.entry(id: first.id)?.phase == .applying)

        let acknowledgement = fixture.acknowledgement(receipt, outcome: .applied)
        try #require(try fixture.journal.transition(id: first.id, from: .applying, to: .applied,
                                                  acknowledgement: acknowledgement))
        #expect(try fixture.journal.pending()?.invocation == second)
        #expect(try fixture.journal.entry(id: first.id)?.phase == .applied)
        #expect(try fixture.journal.acknowledgements() == [acknowledgement])
    }

    @Test func completionAndOutboxSurviveReopeningAndAcknowledgementDoesNotReplay() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        let receipt = fixture.receipt(invocation)
        let acknowledgement = fixture.acknowledgement(receipt, outcome: .applied)
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        try #require(try fixture.journal.transition(id: invocation.id, from: .applying, to: .applied,
                                                  acknowledgement: acknowledgement))
        let reader = try ContinuationJournal(containerURL: fixture.directory)
        #expect(try reader.pending() == nil)
        #expect(try reader.acknowledgements() == [acknowledgement])

        let wrong = Acknowledgement(receiptID: acknowledgement.receiptID,
                                    deliveryID: acknowledgement.deliveryID,
                                    operationID: UUID(), outcome: acknowledgement.outcome)
        try reader.completeAcknowledgement(wrong)
        #expect(try reader.acknowledgements() == [acknowledgement])
        try reader.completeAcknowledgement(acknowledgement)
        #expect(try reader.acknowledgements().isEmpty)
        #expect(try reader.entry(id: invocation.id)?.phase == .applied)
        try reader.capture(invocation)
        #expect(try reader.pending() == nil, "The same invocation cannot restart a completed delivery.")
    }

    @Test func anExactOutboxOperationCanRecoverItsPersistedBearerAfterRestart() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        let receipt = fixture.receipt(invocation)
        let acknowledgement = fixture.acknowledgement(receipt, outcome: .applied)
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        try #require(try fixture.journal.transition(id: invocation.id, from: .applying, to: .applied,
                                                  acknowledgement: acknowledgement))
        let reopened = try ContinuationJournal(containerURL: fixture.directory)
        #expect(try reopened.acknowledgementReceipt(acknowledgement) == receipt)
        let wrongOperation = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                             operationID: UUID(), outcome: .applied)
        #expect(try reopened.acknowledgementReceipt(wrongOperation) == nil)
        let wrongOutcome = Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                                           operationID: acknowledgement.operationID, outcome: .discarded)
        #expect(try reopened.acknowledgementReceipt(wrongOutcome) == nil)
        try reopened.completeAcknowledgement(acknowledgement)
        #expect(try reopened.acknowledgementReceipt(acknowledgement) == nil)
        #expect(try reopened.entry(id: invocation.id)?.phase == .applied)
    }

    @Test func anApplyingMarkerIsRetainedAcrossProcessRestartWithoutBecomingPinned() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(fixture.receipt(invocation)))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        let reader = try ContinuationJournal(containerURL: fixture.directory)

        #expect(try reader.pending()?.phase == .applying)
        #expect(try reader.pending()?.phase == .applying)
        #expect(try reader.acknowledgements().isEmpty)
    }

    @Test func anOldUncertainEntryCannotReturnToPendingAfterANewerCapture() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let first = fixture.invocation(path: "north-studio")
        let second = fixture.invocation(path: "canal-house")
        try fixture.journal.capture(first)
        try #require(try fixture.journal.pin(fixture.receipt(first)))
        try #require(try fixture.journal.transition(id: first.id, from: .pinned, to: .applying))
        try fixture.journal.capture(second)

        #expect(try fixture.journal.transition(id: first.id, from: .applying, to: .pinned) == false)
        #expect(try fixture.journal.transition(id: first.id, from: .applying, to: .held) == false)
        #expect(try fixture.journal.pending()?.invocation == second)
        #expect(try fixture.journal.entry(id: first.id)?.phase == .applying)
    }

    @Test func explicitCancellationPersistsEvenForAnUncertainEntry() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        let receipt = fixture.receipt(invocation)
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        try fixture.journal.cancelPending()
        let reader = try ContinuationJournal(containerURL: fixture.directory)

        #expect(try reader.pending() == nil)
        #expect(try reader.entry(id: invocation.id)?.phase == .discarded)
        #expect(try reader.acknowledgements().first?.outcome == .discarded)
        #expect(try reader.transition(id: invocation.id, from: .applying, to: .applied) == false)
    }

    @Test func pinningIsConditionalAndCannotChangeAnExistingPin() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let first = fixture.invocation(path: "north-studio")
        let second = fixture.invocation(path: "canal-house")
        try fixture.journal.capture(first)
        let receipt = fixture.receipt(first)
        try #require(try fixture.journal.pin(receipt))
        #expect(try fixture.journal.pin(receipt))
        let changed = PinnedReceipt(id: receipt.id, deliveryID: receipt.deliveryID, invocation: first,
                                    canonicalLinkID: "changed-id", destination: receipt.destination,
                                    expiresAt: receipt.expiresAt)
        #expect(throws: LinkFailure.conflict) { try fixture.journal.pin(changed) }
        try fixture.journal.capture(second)
        #expect(try fixture.journal.pin(receipt) == false)
        #expect(try fixture.journal.pending()?.invocation == second)
    }

    @Test func aConflictingTerminalAcknowledgementFailsWithoutChangingTheApplyingMarker() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        let receipt = fixture.receipt(invocation)
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(receipt))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        #expect(throws: LinkFailure.invalidData) {
            try fixture.journal.transition(id: invocation.id, from: .applying, to: .applied,
                                           acknowledgement: fixture.acknowledgement(receipt, outcome: .discarded))
        }
        #expect(try fixture.journal.entry(id: invocation.id)?.phase == .applying)
        #expect(try fixture.journal.acknowledgements().isEmpty)
    }

    @Test func identifiersAndOperationRequestsCannotBeReusedWithDifferentContent() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(invocation)
        let changed = CapturedInvocation(id: invocation.id, operationID: invocation.operationID,
                                         token: invocation.token, originalURL: invocation.originalURL + "?different=true",
                                         capturedAt: invocation.capturedAt, expiresAt: invocation.expiresAt,
                                         scope: invocation.scope)
        #expect(throws: LinkFailure.conflict) { try fixture.journal.capture(changed) }
        let reusedOperation = CapturedInvocation(id: UUID(), operationID: invocation.operationID,
                                                token: invocation.token, originalURL: invocation.originalURL,
                                                capturedAt: invocation.capturedAt, expiresAt: invocation.expiresAt,
                                                scope: invocation.scope)
        #expect(throws: LinkFailure.conflict) { try fixture.journal.capture(reusedOperation) }
        #expect(try fixture.journal.pending()?.invocation == invocation)
    }

    @Test func purgeRetainsMarkersAndOutboxUntilTheOriginalExpiryBoundary() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(fixture.receipt(invocation)))
        try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
        try #require(try fixture.journal.transition(id: invocation.id, from: .applying, to: .applied))
        let before = try #require(try fixture.journal.entry(id: invocation.id))
        try fixture.journal.purge(at: invocation.expiresAt.addingTimeInterval(-0.001))
        #expect(try fixture.journal.entry(id: invocation.id) == before)
        #expect(try fixture.journal.acknowledgements().count == 1)
        try fixture.journal.purge(at: invocation.expiresAt)
        #expect(try fixture.journal.entry(id: invocation.id) == nil)
        #expect(try fixture.journal.acknowledgements().isEmpty)
    }

    @Test(arguments: [JournalPhase.pinned, JournalPhase.applied])
    func aShorterServerDeadlinePurgesActiveContextAndTerminalMarkersAtTheBoundary(phase: JournalPhase) throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        let base = fixture.receipt(invocation)
        let receipt = PinnedReceipt(id: base.id, deliveryID: base.deliveryID, invocation: invocation,
                                    canonicalLinkID: base.canonicalLinkID, destination: base.destination,
                                    expiresAt: fixture.now.addingTimeInterval(3_600))
        try fixture.journal.capture(invocation)
        try #require(try fixture.journal.pin(receipt))
        if phase == .applied {
            try #require(try fixture.journal.transition(id: invocation.id, from: .pinned, to: .applying))
            try #require(try fixture.journal.transition(id: invocation.id, from: .applying, to: .applied))
        }
        let before = try #require(try fixture.journal.entry(id: invocation.id))
        try fixture.journal.purge(at: receipt.expiresAt.addingTimeInterval(-0.001))
        #expect(try fixture.journal.entry(id: invocation.id) == before)
        try fixture.journal.purge(at: receipt.expiresAt)
        #expect(try fixture.journal.entry(id: invocation.id) == nil)
        #expect(try fixture.journal.pending() == nil)
        #expect(try fixture.journal.acknowledgements().isEmpty)
        #expect(receipt.expiresAt < invocation.expiresAt)
    }

    @Test func exhaustingTheBoundDoesNotEvictAnUnexpiredMarkerOrReplacePending() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        var last = fixture.invocation(path: "north-studio")
        for _ in 0..<ContinuationJournal.maximumEntries {
            last = fixture.invocation(path: "north-studio")
            try fixture.journal.capture(last)
        }
        #expect(throws: LinkFailure.storage) {
            try fixture.journal.capture(fixture.invocation(path: "canal-house"))
        }
        #expect(try fixture.journal.pending()?.invocation == last)
        try fixture.journal.purge(at: last.expiresAt)
        let fresh = fixture.invocation(path: "canal-house", at: last.expiresAt)
        try fixture.journal.capture(fresh)
        #expect(try fixture.journal.pending()?.invocation == fresh)
    }

    @Test func anExactEightKiBURLAndFourKiBDestinationCanBePinnedAndReopened() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let prefix = "north-studio?context="
        let origin = "https://example.test/"
        let long = fixture.invocation(path: prefix + String(repeating: "a", count: 8_192 - origin.utf8.count - prefix.utf8.count))
        try fixture.journal.capture(long)
        let empty = LinkDestination(route: "places/detail", data: ["id": .string("")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let destination = LinkDestination(route: empty.route, data: [
            "id": .string(String(repeating: "a", count: 4_096 - (try encoder.encode(empty).count)))
        ])
        try destination.validate()
        let receipt = PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: long,
                                    canonicalLinkID: "immutable-link-id", destination: destination,
                                    expiresAt: long.expiresAt)
        try #require(try fixture.journal.pin(receipt))
        let reader = try ContinuationJournal(containerURL: fixture.directory)
        #expect(try reader.pending()?.receipt == receipt)
        #expect(try reader.pending()?.invocation.originalURL.utf8.count == 8_192)
        #expect(try encoder.encode(destination).count == 4_096)
        #expect(try Data(contentsOf: fixture.recordURL).count < ContinuationJournal.maximumEntryBytes)
    }

    @Test func oversizeURLDoesNotDamageThePreviouslyCommittedState() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let long = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(long)
        let prefix = "north-studio?context="
        let tooLong = fixture.invocation(path: prefix + String(repeating: "a", count: 8_193))
        #expect(throws: LinkFailure.invalidData) { try fixture.journal.capture(tooLong) }
        #expect(try fixture.journal.pending()?.invocation == long)
    }

    @Test(arguments: ["bad-json", "schema", "dangling-pointer", "duplicate-entry", "terminal-pointer", "bad-token", "orphaned-pending"])
    func malformedSnapshotsAreRejectedWithoutDeletingTheirEvidence(kind: String) throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(invocation)
        if kind == "bad-json" {
            try Data("{broken".utf8).write(to: fixture.recordURL)
        } else {
            var snapshot = try fixture.snapshot()
            var entries = try #require(snapshot["entries"] as? [[String: Any]])
            switch kind {
            case "schema": snapshot["schemaVersion"] = 999
            case "dangling-pointer": snapshot["pendingInvocationID"] = UUID().uuidString
            case "orphaned-pending": snapshot.removeValue(forKey: "pendingInvocationID")
            case "duplicate-entry": entries.append(entries[0]); snapshot["entries"] = entries
            case "terminal-pointer": entries[0]["phase"] = "discarded"; snapshot["entries"] = entries
            case "bad-token":
                var capture = try #require(entries[0]["invocation"] as? [String: Any])
                capture["token"] = "not-a-token"
                entries[0]["invocation"] = capture
                snapshot["entries"] = entries
            default: Issue.record("Unexpected corruption fixture")
            }
            try JSONSerialization.data(withJSONObject: snapshot).write(to: fixture.recordURL)
        }
        let bytes = try Data(contentsOf: fixture.recordURL)
        #expect(throws: LinkFailure.invalidData) { try fixture.journal.pending() }
        #expect(try Data(contentsOf: fixture.recordURL) == bytes)
    }

    @Test func anOversizeSnapshotIsRejectedBeforeItCanBeDecoded() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let bytes = Data(repeating: 32, count: ContinuationJournal.maximumSnapshotBytes + 1)
        try bytes.write(to: fixture.recordURL)
        #expect(throws: LinkFailure.invalidData) { try fixture.journal.pending() }
        #expect(try Data(contentsOf: fixture.recordURL).count == bytes.count)
    }

    @Test func anOversizeStoredEntryCannotHideItsSizeInAnUnknownField() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        try fixture.journal.capture(fixture.invocation(path: "north-studio"))
        var snapshot = try fixture.snapshot()
        var entries = try #require(snapshot["entries"] as? [[String: Any]])
        entries[0]["unknown"] = String(repeating: "x", count: ContinuationJournal.maximumEntryBytes)
        snapshot["entries"] = entries
        try JSONSerialization.data(withJSONObject: snapshot).write(to: fixture.recordURL)
        #expect(throws: LinkFailure.invalidData) { try fixture.journal.pending() }
    }

    @Test func anIndependentLockDescriptorCausesANonblockingTypedFailure() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let invocation = fixture.invocation(path: "north-studio")
        try fixture.journal.capture(invocation)
        let descriptor = fixture.lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(throws: LinkFailure.busy) { try fixture.journal.cancelPending() }
        try #require(flock(descriptor, LOCK_UN) == 0)
        #expect(try fixture.journal.pending()?.invocation == invocation)
    }

    @Test(arguments: ["record.lock", "journal-v2.json"])
    func journalFilesCannotFollowSymlinks(filename: String) throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        try fixture.journal.capture(fixture.invocation(path: "north-studio"))
        let target = fixture.directory.appendingPathComponent("outside.txt")
        let bytes = Data("outside data must stay intact".utf8)
        try bytes.write(to: target)
        let link = fixture.storageDirectory.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: LinkFailure.storage) { try fixture.journal.pending() }
        #expect(try Data(contentsOf: target) == bytes)
    }

    @Test func theJournalDirectoryCannotBeRedirectedThroughASymlink() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let target = fixture.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: fixture.storageDirectory)
        try FileManager.default.createSymbolicLink(at: fixture.storageDirectory, withDestinationURL: target)
        #expect(throws: LinkFailure.storage) { try fixture.journal.pending() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(throws: LinkFailure.configuration) { try ContinuationJournal(containerURL: fixture.storageDirectory) }
    }

    @Test func theNewJournalNeverReadsOrChangesTheLegacyPrototypeRecord() throws {
        let fixture = try JournalFixture()
        defer { fixture.cleanup() }
        let legacyDirectory = fixture.directory.appendingPathComponent("AppClipHandoff", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: false)
        let legacy = legacyDirectory.appendingPathComponent("pending-v1.json")
        let bytes = Data("legacy invocation deliberately left untouched".utf8)
        try bytes.write(to: legacy)
        #expect(try fixture.journal.pending() == nil)
        try fixture.journal.capture(fixture.invocation(path: "north-studio"))
        try fixture.journal.cancelPending()
        #expect(try Data(contentsOf: legacy) == bytes)
    }
}

@MainActor
private struct JournalFixture {
    let directory: URL
    let journal: ContinuationJournal
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var storageDirectory: URL { directory.appendingPathComponent("SDKPrototype-v2", isDirectory: true) }
    var lockURL: URL { storageDirectory.appendingPathComponent("record.lock") }
    var recordURL: URL { storageDirectory.appendingPathComponent("journal-v2.json") }
    private let scope = LinkScope(projectID: "journal-test", fullAppBundleID: "app.example.test",
                                  clipBundleID: "app.example.test.Clip")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        journal = try ContinuationJournal(containerURL: directory)
    }

    func invocation(path: String, at date: Date? = nil) -> CapturedInvocation {
        let captured = date ?? now
        return CapturedInvocation(id: UUID(), operationID: UUID(), token: String(repeating: "a", count: 43),
                                  originalURL: "https://example.test/" + path, capturedAt: captured,
                                  expiresAt: captured.addingTimeInterval(CapturedInvocation.lifetime), scope: scope)
    }

    func receipt(_ invocation: CapturedInvocation) -> PinnedReceipt {
        PinnedReceipt(id: UUID(), deliveryID: UUID(), invocation: invocation, canonicalLinkID: "immutable-link-id",
                      destination: LinkDestination(route: "places/detail", data: ["id": .string("north-studio")]),
                      expiresAt: invocation.expiresAt)
    }

    func acknowledgement(_ receipt: PinnedReceipt, outcome: Acknowledgement.Outcome) -> Acknowledgement {
        Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID, operationID: UUID(), outcome: outcome)
    }

    func snapshot() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
