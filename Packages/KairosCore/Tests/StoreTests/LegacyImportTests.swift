import AI
import Foundation
import Jobs
import KairosKit
import Resume
import SQL
import Screening
import Store
import Tailoring
import TestKit
import Testing

/// The first Kairos's database, built from its own migrations (Tests/Fixtures/legacy-schema) and
/// filled the way it wrote rows, imported into this one.
@Suite("Importing the first Kairos")
struct LegacyImportTests {
    let folder: DataFolder
    let legacy: Database

    let acme = "0190a000-0000-7000-8000-000000000001"
    let removed = "0190a000-0000-7000-8000-000000000002"
    let linkedIn = "0190a000-0000-7000-8000-000000000003"
    let adzuna = "0190a000-0000-7000-8000-000000000004"
    let himalayas = "0190a000-0000-7000-8000-000000000005"

    init() async throws {
        folder = DataFolder(
            root: FileManager.default.temporaryDirectory.appending(path: "kairos-import-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: folder.legacyBuilds, withIntermediateDirectories: true)
        legacy = try Database(path: folder.legacyDatabase.path)
        try await Migrator.migrate(legacy, with: try Migrator.migrations(in: Fixtures.url("legacy-schema")))
    }

    func insert(_ table: String, _ values: [String: SQLValue]) async throws {
        var values = values
        if ![
            "private_setting", "llm_key_call", "fetch_log", "lead", "company_lookup", "search_turn",
            "source_fetch_state",
        ]
        .contains(table), values["updated_hlc"] == nil {
            values["updated_hlc"] = "0000000001-0000-node"
        }
        let columns = values.keys.sorted()
        try await legacy.execute(
            "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(columns.map { _ in "?" }.joined(separator: ", ")))",
            columns.map { values[$0] ?? .null })
    }

    func job(
        _ path: String, title: String, state: String = "new", verdict: String? = nil, source: String? = nil,
        rank: Double? = nil, deleted: Bool = false, cleared: Bool = false, kind: String = "full",
        canonical: String? = nil, sourceID: String? = nil
    ) async throws -> String {
        let url = "https://job-boards.greenhouse.io/acme/jobs/\(path)"
        let canonicalURL = canonical ?? url
        let id = StableID.of(canonicalURL)
        let seen = SQLValue(now.addingTimeInterval(-.days(3)))
        try await insert(
            "job",
            [
                "id": .text(id), "source_id": .text(sourceID ?? acme), "url": .text(url),
                "canonical_url": .text(canonicalURL),
                "dedup_key": .text(DedupKey.make(company: "Acme", title: title, city: "Toronto")), "company": "Acme",
                "title": .text(title), "location": "Toronto, ON", "city": "Toronto", "region": "ON", "country": "CA",
                "remote_scope": "onsite", "currency": "CAD",
                "salary": "{\"min\":90000,\"max\":120000,\"period\":\"year\"}",
                "description": .text("Build things for \(title)."), "state": .text(state), "verdict": SQLValue(verdict),
                "verdict_source": SQLValue(source), "rank": SQLValue(rank), "first_seen_at": seen,
                "deleted": SQLValue(deleted),
                "cleared": SQLValue(cleared), "last_seen_at": seen, "description_kind": .text(kind),
                "primary_listing_id": .text(id),
            ])
        try await insert(
            "listing",
            [
                "id": .text(id), "job_id": .text(id), "source_id": .text(sourceID ?? acme), "url": .text(url),
                "canonical_url": .text(canonicalURL), "title": .text(title), "company": "Acme",
                "location": "Toronto, ON",
                "description": .text("Build things for \(title)."), "description_kind": .text(kind),
                "content_hash": "old-hash", "first_seen_at": seen, "last_seen_at": seen, "deleted": SQLValue(deleted),
            ])
        try await insert(
            "job_event",
            [
                "id": .text(UUID().uuidString.lowercased()), "job_id": .text(id), "at": seen, "kind": "found",
                "source_id": .text(acme),
            ])
        return id
    }

    @Test func everythingCarriesOverAndTheOldDatabaseIsUntouched() async throws {
        defer { try? FileManager.default.removeItem(at: folder.root) }
        // Sources: a catalog board, one you removed, a page runner this version doesn't have, and searches.
        try await insert(
            "source",
            [
                "id": .text(acme), "kind": "greenhouse",
                "config": "{\"slug\":\"Acme\",\"company\":\"Acme\",\"origin\":\"catalog\"}",
            ])
        try await insert(
            "source", ["id": .text(removed), "kind": "lever", "config": "{\"slug\":\"gone-co\"}", "deleted": 1])
        try await insert("source", ["id": .text(linkedIn), "kind": "linkedin", "config": "{}"])
        try await insert("source", ["id": .text(adzuna), "kind": "adzuna", "config": "{}"])
        try await insert("source", ["id": .text(himalayas), "kind": "himalayas", "config": "{}", "enabled": 0])
        try await insert(
            "source_fetch_state",
            ["source_id": .text(acme), "etag": "\"v9\"", "last_ok_at": SQLValue(now), "fail_runs": 1])

        // Jobs: judged, overruled and saved, filtered, cleared, retired, a snippet, applied, brought back.
        let judged = try await job("1", title: "Software Engineer", verdict: "yes", source: "analysis", rank: 230)
        let saved = try await job(
            "2", title: "Backend Developer", state: "shortlisted", verdict: "yes", source: "user",
            canonical: "https://boards.greenhouse.io/acme/jobs/2")
        let filtered = try await job("3", title: "Sales Lead", verdict: "no", source: "prefilter")
        _ = try await job("4", title: "Cleared Engineer", deleted: true, cleared: true)
        let retired = try await job("5", title: "Retired Engineer", deleted: true)
        _ = try await job("6", title: "Snippet Developer", kind: "snippet", sourceID: adzuna)
        let applied = try await job(
            "7", title: "Platform Engineer", state: "applied", verdict: "maybe", source: "analysis")
        let back = try await job("8", title: "QA Engineer")

        let requirement = JobAnalysis.Requirement(
            text: "Swift", kind: .must, category: .skill, match: .yes, evidence: ["s1"])
        try await insert(
            "job_analysis",
            [
                "job_id": .text(judged), "requirements": .text(try [requirement].jsonText()),
                "flags": .text(try JobAnalysis.Flags(french: .asset).jsonText()), "domains": "[\"logistics\"]",
                "years_required": 2, "seniority": "mid", "model": "gemini-2.5-flash", "prompt_version": 2,
                "analyzed_at": SQLValue(now),
            ])
        let coverage = Coverage(mustCovered: 1, mustTotal: 1)
        try await insert(
            "screening",
            [
                "id": "s1", "job_id": .text(judged), "stage": "analysis", "verdict": "yes", "rule_id": "strong_match",
                "coverage": .text(try coverage.jsonText()), "reasons": "[\"Shows 1 of 1 must-haves.\"]",
                "at": SQLValue(now),
            ])
        try await insert(
            "screening",
            [
                "id": "s2", "job_id": .text(saved), "stage": "analysis", "verdict": "maybe", "rule_id": "partial_match",
                "coverage": "{}", "reasons": "[]", "at": SQLValue(now),
            ])
        try await insert(
            "screening",
            [
                "id": "s3", "job_id": .text(filtered), "stage": "prefilter", "verdict": "no",
                "rule_id": "title_include",
                "reasons": "[\"Not one of your roles\"]", "at": SQLValue(now),
            ])

        // The master resume.
        try await insert(
            "resume_contact",
            [
                "id": "contact", "full_name": "Jordan Rivera", "email": "jordan.rivera@example.com",
                "phone_e164": "+14165550123", "linkedin_url": "https://www.linkedin.com/in/jordan-rivera",
                "total_years": 5, "master_version": 41,
            ])
        let entry = try #require(Sample.resume.entries.first)
        try await insert(
            "resume_entry",
            [
                "id": .text(entry.id.uuidString), "kind": "experience", "fields": .text(try entry.fields.json()),
                "start_month": "2022-03", "is_current": 1,
            ])
        for (index, bullet) in entry.bullets.enumerated() {
            try await insert(
                "resume_bullet",
                [
                    "id": .text(bullet.id.uuidString.lowercased()), "entry_id": .text(entry.id.uuidString.lowercased()),
                    "text": .text(bullet.text), "metrics": .text(try bullet.metrics.jsonText()),
                    "skills": .text(try bullet.skills.jsonText()), "sort": SQLValue(index),
                ])
        }
        try await insert(
            "skill", ["id": .text(Sample.id(500).uuidString.lowercased()), "name": "Go", "level": "proven"])

        // A build with its PDFs and letter, and the application that sent it.
        let build = "0190a000-0000-7000-8000-0000000000b1"
        let letter = CoverLetter(
            header: .init(name: "Jordan Rivera"), date: "October 20, 2026", company: "Acme",
            jobTitle: "Platform Engineer",
            greeting: "Dear Hiring Team,", paragraphs: ["I build platforms."], closing: "Sincerely,",
            signature: "Jordan Rivera")
        try await insert(
            "build",
            [
                "id": .text(build), "job_id": .text(applied), "mode": "strict", "master_version": 40, "status": "done",
                "content": .text(try TailoredResume(header: .init(name: "Jordan Rivera")).jsonText()),
                "match_score": 78.5,
                "cover_letter": .text("{\"status\":\"done\",\"letter\":\(try letter.jsonText())}"),
                "created_at": SQLValue(now), "finished_at": SQLValue(now),
            ])
        let pdf = folder.legacyBuilds.appending(path: "\(build).pdf")
        try Data("%PDF-1.7 resume".utf8).write(to: pdf)
        try await insert(
            "artifact",
            ["id": "a1", "build_id": .text(build), "kind": "resume", "sha256": "x", "local_path": .text(pdf.path)])
        try await insert(
            "artifact",
            [
                "id": "a2", "build_id": .text(build), "kind": "cover_letter", "sha256": "y",
                "local_path": "/nowhere/letter.pdf",
            ])
        let application = "0190a000-0000-7000-8000-0000000000c1"
        try await insert(
            "application",
            [
                "id": .text(application), "job_id": .text(applied), "build_id": .text(build),
                "applied_at": SQLValue(now),
                "channel": "Company site", "status": "interview", "status_at": SQLValue(now), "next_action": "Prepare",
                "notes": "Met the team.",
            ])
        try await insert(
            "application_event",
            ["id": "e1", "application_id": .text(application), "kind": "applied", "at": SQLValue(now)])

        // Settings, and what budgets and quotas remember.
        var preferences = SearchPreferences()
        preferences.roles = [.software]
        preferences.maxAgeDays = 30
        try await insert("setting", ["key": "screening", "value": .text(try preferences.jsonText())])
        try await insert("setting", ["key": "llm", "value": .text(try AISettings.defaults().jsonText())])
        try await insert("setting", ["key": "stretch_mode", "value": "{\"enabled\":true,\"perRole\":2}"])
        try await insert("setting", ["key": "screening.broughtBack", "value": .text(try [back].jsonText())])
        try await insert("private_setting", ["key": "work_profile", "value": .text(try WorkProfile().jsonText())])
        try await insert(
            "fetch_log",
            [
                "source_id": .text(adzuna), "at": SQLValue(now.addingTimeInterval(-3_600)), "request": "search",
                "outcome": "ok", "requests": 40,
            ])
        try await insert(
            "llm_key_call",
            [
                "at": SQLValue(now.addingTimeInterval(-600)), "provider": "gemini", "key_name": "main",
                "model": "gemini-2.5-flash", "outcome": "used_up", "daily_limit": 250, "back_at": SQLValue(day(1)),
            ])
        try await insert(
            "lead",
            [
                "id": "lead1", "source_id": .text(adzuna), "company": "Maplepay", "title": "Developer",
                "first_seen_at": SQLValue(now), "last_seen_at": SQLValue(now),
            ])
        try await insert(
            "company_lookup",
            ["name_key": "maplepay", "kind": "ashby", "slug": "maplepay", "checked_at": SQLValue(now)])
        try await insert("search_turn", ["source_id": "g", "key": "developer|toronto", "last_at": SQLValue(now)])

        // The old files, as they were before the import.
        let before = try Data(contentsOf: folder.legacyDatabase)

        let store = try await KairosStore.open(at: folder.database)
        let importer = LegacyImport(store: store, folder: folder)
        #expect(try await importer.isPending())
        let report = try await importer.run(at: now)

        #expect(try Data(contentsOf: folder.legacyDatabase) == before)
        #expect(report.schemaVersion == 17)
        #expect(report.sources == 4)
        #expect(report.jobs == 6)
        #expect(report.archived == 1)
        #expect(report.leftBehind == 2)
        #expect(report.readdressed == 1)
        #expect(report.builds == 1 && report.files == 1 && report.missingFiles == 1)
        #expect(report.settings == 4)
        #expect(report.notes.isEmpty)
        let backup = try #require(report.backup)
        #expect(FileManager.default.fileExists(atPath: folder.file(backup).path))
        #expect(try await importer.isPending() == false)
        await #expect(throws: LegacyImport.ImportError.alreadyImported) { try await importer.run(at: now) }

        // Sources.
        let sources = try await store.sources.all()
        let board = try #require(sources.first { $0.kind == .greenhouse })
        #expect(board.slug == "acme" && board.origin == .catalog && board.status == .watching && board.failStreak == 1)
        #expect(board.etag == nil)
        #expect(sources.first { $0.kind == .lever }?.status == .removed)
        #expect(sources.first { $0.kind == .himalayas }?.status == .muted)

        // Jobs and their screening.
        let jobs = try await store.jobs.summaries()
        #expect(Set(jobs.map(\.id)) == [judged, saved, filtered, applied, back])
        let judgedJob = try #require(jobs.first { $0.id == judged })
        #expect(
            judgedJob.verdict == .yes && judgedJob.screening?.coverage == coverage && judgedJob.screening?.rank == 230)
        #expect(judgedJob.salary?.currency == "CAD")
        let savedJob = try #require(jobs.first { $0.id == saved })
        #expect(
            savedJob.decision == .saved && savedJob.screening?.yourVerdict == .yes
                && savedJob.screening?.verdict == .maybe)
        #expect(jobs.first { $0.id == filtered }?.screening?.filterRule == .titleInclude)
        #expect(jobs.first { $0.id == back }?.screening?.broughtBack == true)
        #expect(jobs.first { $0.id == applied }?.application?.status == .interview)
        #expect(try await store.jobs.summaries(.archived).map(\.id) == [retired])
        let detail = try #require(try await store.jobs.detail(judged))
        #expect(detail.analysis?.requirements == [requirement])
        #expect(detail.events.map(\.kind) == [.found])
        #expect(detail.listings.first?.sourceName == "Acme")
        #expect(
            try await store.jobs.job(saved)?.primaryListingID
                == StableID.of("https://job-boards.greenhouse.io/acme/jobs/2"))

        // The master resume.
        let resume = try await store.resume.load()
        #expect(resume.version == 41)
        #expect(resume.header.fullName == "Jordan Rivera" && resume.header.phone == "+14165550123")
        #expect(resume.entries == [entry])
        #expect(resume.skills.map(\.name) == ["Go"])

        // Builds, their files and the application.
        let built = try #require(try await store.builds.builds(for: applied).first)
        #expect(built.status == .done && built.wantsLetter && built.letter == letter && built.score == 78.5)
        let file = try #require(built.file(.resume))
        #expect(try Data(contentsOf: folder.file(file.path)) == Data("%PDF-1.7 resume".utf8))
        let sent = try #require(try await store.applications.application(forJob: applied))
        #expect(sent.buildID == built.id && sent.nextStep == "Prepare" && sent.notes == "Met the team.")
        #expect(try await store.applications.events(of: sent.id).map(\.kind) == ["applied"])

        // Settings, budgets and quotas.
        #expect(try await store.settings.preferences() == preferences)
        #expect(try await store.settings.stretch() == StretchSettings(enabled: true, perRole: 2))
        let search = try #require(sources.first { $0.kind == .adzuna })
        #expect(try await store.activity.requests(of: search.id, at: now).today == 40)
        #expect(
            try await store.ai.keyUsage(provider: "gemini", since: now.addingTimeInterval(-86_400))["main"]?[
                "gemini-2.5-flash"]?.limit == 250)
        #expect(try await store.activity.lastSearched() == ["developer|toronto": now])
        #expect(try await store.activity.lookups(["maplepay"])["maplepay"]?.board?.kind == .ashby)

        // An imported listing's first sighting refreshes its text without counting as an edit.
        let outcome = try await store.ledger.record(
            [listing("acme/jobs/1", title: "Software Engineer", description: "The new Markdown.")], from: board,
            complete: false, at: day(1))
        #expect(outcome.known == 1 && outcome.changed == 0)
        #expect(try await store.jobs.job(judged)?.description == "The new Markdown.")
        #expect(try await store.screening.state(for: judged)?.verdict == .yes)
    }

    @Test func anOldDatabaseItCantReadIsRefused() async throws {
        defer { try? FileManager.default.removeItem(at: folder.root) }
        try await legacy.execute("PRAGMA user_version = 9")
        let store = try await KairosStore.inMemory()
        await #expect(throws: LegacyImport.ImportError.tooOld(9)) {
            try await LegacyImport(store: store, folder: folder).run(at: now)
        }
    }
}
