import Foundation
import Resume
import Testing

@testable import Tailoring

/// One fixture job (see `Fixtures/tailoring/README.md`).
private struct Fixture: Decodable {
    struct Resume: Decodable {
        struct SkillRow: Decodable {
            let name: String
            let level: SkillLevel
        }

        struct Bullet: Decodable {
            let id: String
            let text: String
            let metrics: [String]
            let skills: [String]
        }

        struct Experience: Decodable {
            let employer: String
            let title: String
            let start: String?
            let end: String?
            let bullets: [Bullet]
        }

        struct Education: Decodable {
            let institution: String
            let credential: String
            let field: String
        }

        let totalYears: Double
        let skills: [SkillRow]
        let experience: [Experience]
        let education: [Education]
        let certifications: [String]
    }

    struct Case: Decodable {
        let text: String
        let sources: [String]
        let gap: Bool?
        let expect: [String]
    }

    let job: String
    let mode: String
    let hiringCompany: String?
    let companyProducts: [String]
    let resume: Resume
    let bullets: [Case]
}

/// The verifier suite: every fixture bullet breaks exactly the rules it expects.
@Suite("Verifier suite")
struct VerifierSuite {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/tailoring")

    @Test func everyFixtureBulletBreaksExactlyTheRulesItExpects() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path()).filter {
            $0.hasSuffix(".json")
        }
        .sorted()
        #expect(files.count >= 3, "the suite needs its fixture jobs")
        var checked = 0
        for file in files {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: Self.folder.appending(path: file)))
            var ids: [String: UUID] = [:]
            func id(_ name: String) -> UUID {
                if let known = ids[name] { return known }
                let fresh = UUID()
                ids[name] = fresh
                return fresh
            }
            var header = ResumeHeader()
            header.totalYears = fixture.resume.totalYears
            var entries = fixture.resume.experience.map { role in
                ResumeEntry(
                    fields: .experience(.init(employer: role.employer, title: role.title)),
                    start: role.start.flatMap(YearMonth.init), end: role.end.flatMap(YearMonth.init),
                    isCurrent: role.end == nil,
                    bullets: role.bullets.map {
                        ResumeBullet(id: id($0.id), text: $0.text, metrics: $0.metrics, skills: $0.skills)
                    })
            }
            entries += fixture.resume.education.map {
                ResumeEntry(
                    fields: .education(.init(institution: $0.institution, credential: $0.credential, field: $0.field)))
            }
            entries += fixture.resume.certifications.map { ResumeEntry(fields: .certification(.init(name: $0))) }
            let resume = MasterResume(
                header: header, entries: entries,
                skills: fixture.resume.skills.map { Skill(name: $0.name, level: $0.level) })
            let verifier = Verifier(
                resume: resume, mode: fixture.mode == "stretch" ? .stretch : .strict,
                hiringCompany: fixture.hiringCompany, companyProducts: fixture.companyProducts)
            // A source that names no bullet stands for an id the master resume doesn't have.
            let known = Set(fixture.resume.experience.flatMap(\.bullets).map(\.id))
            for item in fixture.bullets {
                let sources = item.sources.map { known.contains($0) ? id($0) : UUID() }
                let found = verifier.check(TailoredBullet(text: item.text, sourceIDs: sources, gap: item.gap ?? false))
                #expect(
                    Set(found.map(\.rule.rawValue)) == Set(item.expect),
                    "\(file) · \(fixture.job)\n  “\(item.text)”\n  expected \(item.expect), got \(found.map { "\($0.rule.rawValue): \($0.detail)" })"
                )
                checked += 1
            }
        }
        #expect(checked >= 15)
    }

    /// S9's stretch half: no gap bullet breaking a hard limit gets through, and every gap bullet
    /// that passes is stored flagged (`verified: false`).
    @Test func stretchModeLetsNoHardLimitThroughAndFlagsEveryGapBullet() throws {
        let hardLimits: Set<VerificationRule> = [
            .yearsOverstated, .employerOrTitle, .dates, .credential, .hiringCompanyProduct, .personalField,
        ]
        var gaps = 0
        var limitCases = 0
        for file in try FileManager.default.contentsOfDirectory(atPath: Self.folder.path())
        where file.hasSuffix(".json") {
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: Self.folder.appending(path: file)))
            guard fixture.mode == "stretch" else { continue }
            var header = ResumeHeader()
            header.totalYears = fixture.resume.totalYears
            let resume = MasterResume(
                header: header,
                entries: fixture.resume.education.map {
                    ResumeEntry(
                        fields: .education(
                            .init(institution: $0.institution, credential: $0.credential, field: $0.field)))
                },
                skills: fixture.resume.skills.map { Skill(name: $0.name, level: $0.level) })
            let verifier = Verifier(
                resume: resume, mode: .stretch, hiringCompany: fixture.hiringCompany,
                companyProducts: fixture.companyProducts)
            for item in fixture.bullets where item.gap == true {
                gaps += 1
                let bullet = TailoredBullet(text: item.text, sourceIDs: [], gap: true)
                let found = Set(verifier.check(bullet).map(\.rule))
                let expected = Set(item.expect.compactMap(VerificationRule.init(rawValue:)))
                if !expected.isDisjoint(with: hardLimits) {
                    limitCases += 1
                    #expect(!found.isDisjoint(with: hardLimits), "\(file): a hard limit got through: “\(item.text)”")
                }
                if found.isEmpty {
                    let stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bullet)) as? [String: Any]
                    #expect(stored?["verified"] as? Bool == false, "\(file): “\(item.text)” isn't flagged")
                }
            }
        }
        #expect(gaps >= 10 && limitCases >= 6)
    }
}
