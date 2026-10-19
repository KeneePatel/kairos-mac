import Foundation
import Store

/// What normalizing one posting gives (SPEC §5.2, step 2).
public enum Normalized: Equatable, Sendable {
    case job(Job)
    /// Every place it names is outside Canada and the US; ATS postings are filtered by location (SPEC §5.4).
    case outsideCanadaAndUS
}

public enum Normalizer {
    public static func normalize(_ posting: Posting, firstSeenAt: Date) -> Normalized {
        let geo = Geo.parse(
            location: posting.location, otherLocations: posting.otherLocations, countryHint: posting.countryHint,
            workplace: posting.workplace)
        if geo.outsideCanadaAndUS { return .outsideCanadaAndUS }
        let company = tidy(posting.company)
        let title = tidy(posting.title)
        var locations: [String] = []
        for location in [posting.location] + posting.otherLocations {
            let place = tidy(location)
            if !place.isEmpty && !locations.contains(place) { locations.append(place) }
        }
        let markdown = HTMLToMarkdown.convert(posting.descriptionHTML)
        return .job(
            Job(
                canonicalURL: URLCanonicalizer.canonical(posting.url), sourceID: posting.sourceID,
                url: posting.url.absoluteString,
                dedupKey: DedupKey.make(company: company, title: title, city: geo.city),
                company: company, title: title, location: locations.joined(separator: "; "), city: geo.city,
                region: geo.region, country: geo.country, remoteScope: geo.remoteScope, postedAt: posting.postedAt,
                descriptionMarkdown: markdown.isEmpty ? nil : markdown, firstSeenAt: firstSeenAt))
    }

    /// Single spaces, no ends.
    static func tidy(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// The form of a posting's URL that every device and every visit agree on, so its hash can be the job id.
public enum URLCanonicalizer {
    /// Query parameters that only say how you arrived. Anything else could identify the job and stays.
    static let trackingParameters: Set<String> = [
        "gh_src", "lever-source", "lever-origin", "lever-via", "source", "src", "ref", "referrer", "refid", "trk",
        "trkinfo", "trackingid", "fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "_hsenc", "_hsmi", "mkt_tok",
        "igshid",
    ]

    public static func canonical(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme == "http" ? "https" : scheme
        var host = components.host?.lowercased()
        // Greenhouse serves the same posting on both hosts.
        if host == "boards.greenhouse.io" { host = "job-boards.greenhouse.io" }
        components.host = host
        if components.port == 443 || components.port == 80 { components.port = nil }
        components.fragment = nil
        let kept = (components.percentEncodedQueryItems ?? []).filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        components.percentEncodedQueryItems =
            kept.isEmpty ? nil : kept.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if components.percentEncodedPath.count > 1 && components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath.removeLast()
        }
        return components.string ?? url.absoluteString
    }
}

/// A small HTML-to-Markdown converter for job descriptions: headings, paragraphs, lists, bold,
/// italics and web links. Scripts and styles are dropped, as is anything else. Plain string work,
/// so it runs off the main thread (no WebKit).
public enum HTMLToMarkdown {
    public static func convert(_ html: String) -> String {
        var writer = MarkdownWriter()
        var rest = Substring(html)
        while !rest.isEmpty {
            guard let open = rest.firstIndex(of: "<") else {
                writer.text(rest)
                break
            }
            writer.text(rest[..<open])
            rest = rest[open...]
            if rest.hasPrefix("<!--") {
                rest = rest.range(of: "-->").map { rest[$0.upperBound...] } ?? ""
                continue
            }
            guard let tag = Tag(at: &rest) else {
                writer.text(rest.prefix(1))  // a "<" that doesn't start a tag is just text
                rest = rest.dropFirst()
                continue
            }
            writer.handle(tag)
        }
        return writer.finish()
    }
}

struct Tag {
    let name: String
    let closing: Bool
    let href: String?

    /// Reads one tag from the front of `rest`, quotes respected, and advances past it.
    init?(at rest: inout Substring) {
        var index = rest.index(after: rest.startIndex)
        guard index < rest.endIndex, rest[index].isLetter || rest[index] == "/" || rest[index] == "!" else {
            return nil
        }
        var quote: Character?
        while index < rest.endIndex {
            let character = rest[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                break
            }
            index = rest.index(after: index)
        }
        let body = rest[rest.index(after: rest.startIndex)..<min(index, rest.endIndex)]
        rest = index < rest.endIndex ? rest[rest.index(after: index)...] : ""
        closing = body.hasPrefix("/")
        name = String(body.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }).lowercased()
        href = Self.attribute("href", in: body)
    }

    private static func attribute(_ name: String, in body: Substring) -> String? {
        guard let range = body.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        var value = body[range.upperBound...]
        if let quote = value.first, quote == "\"" || quote == "'" {
            value = value.dropFirst().prefix { $0 != quote }
        } else {
            value = value.prefix { !$0.isWhitespace && $0 != ">" }
        }
        return HTMLEntities.decode(String(value))
    }
}

struct MarkdownWriter {
    private var out = ""
    private var lists: [Int?] = []  // nil for a bulleted list, else the next number
    private var links: [(href: String, start: Int)?] = []
    private var emphasis: [String: [Int]] = [:]
    private var skipping = 0
    private var atItemStart = false

    private static let blocks: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "blockquote", "table", "form",
        "fieldset", "figure", "pre", "address", "dl", "dd", "dt",
    ]
    private static let skipped: Set<String> = [
        "script", "style", "head", "title", "noscript", "svg", "template", "iframe",
    ]

    mutating func text(_ raw: Substring) {
        guard skipping == 0, !raw.isEmpty else { return }
        let decoded = HTMLEntities.decode(String(raw)).replacing("\u{00A0}", with: " ")
        var collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if decoded.first?.isWhitespace == true { collapsed = " " + collapsed }
        if decoded.last?.isWhitespace == true && !collapsed.hasSuffix(" ") { collapsed += " " }
        if out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ") { collapsed = String(collapsed.drop { $0 == " " }) }
        guard !collapsed.isEmpty else { return }
        out += collapsed
        if collapsed.contains(where: { !$0.isWhitespace }) { atItemStart = false }
    }

    mutating func handle(_ tag: Tag) {
        if Self.skipped.contains(tag.name) {
            skipping = max(0, skipping + (tag.closing ? -1 : 1))
            return
        }
        guard skipping == 0 else { return }
        switch tag.name {
        case _ where Self.blocks.contains(tag.name):
            blockBreak()
        case "h1", "h2", "h3", "h4", "h5", "h6":
            blockBreak()
            if !tag.closing {
                let level = min(Int(tag.name.dropFirst()) ?? 3, 3)
                out += String(repeating: "#", count: level) + " "
            }
        case "ul", "ol":
            if tag.closing {
                _ = lists.popLast()
                blockBreak()
            } else {
                lists.isEmpty ? blockBreak() : lineBreak()
                lists.append(tag.name == "ol" ? 1 : nil)
            }
        case "li":
            if tag.closing { return lineBreak() }
            lineBreak()
            let depth = max(lists.count - 1, 0)
            var marker = "- "
            if let number = lists.last ?? nil {
                marker = "\(number). "
                lists[lists.count - 1] = number + 1
            }
            out += String(repeating: "  ", count: depth) + marker
            atItemStart = true
        case "br":
            if !atItemStart { out = trimmedTrailingSpaces(out) + "\n" }
        case "hr":
            blockBreak()
            out += "---"
            blockBreak()
        case "tr":
            lineBreak()
        case "td", "th":
            if !out.hasSuffix(" ") && !out.hasSuffix("\n") { out += " " }
        case "strong", "b":
            mark("**", closing: tag.closing)
        case "em", "i":
            mark("*", closing: tag.closing)
        case "a":
            link(tag)
        default:
            break
        }
    }

    /// Opens or closes `**` / `*`, dropping a pair that ended up wrapping nothing.
    private mutating func mark(_ marker: String, closing: Bool) {
        if closing {
            guard let start = emphasis[marker]?.popLast() else { return }
            if out.utf8.count == start + marker.utf8.count {
                out = String(decoding: out.utf8.prefix(start), as: UTF8.self)
            } else {
                out = trimmedTrailingSpaces(out) + marker
            }
        } else {
            if !out.isEmpty && !out.hasSuffix(" ") && !out.hasSuffix("\n") && out.last?.isLetter == true { out += " " }
            emphasis[marker, default: []].append(out.utf8.count)
            out += marker
        }
    }

    /// Web and mail links become `[text](href)`; anything else (javascript:, relative) keeps only its text.
    private mutating func link(_ tag: Tag) {
        if tag.closing {
            guard let open = links.popLast(), let open else { return }
            if out.utf8.count == open.start + 1 {
                out = String(decoding: out.utf8.prefix(open.start), as: UTF8.self)
            } else {
                out = trimmedTrailingSpaces(out) + "](\(open.href))"
            }
            return
        }
        let href = tag.href?.trimmingCharacters(in: .whitespaces) ?? ""
        let lower = href.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("mailto:"),
            !href.contains(where: { $0 == ")" || $0 == " " || $0 == "\n" })
        else {
            links.append(nil)
            return
        }
        links.append((href, out.utf8.count))
        out += "["
    }

    private mutating func lineBreak() {
        guard !atItemStart else { return }
        out = trimmedTrailingSpaces(out)
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
    }

    /// Inside a list a block only starts a new line, so list items stay together.
    private mutating func blockBreak() {
        guard lists.isEmpty else { return lineBreak() }
        out = trimmedTrailingSpaces(out)
        guard !out.isEmpty else { return }
        while !out.hasSuffix("\n\n") { out += "\n" }
    }

    private func trimmedTrailingSpaces(_ text: String) -> String {
        var text = text
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    func finish() -> String {
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = Substring(line)
            while line.last == " " { line = line.dropLast() }
            return line
        }
        var result: [Substring] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
