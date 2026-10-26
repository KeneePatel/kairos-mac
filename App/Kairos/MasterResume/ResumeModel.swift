import Foundation
import MasterResume
import OSLog
import Observation
import Render
import Store
import Tailoring

/// The master resume as the editor sees it. Each edit is one repository operation (one version
/// bump), after which the resume is reloaded so ids, order and the version are the stored ones.
@MainActor
@Observable
final class ResumeModel {
    private(set) var resume = MasterResume()
    private(set) var saveError: String?

    @ObservationIgnored private let repository: MasterResumeRepository
    @ObservationIgnored private let log = Logger(subsystem: "com.keneepatel.kairos", category: "resume")

    init(db: Database) {
        repository = MasterResumeRepository(db)
    }

    #if DEBUG
        /// For previews and snapshots: shows `resume` without reading the database.
        init(preview resume: MasterResume, db: Database) {
            repository = MasterResumeRepository(db)
            self.resume = resume
        }
    #endif

    var readiness: BuildReadiness {
        Validator.readiness(resume, now: YearMonth.containing(Date()))
    }

    func load() async {
        do {
            resume = try await repository.load()
        } catch {
            log.error("Loading the master resume failed: \(String(describing: error), privacy: .public)")
            saveError = "Kairos couldn't read your master resume."
        }
    }

    /// Cleans the header and saves it. Malformed fields are saved as typed, so nothing is lost;
    /// the editor shows what to fix.
    func saveHeader(_ header: ResumeHeader) async {
        let cleaned = Validator.validate(header).header
        guard cleaned != resume.header else { return }
        await perform { try await $0.saveHeader(cleaned) }
    }

    func save(_ entry: ResumeEntry) async {
        await perform { try await $0.save([entry]) }
    }

    func deleteEntry(_ id: UUID) async {
        await perform { try await $0.deleteEntry(id) }
    }

    /// Moves an entry one place up or down within its kind.
    func move(_ entry: ResumeEntry, by offset: Int) async {
        var ids = resume.entries(entry.kind).map(\.id)
        guard let index = ids.firstIndex(of: entry.id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        let order = ids
        await perform { try await $0.reorderEntries(order) }
    }

    /// What you kept from an import: entries in one save, skills in another, and the header text only
    /// where the field is still empty (an import never overwrites what you wrote).
    func addImport(entries: [ResumeEntry], skills: [Skill], headline: String?, highlights: String?, totalYears: Double?)
        async
    {
        if !entries.isEmpty { await perform { try await $0.save(entries) } }
        let known = Set(resume.skills.map { $0.name.lowercased() })
        let fresh = skills.filter { !known.contains($0.name.lowercased()) }
        if !fresh.isEmpty { await perform { try await $0.save(fresh) } }
        var header = resume.header
        if header.headline.isEmpty, let headline { header.headline = headline }
        if header.highlights.isEmpty, let highlights { header.highlights = highlights }
        if header.totalYears == nil, let totalYears { header.totalYears = totalYears }
        if header != resume.header {
            let updated = header
            await perform { try await $0.saveHeader(updated) }
        }
    }

    func save(_ skill: Skill) async {
        let name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var cleaned = skill
        cleaned.name = name
        let saved = cleaned
        await perform { try await $0.save([saved]) }
    }

    func deleteSkill(_ id: UUID) async {
        await perform { try await $0.deleteSkill(id) }
    }

    /// Drag and drop: puts `id` just before `target` (or last), switching its level if it was
    /// dropped into the other group.
    func moveSkill(_ id: UUID, before target: UUID?, level: SkillLevel) async {
        guard var skill = resume.skills.first(where: { $0.id == id }), id != target else { return }
        var ids = resume.skills.map(\.id).filter { $0 != id }
        let insertAt = target.flatMap { ids.firstIndex(of: $0) } ?? ids.endIndex
        ids.insert(id, at: insertAt)
        if skill.level != level {
            skill.level = level
            let changed = skill
            await perform { try await $0.save([changed]) }
        }
        let order = ids
        await perform { try await $0.reorderSkills(order) }
    }

    /// Your whole master resume as one PDF with no page budget (SPEC §5.10, Export), rendered with
    /// the typst in the app bundle: every entry and bullet, Proven and Can-discuss skills, and
    /// every other section, laid out as a build is.
    func exportPDF() async throws -> Data {
        guard let typst = Bundle.main.url(forAuxiliaryExecutable: "typst") else {
            throw RenderError.launch("typst isn't in the app bundle")
        }
        let renderer = ResumeRenderer(runner: TypstRunner(executable: typst))
        return try await renderer.render(ResumeDocument(FullResume(resume))).data
    }

    private func perform(_ change: @Sendable (MasterResumeRepository) async throws -> Int) async {
        do {
            _ = try await change(repository)
            resume = try await repository.load()
            saveError = nil
        } catch {
            log.error("Saving the master resume failed: \(String(describing: error), privacy: .public)")
            saveError = "Couldn't save that change. Try again."
        }
    }
}
