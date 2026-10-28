import Foundation

extension String {
    /// Single spaces and no whitespace at either end.
    public var tidied: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased without accents, for comparing names and titles: "Montréal" and "montreal" match.
    public var folded: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en"))
    }

    /// Lowercase words of letters and digits; "C++", "C#" and ".NET" keep their marks so tech names
    /// survive ("node.js" stays one word).
    public var words: [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: ".-/"))
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for character in folded {
            if character.isLetter || character.isNumber || "+#.-/".contains(character) {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// The text cut to at most `limit` characters at a word boundary, with "…" when cut.
    public func truncated(to limit: Int) -> String {
        guard count > limit, limit > 1 else { return self }
        let cut = prefix(limit - 1)
        let boundary = cut.lastIndex(where: \.isWhitespace).map { cut[..<$0] } ?? cut
        return boundary.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// Whether `phrase` appears as whole words: "go" in "Go and Rust" but not in "Google".
    public func containsWords(_ phrase: String) -> Bool {
        let haystack = words
        let needle = phrase.words
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) where Array(haystack[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }
}

extension Sequence where Element: Hashable {
    /// The elements in order, each first occurrence only.
    public func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

extension Collection {
    public subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
