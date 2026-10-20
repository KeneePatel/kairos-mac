import Foundation
import MasterResume
import Testing

@testable import Tailoring

private let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09

/// The T28 sample posting's requirements.
private let backend = JobRequirements(
    musts: [
        "3+ years building services in Go or Java", "Postgres in production",
        "Experience with message queues such as RabbitMQ or Kafka",
    ], nices: ["Kubernetes", "gRPC"], domains: ["logistics"])

@Suite("Entry selection")
struct SelectorTests {
    @Test func bulletsThatMeetRequirementsRankFirst() {
        let selection = Selector(now: now).select(from: Sample.resume, for: backend)
        let harbourline = selection.experience[0]
        #expect(harbourline.entry.id == Sample.harbourline.id)
        // Go and Kafka (two must-haves) and metrics beat Kubernetes and gRPC (nice-to-haves).
        #expect(
            harbourline.bullets.map(\.bullet.id) == [
                Sample.pipeline.id, Sample.kubernetes.id, Sample.carriers.id, Sample.onCall.id,
            ])
        #expect(harbourline.bullets[0].matched == ["go", "kafka"])
        // "Postgres" in the posting is PostgreSQL in the resume.
        #expect(selection.experience[1].bullets.first?.bullet.id == Sample.apis.id)
        #expect(selection.experience[1].bullets.first?.matched == ["postgresql"])
    }

    @Test func recentRolesKeepMoreBullets() {
        let selection = Selector(maxBulletsPerRole: [3, 2, 1], now: now).select(from: Sample.resume, for: backend)
        #expect(selection.experience.map(\.entry.id) == [Sample.harbourline.id, Sample.rivet.id, Sample.maplepay.id])
        #expect(selection.experience.map(\.bullets.count) == [3, 2, 1])
        // A role with nothing relevant still shows its first bullet, so the history has no hole.
        #expect(selection.experience[2].bullets.first?.bullet.id == Sample.reconciliation.id)
    }

    @Test func projectsAreChosenByRelevance() {
        let selection = Selector(maxProjects: 1, now: now).select(from: Sample.resume, for: backend)
        #expect(selection.projects.map(\.entry.id) == [Sample.dockyardProject.id])  // Go and Docker, not Swift
        let ios = JobRequirements(musts: ["Swift and SwiftUI"], nices: ["SQLite"], domains: [])
        let mobile = Selector(maxProjects: 1, now: now).select(from: Sample.resume, for: ios)
        #expect(mobile.projects.map(\.entry.id) == [Sample.ledgerProject.id])
    }

    /// Resumes claim only Proven skills (design rule 8); the ones the posting asks for come first.
    @Test func matchingProvenSkillsComeFirst() {
        let selection = Selector(now: now).select(from: Sample.resume, for: backend)
        #expect(Array(selection.skills.map(\.name).prefix(5)) == ["Go", "Java", "PostgreSQL", "Kafka", "Kubernetes"])
        #expect(!selection.skills.contains { $0.level == .canDiscuss })
        #expect(selection.skills.count == 10)
    }

    @Test func termsAreFoundThroughSynonymsAndConcepts() {
        let terms = Keywords.terms(in: "Postgres, k8s and message queues on AWS; go live with React")
        #expect(terms.contains("postgresql") && terms.contains("kubernetes") && terms.contains("aws"))
        #expect(terms.contains("kafka") && terms.contains("rabbitmq"))  // "message queues", a concept
        #expect(terms.contains("react") && !terms.contains("go"))  // "go live" isn't Go
        #expect(Keywords.technologies(in: "Built it in Go and Rust on k8s").sorted() == ["go", "kubernetes", "rust"])
        #expect(Keywords.technologies(in: "Message queues at scale").isEmpty)  // concepts aren't claims
    }
}
