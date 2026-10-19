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

/// What was used in a day, for the budget and the Activity screen.
public struct Usage: Sendable, Equatable {
    public let calls: Int
    public let tokens: Int
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
