import Foundation
import Darwin

public enum JournalPhase: String, Codable, Equatable, Sendable {
    case captured, pinned, held, applying, applied, discarded
}

public struct JournalEntry: Codable, Equatable, Sendable {
    public let invocation: CapturedInvocation
    public var receipt: PinnedReceipt?
    public var phase: JournalPhase
    public var acknowledgement: Acknowledgement?

    public init(invocation: CapturedInvocation, receipt: PinnedReceipt? = nil,
                phase: JournalPhase = .captured, acknowledgement: Acknowledgement? = nil) {
        self.invocation = invocation
        self.receipt = receipt
        self.phase = phase
        self.acknowledgement = acknowledgement
    }

    private enum CodingKeys: String, CodingKey { case invocation, receipt, phase, acknowledgement }

    // The receipt's immutable invocation is the entry invocation. Store it once,
    // leaving room for an 8 KiB URL and 4 KiB destination in the 16 KiB bound.
    private struct StoredReceipt: Codable {
        let id: UUID
        let deliveryID: UUID
        let canonicalLinkID: String
        let destination: LinkDestination
        let expiresAt: Date

        init(_ receipt: PinnedReceipt) {
            id = receipt.id
            deliveryID = receipt.deliveryID
            canonicalLinkID = receipt.canonicalLinkID
            destination = receipt.destination
            expiresAt = receipt.expiresAt
        }

        func receipt(invocation: CapturedInvocation) -> PinnedReceipt {
            PinnedReceipt(id: id, deliveryID: deliveryID, invocation: invocation,
                          canonicalLinkID: canonicalLinkID, destination: destination, expiresAt: expiresAt)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        invocation = try container.decode(CapturedInvocation.self, forKey: .invocation)
        receipt = try container.decodeIfPresent(StoredReceipt.self, forKey: .receipt)?.receipt(invocation: invocation)
        phase = try container.decode(JournalPhase.self, forKey: .phase)
        acknowledgement = try container.decodeIfPresent(Acknowledgement.self, forKey: .acknowledgement)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(invocation, forKey: .invocation)
        try container.encodeIfPresent(receipt.map(StoredReceipt.init), forKey: .receipt)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(acknowledgement, forKey: .acknowledgement)
    }
}

/// Protected local receipt state for one corresponding App Clip/full-app pair.
/// Transactions are synchronous and bounded; callers never hold a lock across
/// a network request or application router callback.
@MainActor
public final class ContinuationJournal {
    public static let maximumEntries = 32
    public static let maximumEntryBytes = 16_384
    public static let maximumSnapshotBytes = 524_288
    private static let maximumURLBytes = 8_192
    private static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    private let containerURL: URL

    public init(containerURL: URL?) throws {
        guard let containerURL, containerURL.isFileURL,
              Self.isOrdinaryDirectory(containerURL) else { throw LinkFailure.configuration }
        self.containerURL = containerURL.standardizedFileURL
        // Verify access now, without reading, changing or migrating a legacy file.
        try withLock { _ in () }
    }

    /// Repeated storage of an identical invocation is harmless. A new invocation
    /// supersedes only an uncommitted pending entry, retaining terminal markers
    /// and any older application commitment and acknowledgement outbox.
    public func capture(_ invocation: CapturedInvocation) throws {
        try mutate { snapshot in
            if let existing = snapshot.entries.first(where: { $0.invocation.id == invocation.id }) {
                guard existing.invocation == invocation else { throw LinkFailure.conflict }
                return ((), false)
            }
            guard !snapshot.entries.contains(where: {
                $0.invocation.operationID == invocation.operationID
            }) else { throw LinkFailure.conflict }
            guard snapshot.entries.count < Self.maximumEntries else { throw LinkFailure.storage }
            if let previous = snapshot.pendingInvocationID,
               let index = snapshot.entries.firstIndex(where: { $0.invocation.id == previous }),
               [.captured, .pinned, .held].contains(snapshot.entries[index].phase) {
                Self.discard(&snapshot.entries[index])
            }
            snapshot.entries.append(JournalEntry(invocation: invocation))
            snapshot.pendingInvocationID = invocation.id
            return ((), true)
        }
    }

    /// Expiry is intentionally explicit: the coordinator calls purge(at:) using
    /// its injected clock. Reading does not renew, replay or consume a receipt.
    public func pending() throws -> JournalEntry? {
        try read { snapshot in
            guard let id = snapshot.pendingInvocationID else { return nil }
            return snapshot.entries.first { $0.invocation.id == id }
        }
    }

    public func entry(id: UUID) throws -> JournalEntry? {
        try read { $0.entries.first { $0.invocation.id == id } }
    }

    @discardableResult
    public func pin(_ receipt: PinnedReceipt) throws -> Bool {
        try mutate { snapshot in
            guard snapshot.pendingInvocationID == receipt.invocation.id,
                  let index = snapshot.entries.firstIndex(where: {
                      $0.invocation.id == receipt.invocation.id
                  }) else { return (false, false) }
            guard snapshot.entries[index].invocation == receipt.invocation else {
                throw LinkFailure.conflict
            }
            if let current = snapshot.entries[index].receipt {
                guard current == receipt else { throw LinkFailure.conflict }
                return ([.pinned, .held].contains(snapshot.entries[index].phase), false)
            }
            guard snapshot.entries[index].phase == .captured else { return (false, false) }
            snapshot.entries[index].receipt = receipt
            snapshot.entries[index].phase = .pinned
            return (true, true)
        }
    }

    /// Applying is the durable commitment point. Completion addresses that
    /// particular invocation even when a new capture has replaced the pointer.
    /// Leaving an applying entry for a held/retry state still requires ownership
    /// of the pointer; an older completion cannot resurrect itself over a new tap.
    @discardableResult
    public func transition(id: UUID, from: JournalPhase, to: JournalPhase,
                           acknowledgement: Acknowledgement? = nil) throws -> Bool {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: { $0.invocation.id == id }),
                  snapshot.entries[index].phase == from,
                  Self.allows(from: from, to: to) else { return (false, false) }
            let terminal = to == .applied || to == .discarded
            if !terminal && snapshot.pendingInvocationID != id { return (false, false) }
            guard terminal || acknowledgement == nil else { throw LinkFailure.invalidData }
            snapshot.entries[index].phase = to
            if terminal {
                snapshot.entries[index].acknowledgement = acknowledgement ??
                    Self.acknowledgement(for: snapshot.entries[index], outcome: to)
                if snapshot.pendingInvocationID == id { snapshot.pendingInvocationID = nil }
            }
            return (true, true)
        }
    }

    /// Includes an uncertain applying entry: a deliberate new user action must
    /// persist cancellation before promising that recovery cannot return later.
    public func cancelPending() throws {
        try mutate { snapshot in
            guard let id = snapshot.pendingInvocationID,
                  let index = snapshot.entries.firstIndex(where: { $0.invocation.id == id }) else {
                return ((), false)
            }
            Self.discard(&snapshot.entries[index])
            snapshot.pendingInvocationID = nil
            return ((), true)
        }
    }

    public func acknowledgements() throws -> [Acknowledgement] {
        try read { $0.entries.compactMap(\.acknowledgement) }
    }

    /// The persisted receipt carries the bearer after a process restart. Only
    /// an identical queued operation may recover it for an acknowledgement.
    public func acknowledgementReceipt(_ acknowledgement: Acknowledgement) throws -> PinnedReceipt? {
        try read { snapshot in
            guard let entry = snapshot.entries.first(where: { $0.acknowledgement == acknowledgement }),
                  let receipt = entry.receipt,
                  receipt.id == acknowledgement.receiptID,
                  receipt.deliveryID == acknowledgement.deliveryID else { return nil }
            return receipt
        }
    }

    /// A lost/late response can clear only the identical outbox operation. The
    /// terminal entry remains through its effective receipt deadline to prevent replay.
    public func completeAcknowledgement(_ acknowledgement: Acknowledgement) throws {
        try mutate { snapshot in
            guard let index = snapshot.entries.firstIndex(where: {
                $0.acknowledgement == acknowledgement
            }) else { return ((), false) }
            snapshot.entries[index].acknowledgement = nil
            return ((), true)
        }
    }

    /// Never evicts an unexpired applying marker or outbox to make room. A
    /// server-shortened receipt deadline also ends retention of its local data.
    public func purge(at date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw LinkFailure.invalidData }
        try mutate { snapshot in
            let count = snapshot.entries.count
            snapshot.entries.removeAll { ($0.receipt?.expiresAt ?? $0.invocation.expiresAt) <= date }
            if let id = snapshot.pendingInvocationID,
               !snapshot.entries.contains(where: { $0.invocation.id == id }) {
                snapshot.pendingInvocationID = nil
            }
            return ((), snapshot.entries.count != count)
        }
    }

    private struct Snapshot: Codable {
        var schemaVersion = 2
        var pendingInvocationID: UUID?
        var entries: [JournalEntry] = []
    }

    private static func allows(from: JournalPhase, to: JournalPhase) -> Bool {
        switch (from, to) {
        case (.captured, .discarded), (.pinned, .held), (.held, .pinned),
             (.pinned, .applying), (.held, .applying), (.pinned, .discarded),
             (.held, .discarded), (.applying, .applied), (.applying, .discarded),
             (.applying, .held), (.applying, .pinned):
            true
        default:
            false
        }
    }

    private static func discard(_ entry: inout JournalEntry) {
        entry.phase = .discarded
        entry.acknowledgement = acknowledgement(for: entry, outcome: .discarded)
    }

    private static func acknowledgement(for entry: JournalEntry,
                                        outcome: JournalPhase) -> Acknowledgement? {
        guard let receipt = entry.receipt else { return nil }
        return Acknowledgement(receiptID: receipt.id, deliveryID: receipt.deliveryID,
                               operationID: UUID(), outcome: outcome == .applied ? .applied : .discarded)
    }

    private func read<T>(_ body: (Snapshot) throws -> T) throws -> T {
        try withLock { file in try body(load(file)) }
    }

    private func mutate<T>(_ body: (inout Snapshot) throws -> (T, Bool)) throws -> T {
        try withLock { file in
            var snapshot = try load(file)
            let (result, changed) = try body(&snapshot)
            if changed { try save(snapshot, to: file) }
            return result
        }
    }

    private func withLock<T>(_ body: (URL) throws -> T) throws -> T {
        do {
            guard Self.isOrdinaryDirectory(containerURL) else { throw LinkFailure.storage }
            var directory = containerURL.appendingPathComponent("SDKPrototype-v2", isDirectory: true)
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard Self.isOrdinaryDirectory(directory) else { throw LinkFailure.storage }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: directory.path)
            #endif
            let lock = directory.appendingPathComponent("record.lock")
            let descriptor = lock.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw LinkFailure.storage }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1,
                  fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw LinkFailure.storage }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw LinkFailure.busy }
                throw LinkFailure.storage
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body(directory.appendingPathComponent("journal-v2.json"))
        } catch let failure as LinkFailure {
            throw failure
        } catch {
            throw LinkFailure.storage
        }
    }

    private static func isOrdinaryDirectory(_ url: URL) -> Bool {
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard !path.utf8.contains(0) else { return false }
        var status = stat()
        let result = path.withCString { lstat($0, &status) }
        return result == 0 && status.st_mode & S_IFMT == S_IFDIR
    }

    private func load(_ file: URL) throws -> Snapshot {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return Snapshot() }
            throw LinkFailure.storage
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1 else { throw LinkFailure.storage }
        guard status.st_size > 0, status.st_size <= Self.maximumSnapshotBytes else {
            throw LinkFailure.invalidData
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= Self.maximumSnapshotBytes {
            guard let bytes = try handle.read(upToCount: min(16_384, Self.maximumSnapshotBytes + 1 - data.count)),
                  !bytes.isEmpty else { break }
            data.append(bytes)
        }
        guard data.count <= Self.maximumSnapshotBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let entries = dictionary["entries"] as? [[String: Any]],
              entries.count <= Self.maximumEntries,
              entries.allSatisfy({ entry in
                  guard let encoded = try? JSONSerialization.data(withJSONObject: entry,
                                                                  options: .withoutEscapingSlashes) else { return false }
                  return encoded.count <= Self.maximumEntryBytes
              }),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw LinkFailure.invalidData
        }
        try validate(snapshot)
        return snapshot
    }

    private func save(_ snapshot: Snapshot, to file: URL) throws {
        try validate(snapshot)
        let data: Data
        do { data = try Self.encoder().encode(snapshot) } catch { throw LinkFailure.invalidData }
        guard data.count <= Self.maximumSnapshotBytes else { throw LinkFailure.invalidData }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        let descriptor = file.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw LinkFailure.storage }
        defer { Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw LinkFailure.storage }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == 2, snapshot.entries.count <= Self.maximumEntries else {
            throw LinkFailure.invalidData
        }
        var invocations: Set<UUID> = []
        var operations: Set<UUID> = []
        var receipts: Set<UUID> = []
        var deliveries: Set<UUID> = []
        var acknowledgements: Set<UUID> = []
        for entry in snapshot.entries {
            guard invocations.insert(entry.invocation.id).inserted,
                  operations.insert(entry.invocation.operationID).inserted else { throw LinkFailure.invalidData }
            if [.captured, .pinned, .held].contains(entry.phase),
               snapshot.pendingInvocationID != entry.invocation.id { throw LinkFailure.invalidData }
            try validate(entry)
            if let receipt = entry.receipt {
                guard receipts.insert(receipt.id).inserted,
                      deliveries.insert(receipt.deliveryID).inserted else { throw LinkFailure.invalidData }
            }
            if let acknowledgement = entry.acknowledgement {
                guard acknowledgements.insert(acknowledgement.operationID).inserted else {
                    throw LinkFailure.invalidData
                }
            }
        }
        if let id = snapshot.pendingInvocationID {
            guard let entry = snapshot.entries.first(where: { $0.invocation.id == id }),
                  entry.phase != .applied, entry.phase != .discarded else { throw LinkFailure.invalidData }
        }
    }

    private func validate(_ entry: JournalEntry) throws {
        let invocation = entry.invocation
        guard !invocation.originalURL.isEmpty, invocation.originalURL.utf8.count <= Self.maximumURLBytes,
              let url = URLComponents(string: invocation.originalURL), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.url != nil,
              invocation.token.utf8.count == 43,
              invocation.token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              invocation.capturedAt.timeIntervalSince1970.isFinite,
              invocation.expiresAt.timeIntervalSince1970.isFinite,
              invocation.expiresAt > invocation.capturedAt,
              invocation.expiresAt <= invocation.capturedAt.addingTimeInterval(Self.lifetime) else {
            throw LinkFailure.invalidData
        }
        do { try invocation.scope.validate() } catch { throw LinkFailure.invalidData }
        if let receipt = entry.receipt {
            guard receipt.invocation == invocation, !receipt.canonicalLinkID.isEmpty,
                  receipt.canonicalLinkID.utf8.count <= 1_024,
                  !receipt.canonicalLinkID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  receipt.expiresAt.timeIntervalSince1970.isFinite,
                  receipt.expiresAt > invocation.capturedAt,
                  receipt.expiresAt <= invocation.expiresAt,
                  entry.phase != .captured else { throw LinkFailure.invalidData }
            do { try receipt.destination.validate() } catch { throw LinkFailure.invalidData }
        } else {
            guard entry.phase == .captured || entry.phase == .discarded,
                  entry.acknowledgement == nil else { throw LinkFailure.invalidData }
        }
        if let acknowledgement = entry.acknowledgement {
            guard let receipt = entry.receipt, acknowledgement.receiptID == receipt.id,
                  acknowledgement.deliveryID == receipt.deliveryID,
                  (entry.phase == .applied && acknowledgement.outcome == .applied) ||
                  (entry.phase == .discarded && acknowledgement.outcome == .discarded) else {
                throw LinkFailure.invalidData
            }
        }
        do {
            guard try Self.encoder().encode(entry).count <= Self.maximumEntryBytes else {
                throw LinkFailure.invalidData
            }
        } catch { throw LinkFailure.invalidData }
    }
}
