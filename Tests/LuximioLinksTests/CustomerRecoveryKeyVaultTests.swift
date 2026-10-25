import Darwin
import Foundation
import Testing
@testable import LuximioLinks

@MainActor
struct CustomerRecoveryKeyVaultTests {
    @Test func missingAndSymbolicLinkContainersNeverFallBackToAnotherStore() throws {
        #expect(throws: LinkFailure.configuration) { try CustomerRecoveryKeyVault(containerURL: nil) }
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let missing = f.directory.appendingPathComponent("missing")
        #expect(throws: LinkFailure.configuration) { try CustomerRecoveryKeyVault(containerURL: missing) }
        #expect(FileManager.default.fileExists(atPath: missing.path) == false)
        let link = f.directory.appendingPathComponent("container-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.directory)
        #expect(throws: LinkFailure.configuration) { try CustomerRecoveryKeyVault(containerURL: link) }
    }

    @Test func aReplacedLeaseRejectsStaleMutationsAndStaleRelease() throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let first = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let second = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let old = try first.acquireLease(at: date)
        #expect(throws: LinkFailure.busy) { try second.acquireLease(at: date) }
        let later = date.addingTimeInterval(CustomerRecoveryKeyVault.leaseLifetime)
        let replacement = try second.acquireLease(at: later)
        #expect(throws: LinkFailure.superseded) { try first.checkLease(old, at: later) }
        try first.releaseLease(old)
        #expect(try second.read { $0.lease?.id } == replacement)
        try second.releaseLease(replacement)
        #expect(try second.read { $0.lease } == nil)
    }

    @Test func anActualFileLockReportsBusyWithoutOverwritingTheSnapshot() throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let vault = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let descriptor = f.lockURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDWR | O_NOFOLLOW)
        }
        try #require(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { flock(descriptor, LOCK_UN) }
        #expect(throws: LinkFailure.busy) { try vault.acquireLease(at: Date()) }
        #expect(FileManager.default.fileExists(atPath: f.recordURL.path) == false)
    }

    @Test(arguments: ["lock", "snapshot", "directory"])
    func symbolicLinksFailClosedWithoutChangingTheirTarget(component: String) throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let vault = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let target = f.directory.appendingPathComponent("target")
        let sentinel = Data("unrelated-private-data".utf8)
        try sentinel.write(to: target)
        let link: URL
        switch component {
        case "lock":
            link = f.lockURL
            try FileManager.default.removeItem(at: link)
        case "snapshot": link = f.recordURL
        default:
            link = f.storageDirectory
            try FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: LinkFailure.storage) { try vault.acquireLease(at: Date()) }
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test func aHardLinkedSnapshotCannotBeReadOrReplaced() throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let vault = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let lease = try vault.acquireLease(at: Date())
        try vault.releaseLease(lease)
        let target = f.directory.appendingPathComponent("other-record")
        try FileManager.default.linkItem(at: f.recordURL, to: target)
        let sentinel = try Data(contentsOf: target)
        #expect(throws: LinkFailure.invalidData) { try vault.acquireLease(at: Date()) }
        #expect(try Data(contentsOf: target) == sentinel)
    }

    @Test(arguments: ["oversized", "invalid-json", "unknown-version"])
    func invalidSnapshotsAreNeverTreatedAsAnEmptyVault(kind: String) throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let vault = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let data: Data
        switch kind {
        case "oversized": data = Data(repeating: 32, count: CustomerRecoveryKeyVault.maximumSnapshotBytes + 1)
        case "invalid-json": data = Data("{".utf8)
        default: data = Data(#"{"schemaVersion":2,"keys":[],"activeKeys":{},"pins":[]}"#.utf8)
        }
        try data.write(to: f.recordURL)
        #expect(throws: LinkFailure.invalidData) { try vault.acquireLease(at: Date()) }
        #expect(try Data(contentsOf: f.recordURL) == data)
    }

    @Test func theDedicatedDirectoryAndSnapshotAreProtectedAndExcludedFromBackup() throws {
        let f = try RecoveryVaultFixture()
        defer { f.cleanup() }
        let vault = try CustomerRecoveryKeyVault(containerURL: f.directory)
        let lease = try vault.acquireLease(at: Date())
        try vault.releaseLease(lease)
        let values = try f.storageDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let directory = try FileManager.default.attributesOfItem(atPath: f.storageDirectory.path)
        let file = try FileManager.default.attributesOfItem(atPath: f.recordURL.path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((file[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("SDKPrototype-v2").path) == false)
    }
}

@MainActor
private struct RecoveryVaultFixture {
    let directory: URL
    var storageDirectory: URL { directory.appendingPathComponent(CustomerRecoveryKeyVault.directoryName, isDirectory: true) }
    var lockURL: URL { storageDirectory.appendingPathComponent("vault.lock") }
    var recordURL: URL { storageDirectory.appendingPathComponent("keys-v1.json") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
