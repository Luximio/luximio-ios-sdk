import Darwin
import Foundation

/// Only metadata and registration evidence live here. DeviceCheck owns key material.
/// A short file transaction never spans a provider or HTTP suspension point.
@MainActor
final class CustomerRecoveryKeyVault {
    static let directoryName = "CustomerRecovery-v1"
    static let maximumSnapshotBytes = 524_288
    static let maximumKeys = 32
    static let maximumPins = 128
    static let leaseLifetime: TimeInterval = 360

    enum KeyState: String, Codable { case candidate, registered, quarantined }

    struct RegistrationChallenge: Codable {
        let id: UUID
        let identityHash: String
        let clientData: Data
        let createdAt: Date
        let expiresAt: Date

        init(_ challenge: CustomerRecoveryChallenge) {
            id = challenge.id
            identityHash = challenge.identityHash
            clientData = challenge.clientData
            createdAt = challenge.createdAt
            expiresAt = challenge.expiresAt
        }
    }

    struct Key: Codable, CustomDebugStringConvertible {
        let generation: UUID
        let namespace: String
        let identityHash: String
        let createdAt: Date
        var state: KeyState = .candidate
        var retired = false
        var keyID: String?
        var registrationBearer: String?
        var challenge: RegistrationChallenge?
        var evidence: CustomerRecoveryRegistrationEvidence?
        var expiresAt: Date?

        var debugDescription: String {
            "CustomerRecoveryKey(generation: \(generation), state: \(state.rawValue), retired: \(retired), evidence: <redacted>, capability: <redacted>)"
        }
    }

    struct Pin: Codable {
        let invocationID: UUID
        let fingerprint: String
        let namespace: String
        let keyGeneration: UUID
        var retainUntil: Date
    }

    struct Lease: Codable {
        let id: UUID
        var expiresAt: Date
    }

    struct Snapshot: Codable {
        var schemaVersion = 1
        var lease: Lease?
        var keys: [Key] = []
        var activeKeys: [String: UUID] = [:]
        var pins: [Pin] = []

        mutating func purge(at date: Date) {
            pins.removeAll { $0.retainUntil <= date }
            for index in keys.indices where keys[index].state == .candidate {
                if let expiry = keys[index].challenge?.expiresAt, expiry <= date {
                    keys[index].state = .quarantined
                }
            }
            let retained = Set(pins.map(\.keyGeneration))
            keys.removeAll {
                !retained.contains($0.generation)
                    && ($0.expiresAt ?? $0.createdAt.addingTimeInterval(30 * 86_400)) <= date
            }
            let live = Set(keys.map(\.generation))
            activeKeys = activeKeys.filter { live.contains($0.value) }
        }

        @discardableResult
        mutating func evictOldestUnpinnedQuarantine() -> Bool {
            let pinned = Set(pins.map(\.keyGeneration))
            let evictable = keys.indices.filter {
                keys[$0].state == .quarantined && !pinned.contains(keys[$0].generation)
            }
            guard let index = evictable.min(by: { keys[$0].createdAt < keys[$1].createdAt }) else { return false }
            // A quarantined registration was never confirmed and therefore
            // could not authorize create. Late results still require its CAS.
            keys.remove(at: index)
            return true
        }

        func requireLease(_ id: UUID, at date: Date) throws {
            guard let lease, lease.id == id, lease.expiresAt > date else { throw LinkFailure.superseded }
        }
    }

    private let containerURL: URL

    init(containerURL: URL?) throws {
        guard let containerURL, containerURL.isFileURL,
              Self.isOrdinaryDirectory(containerURL) else { throw LinkFailure.configuration }
        self.containerURL = containerURL.standardizedFileURL
        try withLock { _ in () }
    }

    func acquireLease(at date: Date) throws -> UUID {
        try update { snapshot in
            guard date.timeIntervalSince1970.isFinite else { throw LinkFailure.invalidData }
            if let lease = snapshot.lease, lease.expiresAt > date { throw LinkFailure.busy }
            snapshot.purge(at: date)
            let id = UUID()
            snapshot.lease = Lease(id: id, expiresAt: date.addingTimeInterval(Self.leaseLifetime))
            return id
        }
    }

    func checkLease(_ id: UUID, at date: Date) throws {
        try update { snapshot in
            try snapshot.requireLease(id, at: date)
            snapshot.lease?.expiresAt = date.addingTimeInterval(Self.leaseLifetime)
        }
    }

    func releaseLease(_ id: UUID) throws {
        try update { snapshot in
            if snapshot.lease?.id == id { snapshot.lease = nil }
        }
    }

    func read<Value>(_ body: (Snapshot) throws -> Value) throws -> Value {
        try withLock { try body(load($0)) }
    }

    func update<Value>(_ body: (inout Snapshot) throws -> Value) throws -> Value {
        try withLock { file in
            var snapshot = try load(file)
            let result = try body(&snapshot)
            try save(snapshot, to: file)
            return result
        }
    }

    func update<Value>(lease: UUID, at date: Date,
                       _ body: (inout Snapshot) throws -> Value) throws -> Value {
        try update { snapshot in
            try snapshot.requireLease(lease, at: date)
            return try body(&snapshot)
        }
    }

    private func withLock<Value>(_ body: (URL) throws -> Value) throws -> Value {
        do {
            guard Self.isOrdinaryDirectory(containerURL) else { throw LinkFailure.storage }
            var directory = containerURL.appendingPathComponent(Self.directoryName, isDirectory: true)
            let created = directory.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.mkdir(path, S_IRWXU)
            }
            guard created == 0 || errno == EEXIST,
                  Self.isOrdinaryDirectory(directory) else { throw LinkFailure.storage }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: directory.path)
            #endif
            let lock = directory.appendingPathComponent("vault.lock")
            let descriptor = lock.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else { throw LinkFailure.storage }
            defer { Darwin.close(descriptor) }
            var status = stat()
            guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
                  status.st_nlink == 1, fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw LinkFailure.storage
            }
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes([
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ], ofItemAtPath: lock.path)
            #endif
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { throw LinkFailure.busy }
                throw LinkFailure.storage
            }
            defer { flock(descriptor, LOCK_UN) }
            return try body(directory.appendingPathComponent("keys-v1.json"))
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
        return path.withCString { lstat($0, &status) } == 0 && status.st_mode & S_IFMT == S_IFDIR
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
              status.st_nlink == 1, status.st_size > 0,
              status.st_size <= Self.maximumSnapshotBytes else { throw LinkFailure.invalidData }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count <= Self.maximumSnapshotBytes {
            guard let bytes = try handle.read(upToCount: min(16_384, Self.maximumSnapshotBytes + 1 - data.count)),
                  !bytes.isEmpty else { break }
            data.append(bytes)
        }
        guard data.count <= Self.maximumSnapshotBytes,
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            throw LinkFailure.invalidData
        }
        try validate(snapshot)
        return snapshot
    }

    private func save(_ proposed: Snapshot, to file: URL) throws {
        var snapshot = proposed
        try validate(snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(snapshot)
        while data.count > Self.maximumSnapshotBytes {
            // Base64 evidence can exhaust the byte budget before key count.
            // Registered/pinned keys and candidates that can still replay are
            // never sacrificed to make a mutation fit; fail atomically instead.
            guard snapshot.evictOldestUnpinnedQuarantine() else { throw LinkFailure.storage }
            data = try encoder.encode(snapshot)
        }
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
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_nlink == 1, fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              fsync(descriptor) == 0 else { throw LinkFailure.storage }
    }

    private func validate(_ snapshot: Snapshot) throws {
        guard snapshot.schemaVersion == 1, snapshot.keys.count <= Self.maximumKeys,
              snapshot.pins.count <= Self.maximumPins,
              snapshot.activeKeys.count <= Self.maximumKeys,
              snapshot.lease?.expiresAt.timeIntervalSince1970.isFinite != false else {
            throw LinkFailure.invalidData
        }
        var generations: Set<UUID> = []
        for key in snapshot.keys {
            guard generations.insert(key.generation).inserted, Self.isHash(key.namespace),
                  Self.isHash(key.identityHash), key.createdAt.timeIntervalSince1970.isFinite,
                  key.expiresAt?.timeIntervalSince1970.isFinite != false,
                  key.keyID.map(Self.isKeyID) != false else { throw LinkFailure.invalidData }
            if key.state == .registered {
                guard key.keyID != nil, let expiry = key.expiresAt, expiry > key.createdAt,
                      key.registrationBearer == nil, key.challenge == nil, key.evidence == nil else {
                    throw LinkFailure.invalidData
                }
            } else {
                guard key.expiresAt == nil, key.retired == false, let bearer = key.registrationBearer,
                      Self.isBearer(bearer) else { throw LinkFailure.invalidData }
            }
            if let challenge = key.challenge {
                guard key.keyID != nil, challenge.identityHash == key.identityHash,
                      !challenge.clientData.isEmpty, challenge.clientData.count <= 16_384,
                      challenge.createdAt.timeIntervalSince1970.isFinite,
                      challenge.expiresAt.timeIntervalSince1970.isFinite,
                      challenge.expiresAt > challenge.createdAt else { throw LinkFailure.invalidData }
            }
            if let evidence = key.evidence {
                guard key.keyID != nil, let challenge = key.challenge,
                      evidence.challengeID == challenge.id, evidence.clientData == challenge.clientData,
                      evidence.challengeExpiresAt == challenge.expiresAt,
                      evidence.identityHash == key.identityHash,
                      !evidence.clientData.isEmpty, evidence.clientData.count <= 16_384,
                      !evidence.attestationObject.isEmpty, evidence.attestationObject.count <= 16_384,
                      evidence.challengeExpiresAt.timeIntervalSince1970.isFinite else {
                    throw LinkFailure.invalidData
                }
            }
        }
        for (namespace, generation) in snapshot.activeKeys {
            guard snapshot.keys.contains(where: {
                $0.generation == generation && $0.namespace == namespace && $0.state == .registered && $0.retired == false
            }) else { throw LinkFailure.invalidData }
        }
        var invocationIDs: Set<UUID> = []
        for pin in snapshot.pins {
            guard invocationIDs.insert(pin.invocationID).inserted, Self.isHash(pin.fingerprint),
                  pin.retainUntil.timeIntervalSince1970.isFinite,
                  let key = snapshot.keys.first(where: { $0.generation == pin.keyGeneration }),
                  key.state == .registered, key.namespace == pin.namespace,
                  let expiry = key.expiresAt, pin.retainUntil <= expiry else { throw LinkFailure.invalidData }
        }
    }

    static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isKeyID(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value), data.count == 32 else { return false }
        return data.base64EncodedString() == value
    }

    private static func isBearer(_ value: String) -> Bool {
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard value.utf8.count == 43, let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") == value
    }
}
