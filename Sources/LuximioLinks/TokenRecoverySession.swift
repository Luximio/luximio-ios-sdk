import Darwin
import Foundation

/// Explicitly pairs token recovery with protected, protocol/scope-isolated local
/// state. Existing attested/private journals and key vaults are never opened,
/// migrated or cleared. Clip and full-app roles share this same namespace.
@MainActor
public struct TokenRecoverySession {
    public let journal: ContinuationJournal
    public let backend: TokenRecoveryBackend

    public init(configuration: LinksConfiguration, containerURL: URL?,
                transport: any ContinuationHTTPTransport = OwnedContinuationHTTPTransport(responseLimit: .customerRecovery),
                now: @escaping @MainActor () -> Date = Date.init) throws {
        let bundle = configuration.role == .fullApp ? configuration.scope.fullAppBundleID : configuration.scope.clipBundleID
        try configuration.validate(bundleIdentifier: bundle)
        let directory = try Self.namespace(configuration: configuration, containerURL: containerURL)
        let journal = try ContinuationJournal(containerURL: directory)
        self.journal = journal
        backend = try TokenRecoveryBackend(configuration: configuration, journal: journal, transport: transport, now: now)
    }

    private static func namespace(configuration: LinksConfiguration, containerURL: URL?) throws -> URL {
        guard let containerURL, containerURL.isFileURL, containerURL.query == nil, containerURL.fragment == nil,
              containerURL.user == nil, containerURL.password == nil, containerURL.port == nil,
              containerURL.host == nil || containerURL.host == "" || containerURL.host == "localhost",
              containerURL.path.hasPrefix("/"), containerURL.path != "/",
              !containerURL.pathComponents.contains(".."), !containerURL.pathComponents.contains(".") else {
            throw LinkFailure.configuration
        }
        let root = containerURL.resolvingSymlinksInPath()
        var supplied = containerURL.path
        while supplied.count > 1 && supplied.hasSuffix("/") { supplied.removeLast() }
        var original = stat()
        guard !supplied.utf8.contains(0), lstat(supplied, &original) == 0,
              original.st_mode & S_IFMT == S_IFDIR, original.st_uid == geteuid(),
              original.st_mode & S_IWOTH == 0 else { throw LinkFailure.configuration }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LinkFailure.configuration }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == original.st_ino, opened.st_dev == original.st_dev else {
            throw LinkFailure.configuration
        }
        let hosts = Dictionary(uniqueKeysWithValues: configuration.trustedHosts.map { ($0, CustomerRecoveryJSON.null) })
        let identity = try CustomerRecoveryJSON.object([
            "protocol": .string("token-recovery-v1"), "projectID": .string(configuration.scope.projectID),
            "fullAppBundleID": .string(configuration.scope.fullAppBundleID),
            "clipBundleID": .string(configuration.scope.clipBundleID),
            "appGroupIdentifier": .string(configuration.appGroupIdentifier), "trustedHosts": .object(hosts)
        ]).encoded()
        let scopeName = CustomerRecoveryWire.hash(identity)
        let protocolURL = root.appendingPathComponent("TokenRecovery-v1", isDirectory: true)
        let protocolDescriptor = try privateChild("TokenRecovery-v1", parent: descriptor, url: protocolURL)
        defer { close(protocolDescriptor) }
        let scopeURL = protocolURL.appendingPathComponent(scopeName, isDirectory: true)
        let scopeDescriptor = try privateChild(scopeName, parent: protocolDescriptor, url: scopeURL)
        close(scopeDescriptor)
        return scopeURL
    }

    private static func privateChild(_ name: String, parent: Int32, url: URL) throws -> Int32 {
        if mkdirat(parent, name, 0o700) != 0, errno != EEXIST { throw LinkFailure.storage }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LinkFailure.storage }
        do {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw LinkFailure.storage }
            var directory = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: directory.path)
            #endif
            var path = directory.path
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            var current = stat()
            guard lstat(path, &current) == 0, current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR, current.st_uid == geteuid(),
                  current.st_mode & 0o077 == 0 else { throw LinkFailure.storage }
            return descriptor
        } catch {
            close(descriptor)
            if let failure = error as? LinkFailure { throw failure }
            throw LinkFailure.storage
        }
    }
}
