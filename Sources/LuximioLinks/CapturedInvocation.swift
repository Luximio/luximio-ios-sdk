import Foundation
import Security

/// A single intentional capture. Its token and operation survive retries; never log either.
public struct CapturedInvocation: Codable, Equatable, Sendable, CustomDebugStringConvertible {
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumURLBytes = 8_192
    public let id: UUID
    public let operationID: UUID
    public let token: String
    public let originalURL: String
    public let capturedAt: Date
    public let expiresAt: Date
    public let scope: LinkScope

    public var debugDescription: String {
        "CapturedInvocation(id: \(id), operationID: \(operationID), token: <redacted>, originalURL: <redacted>)"
    }

    public init(id: UUID, operationID: UUID, token: String, originalURL: String,
                capturedAt: Date, expiresAt: Date, scope: LinkScope) {
        self.id = id
        self.operationID = operationID
        self.token = token
        self.originalURL = originalURL
        self.capturedAt = capturedAt
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public static func capture(url: URL, configuration: LinksConfiguration, at date: Date) throws -> Self {
        try configuration.validateURL(url)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let pointer = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, pointer)
        }
        guard status == errSecSuccess else { throw LinkFailure.storage }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invocation = Self(id: UUID(), operationID: UUID(), token: token,
                              originalURL: url.absoluteString, capturedAt: date,
                              expiresAt: date.addingTimeInterval(lifetime), scope: configuration.scope)
        try invocation.validate(configuration: configuration, now: date)
        return invocation
    }

    public func validate(configuration: LinksConfiguration, now: Date) throws {
        try validate(scope: configuration.scope, now: now)
        guard let url = URL(string: originalURL) else { throw LinkFailure.untrustedURL }
        try configuration.validateURL(url)
    }

    public func validate(scope expectedScope: LinkScope, now: Date) throws {
        guard scope == expectedScope else { throw LinkFailure.wrongScope }
        do { try scope.validate() }
        catch { throw LinkFailure.invalidData }
        guard originalURL.utf8.count <= Self.maximumURLBytes,
              let url = URL(string: originalURL), url.absoluteString == originalURL,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host, !host.isEmpty,
              token.utf8.count == 43,
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              Self.isCanonicalToken(token),
              capturedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              now.timeIntervalSince1970.isFinite, capturedAt <= now.addingTimeInterval(300),
              expiresAt > capturedAt, expiresAt <= capturedAt.addingTimeInterval(Self.lifetime) else {
            throw LinkFailure.invalidData
        }
        guard expiresAt > now else { throw LinkFailure.expired }
    }

    private static func isCanonicalToken(_ value: String) -> Bool {
        let standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard let bytes = Data(base64Encoded: standard), bytes.count == 32 else { return false }
        let canonical = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return canonical == value
    }
}
