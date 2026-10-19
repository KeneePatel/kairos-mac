/// One way a value breaks its schema, named by its path: "requirements[2].kind: expected one of must, nice".
public struct SchemaIssue: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let problem: String

    public var description: String { "\(path.isEmpty ? "top level" : path): \(problem)" }
}

/// Checks a parsed reply against a task's schema (SPEC §5.5, "Structured output", step 2). Every issue
/// is reported in document order, so the one repair call can quote them all back to the model.
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
            if let minimum, number < minimum { report("must be at least \(JSONValue.format(minimum))") }
            if let maximum, number > maximum { report("must be at most \(JSONValue.format(maximum))") }
        case (.number, _):
            report("expected a number")

        case (.boolean, .bool):
            break
        case (.boolean, _):
            report("expected true or false")
        }
    }
}
