import AI
import Foundation
import KairosKit
import SQL

/// The call log and the result cache, for the AI router; and what Settings shows about each key.
public struct AIRepository: AICallLog, AIResultCache {
    let db: Database

    public func record(_ call: AICall) async {
        try? await db.execute(
            """
            INSERT INTO ai_call (at, task, provider, key_name, model, prompt_version, outcome, error_code, input_tokens,
                output_tokens, ms, fell_back, job_id, build_id, daily_limit, back_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                SQLValue(call.at), .text(call.task.rawValue), .text(call.provider), SQLValue(call.keyName),
                .text(call.model),
                SQLValue(call.promptVersion), .text(call.outcome.rawValue), SQLValue(call.errorCode),
                SQLValue(call.inputTokens),
                SQLValue(call.outputTokens), SQLValue(call.milliseconds), SQLValue(call.fellBack), SQLValue(call.jobID),
                SQLValue(call.buildID), SQLValue(call.dailyLimit), SQLValue(call.backAt),
            ])
    }

    public func usage(since start: Date) async -> (calls: Int, tokens: Int) {
        let row = try? await db.first(
            """
            SELECT count(*) AS calls, coalesce(sum(coalesce(input_tokens, 0) + coalesce(output_tokens, 0)), 0) AS tokens
            FROM ai_call WHERE at >= ? AND outcome IN ('ok', 'invalid', 'failed', 'used_up')
            """, [SQLValue(start)])
        return (row?.int("calls") ?? 0, row?.int("tokens") ?? 0)
    }

    public func output(task: TaskID, inputHash: String, promptVersion: Int, model: String) async -> String? {
        try? await db.first(
            "SELECT output FROM ai_cache WHERE task = ? AND input_hash = ? AND prompt_version = ? AND model = ?",
            [.text(task.rawValue), .text(inputHash), SQLValue(promptVersion), .text(model)])?.string("output")
    }

    public func store(_ json: String, task: TaskID, inputHash: String, promptVersion: Int, model: String) async {
        try? await db.execute(
            """
            INSERT INTO ai_cache (task, input_hash, prompt_version, model, output, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (task, input_hash, prompt_version, model) DO UPDATE SET output = excluded.output,
                created_at = excluded.created_at
            """,
            [
                .text(task.rawValue), .text(inputHash), SQLValue(promptVersion), .text(model), .text(json),
                SQLValue(Date()),
            ])
    }

    /// Each key's use of each model since `start` (its quota day), and the last limit a refusal named.
    public func keyUsage(provider: String, since start: Date) async throws -> [String: [String: KeyModelUse]] {
        var result: [String: [String: KeyModelUse]] = [:]
        for row in try await db.query(
            """
            SELECT key_name, model,
                sum(CASE WHEN at >= ? AND outcome IN ('ok', 'invalid', 'failed') THEN 1 ELSE 0 END) AS calls,
                max(CASE WHEN at >= ? AND outcome = 'used_up' THEN 1 ELSE 0 END) AS refused,
                max(CASE WHEN at >= ? AND outcome = 'used_up' THEN back_at END) AS back
            FROM ai_call WHERE provider = ? AND key_name IS NOT NULL GROUP BY key_name, model
            """, [SQLValue(start), SQLValue(start), SQLValue(start), .text(provider)])
        {
            guard let key = row.string("key_name"), let model = row.string("model") else { continue }
            result[key, default: [:]][model] = KeyModelUse(
                calls: row.int("calls") ?? 0, refused: row.bool("refused") ?? false, back: row.date("back"))
        }
        for row in try await db.query(
            """
            SELECT key_name, model, daily_limit FROM ai_call a WHERE provider = ? AND daily_limit IS NOT NULL
                AND at = (SELECT max(at) FROM ai_call b WHERE b.provider = a.provider AND b.key_name = a.key_name
                    AND b.model = a.model AND b.daily_limit IS NOT NULL)
            """, [.text(provider)])
        {
            guard let key = row.string("key_name"), let model = row.string("model") else { continue }
            result[key, default: [:]][model, default: KeyModelUse()].limit = row.int("daily_limit")
        }
        return result
    }

    /// Calls today per provider and model: answers, failures, and the average time of an answer.
    public struct ModelDay: Sendable, Equatable {
        public let provider: String
        public let model: String
        public let answered: Int
        public let failed: Int
        public let averageSeconds: Double?
    }

    public func today(since start: Date) async throws -> [ModelDay] {
        try await db.query(
            """
            SELECT provider, model, sum(outcome = 'ok') AS answered, sum(outcome IN ('invalid', 'failed', 'used_up')) AS failed,
                avg(CASE WHEN outcome = 'ok' THEN ms END) AS ms
            FROM ai_call WHERE at >= ? GROUP BY provider, model ORDER BY provider, model
            """, [SQLValue(start)]
        ).compactMap { row in
            guard let provider = row.string("provider"), let model = row.string("model") else { return nil }
            return ModelDay(
                provider: provider, model: model, answered: row.int("answered") ?? 0, failed: row.int("failed") ?? 0,
                averageSeconds: row.double("ms").map { $0 / 1_000 })
        }
    }

    /// A build's calls in order, for its timeline: task, model, outcome, error and time.
    public func calls(build: UUID) async throws -> [AICall] {
        try await db.query("SELECT * FROM ai_call WHERE build_id = ? ORDER BY at, id", [.text(build.lowercased)])
            .compactMap { row in
                guard let task = row.string("task"), let provider = row.string("provider"),
                    let model = row.string("model"),
                    let outcome = row.optionalValue("outcome", as: AICall.Outcome.self), let at = row.date("at")
                else { return nil }
                return AICall(
                    at: at, task: TaskID(task), provider: provider, keyName: row.string("key_name"), model: model,
                    promptVersion: row.int("prompt_version") ?? 0, outcome: outcome,
                    errorCode: row.string("error_code"),
                    inputTokens: row.int("input_tokens"), outputTokens: row.int("output_tokens"),
                    milliseconds: row.int("ms") ?? 0,
                    fellBack: row.bool("fell_back") ?? false, jobID: row.string("job_id"),
                    buildID: row.string("build_id"))
            }
    }

    /// Drops call rows and cache entries older than `days`.
    public func trim(olderThan days: Int, at now: Date = Date()) async throws {
        let cutoff = SQLValue(now.addingTimeInterval(-.days(Double(days))))
        try await db.transaction { connection in
            try connection.execute("DELETE FROM ai_call WHERE at < ?", [cutoff])
            try connection.execute("DELETE FROM ai_cache WHERE created_at < ?", [cutoff])
        }
    }
}
