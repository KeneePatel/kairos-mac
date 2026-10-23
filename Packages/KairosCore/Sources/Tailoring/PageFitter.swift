import Foundation

/// Fits a resume to its page budget by what each line is worth (resume v2 plan, phase 1), from the
/// template's measurements:
/// - Over the budget, it cuts whatever costs the least per line saved: one bullet, a whole
///   project, or a whole role none of whose bullets answers the posting, except your most recent
///   role, whose absence would read as a gap. That role keeps at least two bullets (all of them
///   when it has fewer) and an older one at least one, so a strong project isn't cut to keep a
///   weak second bullet. A gap bullet goes before any bullet your master resume backs.
/// - Then it fills what the cuts left: bullets and projects it cut come back, the most relevant
///   first, while they still fit. A role cut for answering nothing stays out.
/// With only a page count (a template that isn't measured) it drops the lowest-ranked bullet at a
/// time, as builds always did.
struct PageFitter {
    let budget: Int
    /// You allow two pages when needed (`PageSettings`): the fitter decides between one and two.
    var allowingTwo = false
    let measure: BuildLoop.Measure

    /// A bullet ranked at or under this answers no requirement: its only credit is for a number.
    static let irrelevant = 0.25
    /// Lines a heading takes with the space around it: a role's two rows, a project's one.
    static let roleHeading = 2.5
    static let projectHeading = 1.5
    /// Tries at putting something back once the page fits.
    static let refills = 8

    struct Result {
        var resume: TailoredResume
        var layout: PageLayout
        var dropped: Int
        /// The pages it fitted to.
        var budget: Int
    }

    /// A bullet by its entry and its place in the entry as written.
    struct Key: Hashable {
        let entry: UUID
        let index: Int
    }

    /// What's been cut from the resume as written.
    struct Cuts {
        var entries: Set<UUID> = []
        var bullets: Set<Key> = []
    }

    enum Cut: Equatable {
        case bullet(Key)
        case entry(UUID)
    }

    func fit(_ written: TailoredResume, progress: (BuildStep) -> Void) async throws -> Result {
        var layout = try await measure(written)
        let budget = allowingTwo ? Self.pages(for: written, layout: layout) : budget
        guard layout.isMeasured else {
            return try await fitByRank(written, layout: layout, budget: budget, progress: progress)
        }
        var cuts = Cuts()
        var resume = written
        while layout.pages > budget {
            guard let cut = Self.cheapest(in: written, cuts: cuts, layout: layout) else { break }
            progress(.fitting(pages: layout.pages))
            Self.apply(cut, to: &cuts)
            resume = Self.applying(cuts, to: written)
            layout = try await measure(resume)
        }
        guard layout.pages <= budget else {
            return try await fitByRank(
                resume, layout: layout, budget: budget, progress: progress,
                alreadyDropped: Self.count(cuts, in: written))
        }
        for cut in Self.refills(in: written, cuts: cuts).prefix(Self.refills) {
            guard Self.lines(of: cut, in: written) <= layout.freeLines else { continue }
            var trial = cuts
            Self.restore(cut, in: &trial)
            let candidate = Self.applying(trial, to: written)
            let measured = try await measure(candidate)
            if measured.pages <= budget {
                cuts = trial
                resume = candidate
                layout = measured
            }
        }
        return Result(resume: resume, layout: layout, dropped: Self.count(cuts, in: written), budget: budget)
    }

    /// One page, unless what answers the posting runs at least half a page past it. What the fitter
    /// would cut first doesn't count: bullets that answer nothing, roles none of whose bullets do,
    /// and gap bullets. A second page that thin reads as padding.
    static func pages(for resume: TailoredResume, layout: PageLayout) -> Int {
        guard layout.isMeasured, layout.pages > 1 else { return 1 }
        var spare = 0.0
        for (isRole, entries, measured) in [
            (true, resume.experience, layout.experience), (false, resume.projects, layout.projects),
        ] {
            for (place, entry) in entries.enumerated() where place < measured.count {
                let lines = measured[place].map { Double($0.lines) }
                let off = entry.bullets.indices.filter {
                    entry.bullets[$0].gap || entry.bullets[$0].rank <= irrelevant
                }.filter { $0 < lines.count }
                if isRole, off.count == entry.bullets.count, entry.entryID != resume.experience.first?.entryID {
                    spare += lines.reduce(0, +) + roleHeading
                } else {
                    spare += off.map { lines[$0] }.reduce(0, +)
                }
            }
        }
        return layout.overflow(budget: 1) - spare >= layout.linesPerPage / 2 ? 2 : 1
    }

    // MARK: - Choosing a cut

    /// What a bullet is worth: its rank, a little for being there at all, and nothing for a gap
    /// bullet, which goes first.
    static func value(_ bullet: TailoredBullet) -> Double {
        bullet.gap ? -1 : bullet.rank + 0.1
    }

    /// The cut that loses the least per line it saves; ties go to the later entry and bullet.
    static func cheapest(in written: TailoredResume, cuts: Cuts, layout: PageLayout) -> Cut? {
        let current = applying(cuts, to: written)
        let latest = written.experience.first?.entryID
        var best: (cut: Cut, cost: Double)?
        func consider(_ cut: Cut, value: Double, lines: Double) {
            guard lines > 0 else { return }
            let cost = value / lines
            if best.map({ cost <= $0.cost }) ?? true { best = (cut, cost) }
        }
        for (isRole, entries, measured) in [
            (true, current.experience, layout.experience), (false, current.projects, layout.projects),
        ] {
            for (place, entry) in entries.enumerated() {
                let keys = keptKeys(of: entry.entryID, in: written, cuts: cuts)
                let lines = place < measured.count ? measured[place].map { Double($0.lines) } : []
                guard keys.count == entry.bullets.count, lines.count == entry.bullets.count else { continue }
                let original = written.entry(entry.entryID)?.bullets.count ?? entry.bullets.count
                let minimum = isRole && entry.entryID == latest ? min(2, original) : 1
                for (index, bullet) in entry.bullets.enumerated() where entry.bullets.count > minimum || bullet.gap {
                    consider(.bullet(keys[index]), value: value(bullet), lines: lines[index])
                }
                let answersNothing = entry.bullets.allSatisfy { $0.gap || $0.rank <= irrelevant }
                if !isRole || (answersNothing && entry.entryID != latest) {
                    consider(
                        .entry(entry.entryID), value: entry.bullets.map(value).reduce(0, +),
                        lines: lines.reduce(0, +) + (isRole ? roleHeading : projectHeading))
                }
            }
        }
        return best?.cut
    }

    /// What came out that could go back, the most relevant first: bullets of entries still on the
    /// page, then whole projects. Roles cut for answering nothing don't come back.
    static func refills(in written: TailoredResume, cuts: Cuts) -> [Cut] {
        let bullets = cuts.bullets.filter { !cuts.entries.contains($0.entry) }.compactMap { key -> (Cut, Double)? in
            guard let bullet = written.entry(key.entry)?.bullets[safe: key.index], !bullet.gap else { return nil }
            return (.bullet(key), value(bullet))
        }
        let projects = written.projects.filter { cuts.entries.contains($0.entryID) }.map {
            (Cut.entry($0.entryID), $0.bullets.map(value).reduce(0, +))
        }
        return (bullets + projects).sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Applying cuts

    static func apply(_ cut: Cut, to cuts: inout Cuts) {
        switch cut {
        case .bullet(let key): cuts.bullets.insert(key)
        case .entry(let id): cuts.entries.insert(id)
        }
    }

    static func restore(_ cut: Cut, in cuts: inout Cuts) {
        switch cut {
        case .bullet(let key): cuts.bullets.remove(key)
        case .entry(let id): cuts.entries.remove(id)
        }
    }

    /// The resume as written, less the cuts, in its own order.
    static func applying(_ cuts: Cuts, to written: TailoredResume) -> TailoredResume {
        func kept(_ entries: [TailoredResume.Entry]) -> [TailoredResume.Entry] {
            entries.filter { !cuts.entries.contains($0.entryID) }.map { entry in
                var entry = entry
                entry.bullets = entry.bullets.enumerated().filter {
                    !cuts.bullets.contains(Key(entry: entry.entryID, index: $0.offset))
                }.map(\.element)
                return entry
            }
        }
        var resume = written
        resume.experience = kept(written.experience)
        resume.projects = kept(written.projects)
        return resume
    }

    static func keptKeys(of entry: UUID, in written: TailoredResume, cuts: Cuts) -> [Key] {
        (written.entry(entry)?.bullets.indices ?? 0..<0).map { Key(entry: entry, index: $0) }.filter {
            !cuts.bullets.contains($0)
        }
    }

    /// Lines a refill would add, by the bullets' lengths when nothing measured them: a line holds
    /// about 100 characters at Harvard's 11 pt.
    static func lines(of cut: Cut, in written: TailoredResume) -> Double {
        func estimate(_ bullet: TailoredBullet) -> Double { (Double(bullet.text.count) / 100).rounded(.up) }
        switch cut {
        case .bullet(let key):
            return written.entry(key.entry)?.bullets[safe: key.index].map(estimate) ?? 0
        case .entry(let id):
            return (written.entry(id)?.bullets.map(estimate).reduce(0, +) ?? 0) + projectHeading
        }
    }

    /// Bullets the cuts removed, counting those of whole entries.
    static func count(_ cuts: Cuts, in written: TailoredResume) -> Int {
        (written.experience + written.projects).reduce(0) { total, entry in
            total
                + (cuts.entries.contains(entry.entryID)
                    ? entry.bullets.count
                    : entry.bullets.indices.count { cuts.bullets.contains(Key(entry: entry.entryID, index: $0)) })
        }
    }

    // MARK: - Page count only

    /// The lowest-ranked bullet at a time, while the page count is over.
    private func fitByRank(
        _ resume: TailoredResume, layout: PageLayout, budget: Int, progress: (BuildStep) -> Void,
        alreadyDropped: Int = 0
    ) async throws -> Result {
        var resume = resume
        var layout = layout
        var dropped = alreadyDropped
        while layout.pages > budget, BuildLoop.dropLowest(&resume) {
            progress(.fitting(pages: layout.pages))
            dropped += 1
            layout = try await measure(resume)
        }
        return Result(resume: resume, layout: layout, dropped: dropped, budget: budget)
    }
}

extension TailoredResume {
    /// A role or project by its master-resume entry.
    func entry(_ id: UUID) -> Entry? {
        (experience + projects).first { $0.entryID == id }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
