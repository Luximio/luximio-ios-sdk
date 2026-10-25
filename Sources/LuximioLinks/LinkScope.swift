import Foundation

public struct LinkScope: Codable, Equatable, Sendable {
    public let projectID: String
    public let fullAppBundleID: String
    public let clipBundleID: String

    public init(projectID: String, fullAppBundleID: String, clipBundleID: String) {
        self.projectID = projectID
        self.fullAppBundleID = fullAppBundleID
        self.clipBundleID = clipBundleID
    }

    public func validate() throws {
        guard !projectID.isEmpty, projectID.utf8.count <= 200,
              !projectID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              Self.acceptsBundleID(fullAppBundleID), Self.acceptsBundleID(clipBundleID),
              clipBundleID.hasPrefix(fullAppBundleID + ".") else { throw LinkFailure.configuration }
    }

    private static func acceptsBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 &&
        value.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z"#, options: .regularExpression) != nil
    }
}
