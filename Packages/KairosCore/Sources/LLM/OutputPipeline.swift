import Foundation

/// Turns a reply into a task's typed output (SPEC §5.5, "Structured output"): strip code fences,
/// parse, validate against the schema, decode, run the task's own check. A failure comes back as a
/// sentence the repair call can hand to the model.
enum OutputPipeline {
    struct Problem: Error, Equatable, CustomStringConvertible {
        let description: String
    }

    static func output<T: LLMTask>(from response: ChatResponse, task: T, input: T.Input) -> Result<T.Output, Problem> {
        if response.finishReason == "length" {
            return .failure(Problem(description: "The reply was cut off at the output limit."))
        }
        let text = unfenced(response.text)
        guard let value = try? JSONValue(parsing: text) else {
            return .failure(Problem(description: "The reply isn't valid JSON."))
        }
        let issues = SchemaValidator.issues(in: value, against: T.outputSchema)
        guard issues.isEmpty else {
            let list = issues.map(\.description).joined(separator: "; ")
            return .failure(Problem(description: "The reply doesn't match the schema: \(list)."))
        }
        let decoder = JSONDecoder()
        // Schemas name properties in snake_case; Swift output types use camelCase.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let output: T.Output
        do {
            output = try decoder.decode(T.Output.self, from: Data(text.utf8))
        } catch {
            return .failure(Problem(description: "The reply couldn't be read: \(error.localizedDescription)"))
        }
        do {
            try task.check(output, for: input)
        } catch let LLMError.invalidOutput(reason) {
            return .failure(Problem(description: "The reply failed a check: \(reason)."))
        } catch {
            return .failure(Problem(description: "The reply failed a check: \(error)."))
        }
        return .success(output)
    }

    /// Models sometimes wrap JSON in a Markdown fence (T20: Ollama with thinking off).
    static func unfenced(_ text: String) -> String {
        text.replacing(/^\s*```(?:json)?\s*|\s*```\s*$/, with: "")
    }

    /// The message that asks for a fixed reply, quoting what was wrong.
    static func repairNote(_ problem: Problem) -> String {
        "That reply can't be used. \(problem.description) Reply again with JSON only, fixing that and keeping "
            + "everything else that was right."
    }
}
