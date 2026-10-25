import Foundation

public struct LinksConfiguration: Equatable, Sendable {
    public enum Role: Equatable, Sendable { case fullApp, appClip }

    public let scope: LinkScope
    public let role: Role
    public let trustedHosts: [String]
    public let appGroupIdentifier: String

    public init(scope: LinkScope, role: Role, trustedHosts: [String], appGroupIdentifier: String) {
        self.scope = scope
        self.role = role
        self.trustedHosts = trustedHosts
        self.appGroupIdentifier = appGroupIdentifier
    }

    public func validate(bundleIdentifier: String) throws {
        try scope.validate()
        let expectedBundle = role == .fullApp ? scope.fullAppBundleID : scope.clipBundleID
        guard bundleIdentifier == expectedBundle,
              appGroupIdentifier.hasPrefix("group."), appGroupIdentifier.utf8.count <= 255,
              appGroupIdentifier.range(of: #"^group\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#,
                                       options: .regularExpression) != nil,
              !trustedHosts.isEmpty, trustedHosts.count <= 16,
              Set(trustedHosts).count == trustedHosts.count,
              trustedHosts.allSatisfy(Self.acceptsHost) else { throw LinkFailure.configuration }
    }

    public func validateURL(_ url: URL) throws {
        guard url.absoluteString.utf8.count <= CapturedInvocation.maximumURLBytes,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(), Self.acceptsHost(host),
              trustedHosts.contains(host), url.baseURL == nil else { throw LinkFailure.untrustedURL }
    }

    private static func acceptsHost(_ value: String) -> Bool {
        guard !value.isEmpty, value == value.lowercased(), value.utf8.count <= 253,
              !value.hasSuffix("."), value.contains(".") else { return false }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
