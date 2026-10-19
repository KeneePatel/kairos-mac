import Foundation

/// The built-in instructions for each task, one versioned resource per prompt:
/// `Prompts/<task>.v<N>.md` (SPEC §5.5, "Versioned prompts"). Changing a prompt means a new file
/// and a bumped `promptVersion`, which also invalidates cached results.
public enum PromptLibrary {
    public static func instructions(for task: TaskID, version: Int) -> String? {
        guard
            let url = Bundle.module.url(
                forResource: "\(task.rawValue).v\(version)", withExtension: "md", subdirectory: "Prompts")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
