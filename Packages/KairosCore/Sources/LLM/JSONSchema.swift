import Foundation

/// The JSON Schema subset task outputs use (SPEC §5.5): objects, arrays, strings, enums, integers
/// and numbers with ranges, booleans, required properties, maximum lengths and item counts.
public indirect enum JSONSchema: Equatable, Sendable {
    /// Properties in the order the model should write them. Unknown extra properties are ignored.
    case object([Property])
    case array(of: JSONSchema, maxItems: Int? = nil)
    case string(maxLength: Int? = nil)
    case enumeration([String])
    case integer(minimum: Int? = nil, maximum: Int? = nil)
    case number(minimum: Double? = nil, maximum: Double? = nil)
    case boolean

    public struct Property: Equatable, Sendable {
        public let name: String
        public let schema: JSONSchema
        public let isRequired: Bool

        public static func required(_ name: String, _ schema: JSONSchema) -> Property {
            Property(name: name, schema: schema, isRequired: true)
        }

        /// May be absent or null.
        public static func optional(_ name: String, _ schema: JSONSchema) -> Property {
            Property(name: name, schema: schema, isRequired: false)
        }
    }

    /// The schema as JSON Schema text for `response_format`, properties in declared order, with
    /// `additionalProperties: false` on every object (strict schema modes require it).
    public var jsonString: String {
        switch self {
        case .object(let properties):
            let required = properties.filter(\.isRequired).map { quote($0.name) }.joined(separator: ",")
            let fields = properties.map { "\(quote($0.name)):\($0.schema.jsonString)" }.joined(separator: ",")
            return
                #"{"type":"object","additionalProperties":false,"required":[\#(required)],"properties":{\#(fields)}}"#
        case .array(let items, let maxItems):
            return #"{"type":"array"\#(field("maxItems", maxItems)),"items":\#(items.jsonString)}"#
        case .string(let maxLength):
            return #"{"type":"string"\#(field("maxLength", maxLength))}"#
        case .enumeration(let values):
            return #"{"type":"string","enum":[\#(values.map(quote).joined(separator: ","))]}"#
        case .integer(let minimum, let maximum):
            return #"{"type":"integer"\#(field("minimum", minimum))\#(field("maximum", maximum))}"#
        case .number(let minimum, let maximum):
            return #"{"type":"number"\#(field("minimum", minimum))\#(field("maximum", maximum))}"#
        case .boolean:
            return #"{"type":"boolean"}"#
        }
    }

    /// The same schema with no `maxItems` anywhere, for strict schema modes. Gemini refuses a strict
    /// schema whose lists carry item counts once it grows past a few small lists, saying only "Request
    /// contains an invalid argument" (`importResume`, 2026-10-19). `SchemaValidator` still checks the
    /// counts on every reply.
    public var withoutItemCounts: JSONSchema {
        switch self {
        case .object(let properties):
            .object(
                properties.map {
                    Property(name: $0.name, schema: $0.schema.withoutItemCounts, isRequired: $0.isRequired)
                })
        case .array(let items, _): .array(of: items.withoutItemCounts)
        case .string, .enumeration, .integer, .number, .boolean: self
        }
    }

    private func field(_ name: String, _ value: Int?) -> String {
        value.map { ",\"\(name)\":\($0)" } ?? ""
    }

    private func field(_ name: String, _ value: Double?) -> String {
        value.map { ",\"\(name)\":\(JSONValue.format($0))" } ?? ""
    }

    private func quote(_ text: String) -> String {
        JSONValue.string(text).jsonString
    }
}

/// Any JSON value. Model replies are parsed into this first, so they can be checked against the
/// schema before being decoded into a task's output type.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(parsing text: String) throws(LLMError) {
        do {
            self = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw .invalidJSON(String(text.prefix(80)))
        }
    }

    /// Compact JSON with sorted keys.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 1 rather than 1.0, so bounds read the way they were written.
    static func format(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
