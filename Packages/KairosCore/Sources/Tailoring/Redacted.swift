import LLM
import MasterResume

/// A task with your contact details removed from the data it sends (SPEC §5.5, Privacy). They
/// belong in your contact block, which code adds to the PDF and the letter, but a bullet or an
/// employer can mention them too ("github.com/averyquill/dockhand", "Avery Quill Consulting").
/// Instructions pass unchanged; the reply and its check are the task's own.
public struct Redacted<Task: LLMTask>: LLMTask {
    public typealias Input = Task.Input
    public typealias Output = Task.Output

    public static var id: TaskID { Task.id }
    public static var promptVersion: Int { Task.promptVersion }
    public static var outputSchema: JSONSchema { Task.outputSchema }

    public let task: Task
    public let header: ResumeHeader

    public init(_ task: Task, header: ResumeHeader) {
        self.task = task
        self.header = header
    }

    public func messages(for input: Input, budget: TokenBudget) -> [ChatMessage] {
        task.messages(for: input, budget: budget).map { message in
            guard message.role == .user else { return message }
            return ChatMessage(role: .user, content: ContactRedactor.redact(message.content, header: header))
        }
    }

    public func check(_ output: Output, for input: Input) throws {
        try task.check(output, for: input)
    }
}
