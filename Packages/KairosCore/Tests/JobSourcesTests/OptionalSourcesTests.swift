import Foundation
import Store
import TestSupport
import Testing

@testable import JobSources

private let sourceID = UUID(uuidString: "0199f0a0-0000-7000-8000-0000000000ef")!
private let now = Date(timeIntervalSince1970: 1_792_756_800)

private func himalayasURL(_ q: String, page: Int) -> String {
    "https://himalayas.app/jobs/api/search?q=\(q.replacing(" ", with: "%20"))&country=CA&sort=recent&page=\(page)"
}

/// Himalayas's answer, in the shape its API page documents (companies made up).
private func himalayas(_ jobs: [(guid: String, title: String, posted: Double, expiry: Double?, places: [String])])
    -> Data
{
    let items = jobs.map { job in
        let places = job.places.map { "\"\($0)\"" }.joined(separator: ",")
        let expiry = job.expiry.map { String($0) } ?? "null"
        return
            #"{"title":"\#(job.title)","companyName":"Acme Robotics","guid":"\#(job.guid)","applicationLink":"https://boards.greenhouse.io/acme/jobs/1","description":"<p>Build the fleet API.</p>","pubDate":\#(job.posted),"expiryDate":\#(expiry),"locationRestrictions":[\#(places)]}"#
    }
    return Data(#"{"jobs":[\#(items.joined(separator: ","))],"totalCount":\#(jobs.count)}"#.utf8)
}

private func serpURL(_ q: String) -> String {
    "https://serpapi.com/search.json?engine=google_jobs&q=\(q.replacing(" ", with: "%20"))&location=Canada&gl=ca&hl=en&api_key=serp-key"
}

/// SerpApi's Google Jobs answer, in the shape its page shows (companies made up): one job found
/// on the employer's own page among the apply options, one found on a board's page.
private let serpJobs = Data(
    #"""
    {"jobs_results":[
      {"job_id":"g1","title":"Backend Developer","company_name":"Northline Freight","location":"Toronto, ON","via":"LinkedIn",
       "share_link":"https://www.google.com/search?ibp=htl;jobs#htidocid=g1","description":"Build shipment services in Go.\nOn call one week in six.",
       "job_highlights":[{"title":"Qualifications","items":["3+ years with Go","PostgreSQL"]}],
       "detected_extensions":{"posted_at":"3 days ago"},
       "apply_options":[{"title":"Northline Careers","link":"https://jobs.northline.example/1"}]},
      {"job_id":"g2","title":"Software Engineer","company_name":"Maplepay","location":"Anywhere","share_link":"https://www.google.com/search?ibp=htl;jobs#htidocid=g2",
       "source_link":"https://maplepay.example/jobs/2","description":"Payments.","detected_extensions":{"posted_at":"5 hours ago","work_from_home":true}}
    ]}
    """#.utf8)

/// Job collection v2, J7: Himalayas and Google Jobs (through SerpApi), searched for your roles.
@Suite("Optional sources")
struct OptionalSourcesTests {
    /// Himalayas: each role in each country, newest first, its page as the job's address, expired
    /// and too-old jobs left out, the key sent as a Bearer token.
    @Test func himalayasSearchesYourRoles() async throws {
        let fresh = now.timeIntervalSince1970 - 86_400
        let (http, script) = ScriptedURLProtocol.client([
            himalayasURL("software engineer", page: 1): .http(
                status: 200,
                body: himalayas([
                    ("https://himalayas.app/companies/acme/jobs/backend", "Backend Engineer", fresh, nil, ["Canada"]),
                    ("https://himalayas.app/companies/acme/jobs/old", "Old Role", fresh - 30 * 86_400, nil, []),
                    ("https://himalayas.app/companies/acme/jobs/gone", "Expired Role", fresh, fresh, ["Canada"]),
                ])),
            himalayasURL("software engineer", page: 2): .http(status: 200, body: himalayas([])),
        ])
        let source = HimalayasSource(id: sourceID, key: "him-key", http: http, now: { now })
        guard
            case .postings(let postings, let memo) = try await source.fetch(
                SourceQuery(titles: ["software engineer"], countries: [.canada], maxAgeDays: 7), since: nil)
        else {
            Issue.record("expected postings")
            return
        }
        #expect(postings.map(\.title) == ["Backend Engineer"] && memo?.requests == 2)
        let posting = try #require(postings.first)
        #expect(posting.url.absoluteString == "https://himalayas.app/companies/acme/jobs/backend")
        #expect(posting.location == "Remote - Canada" && posting.workplace == .remote && posting.countryHint == "CA")
        #expect(posting.descriptionHTML.contains("fleet API"))
        // Apply opens the application link unchanged (its terms); Himalayas is where it was seen.
        #expect(
            posting.applyURL?.absoluteString == "https://boards.greenhouse.io/acme/jobs/1" && posting.via == "Himalayas"
        )
        #expect(script.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer him-key")
        let (open, keyless) = ScriptedURLProtocol.client([
            himalayasURL("qa engineer", page: 1): .http(status: 200, body: himalayas([]))
        ])
        _ = try await HimalayasSource(id: sourceID, key: "", http: open, now: { now })
            .fetch(SourceQuery(titles: ["qa engineer"], countries: [.canada]))
        #expect(keyless.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// Google Jobs: one page per search; Google's link is the address; highlights follow the text;
    /// "3 days ago" is a date; "Anywhere" with home working is remote in your country.
    /// Google Jobs (job collection v3, C1): each result's address is the page Google took it from,
    /// Apply goes to the employer's own page behind a job board's copy, the age comes from
    /// `extensions`, and every option's link is kept for finding boards. Recorded from one real
    /// search (2026-10-26), trimmed.
    @Test func googleJobsReadsSerpApi() async throws {
        let recorded = try ScriptedURLProtocol.fixture("serpapi_google_jobs.json")
        let (http, script) = ScriptedURLProtocol.client([
            serpURL("software engineer"): .http(status: 200, body: serpJobs),
            serpURL("data engineer"): .http(status: 200, body: recorded),
        ])
        let source = GoogleJobsSource(id: sourceID, key: "serp-key", http: http, now: { now })
        let query = SourceQuery(
            titles: ["software engineer", "data engineer", "qa engineer"], countries: [.canada], callBudget: 2)
        guard case .postings(let postings, let memo) = try await source.fetch(query, since: nil) else {
            Issue.record("expected postings")
            return
        }
        #expect(postings.count == 7 && memo?.requests == 2 && script.requests.count == 2)
        let first = postings[0]
        // Never Google's search page: the employer's own page among the options is the address.
        #expect(first.url.absoluteString == "https://jobs.northline.example/1")
        #expect(first.applyURL?.absoluteString == "https://jobs.northline.example/1" && first.via == "LinkedIn")
        #expect(first.company == "Northline Freight" && first.location == "Toronto, ON" && first.countryHint == "CA")
        #expect(first.descriptionHTML.contains("<p>Build shipment services in Go.</p><p>On call one week in six.</p>"))
        #expect(first.descriptionHTML.contains("<h3>Qualifications</h3><ul><li>3+ years with Go</li>"))
        #expect(first.postedAt == now.addingTimeInterval(-3 * 86_400))
        #expect(postings[1].location == "Remote - Canada" && postings[1].workplace == .remote)
        #expect(postings[1].url.absoluteString == "https://maplepay.example/jobs/2")

        // Recorded from one real search (2026-10-26), trimmed: five jobs as Google returns them.
        let byCompany = Dictionary(uniqueKeysWithValues: postings.map { ($0.company, $0) })
        // Found on the employer's own site: that page is the address and the place to apply.
        let scotiabank = try #require(byCompany["Scotiabank"])
        let page = "https://jobs.scotiabank.com/job/Toronto-Software-Developer-ON-M5A-3X5/607183517/"
        #expect(scotiabank.url.absoluteString == page && scotiabank.applyURL?.absoluteString == page)
        #expect(scotiabank.via == "Scotiabank" && scotiabank.location == "Toronto, ON")
        // "7 days ago" sits in `extensions`; `detected_extensions` came back empty.
        #expect(scotiabank.postedAt == now.addingTimeInterval(-7 * 86_400) && scotiabank.links.count == 8)
        // Found on Indeed, with the employer's page among the options: Apply goes there, tracking dropped.
        let softline = try #require(byCompany["Softline Technology"])
        #expect(softline.url.absoluteString == "https://ca.indeed.com/viewjob?jk=46a439dfd909f1d0")
        #expect(softline.applyURL?.absoluteString == "https://softlinetechnology.com/job/title-dashed-rq10575/")
        #expect(softline.via == "Indeed" && softline.postedAt == now.addingTimeInterval(-2 * 86_400))
        // Found on job boards only: their page is the address and the place to apply.
        let industrious = try #require(byCompany["Industrious CRM"])
        #expect(industrious.url.host() == "csjobs.ca" && industrious.applyURL == industrious.url)
        let broadsign = try #require(byCompany["Broadsign"])
        #expect(broadsign.url.host() == "jobgether.com" && broadsign.applyURL == broadsign.url)
        #expect(
            broadsign.location == "Canada (+30 others)" && broadsign.postedAt == now.addingTimeInterval(-4 * 86_400))
        // No age among its extensions: undated, and kept.
        #expect(byCompany["Info-Tech Research Group"]?.postedAt == nil)

        #expect(source.posted("1 month ago") == now.addingTimeInterval(-30 * 86_400) && source.posted("soon") == nil)
        let (rejected, _) = ScriptedURLProtocol.client([serpURL("software engineer"): .http(status: 401)])
        await #expect(throws: SourceError.self) {
            _ = try await GoogleJobsSource(id: sourceID, key: "serp-key", http: rejected, now: { now })
                .fetch(SourceQuery(titles: ["software engineer"], countries: [.canada]))
        }
    }

    /// Where to apply: the page itself unless it's a job board's copy and an option names the
    /// employer; an option that names neither the company nor the source belongs to another
    /// posting (Google lists some by mistake) and is never chosen. Google's search page never is.
    @Test func googleJobsPicksWhereToApply() throws {
        func url(_ text: String) -> URL { URL(string: text)! }
        let linkedIn = url("https://ca.linkedin.com/jobs/view/backend-developer-at-acme-1")
        let employer = url("https://careers.acme.example/jobs/1?utm_source=google_jobs_apply&utm_campaign=x")
        let foreign = url("https://fil.wd3.myworkdayjobs.com/fr-CA/fidelitycanada/job/Toronto/Developer")
        #expect(
            GoogleJobsSource.applyLink(
                page: linkedIn, options: [("LinkedIn", linkedIn), ("Acme Careers", employer), ("Workday", foreign)],
                company: "Acme Robotics Inc.", via: "LinkedIn"
            ) == url("https://careers.acme.example/jobs/1"))
        #expect(
            GoogleJobsSource.applyLink(
                page: linkedIn,
                options: [
                    ("LinkedIn", linkedIn), ("Workday", foreign), ("Indeed", url("https://ca.indeed.com/viewjob?jk=1")),
                ],
                company: "Acme Robotics", via: "LinkedIn"
            ) == linkedIn)
        let own = url("https://jobs.acme.example/1?utm_medium=google")
        #expect(
            GoogleJobsSource.applyLink(
                page: own, options: [("Indeed", url("https://ca.indeed.com/viewjob?jk=1"))], company: "Acme",
                via: "Acme")
                == url("https://jobs.acme.example/1"))
        // The option that names the site the posting came from counts too.
        #expect(
            GoogleJobsSource.applyLink(
                page: url("https://ca.jooble.org/jdp/1"),
                options: [("MyProcom", url("https://myprocom-portal.procomservices.com/jobs/1"))],
                company: "Procom", via: "MyProcom"
            ) == url("https://myprocom-portal.procomservices.com/jobs/1"))
    }

    /// Both are built from your search settings; Google Jobs needs its key.
    @Test func theFactoryBuildsThem() throws {
        let (http, _) = ScriptedURLProtocol.client([:])
        let search = SearchContext(query: SourceQuery(titles: ["qa engineer"]), himalayasKey: nil, serpAPIKey: "k")
        let (himalayas, query) = try SourceFactory.make(
            Source(id: sourceID, kind: .himalayas), http: http, search: search)
        #expect(himalayas is HimalayasSource && query.titles == ["qa engineer"] && !himalayas.listsEverything)
        #expect(
            try SourceFactory.make(Source(id: sourceID, kind: .googleJobs), http: http, search: search).0
                is GoogleJobsSource)
        #expect(throws: SourceError.self) {
            try SourceFactory.make(Source(id: sourceID, kind: .googleJobs), http: http, search: SearchContext())
        }
        #expect(SourceKind.himalayas.isSearch && SourceKind.googleJobs.isSearch && !SourceKind.himalayas.sendsSnippets)
    }
}
