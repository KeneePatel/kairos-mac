import Foundation
import Resume

/// Jordan Rivera, the design's sample person: a master resume for tests and previews only.
public enum Sample {
    /// A fixed id, so tests can cite bullets: `Sample.id(1)` is "00000000-0000-7000-8000-000000000001".
    public static func id(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", number)) ?? UUID()
    }

    public static let header: ResumeHeader = {
        var header = ResumeHeader()
        header.fullName = "Jordan Rivera"
        header.email = "jordan.rivera@example.com"
        header.phone = "+14165550123"
        header.linkedInURL = "https://www.linkedin.com/in/jordan-rivera"
        header.gitHubURL = "https://github.com/jrivera"
        header.city = "Toronto"
        header.region = "ON"
        header.country = "CA"
        header.headline = "Backend developer who ships reliable services"
        header.highlights = "Five years building event-driven services in Go and Python for logistics and fintech."
        header.totalYears = 5
        return header
    }()

    public static let resume = MasterResume(
        header: header,
        entries: [
            ResumeEntry(
                id: id(1),
                fields: .experience(
                    .init(employer: "Harbourline Logistics", title: "Software Developer, Backend", location: "Toronto, ON")),
                start: YearMonth("2022-03"), isCurrent: true,
                bullets: [
                    ResumeBullet(
                        id: id(11), text: "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.",
                        metrics: ["4.2M events a day"], skills: ["Go", "Kafka"]),
                    ResumeBullet(
                        id: id(12), text: "Onboarded 11 carriers in 4 days instead of 3 weeks by designing a gRPC integration kit.",
                        skills: ["gRPC"]),
                    ResumeBullet(
                        id: id(13), text: "Moved 40 services to Kubernetes with zero-downtime deploys and PostgreSQL failover.",
                        metrics: ["40 services"], skills: ["Kubernetes", "PostgreSQL"]),
                ]),
            ResumeEntry(
                id: id(2),
                fields: .experience(.init(employer: "Maplepay", title: "Junior Developer", location: "Waterloo, ON")),
                start: YearMonth("2020-06"), end: YearMonth("2022-02"),
                bullets: [
                    ResumeBullet(
                        id: id(21), text: "Wrote the Python reconciliation job that matched 98% of payouts without review.",
                        metrics: ["98%"], skills: ["Python", "PostgreSQL"]),
                    ResumeBullet(id: id(22), text: "Added contract tests to 6 payment APIs, catching 3 breaking changes before release.",
                        metrics: ["6 payment APIs", "3 breaking changes"], skills: ["Python"]),
                ]),
            ResumeEntry(
                id: id(3), fields: .project(.init(name: "Ledger", role: "Creator", tech: ["Swift", "SQLite"], repoURL: "https://github.com/jrivera/ledger")),
                start: YearMonth("2023-01"), end: YearMonth("2023-06"),
                bullets: [
                    ResumeBullet(id: id(31), text: "Built a budgeting app in Swift with an SQLite store and 200 unit tests.",
                        metrics: ["200 unit tests"], skills: ["Swift", "SQLite"])
                ]),
            ResumeEntry(
                id: id(4),
                fields: .education(
                    .init(institution: "University of Waterloo", credential: "BMath", field: "Computer Science", location: "Waterloo, ON",
                        honours: "Dean's List")),
                start: YearMonth("2016-09"), end: YearMonth("2020-04")),
            ResumeEntry(
                id: id(5), fields: .certification(.init(name: "AWS Certified Solutions Architect – Associate", issuer: "Amazon Web Services")),
                start: YearMonth("2023-09")),
            ResumeEntry(id: id(6), fields: .language(.init(language: "English", proficiency: .native))),
            ResumeEntry(id: id(7), fields: .language(.init(language: "French", proficiency: .conversational))),
        ],
        skills: [
            Skill(id: id(101), name: "Go", category: "Language"),
            Skill(id: id(102), name: "Python", category: "Language"),
            Skill(id: id(103), name: "PostgreSQL", category: "Database"),
            Skill(id: id(104), name: "Kafka", category: "Tool"),
            Skill(id: id(105), name: "Kubernetes", category: "Cloud"),
            Skill(id: id(106), name: "gRPC", category: "Framework"),
            Skill(id: id(107), name: "Swift", category: "Language"),
            Skill(id: id(108), name: "Terraform", category: "Cloud", level: .canDiscuss),
            Skill(id: id(109), name: "Rust", category: "Language", level: .canDiscuss),
        ],
        version: 12)
}
