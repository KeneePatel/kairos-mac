import Foundation
import Store

/// What a pasted careers URL points at.
public enum ATSDetection: Equatable, Sendable {
    case detected(kind: SourceKind, slug: String)
    /// Why not, in words the Sources screen can show.
    case notDetected(String)
}

/// Turns a careers URL into a source kind and board slug (SPEC §5.4: pasting a careers URL detects
/// the ATS). Accepts board pages, single postings, embeds and API URLs, with or without a scheme.
public enum ATSDetector {
    /// Boards that live on a subdomain of their ATS: acme.recruitee.com, acme.jobs.personio.de,
    /// acme.bamboohr.com, acme.teamtailor.com, and Workable's older acme.workable.com.
    static func subdomainBoard(_ host: String) -> (SourceKind, String?)? {
        let suffixes: [(String, SourceKind)] = [
            (".recruitee.com", .recruitee), (".jobs.personio.de", .personio), (".jobs.personio.com", .personio),
            (".bamboohr.com", .bambooHR), (".teamtailor.com", .teamtailor), (".workable.com", .workable),
        ]
        for (suffix, kind) in suffixes where host.hasSuffix(suffix) {
            let name = String(host.dropLast(suffix.count))
            // The vendor's own site, not a company's board.
            let isCompany = !name.isEmpty && !name.contains(".") && !["www", "api", "app", "apply"].contains(name)
            return (kind, isCompany ? name : nil)
        }
        return nil
    }

    /// "eu" when a Lever address is on Lever's EU instance, which has its own API host.
    public static func leverRegion(_ text: String) -> String? {
        text.lowercased().contains("eu.lever.co") ? "eu" : nil
    }

    public static func detect(_ text: String) -> ATSDetection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme), let host = components.host?.lowercased(),
            ["http", "https"].contains(components.scheme?.lowercased() ?? "")
        else {
            return .notDetected("That doesn't look like a web address.")
        }
        // Encoded, so "%2F" inside a segment can't split it into more segments.
        let path = components.percentEncodedPath.split(separator: "/").map(String.init)
        let forParameter = components.queryItems?.first { $0.name == "for" }?.value

        let found: (SourceKind, String?)? =
            switch host {
            // boards.greenhouse.io/acme, /acme/jobs/123, /embed/job_board?for=acme
            case "boards.greenhouse.io", "job-boards.greenhouse.io":
                (.greenhouse, path.first == "embed" ? forParameter : path.first)
            // boards-api.greenhouse.io/v1/boards/acme/jobs
            case "boards-api.greenhouse.io":
                (.greenhouse, path.count >= 3 && path[0] == "v1" && path[1] == "boards" ? path[2] : nil)
            // jobs.lever.co/acme, /acme/<posting id>; jobs.eu.lever.co for Lever's EU instance
            case "jobs.lever.co", "jobs.eu.lever.co":
                (.lever, path.first)
            // api.lever.co/v0/postings/acme
            case "api.lever.co", "api.eu.lever.co":
                (.lever, path.count >= 3 && path[0] == "v0" && path[1] == "postings" ? path[2] : nil)
            // jobs.ashbyhq.com/acme, /acme/<job id>, /acme/embed
            case "jobs.ashbyhq.com":
                (.ashby, path.first)
            // api.ashbyhq.com/posting-api/job-board/acme
            case "api.ashbyhq.com":
                (.ashby, path.count >= 3 && path[0] == "posting-api" && path[1] == "job-board" ? path[2] : nil)
            // jobs.smartrecruiters.com/Acme, /Acme/<id>; careers.smartrecruiters.com/Acme (case matters)
            case "jobs.smartrecruiters.com", "careers.smartrecruiters.com":
                (.smartRecruiters, path.first)
            // api.smartrecruiters.com/v1/companies/Acme/postings
            case "api.smartrecruiters.com":
                (.smartRecruiters, path.count >= 3 && path[0] == "v1" && path[1] == "companies" ? path[2] : nil)
            // apply.workable.com/acme, /acme/j/<code>; the widget feed's /api/v1/widget/accounts/acme
            case "apply.workable.com":
                (
                    .workable,
                    path.first == "api"
                        ? (path.count >= 5 && path[3] == "accounts" ? path[4] : nil)
                        : path.first == "j" ? nil : path.first
                )
            default:
                Self.subdomainBoard(host)
            }

        guard let (kind, slug) = found else {
            if components.queryItems?.contains(where: { $0.name == "gh_jid" || $0.name == "ashby_jid" }) == true {
                return .notDetected(
                    "This company page embeds its job board. Open the board itself and paste that address.")
            }
            if host.hasSuffix("myworkdayjobs.com") || host.hasSuffix("myworkdaysite.com") {
                return .notDetected(
                    "This company's jobs are on Workday, whose terms don't allow automated access, so Kairos can't watch them. They often reach Kairos through Adzuna."
                )
            }
            return .notDetected(
                "Not a job board Kairos reads. It reads Greenhouse, Lever, Ashby, SmartRecruiters, Workable, Recruitee, Personio, BambooHR and Teamtailor."
            )
        }
        guard let slug, BoardSlug.isValid(slug) else {
            return .notDetected("That's a \(kind.rawValue.capitalized) address, but it doesn't say which company.")
        }
        return .detected(kind: kind, slug: slug)
    }
}
