import Foundation
import KairosKit

/// The JSON Schema subset task outputs use: objects, arrays, strings, enums, integers and numbers
/// with ranges, booleans, required properties, maximum lengths and item counts.
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

    /// JSON Schema text for `response_format`, properties in declared order, with
    /// `additionalProperties: false` on every object (strict schema modes require it).
    public var text: String {
        switch self {
        case .object(let properties):
            let required = properties.filter(\.isRequired).map { quote($0.name) }.joined(separator: ",")
            let fields = properties.map { "\(quote($0.name)):\($0.schema.text)" }.joined(separator: ",")
            return
                #"{"type":"object","additionalProperties":false,"required":[\#(required)],"properties":{\#(fields)}}"#
        case .array(let items, let maxItems):
            return #"{"type":"array"\#(field("maxItems", maxItems)),"items":\#(items.text)}"#
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

    /// The same schema with no `maxItems` anywhere, for strict schema modes: Gemini refuses a strict
    /// schema whose lists carry item counts once it grows past a few small lists, saying only
    /// "Request contains an invalid argument" (importResume, 2026-10-19). Counts are still checked
    /// on every reply.
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
        value.map { ",\"\(name)\":\(JSONValue.number($0).text)" } ?? ""
    }

    private func quote(_ text: String) -> String { JSONValue.string(text).text }
}

/// One way a value breaks its schema: "requirements[2].kind: expected one of must, nice".
public struct SchemaIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let problem: String

    public var description: String { "\(path.isEmpty ? "top level" : path): \(problem)" }
}

/// Checks a parsed reply against a schema. Every issue is reported in document order, so the one
/// repair call can quote them all back to the model.
public enum SchemaValidator {
    public static func issues(in value: JSONValue, against schema: JSONSchema, limit: Int = 20) -> [SchemaIssue] {
        var found: [SchemaIssue] = []
        check(value, schema, path: "", into: &found, limit: limit)
        return found
    }

    private static func check(
        _ value: JSONValue, _ schema: JSONSchema, path: String, into found: inout [SchemaIssue], limit: Int
    ) {
        guard found.count < limit else { return }
        func report(_ problem: String) { found.append(SchemaIssue(path: path, problem: problem)) }

        switch (schema, value) {
        case (.object(let properties), .object(let fields)):
            for property in properties {
                let child = path.isEmpty ? property.name : "\(path).\(property.name)"
                switch fields[property.name] {
                case nil, .null?:
                    if property.isRequired { found.append(SchemaIssue(path: child, problem: "missing")) }
                case let field?:
                    check(field, property.schema, path: child, into: &found, limit: limit)
                }
            }
        case (.object, _):
            report("expected an object")

        case (.array(let items, let maxItems), .array(let elements)):
            if let maxItems, elements.count > maxItems { report("more than \(maxItems) items") }
            for (index, element) in elements.enumerated() {
                check(element, items, path: "\(path)[\(index)]", into: &found, limit: limit)
            }
        case (.array, _):
            report("expected an array")

        case (.string(let maxLength), .string(let text)):
            if let maxLength, text.count > maxLength { report("longer than \(maxLength) characters") }
        case (.string, _):
            report("expected a string")

        case (.enumeration(let allowed), .string(let text)) where allowed.contains(text):
            break
        case (.enumeration(let allowed), _):
            report("expected one of \(allowed.joined(separator: ", "))")

        case (.integer(let minimum, let maximum), .number(let number)) where number == number.rounded():
            if let minimum, number < Double(minimum) { report("must be at least \(minimum)") }
            if let maximum, number > Double(maximum) { report("must be at most \(maximum)") }
        case (.integer, _):
            report("expected an integer")

        case (.number(let minimum, let maximum), .number(let number)):
            if let minimum, number < minimum { report("must be at least \(JSONValue.number(minimum).text)") }
            if let maximum, number > maximum { report("must be at most \(JSONValue.number(maximum).text)") }
        case (.number, _):
            report("expected a number")

        case (.boolean, .bool):
            break
        case (.boolean, _):
            report("expected true or false")
        }
    }
}

/// Turns a reply into a task's typed output: strip code fences, parse, validate against the
/// schema, decode, run the task's check. A failure comes back as a sentence the repair call can
/// hand to the model.
public enum OutputCheck {
    public struct Problem: Error, Equatable, Sendable, CustomStringConvertible {
        public let description: String
    }

    public static func output<T: AITask>(from text: String, cutOff: Bool = false, task: T, input: T.Input)
        -> Result<T.Output, Problem>
    {
        if cutOff { return .failure(Problem(description: "The reply was cut off at the output limit.")) }
        let json = unfenced(text)
        guard let value = try? JSONValue(parsing: json) else {
            return .failure(Problem(description: "The reply isn't valid JSON."))
        }
        let issues = SchemaValidator.issues(in: value, against: T.outputSchema)
        guard issues.isEmpty else {
            return .failure(
                Problem(
                    description:
                        "The reply doesn't match the schema: \(issues.map(\.description).joined(separator: "; "))."))
        }
        let decoder = JSONDecoder()
        // Schemas name properties in snake_case; output types use camelCase.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let output: T.Output
        do {
            output = try decoder.decode(T.Output.self, from: Data(json.utf8))
        } catch let error as DecodingError {
            return .failure(Problem(description: "The reply couldn't be read: \(describe(error))."))
        } catch {
            return .failure(Problem(description: "The reply couldn't be read."))
        }
        do {
            try task.check(output, for: input)
        } catch {
            let reason = if case .invalidOutput(let reason) = error { reason } else { error.reason }
            return .failure(Problem(description: "The reply failed a check: \(reason)."))
        }
        return .success(output)
    }

    /// Models sometimes wrap JSON in a Markdown fence (Ollama with thinking off, T20), or put a
    /// sentence before it.
    public static func unfenced(_ text: String) -> String {
        let json = text.replacing(/^\s*```(?:json)?\s*|\s*```\s*$/, with: "").trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard (try? JSONValue(parsing: json)) == nil, let first = json.firstIndex(where: { $0 == "{" || $0 == "[" }),
            let last = json.lastIndex(where: { $0 == "}" || $0 == "]" }), first < last
        else { return json }
        // A sentence before the JSON, or a fence or remark after it.
        return String(json[first...last])
    }

    /// The message asking for a fixed reply, quoting what was wrong.
    public static func repairNote(_ problem: Problem) -> String {
        "That reply can't be used. \(problem.description) Reply again with JSON only, fixing that and keeping "
            + "everything else that was right."
    }
}
