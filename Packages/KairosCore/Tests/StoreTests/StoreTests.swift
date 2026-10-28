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

@Suite("Store")
struct StoreTests {
    // MARK: - Schema

    @Test func aNewDatabaseIsAtTheNewestSchemaAndOpensAgain() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kairos-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Library/kairos.sqlite")
        let first = try await KairosStore.open(at: url)
        let known = try KairosStore.migrations().count
        #expect(try await first.db.userVersion() == known)
        #expect(try await first.db.journalMode() == "wal")
        try await first.settings.set("probe", to: ["a": 1], at: now)

        let again = try await KairosStore.open(at: url)
        #expect(try await again.settings.value("probe", as: [String: Int].self) == ["a": 1])
    }

    @Test func aDatabaseFromANewerKairosIsRefused() async throws {
        let db = try Database.inMemory()
        try await db.execute("PRAGMA user_version = 999")
        await #expect(throws: SQLError.self) {
            try await Migrator.migrate(db, with: try KairosStore.migrations())
        }
    }

    @Test func theDataFolderKeepsPathsRelative() {
        let folder = DataFolder(root: URL(filePath: "/tmp/Kairos", directoryHint: .isDirectory))
        let pdf = folder.builds.appending(path: "a.pdf")
        #expect(folder.relative(pdf) == "Library/Builds/a.pdf")
        #expect(folder.file("Library/Builds/a.pdf").path == pdf.path)
        #expect(folder.relative(URL(filePath: "/elsewhere/b.pdf")) == "/elsewhere/b.pdf")
    }

    // MARK: - Settings

    @Test func settingsFallBackToTheirDefaults() async throws {
        let store = try await emptyStore()
        #expect(try await store.settings.preferences() == SearchPreferences())
        #expect(try await store.settings.stretch() == StretchSettings())
        var stretch = StretchSettings()
        stretch.enabled = true
        try await store.settings.set(StretchSettings.storageKey, to: stretch, at: now)
        #expect(try await store.settings.stretch().enabled)
        try await store.settings.remove(StretchSettings.storageKey)
        #expect(try await store.settings.stretch().enabled == false)
    }

    // MARK: - Sources

    @Test func aRemovedBoardIsNeverAddedBackButYouCanAddItAgain() async throws {
        let store = try await emptyStore()
        let catalog = [
            Board(kind: .greenhouse, slug: "Acme", name: "Acme"), Board(kind: .lever, slug: "beta", name: "Beta"),
        ]
        #expect(try await store.sources.add(catalog, origin: .catalog, at: now) == 2)
        let acme = try #require(try await store.sources.board(kind: .greenhouse, slug: "acme"))
        #expect(acme.slug == "acme")
        try await store.sources.setStatus(.removed, for: acme.id)

        #expect(try await store.sources.add(catalog, origin: .catalog, at: day(1)) == 0)
        #expect(try await store.sources.add(catalog[0], origin: .lead, at: day(1)) == nil)
        #expect(try await store.sources.board(kind: .greenhouse, slug: "acme")?.status == .removed)

        let back = try await store.sources.addByYou(
            Board(kind: .greenhouse, slug: "acme", name: "Acme Corp"), at: day(2))
        #expect(back.id == acme.id)
        #expect(back.status == .watching && back.origin == .you && back.name == "Acme Corp")
    }

    @Test func smartRecruitersSlugsKeepTheirCase() async throws {
        let store = try await emptyStore()
        try await store.sources.add(
            Board(kind: .smartRecruiters, slug: "BoschGroup", name: "Bosch"), origin: .you, at: now)
        #expect(try await store.sources.board(kind: .smartRecruiters, slug: "BoschGroup") != nil)
        #expect(try await store.sources.board(kind: .smartRecruiters, slug: "boschgroup") == nil)
    }

    @Test func eachSearchHasOneSource() async throws {
        let store = try await emptyStore()
        let first = try await store.sources.search(.googleJobs, at: now)
        let second = try await store.sources.search(.googleJobs, at: day(1))
        #expect(first.id == second.id)
        #expect(first.displayName == "Google Jobs")
        #expect(try await store.sources.all().count == 1)
    }

    @Test func aRestingSourceIsntDue() {
        var source = Source(kind: .lever, slug: "beta", origin: .catalog, addedAt: now)
        #expect(source.isDue(at: now))
        source.restUntil = day(3)
        #expect(!source.isDue(at: day(1)))
        #expect(source.isDue(at: day(3)))
        source.status = .muted
        #expect(!source.isDue(at: day(5)))
    }

    // MARK: - Jobs

    @Test func summariesCarryScreeningTheLatestBuildAndTheApplication() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let id = try #require(try await store.jobs.summaries().first?.id)
        try await store.screening.record(
            ScreeningState(
                stage: .judged, verdict: .yes, rule: VerdictRule.strongMatch.rawValue, match: 0.8, rank: 230.8,
                screenedAt: now),
            for: id)
        let older = BuildRecord(jobID: id, mode: .strict, resumeVersion: 1, status: .failed, createdAt: day(1))
        let newer = BuildRecord(jobID: id, mode: .lite, resumeVersion: 1, status: .done, score: 0.7, createdAt: day(2))
        try await store.builds.save(older)
        try await store.builds.save(newer)
        try await store.applications.apply(Application(jobID: id, buildID: newer.id, appliedAt: day(3)))

        let summary = try #require(try await store.jobs.summary(id))
        #expect(summary.verdict == .yes)
        #expect(summary.screening?.verdictRule == .strongMatch)
        #expect(summary.build == .init(id: newer.id, status: .done, score: 0.7))
        #expect(summary.application?.status == .applied)
        #expect(summary.placeLine == "Toronto, ON")
    }

    @Test func retentionArchivesThenSlimsJobsYouNeverActedOn() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record(
            [listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true,
            at: day(-130))
        let kept = try #require(try await store.jobs.summaries().first { $0.title == "Data Engineer" })
        try await store.jobs.setDecision(.saved, for: kept.id, at: day(-100))

        let result = try await store.jobs.applyRetention(at: now)
        #expect(result == .init(archived: 1, slimmed: 1))
        #expect(try await store.jobs.summaries().map(\.id) == [kept.id])
        let archived = try #require(try await store.jobs.summaries(.archived).first)
        #expect(try await store.jobs.job(archived.id)?.description == "")
        #expect(try await store.jobs.detail(archived.id)?.events.isEmpty == true)
        #expect(try await store.jobs.applyRetention(at: now) == .init())
    }

    // MARK: - Screening

    @Test func screeningFindsNewJobsAndKeepsYourVerdict() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record(
            [listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer")], from: acme, complete: true,
            at: now)
        let unscreened = try await store.screening.unscreened()
        #expect(unscreened.count == 2)
        let (first, second) = (unscreened[0].id, unscreened[1].id)

        try await store.screening.record([
            first: ScreeningState(stage: .waiting, screenedAt: now),
            second: ScreeningState(
                stage: .filtered, rule: PrefilterRule.titleInclude.rawValue, reasons: ["Not one of your roles"],
                screenedAt: now),
        ])
        #expect(try await store.screening.unscreened().isEmpty)
        #expect(try await store.screening.waiting().map(\.id) == [first])

        try await store.screening.setYourVerdict(.yes, for: first, at: now)
        try await store.screening.record(ScreeningState(stage: .judged, verdict: .no, screenedAt: day(1)), for: first)
        let state = try #require(try await store.screening.state(for: first))
        #expect(state.verdict == .no && state.yourVerdict == .yes && state.shownVerdict == .yes)

        #expect(try await store.screening.bringBack(second, at: day(1)))
        let back = try #require(try await store.screening.state(for: second))
        #expect(back.stage == .waiting && back.broughtBack && back.rule == nil)
        #expect(try await store.screening.bringBack(second, at: day(1)) == false)

        var counts = ScreeningRepository.Counts()
        counts.waiting = 1
        counts.yes = 1
        #expect(try await store.screening.counts() == counts)
    }

    @Test func analysesAreStoredWithTheirStateAndResetsKeepWhatYouDecided() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record(
            [
                listing("acme/jobs/1"), listing("acme/jobs/2", title: "Data Engineer"),
                listing("acme/jobs/3", title: "QA Engineer"),
            ],
            from: acme, complete: true, at: now)
        let ids = try await store.screening.unscreened().map(\.id)
        let analysis = JobAnalysis(
            requirements: [.init(text: "Go", kind: .must, category: .skill, match: .yes, evidence: ["s1"])],
            yearsRequired: 2, seniority: .mid, domains: ["logistics"],
            flags: .init(sponsorship: .notMentioned, french: .asset, remoteScope: .hybrid))
        for id in ids {
            try await store.screening.save(
                StoredAnalysis(analysis: analysis, model: "gemini-2.5-flash", promptVersion: 2, analyzedAt: now),
                state: ScreeningState(stage: .judged, verdict: .maybe, coverage: Coverage(analysis), screenedAt: now),
                for: id)
        }
        let stored = try #require(try await store.screening.analysis(for: ids[0]))
        #expect(stored.analysis == analysis)
        #expect(stored.promptVersion == 2)
        #expect(try await store.screening.analyses(for: ids).count == 3)

        try await store.screening.setYourVerdict(.yes, for: ids[0], at: now)
        try await store.jobs.setDecision(.skipped, for: ids[1], at: now)
        #expect(try await store.screening.candidates(everything: false).isEmpty)
        let everything = try await store.screening.candidates(everything: true)
        #expect(everything.map(\.job.id) == [ids[2]])
        #expect(everything.first?.state?.verdict == .maybe)
    }

    // MARK: - Master resume

    @Test func theMasterResumeRoundTripsAndEveryChangeBumpsItsVersion() async throws {
        let store = try await emptyStore()
        #expect(try await store.resume.load() == MasterResume())
        let version = try await store.resume.replace(with: Sample.resume, reason: "First import", at: now)
        #expect(version == 1)
        var loaded = try await store.resume.load()
        #expect(loaded.version == 1)
        loaded.version = Sample.resume.version
        #expect(loaded == Sample.resume)
        // Nothing to keep before the first import.
        #expect(try await store.resume.snapshots().isEmpty)

        var entry = try #require(Sample.resume.entries.first)
        entry.bullets.removeLast()
        entry.bullets.insert(ResumeBullet(id: Sample.id(99), text: "Led the on-call rotation."), at: 0)
        #expect(try await store.resume.saveEntry(entry, at: day(1)) == 2)
        let saved = try #require(try await store.resume.load().entry(entry.id))
        #expect(saved.bullets.map(\.id) == entry.bullets.map(\.id))

        let ids = Sample.resume.entries(.experience).map(\.id)
        try await store.resume.order(ids.reversed(), at: day(2))
        #expect(try await store.resume.load().entries(.experience).map(\.id) == ids.reversed())

        try await store.resume.deleteEntry(entry.id, at: day(3))
        #expect(
            try await store.count("resume_bullet")
                == Sample.resume.entries.dropFirst().reduce(0) { $0 + $1.bullets.count })
        #expect(try await store.resume.version() == 4)
    }

    @Test func aReplacedResumeCanBePutBack() async throws {
        let store = try await emptyStore()
        try await store.resume.replace(with: Sample.resume, reason: "First import", at: now)
        try await store.resume.replace(
            with: MasterResume(header: Sample.header), reason: "Before importing cv.pdf", at: day(1))
        #expect(try await store.resume.load().entries.isEmpty)
        let snapshot = try #require(try await store.resume.snapshots().first)
        #expect(snapshot.version == 1 && snapshot.reason == "Before importing cv.pdf")

        try await store.resume.restore(snapshot.id, at: day(2))
        let restored = try await store.resume.load()
        #expect(restored.entries == Sample.resume.entries)
        #expect(restored.skills == Sample.resume.skills)
        #expect(try await store.resume.snapshots().count == 2)
    }

    // MARK: - Builds and applications

    @Test func buildsRoundTripWithTheirFilesAndQueue() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let jobID = try #require(try await store.jobs.summaries().first?.id)

        let first = BuildRecord(jobID: jobID, mode: .strict, resumeVersion: 3, wantsLetter: true, createdAt: now)
        let second = BuildRecord(jobID: jobID, mode: .lite, resumeVersion: 3, createdAt: day(1))
        try await store.builds.save(second)
        try await store.builds.save(first)
        #expect(try await store.builds.nextQueued()?.id == first.id)
        #expect(try await store.builds.start(first.id, at: day(1)))
        #expect(try await store.builds.start(first.id, at: day(1)) == false)

        var done = try #require(try await store.builds.build(first.id))
        done.status = .done
        done.finishedAt = day(1).addingTimeInterval(40)
        done.resume = TailoredResume(header: .init(name: "Jordan Rivera"), summary: "Backend developer.")
        done.report = BuildNotes(fellBack: ["summary"], notes: ["gemini-2.5-flash timed out"])
        done.score = 0.82
        done.files = [.init(kind: .resume, path: "Library/Builds/a.pdf", sha256: "abc")]
        try await store.builds.save(done)
        let loaded = try #require(try await store.builds.build(first.id))
        #expect(loaded == done)
        #expect(loaded.seconds == 40)

        try await store.builds.stop(second.id, at: day(2))
        #expect(try await store.builds.nextQueued() == nil)
        #expect(try await store.builds.builds(for: jobID).map(\.id) == [second.id, first.id])

        try await store.applications.apply(Application(jobID: jobID, buildID: first.id, appliedAt: day(3)))
        #expect(try await store.builds.delete(first.id) == done.files)
        #expect(try await store.applications.application(forJob: jobID)?.buildID == nil)
    }

    @Test func runningBuildsGoBackInTheQueueAfterAQuit() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let jobID = try #require(try await store.jobs.summaries().first?.id)
        let build = BuildRecord(jobID: jobID, mode: .strict, resumeVersion: 1, createdAt: now)
        try await store.builds.save(build)
        _ = try await store.builds.start(build.id, at: now)
        #expect(try await store.builds.requeueInterrupted() == 1)
        #expect(try await store.builds.build(build.id)?.status == .queued)
    }

    @Test func applicationsKeepATimeline() async throws {
        let store = try await emptyStore()
        let acme = try await store.board("acme")
        _ = try await store.ledger.record([listing("acme/jobs/1")], from: acme, complete: true, at: now)
        let jobID = try #require(try await store.jobs.summaries().first?.id)

        let application = try await store.applications.apply(
            Application(jobID: jobID, appliedAt: now, channel: "Company site"))
        let again = try await store.applications.apply(Application(jobID: jobID, appliedAt: day(1)))
        #expect(again.id == application.id)

        var moved = application
        moved.status = .interview
        moved.nextStep = "Technical interview"
        try await store.applications.save(moved, note: "Booked for Tuesday", at: day(5))
        try await store.applications.save(moved, note: "Prepared the system design", at: day(6))

        let loaded = try #require(try await store.applications.application(application.id))
        #expect(loaded.status == .interview && loaded.statusAt == day(5) && loaded.updatedAt == day(6))
        let events = try await store.applications.events(of: application.id)
        #expect(events.map(\.kind) == ["applied", "interview", "note"])
        #expect(events.last?.note == "Prepared the system design")

        try await store.applications.delete(application.id)
        #expect(try await store.applications.all().isEmpty)
        #expect(try await store.count("application_event") == 0)
    }

    // MARK: - AI log and cache

    @Test func theCallLogCountsWhatReachedAProviderAndEachKeysDay() async throws {
        let store = try await emptyStore()
        let log = store.ai
        func call(_ outcome: AICall.Outcome, key: String = "main", at time: Date = now, limit: Int? = nil) -> AICall {
            AICall(
                at: time, task: .analyzeJob, provider: "gemini", keyName: key, model: "gemini-2.5-flash",
                promptVersion: 2,
                outcome: outcome, inputTokens: 100, outputTokens: 20, milliseconds: 900, dailyLimit: limit,
                backAt: outcome == .usedUp ? day(1) : nil)
        }
        await log.record(call(.ok))
        await log.record(call(.ok, key: "spare"))
        await log.record(call(.rateLimited))
        await log.record(call(.cached))
        await log.record(call(.usedUp, limit: 250))
        await log.record(call(.ok, at: day(-2)))

        let usage = await log.usage(since: day(-1))
        #expect(usage.calls == 3)
        #expect(usage.tokens == 360)

        let keys = try await log.keyUsage(provider: "gemini", since: day(-1))
        #expect(keys["main"]?["gemini-2.5-flash"] == KeyModelUse(calls: 1, limit: 250, refused: true, back: day(1)))
        #expect(keys["spare"]?["gemini-2.5-flash"]?.calls == 1)

        let today = try await log.today(since: day(-1))
        #expect(today.first?.answered == 2 && today.first?.failed == 1)

        await log.store("{\"a\":1}", task: .analyzeJob, inputHash: "h", promptVersion: 2, model: "m")
        #expect(await log.output(task: .analyzeJob, inputHash: "h", promptVersion: 2, model: "m") == "{\"a\":1}")
        #expect(await log.output(task: .analyzeJob, inputHash: "h", promptVersion: 3, model: "m") == nil)

        try await log.trim(olderThan: 1, at: now)
        #expect(await log.usage(since: day(-30)).calls == 3)
    }

    // MARK: - Activity

    @Test func runsAndTheFetchLogFeedBudgetsAndSources() async throws {
        let store = try await emptyStore()
        var run = try await store.activity.start(.fetch, at: now)
        run.stats.added = 4
        run.finishedAt = now.addingTimeInterval(30)
        try await store.activity.finish(run)
        #expect(try await store.activity.lastGoodRun(.fetch)?.stats.added == 4)

        _ = try await store.activity.start(.screen, at: now)
        #expect(try await store.activity.closeInterruptedRuns(at: day(1)) == 1)
        #expect(try await store.activity.lastRun(.screen)?.error != nil)

        let adzuna = try await store.sources.search(.adzuna, at: now)
        try await store.activity.log([
            FetchLogEntry(sourceID: adzuna.id, at: now, outcome: .ok, requests: 10, added: 2),
            FetchLogEntry(sourceID: adzuna.id, at: day(-3), outcome: .ok, requests: 5),
            FetchLogEntry(sourceID: adzuna.id, at: day(-20), outcome: .failed, requests: 1),
        ])
        let used = try await store.activity.requests(of: adzuna.id, at: now)
        #expect(used.today == 10)
        #expect(used.week == 15)
        #expect(used.month == 16)
        #expect(try await store.activity.lastReads()[adzuna.id]?.requests == 10)
        #expect(try await store.activity.added(since: day(-7))[adzuna.id] == 2)
    }

    @Test func leadsLookupsAndSearchTurnsAreRemembered() async throws {
        let store = try await emptyStore()
        let lead = Lead(
            id: "l1", company: "Maplepay", title: "Developer", location: "Toronto", postedAt: nil, firstSeenAt: now,
            lastSeenAt: now)
        #expect(try await store.activity.save([lead], at: now) == 1)
        #expect(try await store.activity.save([lead], at: day(1)) == 0)
        #expect(try await store.activity.leads(since: day(-1)).first?.lastSeenAt == day(1))

        try await store.activity.save([
            CompanyLookup(nameKey: "maplepay", board: Board(kind: .ashby, slug: "maplepay", name: ""), checkedAt: now),
            CompanyLookup(nameKey: "nowhere", board: nil, checkedAt: now),
        ])
        let lookups = try await store.activity.lookups(["maplepay", "nowhere", "unknown"])
        #expect(lookups["maplepay"]?.board?.kind == .ashby)
        #expect(lookups["nowhere"] != nil && lookups["nowhere"]?.board == nil)
        #expect(lookups["unknown"] == nil)

        try await store.activity.markSearched(["developer|toronto"], at: now)
        try await store.activity.markSearched(["developer|toronto"], at: day(1))
        #expect(try await store.activity.lastSearched() == ["developer|toronto": day(1)])

        try await store.activity.trim(olderThan: 90, at: day(100))
        #expect(try await store.activity.leads(since: .distantPast).isEmpty)
    }
}
