#if DEBUG
    import Foundation
    import MasterResume
    import Screening
    import Store

    /// `Kairos --screening-report`: why jobs end up where they do, printed from this Mac's database
    /// so a terminal (which macOS keeps out of the app's container) can see it. It prints your
    /// skills, titles, search settings, sources and each job's verdict with the rule behind it.
    /// Never contact details, keys or posting text. Debug builds only.
    enum DebugReport {
        static func runIfRequested() {
            guard CommandLine.arguments.contains("--screening-report") else { return }
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    print(try await report())
                } catch {
                    print("screening-report: \(error)")
                }
                done.signal()
            }
            done.wait()
            exit(0)
        }

        private static func report() async throws -> String {
            let db = try Database(path: try AccountStore.applicationSupport().databaseURL(for: .local).path)
            var out = "# Kairos screening report (no contact details, no keys)\n"

            let resume = try await MasterResumeRepository(db).load()
            out += "\n## Master resume (version \(resume.version))\n"
            out += "Headline: \(resume.header.headline)\n"
            out += "Total years: \(resume.header.totalYears.map { $0.formatted() } ?? "not set")\n"
            for entry in resume.entries {
                switch entry.fields {
                case .experience(let role):
                    out +=
                        "Experience: \(role.title) · \(role.employer) · \(entry.start.map { "\($0.year)" } ?? "?")–"
                        + "\(entry.isCurrent ? "now" : entry.end.map { "\($0.year)" } ?? "?") · \(entry.bullets.count) bullets\n"
                case .project(let project):
                    out += "Project: \(project.name) · \(project.tech.joined(separator: ", "))\n"
                case .education(let school):
                    out += "Education: \(school.credential) \(school.field) · \(school.institution)\n"
                case .language(let language):
                    out += "Language: \(language.language) (\(language.proficiency.rawValue))\n"
                default:
                    continue
                }
            }
            for level in SkillLevel.allCases {
                let names = resume.skills.filter { $0.level == level }.map(\.name)
                out += "Skills, \(level.rawValue) (\(names.count)): \(names.joined(separator: ", "))\n"
            }

            let preferences =
                try await SettingsRepository(db).value(SearchPreferences.storageKey, as: SearchPreferences.self)
                ?? SearchPreferences()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            out += "\n## Search settings\n"
            out += String(decoding: try encoder.encode(preferences), as: UTF8.self) + "\n"
            let profile =
                try await PrivateSettingsRepository(db).value(WorkProfile.storageKey, as: WorkProfile.self)
                ?? WorkProfile()
            out +=
                "Work profile: "
                + profile.authorization.map { "\($0.key.rawValue): \($0.value.rawValue)" }.sorted().joined(
                    separator: ", ")
                + " · clearance: \(profile.hasClearance)\n"

            out += "\n## Sources\n"
            for source in try await SourceRepository(db).sources() {
                out +=
                    "\(source.kind.rawValue) · \(source.config) · \(source.enabled ? "on" : "off") · \(source.health.rawValue)\n"
            }

            let jobs = try await JobRepository(db).jobs()
            let screenings = try await ScreeningRepository(db).latestByJob()
            out += "\n## Jobs: \(jobs.count)\n"
            let byCountry = Dictionary(grouping: jobs) { $0.country?.rawValue ?? "unknown" }
            out +=
                "By country: " + byCountry.map { "\($0.key) \($0.value.count)" }.sorted().joined(separator: ", ") + "\n"
            let byCompany = Dictionary(grouping: jobs, by: \.company).mapValues(\.count).sorted { $0.value > $1.value }
            out += "By company: " + byCompany.prefix(30).map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"

            var groups: [String: [(Job, ScreeningRecord)]] = [:]
            var unscreened = 0
            for job in jobs {
                guard let record = screenings[job.id.rawValue] else {
                    unscreened += 1
                    continue
                }
                groups["\(record.stage.rawValue) · \(record.verdict.rawValue) · \(record.ruleID ?? "you")", default: []]
                    .append((job, record))
            }
            out += "Not screened yet: \(unscreened)\n"
            out += "\n## Verdicts by stage and rule\n"
            for (group, members) in groups.sorted(by: { $0.value.count > $1.value.count }) {
                out += "\n### \(group): \(members.count)\n"
                for (job, record) in members.prefix(8) {
                    out +=
                        "- \(job.title) · \(job.company) · \(job.location) [\(job.country?.rawValue ?? "?"), "
                        + "\(job.remoteScope.rawValue)] — \(record.reasons.first ?? "")\n"
                }
            }
            return out
        }
    }
#endif
