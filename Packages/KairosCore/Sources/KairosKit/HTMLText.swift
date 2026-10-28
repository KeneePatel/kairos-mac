/// Decodes HTML character references in one left-to-right pass. One pass matters: Greenhouse
/// escapes its HTML once, so "&amp;#39;" must become "&#39;" (still valid HTML), not "'". Unknown
/// or malformed references are left as written.
public enum HTMLEntities {
    static let named: [Substring: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "hellip": "\u{2026}", "bull": "\u{2022}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "agrave": "à", "acirc": "â", "ccedil": "ç",
        "ocirc": "ô", "ucirc": "û", "icirc": "î", "euml": "ë", "iuml": "ï", "Eacute": "É",
    ]

    /// Plain text made safe inside HTML: "&", "<" and ">" escaped.
    public static func escape(_ text: String) -> String {
        text.replacing("&", with: "&amp;").replacing("<", with: "&lt;").replacing(">", with: "&gt;")
    }

    public static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            output += rest[..<amp]
            let afterAmp = rest.index(after: amp)
            // References are short; a ";" further away than this doesn't end one.
            let window = rest[afterAmp...].prefix(12)
            if let semicolon = window.firstIndex(of: ";"), let decoded = reference(rest[afterAmp..<semicolon]) {
                output += decoded
                rest = rest[rest.index(after: semicolon)...]
            } else {
                output += "&"
                rest = rest[afterAmp...]
            }
        }
        output += rest
        return output
    }

    private static func reference(_ name: Substring) -> String? {
        guard name.first == "#" else { return named[name] }
        let digits = name.dropFirst()
        let value: UInt32? =
            if digits.first == "x" || digits.first == "X" {
                UInt32(digits.dropFirst(), radix: 16)
            } else {
                UInt32(digits, radix: 10)
            }
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}

/// A small HTML-to-Markdown converter for job postings: headings, paragraphs, lists, bold, italics
/// and web links. Scripts, styles and every other tag are dropped. Plain string work, so it runs
/// anywhere (no WebKit).
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
            guard let tag = HTMLTag(reading: &rest) else {
                writer.text(rest.prefix(1))  // a "<" that doesn't start a tag is text
                rest = rest.dropFirst()
                continue
            }
            writer.handle(tag)
        }
        return writer.finish()
    }

    /// Whether `text` looks like HTML rather than plain text or Markdown.
    public static func looksLikeHTML(_ text: String) -> Bool {
        text.contains("</") || text.contains("<br") || text.contains("<p>") || text.contains("<li>")
    }
}

struct HTMLTag {
    let name: String
    let closing: Bool
    let href: String?

    /// Reads one tag from the front of `rest`, quotes respected, and moves past it.
    init?(reading rest: inout Substring) {
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
    /// nil for a bulleted list, else the next number.
    private var lists: [Int?] = []
    private var links: [(href: String, start: Int)?] = []
    private var emphasis: [String: [Int]] = [:]
    private var skipping = 0
    private var atItemStart = false

    private static let blocks: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "blockquote", "table", "form",
        "fieldset", "figure", "pre", "address", "dl", "dd", "dt",
    ]
    private static let skipped: Set<String> = ["script", "style", "head", "title", "noscript", "svg", "template", "iframe"]

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

    mutating func handle(_ tag: HTMLTag) {
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
                if lists.isEmpty { blockBreak() } else { lineBreak() }
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
            if !atItemStart { out = trimmingTrailingSpaces(out) + "\n" }
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

    /// Opens or closes `**` or `*`, dropping a pair that ended up wrapping nothing.
    private mutating func mark(_ marker: String, closing: Bool) {
        if closing {
            guard let start = emphasis[marker]?.popLast() else { return }
            if out.utf8.count == start + marker.utf8.count {
                out = String(decoding: out.utf8.prefix(start), as: UTF8.self)
            } else {
                out = trimmingTrailingSpaces(out) + marker
            }
        } else {
            if !out.isEmpty && !out.hasSuffix(" ") && !out.hasSuffix("\n") && out.last?.isLetter == true { out += " " }
            emphasis[marker, default: []].append(out.utf8.count)
            out += marker
        }
    }

    /// Web and mail links become `[text](href)`; anything else (javascript:, relative) keeps its text.
    private mutating func link(_ tag: HTMLTag) {
        if tag.closing {
            guard let open = links.popLast(), let open else { return }
            if out.utf8.count == open.start + 1 {
                out = String(decoding: out.utf8.prefix(open.start), as: UTF8.self)
            } else {
                out = trimmingTrailingSpaces(out) + "](\(open.href))"
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
        out = trimmingTrailingSpaces(out)
        if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
    }

    /// Inside a list a block only starts a new line, so list items stay together.
    private mutating func blockBreak() {
        guard lists.isEmpty else { return lineBreak() }
        out = trimmingTrailingSpaces(out)
        guard !out.isEmpty else { return }
        while !out.hasSuffix("\n\n") { out += "\n" }
    }

    private func trimmingTrailingSpaces(_ text: String) -> String {
        var text = text
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    func finish() -> String {
        var result: [Substring] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(line)
            while line.last == " " { line = line.dropLast() }
            if line.isEmpty && (result.last?.isEmpty ?? true) { continue }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The block structure of Markdown that `HTMLToMarkdown` wrote, for views that render it: SwiftUI's
/// Markdown support is inline only, so headings and lists are split out here.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    /// May hold line breaks.
    case paragraph(String)
    /// `marker` is "•" or "3."; `depth` 0 is the outermost list.
    case item(marker: String, depth: Int, text: String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if body.isEmpty {
                flush()
            } else if body == "---" {
                flush()
                blocks.append(.rule)
            } else if let level = headingLevel(body) {
                flush()
                blocks.append(.heading(level: level, text: String(body.dropFirst(level + 1))))
            } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("• ") {
                flush()
                blocks.append(.item(marker: "•", depth: indent / 2, text: String(body.dropFirst(2))))
            } else if let number = orderedMarker(body) {
                flush()
                blocks.append(.item(marker: number, depth: indent / 2, text: String(body.dropFirst(number.count + 1))))
            } else {
                paragraph.append(body)
            }
        }
        flush()
        return blocks
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// "12. text" → "12."
    private static func orderedMarker(_ line: Substring) -> String? {
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return digits + "."
    }
}
