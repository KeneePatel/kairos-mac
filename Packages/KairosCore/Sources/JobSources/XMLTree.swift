import Foundation

/// A whole XML document as a small tree, for the feeds that answer in XML (Personio's job feed,
/// Teamtailor's RSS). Names keep their prefixes ("tt:location"); text joins its character data and
/// CDATA. External entities are never loaded.
struct XMLElement: Sendable, Equatable {
    var name: String
    var text = ""
    var children: [XMLElement] = []

    /// The first child named `name`.
    func child(_ name: String) -> XMLElement? { children.first { $0.name == name } }

    /// Every child named `name`.
    func all(_ name: String) -> [XMLElement] { children.filter { $0.name == name } }

    /// The trimmed text of the first child named `name`; nil when there's none or it's empty.
    func value(_ name: String) -> String? {
        child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func parse(_ data: Data) throws(SourceError) -> XMLElement {
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
        var stack: [XMLElement] = []
        var root: XMLElement?

        func parser(
            _ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            stack.append(XMLElement(name: name))
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
