import Foundation
import Tailoring

/// What a measured template (Harvard's) records as it lays a resume out: `<kairos-layout>`, read with
/// `typst eval`. Lengths are in points.
public struct ResumeLayout: Decodable, Sendable, Equatable {
    public struct Bullet: Decodable, Sendable, Equatable {
        /// The section's kind: "experience", "projects".
        public var section: String
        /// The entry's place in its section, and the bullet's in its entry.
        public var item: Int
        public var bullet: Int
        public var lines: Int
        /// Its width set on one line, and its characters.
        public var width: Double
        public var characters: Int?
    }

    public struct End: Decodable, Sendable, Equatable {
        public var page: Int
        public var y: Double
    }

    /// The width a bullet's lines run to.
    public var column: Double
    /// From one line of body text to the next.
    public var step: Double
    /// Where body text starts and stops on a page.
    public var top: Double
    public var bottom: Double
    /// Where the resume ends.
    public var end: End
    public var bullets: [Bullet]

    /// Reads it: an empty list from a template that isn't measured.
    static let expression = "query(<kairos-layout>).map(it => it.value)"

    /// For the fitter. A bullet's last line is estimated from its one-line width, so wrapped lines
    /// are taken as full: a slight underestimate, since a line breaks before a word that won't fit.
    public var pageLayout: PageLayout {
        func entries(_ kind: String) -> [[PageLayout.Bullet]] {
            let mine = bullets.filter { $0.section == kind }
            let count = (mine.map(\.item).max() ?? -1) + 1
            return (0..<count).map { item in
                mine.filter { $0.item == item }.sorted { $0.bullet < $1.bullet }.map { bullet in
                    let rest = bullet.width - Double(bullet.lines - 1) * column
                    let perLine = bullet.characters.flatMap {
                        bullet.width > 0 ? Double($0) * column / bullet.width : nil
                    }
                    return PageLayout.Bullet(
                        lines: bullet.lines, lastLineFill: min(1, max(0, rest / column)), lineCharacters: perLine)
                }
            }
        }
        return PageLayout(
            pages: end.page, linesPerPage: (bottom - top) / step, freeLines: max(0, (bottom - end.y) / step),
            experience: entries("experience"), projects: entries("projects"))
    }
}
