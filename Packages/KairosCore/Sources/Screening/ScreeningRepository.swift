import Foundation
import Store

/// One verdict in a job's trail.
public struct ScreeningRecord: Sendable, Equatable {
    public let stage: VerdictSource
    public let verdict: Verdict
    /// A `PrefilterRule` or `VerdictRule` raw value; nil for your own overrule.
    public let ruleID: String?
    public let coverage: Coverage?
    public let reasons: [String]
    public let at: Date
}

/// Writes and reads `screening`: every verdict a job got and what decided it (SPEC §6.2).
public struct ScreeningRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    public func record(_ rejection: Rejection, for job: JobID) async throws {
        try await insert(
            job, stage: .prefilter, verdict: .no, rule: rejection.rule.rawValue, coverage: nil,
            reasons: [rejection.reason])
    }

    public func record(_ decision: VerdictDecision, for job: JobID) async throws {
        try await insert(
            job, stage: .analysis, verdict: decision.verdict, rule: decision.rule.rawValue,
            coverage: decision.coverage, reasons: decision.reasons)
    }

    /// Oldest first.
    public func trail(for job: JobID) async throws -> [ScreeningRecord] {
        let rows = try await db.query(
            "SELECT * FROM screening WHERE job_id = ? AND deleted = 0 ORDER BY at, rowid", [.text(job.rawValue)])
        return try rows.map { row throws in
            let reader = RowReader(row: row, table: "screening")
            let coverage = try row.string("coverage").flatMap { text throws -> Coverage? in
                text == "null" ? nil : try reader.json("coverage", as: Coverage.self)
            }
            return ScreeningRecord(
                stage: try reader.value("stage", as: VerdictSource.self),
                verdict: try reader.value("verdict", as: Verdict.self), ruleID: row.string("rule_id"),
                coverage: coverage, reasons: try reader.json("reasons", as: [String].self) ?? [],
                at: try reader.date("at"))
        }
    }

    private func insert(
        _ job: JobID, stage: VerdictSource, verdict: Verdict, rule: String?, coverage: Coverage?, reasons: [String]
    ) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let coverageJSON: String
        let reasonsJSON: String
        do {
            coverageJSON = try coverage.map { String(decoding: try encoder.encode($0), as: UTF8.self) } ?? "null"
            reasonsJSON = String(decoding: try encoder.encode(reasons), as: UTF8.self)
        } catch {
            throw StoreError.invalidValue("can't encode a screening record")
        }
        try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO screening (id, job_id, stage, verdict, rule_id, coverage, reasons, at, updated_hlc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(UUID.v7().lowercased), .text(job.rawValue), .text(stage.rawValue),
                    .text(verdict.rawValue), SQLValue(rule), .text(coverageJSON), .text(reasonsJSON),
                    .integer(stamp.milliseconds), .text(stamp.hlc.description),
                ])
        }
    }
}
