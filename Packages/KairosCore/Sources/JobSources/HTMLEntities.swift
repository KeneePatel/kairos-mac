/// Decodes HTML character references in one left-to-right pass. One pass matters: Greenhouse
/// escapes its HTML once, so "&amp;#39;" must become "&#39;" (still valid HTML), not "'".
/// Unknown or malformed references are left as written.
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
            // References are short; a ";" further away than this isn't ending one.
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
