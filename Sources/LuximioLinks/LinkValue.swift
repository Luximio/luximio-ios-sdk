
/// JSON carried with an app destination. These values never grant access to a resource.
public indirect enum LinkValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LinkValue])
    case object([String: LinkValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([LinkValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: LinkValue].self) { self = .object(value) }
        else { throw LinkFailure.invalidData }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw LinkFailure.invalidData }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    func validate(depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard nodes <= 256, depth <= 6 else { throw LinkFailure.invalidData }
        switch self {
        case .null, .bool: break
        case .number(let value):
            guard value.isFinite else { throw LinkFailure.invalidData }
        case .string(let value):
            guard value.utf8.count <= LinkDestination.maximumBytes else { throw LinkFailure.invalidData }
        case .array(let values):
            for value in values { try value.validate(depth: depth + 1, nodes: &nodes) }
        case .object(let values):
            for (key, value) in values {
                guard !key.isEmpty, key.utf16.count <= 64,
                      !["__proto__", "prototype", "constructor"].contains(key) else {
                    throw LinkFailure.invalidData
                }
                try value.validate(depth: depth + 1, nodes: &nodes)
            }
        }
    }
}
