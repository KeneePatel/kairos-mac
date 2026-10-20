import Foundation
import MasterResume
import Testing

@testable import Tailoring

private func bullet(_ text: String, _ sources: [ResumeBullet], gap: Bool = false) -> TailoredBullet {
    TailoredBullet(text: text, sourceIDs: sources.map(\.id), gap: gap)
}

private func rules(_ violations: [Violation]) -> [VerificationRule] { violations.map(\.rule) }

/// SPEC §5.3: strict mode, and the hard limits that hold in every mode.
@Suite("Strict verifier")
struct VerifierTests {
    let strict = Verifier(
        resume: Sample.resume, mode: .strict, hiringCompany: "Northline Freight", companyProducts: ["FreightOS"])

    @Test func aBulletGroundedInItsSourcesPasses() {
        let grounded = [
            bullet("Built a Go event pipeline handling 4.2M events a day at p99 under 120 ms.", [Sample.pipeline]),
            bullet(
                "Cut carrier onboarding from 3 weeks to 4 days with a gRPC integration kit for 11 carriers.",
                [Sample.carriers]),
            bullet(
                "Helped the team go live with a shared Helm chart for 14 services on Kubernetes.", [Sample.kubernetes]),
            // Python is a Proven skill, so a bullet may name it even if its source doesn't.
            bullet(
                "Built Kafka and Python tooling behind an event pipeline handling 4.2M events a day.", [Sample.pipeline]
            ),
            bullet("Shipped REST APIs in Django and PostgreSQL for 30+ client projects.", [Sample.apis]),
        ]
        for tailored in grounded {
            #expect(strict.check(tailored).isEmpty, "\(tailored.text): \(strict.check(tailored))")
        }
    }

    @Test func everyBulletCitesRealSources() {
        #expect(rules(strict.check(bullet("Built an event pipeline in Go.", []))) == [.missingSource])
        let unknown = TailoredBullet(text: "Built an event pipeline in Go.", sourceIDs: [UUID()])
        #expect(rules(strict.check(unknown)) == [.unknownSource])
        #expect(
            rules(strict.check(bullet("Built an event pipeline in Go.", [Sample.pipeline], gap: true))) == [
                .gapNotAllowed
            ])
    }

    /// Only technologies in the cited bullets or your Proven skills. Can-discuss ones and a
    /// certification's subject aren't enough.
    @Test func technologiesComeFromSourcesOrProvenSkills() {
        let rust = strict.check(
            bullet("Built an event pipeline in Rust handling 4.2M events a day.", [Sample.pipeline]))
        #expect(rules(rust) == [.unsupportedTechnology] && rust.first?.detail.contains("Rust") == true)
        #expect(
            rules(strict.check(bullet("Ran the Go event pipeline on AWS Lambda.", [Sample.pipeline]))) == [
                .unsupportedTechnology, .unsupportedTechnology,
            ])
        #expect(
            rules(strict.check(bullet("Managed Terraform for 14 services.", [Sample.kubernetes]))) == [
                .unsupportedTechnology
            ])
    }

    @Test func numbersComeFromTheCitedBullets() {
        #expect(
            rules(strict.check(bullet("Cut repeat incidents by 60% over two quarters.", [Sample.onCall]))) == [
                .unsupportedNumber
            ])
        #expect(
            rules(strict.check(bullet("Onboarded 12 carriers with a gRPC integration kit.", [Sample.carriers]))) == [
                .unsupportedNumber
            ])
        // "4.2 million" is the source's "4.2M".
        #expect(rules(strict.check(bullet("Handled 4.2 million events a day in Go.", [Sample.pipeline]))).isEmpty)
        #expect(strict.check(bullet("Kept p99 under 120 ms for the Go event pipeline.", [Sample.pipeline])).isEmpty)
    }

    @Test func yearsCanNotExceedYourTotal() {
        #expect(rules(strict.check(text: "Backend developer with 8 years of experience in Go.")) == [.yearsOverstated])
        #expect(strict.check(text: "Backend developer with 5 years of experience in Go and PostgreSQL.").isEmpty)
        #expect(rules(strict.check(text: "Backend developer with 5 years in Go and Rust.")) == [.unsupportedTechnology])
    }

    /// Employers, titles and dates must match a master-resume experience exactly.
    @Test func experienceHeadersMatchExactly() {
        #expect(
            strict.check(
                employer: "Harbourline Logistics", title: "Software Developer, Backend",
                start: YearMonth(year: 2022, month: 3), end: nil
            ).isEmpty)
        #expect(
            rules(
                strict.check(
                    employer: "Harbourline Logistics", title: "Senior Software Developer",
                    start: YearMonth(year: 2022, month: 3), end: nil)) == [.employerOrTitle])
        #expect(
            rules(
                strict.check(
                    employer: "Rivet Studio", title: "Junior Developer", start: YearMonth(year: 2019, month: 6),
                    end: YearMonth(year: 2022, month: 2))) == [.dates])
        #expect(
            rules(strict.check(employer: "Shopify", title: "Junior Developer", start: nil, end: nil)) == [
                .employerOrTitle
            ])
    }

    @Test func credentialsMustBeYours() {
        #expect(strict.check(credential: "BMath, Computer Science").isEmpty)
        #expect(strict.check(credential: "AWS Solutions Architect – Associate").isEmpty)
        #expect(rules(strict.check(credential: "MSc, Computer Science")) == [.credential])
        #expect(rules(strict.check(credential: "AWS Solutions Architect – Professional")) == [.credential])
    }

    @Test func personalFieldsNeverAppear() {
        #expect(rules(strict.check(text: "Date of birth: March 1997.")) == [.personalField])
        #expect(rules(strict.check(text: "Married, SIN 123 456 789.")).allSatisfy { $0 == .personalField })
        #expect(strict.check(text: "Built a single-page app in React.").filter { $0.rule == .personalField }.isEmpty)
    }

    /// The hiring company's own products, unless your master resume already names them.
    @Test func theHiringCompanysProductsStayOut() {
        #expect(
            rules(strict.check(bullet("Integrated 11 carriers with FreightOS through a gRPC kit.", [Sample.carriers])))
                == [.hiringCompanyProduct])
        #expect(
            rules(strict.check(bullet("Built a gRPC kit for Northline Freight's 11 carriers.", [Sample.carriers]))) == [
                .hiringCompanyProduct
            ])
    }

    /// Stretch mode (T37 completes it): a gap bullet needs no source and may use a Can-discuss
    /// skill, but the hard limits still hold.
    @Test func stretchAllowsGapBulletsWithinTheHardLimits() {
        let stretch = Verifier(resume: Sample.resume, mode: .stretch)
        #expect(
            stretch.check(
                TailoredBullet(text: "Wrote Terraform modules for the event pipeline.", sourceIDs: [], gap: true)
            ).isEmpty)
        #expect(
            rules(stretch.check(TailoredBullet(text: "Wrote Elixir services.", sourceIDs: [], gap: true))) == [
                .unsupportedTechnology
            ])
        #expect(
            rules(stretch.check(TailoredBullet(text: "Date of birth: 1997.", sourceIDs: [], gap: true))) == [
                .personalField
            ])
    }

    /// A photo of you is out; a photo-sharing app you built isn't.
    @Test func onlyAPhotoOfYouIsAPersonalField() {
        #expect(rules(strict.check(text: "Headshot attached.")) == [.personalField])
        #expect(strict.check(text: "Built a photo-sharing app.").isEmpty)
    }
}
