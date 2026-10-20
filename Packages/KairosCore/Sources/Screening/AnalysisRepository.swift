import Foundation
import Store

/// An analysis as stored, with the model and prompt that made it.
public struct StoredAnalysis: Sendable, Equatable {
    public let analysis: JobAnalysis
    public let model: String
    public let promptVersion: Int
    public let analyzedAt: Date
}

/// Reads and writes `job_analysis`: one row per job, the latest analysis (SPEC §6.2).
public struct AnalysisRepository: Sendable {
    public let db: Database

    public init(_ db: Database) {
        self.db = db
    }

    /// The stored analysis of `job` if `promptVersion` made it. An older prompt's is stale, so the
    /// job gets analysed again (SPEC §5.5, "Versioned prompts").
    public func analysis(for job: JobID, promptVersion: Int) async throws -> StoredAnalysis? {
        let rows = try await db.query(
            "SELECT * FROM job_analysis WHERE job_id = ? AND prompt_version = ? AND deleted = 0",
            [.text(job.rawValue), SQLValue(promptVersion)])
        guard let row = rows.first else { return nil }
        let reader = RowReader(row: row, table: "job_analysis")
        guard let flags = try reader.json("flags", as: JobAnalysis.Flags.self) else { throw reader.corrupt("flags") }
        let analysis = JobAnalysis(
            requirements: try reader.json("requirements", as: [JobAnalysis.Requirement].self) ?? [],
            yearsRequired: row.int("years_required"),
            seniority: try reader.optionalValue("seniority", as: Seniority.self),
            domains: try reader.json("domains", as: [String].self) ?? [], flags: flags)
        return StoredAnalysis(
            analysis: analysis, model: try reader.string("model"), promptVersion: try reader.int("prompt_version"),
            analyzedAt: try reader.date("analyzed_at"))
    }

    public func save(_ analysis: JobAnalysis, for job: JobID, model: String, promptVersion: Int) async throws {
        let values: [SQLValue] = [
            .text(job.rawValue), .text(try Self.json(analysis.requirements)), .text(try Self.json(analysis.flags)),
            .text(try Self.json(analysis.domains)), SQLValue(analysis.yearsRequired),
            SQLValue(analysis.seniority?.rawValue), .text(model), SQLValue(promptVersion),
        ]
        try await db.write { connection, stamp in
            try connection.execute(
                """
                INSERT INTO job_analysis (job_id, requirements, flags, domains, years_required, seniority, model,
                    prompt_version, analyzed_at, updated_hlc)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (job_id) DO UPDATE SET requirements = excluded.requirements, flags = excluded.flags,
                    domains = excluded.domains, years_required = excluded.years_required,
                    seniority = excluded.seniority, model = excluded.model, prompt_version = excluded.prompt_version,
                    analyzed_at = excluded.analyzed_at, updated_hlc = excluded.updated_hlc, deleted = 0
                """, values + [.integer(stamp.milliseconds), .text(stamp.hlc.description)])
        }
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        do {
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            throw StoreError.invalidValue("can't encode an analysis")
        }
    }
}
