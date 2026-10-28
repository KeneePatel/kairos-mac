import Foundation
import KairosKit

/// A company's Personio job page, through its public XML feed (no key). Every published job with
/// its text in one answer, and an ETag. A name that isn't a Personio customer redirects to
/// personio.com: that's "not found", never an empty board.
public struct PersonioReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        let host = "\(board.slug).jobs.personio.de"
        guard BoardSlug.isValid(board.slug), let url = URL(string: "https://\(host)/xml?language=en") else {
            throw .invalidConfiguration("Personio company: \(board.slug)")
        }
        var feed = HTTPRequest(url: url)
        if let etag = request.etag { feed.headers["If-None-Match"] = etag }
        let response = try await http.fetch(feed)
        if response.status == 304 { return .notModified(etag: request.etag) }
        guard response.url.host() == host else { throw .notFound(endpoint: endpoint(of: url)) }
        let root = try XMLNode.parse(response.body)
        let postings = root.all("position").compactMap { position -> Posting? in
            guard let id = position.value("id"), let title = position.value("name"),
                let link = URL(string: "https://\(host)/job/\(id)")
            else { return nil }
            let text = position.child("jobDescriptions")?.all("jobDescription").map { section in
                (section.value("name").map { "<h3>\(HTMLEntities.escape($0))</h3>" } ?? "") + (section.value("value") ?? "")
            }.joined()
            let offices =
                [position.value("office")]
                + (position.child("additionalOffices")?.all("office").map { $0.text.tidied } ?? [])
            let places = offices.compactMap { $0 }.filter { !$0.isEmpty }
            return Posting(
                url: link,
                company: board.name.isEmpty ? (position.value("subcompany") ?? board.slug) : board.name,
                title: title, location: places.first ?? "", postedAt: position.value("createdAt").flatMap(ISODate.parse),
                descriptionHTML: text ?? "", otherLocations: Array(places.dropFirst()))
        }
        return ReadResult(postings: postings, etag: response.header("ETag"), complete: true)
    }
}

/// A company's Teamtailor careers site, through its public RSS feed (no key). Every published job
/// with its text and places in one answer, with an ETag.
public struct TeamtailorReader: JobReader {
    let board: Board
    let http: any HTTPClient

    public init(board: Board, http: any HTTPClient) {
        self.board = board
        self.http = http
    }

    public func read(_ request: ReadRequest) async throws(SourceError) -> ReadResult {
        guard BoardSlug.isValid(board.slug), let url = URL(string: "https://\(board.slug).teamtailor.com/jobs.rss")
        else { throw .invalidConfiguration("Teamtailor company: \(board.slug)") }
        var feed = HTTPRequest(url: url)
        if let etag = request.etag { feed.headers["If-None-Match"] = etag }
        let response = try await http.fetch(feed)
        if response.status == 304 { return .notModified(etag: request.etag) }
        let channel = try XMLNode.parse(response.body).child("channel")
        let postings = (channel?.all("item") ?? []).compactMap { item -> Posting? in
            guard let title = item.value("title"), let link = item.value("link").flatMap(URL.init(string:)) else {
                return nil
            }
            let locations = item.child("tt:locations")?.all("tt:location") ?? []
            let places = locations.map { location in
                [location.value("tt:city") ?? location.value("tt:name"), location.value("tt:country")]
                    .compactMap { $0 }.joined(separator: ", ")
            }
            let remote = item.value("remoteStatus")?.lowercased()
            return Posting(
                url: link, company: board.name.isEmpty ? (channel?.value("title") ?? board.slug) : board.name,
                title: title, location: places.first ?? "", postedAt: item.value("pubDate").flatMap(RFC822Date.parse),
                // RSS escapes the HTML once; the XML reader has already undone that.
                descriptionHTML: item.value("description") ?? "", otherLocations: Array(places.dropFirst()),
                countryHint: locations.first?.value("tt:country"),
                workplace: remote == "fully" || remote == "remote" ? .remote : remote == "hybrid" ? .hybrid : nil)
        }
        return ReadResult(postings: postings, etag: response.header("ETag"), complete: true)
    }
}

/// RSS dates: "Fri, 24 Jul 2026 09:05:16 +0200".
enum RFC822Date {
    static func parse(_ text: String) -> Date? {
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) { return date }
        }
        return ISODate.parse(text)
    }
}

/// A whole XML document as a small tree, for the feeds that answer in XML. Names keep their
/// prefixes ("tt:location"); text joins character data and CDATA. External entities never load.
struct XMLNode: Sendable, Equatable {
    var name: String
    var text = ""
    var children: [XMLNode] = []

    func child(_ name: String) -> XMLNode? { children.first { $0.name == name } }

    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// The trimmed text of the first child named `name`; nil when there's none or it's empty.
    func value(_ name: String) -> String? {
        child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parse(_ data: Data) throws(SourceError) -> XMLNode {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            throw .decoding("not XML: \(parser.parserError?.localizedDescription ?? "empty")")
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLNode] = []
        var root: XMLNode?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            stack.append(XMLNode(name: name))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty { root = element } else { stack[stack.count - 1].children.append(element) }
        }
    }
}
