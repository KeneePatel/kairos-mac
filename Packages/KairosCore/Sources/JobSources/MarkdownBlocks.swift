/// The block structure of a description that `HTMLToMarkdown` wrote, for views that render it.
/// SwiftUI's Markdown support is inline only, so headings and lists are split out here.
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
            } else if body.hasPrefix("- ") {
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
