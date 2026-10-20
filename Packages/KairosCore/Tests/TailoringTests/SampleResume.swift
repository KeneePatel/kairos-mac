import Foundation
import MasterResume

/// The design's sample persona, as a master resume (fixtures only). Bullet ids are fixed so tests
/// can cite them.
enum Sample {
    static let pipeline = ResumeBullet(
        id: id(1), text: "Built an event pipeline in Go handling 4.2M events a day with p99 under 120 ms.",
        metrics: ["4.2M events a day", "p99 under 120 ms"], skills: ["Go", "Kafka"])
    static let carriers = ResumeBullet(
        id: id(2), text: "Onboarded 11 carriers in 4 days instead of 3 weeks by designing a gRPC integration kit.",
        skills: ["gRPC"])
    static let kubernetes = ResumeBullet(
        id: id(3),
        text: "Migrated 14 services to Kubernetes with a shared Helm chart; deploys dropped from 25 to 6 minutes.",
        skills: ["Kubernetes", "Helm"])
    static let onCall = ResumeBullet(
        id: id(4), text: "Led the five-person on-call rotation and cut repeat incidents by 40% over two quarters.")
    static let apis = ResumeBullet(
        id: id(5), text: "Shipped REST APIs in Django and PostgreSQL for 30+ client projects.",
        skills: ["Django", "PostgreSQL"])
    static let ci = ResumeBullet(
        id: id(6), text: "Introduced GitHub Actions CI, cutting release prep from a day to an hour.")
    static let reconciliation = ResumeBullet(
        id: id(7), text: "Wrote reconciliation jobs in Java that matched 2M card transactions nightly.",
        skills: ["Java"])
    static let dockyard = ResumeBullet(
        id: id(8), text: "Finds and removes dangling Docker images and volumes; 400+ stars.", skills: ["Docker"])
    static let ledger = ResumeBullet(id: id(9), text: "A budgeting app in SwiftUI with an SQLite store.")

    static let harbourline = ResumeEntry(
        id: id(101),
        fields: .experience(
            .init(employer: "Harbourline Logistics", title: "Software Developer, Backend", location: "Toronto, ON")),
        start: YearMonth(year: 2022, month: 3), isCurrent: true, bullets: [pipeline, carriers, kubernetes, onCall])
    static let rivet = ResumeEntry(
        id: id(102),
        fields: .experience(.init(employer: "Rivet Studio", title: "Junior Developer", location: "Toronto, ON")),
        start: YearMonth(year: 2020, month: 6), end: YearMonth(year: 2022, month: 2), bullets: [apis, ci])
    static let maplepay = ResumeEntry(
        id: id(103),
        fields: .experience(.init(employer: "Maplepay", title: "Developer Intern", location: "Waterloo, ON")),
        start: YearMonth(year: 2019, month: 5), end: YearMonth(year: 2019, month: 8), bullets: [reconciliation])
    static let dockyardProject = ResumeEntry(
        id: id(104), fields: .project(.init(name: "Dockyard", tech: ["Go", "Docker"])),
        start: YearMonth(year: 2023, month: 1), isCurrent: true, bullets: [dockyard])
    static let ledgerProject = ResumeEntry(
        id: id(105), fields: .project(.init(name: "Ledger", tech: ["Swift", "SQLite"])),
        start: YearMonth(year: 2021, month: 1), end: YearMonth(year: 2021, month: 6), bullets: [ledger])
    static let degree = ResumeEntry(
        id: id(106),
        fields: .education(
            .init(institution: "University of Waterloo", credential: "BMath", field: "Computer Science")),
        start: YearMonth(year: 2015, month: 9), end: YearMonth(year: 2019, month: 4))
    static let certificate = ResumeEntry(
        id: id(107), fields: .certification(.init(name: "AWS Solutions Architect – Associate", issuer: "AWS")))

    static let resume: MasterResume = {
        var header = ResumeHeader()
        header.fullName = "Jordan Rivera"
        header.totalYears = 5
        let proven = ["Go", "Java", "Python", "PostgreSQL", "Kafka", "Kubernetes", "Docker", "gRPC", "Django", "Helm"]
        return MasterResume(
            header: header,
            entries: [harbourline, rivet, maplepay, dockyardProject, ledgerProject, degree, certificate],
            skills: proven.map { Skill(name: $0) } + [
                Skill(name: "Terraform", level: .canDiscuss), Skill(name: "Rust", level: .canDiscuss),
            ], version: 7)
    }()

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", n))!
    }
}
