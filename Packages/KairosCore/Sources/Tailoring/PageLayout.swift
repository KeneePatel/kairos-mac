import Foundation

/// How a rendered resume fills its pages, as the template measured it while laying it out
/// (Render's `ResumeLayout`). The page fitter and the build report read it. A template that
/// isn't measured gives only its page count.
public struct PageLayout: Codable, Sendable, Equatable {
    /// One bullet as set: its lines, and how much of the last one it fills, 0 to 1.
    public struct Bullet: Codable, Sendable, Equatable {
        public var lines: Int
        public var lastLineFill: Double
        /// Characters a full line of this bullet holds, from its own text; nil when not measured.
        public var lineCharacters: Double?

        public init(lines: Int, lastLineFill: Double, lineCharacters: Double? = nil) {
            self.lines = lines
            self.lastLineFill = lastLineFill
            self.lineCharacters = lineCharacters
        }

        /// Runs onto a line it barely uses: a few words that cost a whole line.
        public var isShortWrap: Bool { lines > 1 && lastLineFill < PageLayout.shortWrapFill }
    }

    /// A last line under this share of the column is a short wrap.
    public static let shortWrapFill = 0.35

    public var pages: Int
    /// Lines of body text one page holds; 0 when the template wasn't measured.
    public var linesPerPage: Double
    /// Lines left empty under the end of the resume on its last page.
    public var freeLines: Double
    /// By entry, then by bullet, in the resume's order. Empty when the template wasn't measured.
    public var experience: [[Bullet]]
    public var projects: [[Bullet]]

    public init(
        pages: Int, linesPerPage: Double = 0, freeLines: Double = 0, experience: [[Bullet]] = [],
        projects: [[Bullet]] = []
    ) {
        self.pages = pages
        self.linesPerPage = linesPerPage
        self.freeLines = freeLines
        self.experience = experience
        self.projects = projects
    }

    /// Whether lines were measured, not just pages counted.
    public var isMeasured: Bool { linesPerPage > 0 }

    /// Lines past the end of `budget` pages; 0 when it fits.
    public func overflow(budget: Int) -> Double {
        guard pages > budget else { return 0 }
        return Double(pages - budget) * linesPerPage - freeLines
    }

    /// Every measured bullet, experience first.
    public var bullets: [Bullet] { (experience + projects).flatMap { $0 } }
}
