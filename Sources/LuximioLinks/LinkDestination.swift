import Foundation

/// A logical screen identifier and bounded JSON data, matching Luximio's resolver schema.
public struct LinkDestination: Codable, Equatable, Sendable {
    public static let maximumBytes = 4_096
    public let route: String
    public let data: [String: LinkValue]

    public init(route: String, data: [String: LinkValue]) {
        self.route = route
        self.data = data
    }

    public func validate() throws {
        guard !route.isEmpty, route.utf16.count <= 200,
              route.range(of: #"^/?[A-Za-z0-9_-][A-Za-z0-9/_.-]*\z"#, options: .regularExpression) != nil,
              !route.contains("//"), !route.hasSuffix("/"),
              !route.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LinkFailure.invalidData
        }
        var nodes = 0
        try LinkValue.object(data).validate(depth: 0, nodes: &nodes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(self).count <= Self.maximumBytes else { throw LinkFailure.invalidData }
    }
}
