import Foundation
import Testing

@testable import LLM

/// A cut-down `analyzeJob` output: the shapes the validator has to handle.
private let analysis = JSONSchema.object([
    .required(
        "requirements",
        .array(
            of: .object([
                .required("text", .string(maxLength: 200)),
                .required("kind", .enumeration(["must", "nice"])),
                .optional("matched_skill", .string()),
            ]), maxItems: 3)),
    .required("years", .integer(minimum: 0, maximum: 40)),
    .optional("remote", .boolean),
    .optional("score", .number(minimum: 0, maximum: 1)),
])

private func issues(_ json: String, _ schema: JSONSchema = analysis) throws -> [String] {
    SchemaValidator.issues(in: try JSONValue(parsing: json), against: schema).map(\.description)
}

@Suite("Schema validator")
struct SchemaValidatorTests {
    @Test func aConformingValuePasses() throws {
        let json = """
            {"requirements":[{"text":"Go","kind":"must","matched_skill":"Go"},{"text":"Kafka","kind":"nice"}],
             "years":5,"remote":true,"score":0.75,"extra":"ignored"}
            """
        #expect(try issues(json).isEmpty)
    }

    @Test(arguments: [
        (#"{"years":5}"#, "requirements: missing"),
        (#"{"requirements":null,"years":5}"#, "requirements: missing"),
        (#"{"requirements":[{"text":"Go"}],"years":5}"#, "requirements[0].kind: missing"),
        (
            #"{"requirements":[{"text":"Go","kind":"maybe"}],"years":5}"#,
            "requirements[0].kind: expected one of must, nice"
        ),
        (#"{"requirements":[],"years":"five"}"#, "years: expected an integer"),
        (#"{"requirements":[],"years":3.5}"#, "years: expected an integer"),
        (#"{"requirements":[],"years":41}"#, "years: must be at most 40"),
        (#"{"requirements":[],"years":-1}"#, "years: must be at least 0"),
        (#"{"requirements":[],"years":2,"score":1.5}"#, "score: must be at most 1"),
        (#"{"requirements":[],"years":2,"remote":"yes"}"#, "remote: expected true or false"),
        (#"{"requirements":{},"years":2}"#, "requirements: expected an array"),
        (#"[1,2]"#, "top level: expected an object"),
        (
            #"{"requirements":[{"text":"Go","kind":"must","matched_skill":7}],"years":2}"#,
            "requirements[0].matched_skill: expected a string"
        ),
    ])
    func namesTheFailingPath(json: String, expected: String) throws {
        #expect(try issues(json) == [expected])
    }

    @Test func longStringsAndLongArraysAreCaught() throws {
        let long = String(repeating: "x", count: 201)
        let json = """
            {"requirements":[{"text":"a","kind":"must"},{"text":"b","kind":"must"},{"text":"c","kind":"must"},
             {"text":"\(long)","kind":"nice"}],"years":1}
            """
        #expect(
            try issues(json) == [
                "requirements: more than 3 items", "requirements[3].text: longer than 200 characters",
            ])
    }

    @Test func reportsEveryIssueInDocumentOrder() throws {
        let json = #"{"requirements":[{"kind":"must"},{"text":"b","kind":"no"}],"years":99,"remote":1}"#
        #expect(
            try issues(json) == [
                "requirements[0].text: missing", "requirements[1].kind: expected one of must, nice",
                "years: must be at most 40", "remote: expected true or false",
            ])
    }

    @Test func aWholeNumberCountsAsAnInteger() throws {
        #expect(try issues(#"{"requirements":[],"years":3.0}"#).isEmpty)
    }

    @Test func nullIsFineForAnOptionalProperty() throws {
        #expect(
            try issues(#"{"requirements":[{"text":"Go","kind":"nice","matched_skill":null}],"years":0,"remote":null}"#)
                .isEmpty)
    }
}

@Suite("JSON values")
struct JSONValueTests {
    @Test func parsesEveryKindOfValue() throws {
        let value = try JSONValue(parsing: #"{"a":[1,2.5,"x",true,null,{"b":false}]}"#)
        #expect(
            value
                == .object([
                    "a": .array([
                        .number(1), .number(2.5), .string("x"), .bool(true), .null, .object(["b": .bool(false)]),
                    ])
                ]))
    }

    @Test(arguments: ["", "{", "not json", #"{"a":}"#])
    func rejectsWhatIsntJSON(_ text: String) {
        #expect(throws: LLMError.self) { try JSONValue(parsing: text) }
    }

    @Test func encodesBackToTheSameJSON() throws {
        let text = #"{"a":[1,2.5,"x",true,null],"b":{"c":"d"}}"#
        let value = try JSONValue(parsing: text)
        #expect(try JSONValue(parsing: value.jsonString) == value)
    }
}

@Suite("Schema export")
struct SchemaExportTests {
    @Test func producesTheJSONSchemaProvidersAccept() throws {
        let exported = try JSONValue(parsing: analysis.jsonString)
        let expected = try JSONValue(
            parsing: """
                {"type":"object","additionalProperties":false,"required":["requirements","years"],
                 "properties":{
                   "requirements":{"type":"array","maxItems":3,"items":{"type":"object","additionalProperties":false,
                     "required":["text","kind"],
                     "properties":{"text":{"type":"string","maxLength":200},"kind":{"type":"string","enum":["must","nice"]},
                                   "matched_skill":{"type":"string"}}}},
                   "years":{"type":"integer","minimum":0,"maximum":40},
                   "remote":{"type":"boolean"},
                   "score":{"type":"number","minimum":0,"maximum":1}}}
                """)
        #expect(exported == expected)
    }

    @Test func keepsPropertiesInDeclaredOrder() {
        let json = analysis.jsonString
        let order = ["requirements", "years", "remote", "score"].compactMap {
            json.range(of: "\"\($0)\":{")?.lowerBound
        }
        #expect(order == order.sorted())
    }
}
