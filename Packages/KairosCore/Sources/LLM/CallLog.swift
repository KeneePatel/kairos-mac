import CryptoKit
import Foundation
import Store

/// One row of `llm_call` (SPEC §5.5, Observability). There's deliberately no field for prompt or
/// reply text: the log holds counts, codes and ids only.
public struct CallRecord: Sendable, Equatable {
    public let at: Date
    public let task: TaskID
    public let provider: String
    public let model: String
    public let promptVersion: Int
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latency: Duration
    public let attempts: Int
    public let outcome: LLMOutcome
    public let errorCode: String?
    public let jobID: String?
    public let buildID: String?
}

/// Tokens a model read and wrote.
public struct TokenCount: Sendable, Equatable {
    public let input: Int
    public let output: Int

    public init(input: Int, output: Int) {
        self.input = input
        self.output = output
    }
}

/// What was used in a day, for the budget and the Activity screen.
public struct Usage: Sendable, Equatable {
    public let calls: Int
    public let tokens: Int

    public init(calls: Int, tokens: Int) {
        self.calls = calls
        self.tokens = tokens
    }
}

/// The local-only `llm_call` table.
public struct CallLog: Sendable {
    /// Rows older than this are deleted (SPEC §6.2: kept 30 days).
    public static let retentionDays = 30

    let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func record(_ call: CallRecord) async throws {
        try await db.execute(
            """
            INSERT INTO llm_call (at, task_id, provider, model, prompt_version, input_tokens, output_tokens,
                latency_ms, attempt, outcome, error_code, job_id, build_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(call.at), .text(call.task.rawValue), .text(call.provider), .text(call.model),
                SQLValue(call.promptVersion), SQLValue(call.inputTokens), SQLValue(call.outputTokens),
                .integer(RateLimiter.milliseconds(call.latency)), SQLValue(call.attempts), .text(call.outcome.rawValue),
                SQLValue(call.errorCode), SQLValue(call.jobID), SQLValue(call.buildID),
            ])
    }

    /// Provider calls and tokens since `date` (cache hits aren't rows, so they cost nothing).
    public func usage(since date: Date) async throws -> Usage {
        let row = try await db.query(
            """
            SELECT coalesce(sum(attempt), 0) AS calls,
                   coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) AS tokens
            FROM llm_call WHERE at >= ?
            """, [SQLValue(date)]
        ).first
        return Usage(calls: row?.int("calls") ?? 0, tokens: row?.int("tokens") ?? 0)
    }

    /// Usage per provider id since `date`, for the provider cards ("131 calls today").
    public func usageByProvider(since date: Date) async throws -> [String: Usage] {
        let rows = try await db.query(
            """
            SELECT provider, coalesce(sum(attempt), 0) AS calls,
                   coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) AS tokens
            FROM llm_call WHERE at >= ? GROUP BY provider
            """, [SQLValue(date)])
        var usage: [String: Usage] = [:]
        for row in rows {
            guard let provider = row.string("provider") else { continue }
            usage[provider] = Usage(calls: row.int("calls") ?? 0, tokens: row.int("tokens") ?? 0)
        }
        return usage
    }

    /// Tokens in and out per model at one provider since `date`: what a paid provider's calls cost.
    public func tokens(provider: String, since date: Date) async throws -> [String: TokenCount] {
        let rows = try await db.query(
            """
            SELECT model, coalesce(sum(input_tokens), 0) AS input, coalesce(sum(output_tokens), 0) AS output
            FROM llm_call WHERE provider = ? AND at >= ? GROUP BY model
            """, [.text(provider), SQLValue(date)])
        var tokens: [String: TokenCount] = [:]
        for row in rows {
            guard let model = row.string("model") else { continue }
            tokens[model] = TokenCount(input: row.int("input") ?? 0, output: row.int("output") ?? 0)
        }
        return tokens
    }

    /// One build's calls, oldest first: what its "What happened" list is made from once it's over.
    public func calls(build id: String) async throws -> [CallRecord] {
        try await db.query(
            """
            SELECT at, task_id, provider, model, prompt_version, input_tokens, output_tokens, latency_ms, attempt,
                outcome, error_code, job_id, build_id
            FROM llm_call WHERE build_id = ? ORDER BY at, rowid
            """, [.text(id)]
        ).compactMap { row in
            guard let at = row.int64("at"), let task = row.string("task_id").flatMap(TaskID.init(rawValue:)),
                let outcome = row.string("outcome").flatMap(LLMOutcome.init(rawValue:))
            else { return nil }
            return CallRecord(
                at: Date(timeIntervalSince1970: Double(at) / 1_000), task: task, provider: row.string("provider") ?? "",
                model: row.string("model") ?? "", promptVersion: row.int("prompt_version") ?? 0,
                inputTokens: row.int("input_tokens"), outputTokens: row.int("output_tokens"),
                latency: .milliseconds(row.int64("latency_ms") ?? 0), attempts: row.int("attempt") ?? 1,
                outcome: outcome,
                errorCode: row.string("error_code"), jobID: row.string("job_id"), buildID: row.string("build_id"))
        }
    }

    /// What one build cost, per task: its report card's calls and tokens.
    public func usage(build id: String) async throws -> [TaskID: Usage] {
        let rows = try await db.query(
            """
            SELECT task_id, coalesce(sum(attempt), 0) AS calls,
                   coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) AS tokens
            FROM llm_call WHERE build_id = ? GROUP BY task_id
            """, [.text(id)])
        var usage: [TaskID: Usage] = [:]
        for row in rows {
            guard let task = row.string("task_id").flatMap(TaskID.init(rawValue:)) else { continue }
            usage[task] = Usage(calls: row.int("calls") ?? 0, tokens: row.int("tokens") ?? 0)
        }
        return usage
    }

    @discardableResult
    public func deleteOlder(than date: Date) async throws -> Int {
        try await db.transaction { connection in
            try connection.execute("DELETE FROM llm_call WHERE at < ?", [SQLValue(date)])
            return connection.changes
        }
    }
}

/// The local-only `llm_cache`: validated outputs keyed by (task, input hash, prompt version, model),
/// so a cancelled or crashed build resumes without paying again (SPEC §5.5, Reliability).
public struct ResultCache: Sendable {
    public struct Key: Hashable, Sendable {
        public let task: TaskID
        public let inputHash: String
        public let promptVersion: Int
        public let model: String

        /// `inputHash` is the SHA-256 of the rendered messages, so it changes whenever the input or
        /// the prompt's wording does.
        public init(task: TaskID, messages: [ChatMessage], promptVersion: Int, model: String) {
            self.task = task
            let rendered = messages.map { "\($0.role.rawValue)\u{1F}\($0.content)" }.joined(separator: "\u{1E}")
            inputHash = SHA256.hash(data: Data(rendered.utf8)).map { String(format: "%02x", $0) }.joined()
            self.promptVersion = promptVersion
            self.model = model
        }
    }

    let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func output(for key: Key) async throws -> String? {
        try await db.query(
            "SELECT output FROM llm_cache WHERE task_id = ? AND input_hash = ? AND prompt_version = ? AND model = ?",
            Self.values(key)
        ).first?.string("output")
    }

    public func store(_ output: String, for key: Key, at date: Date) async throws {
        try await db.execute(
            """
            INSERT INTO llm_cache (task_id, input_hash, prompt_version, model, output, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT DO UPDATE SET output = excluded.output, created_at = excluded.created_at
            """, Self.values(key) + [.text(output), SQLValue(date)])
    }

    private static func values(_ key: Key) -> [SQLValue] {
        [.text(key.task.rawValue), .text(key.inputHash), SQLValue(key.promptVersion), .text(key.model)]
    }
}
