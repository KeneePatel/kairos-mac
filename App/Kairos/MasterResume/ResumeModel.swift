import Foundation
import MasterResume
import OSLog
import Observation
import Store

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
