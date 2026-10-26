import AppKit
import MasterResume
import PDFKit
import Pipeline
import Store
import SwiftUI
import Tailoring

/// A job's resume page (UI v2): the job's newest build, or one chosen from History in the toolbar,
/// as the Resumes section shows it. Opened from a job's Resume button; building again stays here.
struct BuildsView: View {
    @Environment(AppModel.self) private var model
    private let jobID: JobID
    /// The job's builds, newest first.
    @State private var history: [BuildRecord] = []
    /// The build chosen from History; nil for the newest.
    @State private var chosen: UUID?

    init(job: JobID) {
        jobID = job
    }

    private var build: BuildRecord? {
        guard let id = chosen ?? history.first?.id else { return nil }
        // The model's copy follows a running build; the page's list is read when the job's newest changes.
        return model.build(id) ?? history.first { $0.id == id }
    }

    private var job: Job? { model.job(jobID) }

    /// The job's newest build, so the list is read again when it changes.
    private var newest: BuildRecord? { model.latestBuilds[jobID.rawValue] }

    var body: some View {
        Group {
            if let build {
                ResumePage(build: build, job: job) { chosen = nil }
            } else {
                ContentUnavailableView {
                    Label("No resume for this job yet", systemImage: "doc.text")
                } description: {
                    Text("Press B on the job to build one.").foregroundStyle(Color(.inkSecondary))
                }
            }
        }
        .navigationTitle(job.map { "\($0.title) · \($0.company)" } ?? "Resume")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(history) { other in
                        Button {
                            chosen = other.id
                        } label: {
                            if other.id == build?.id {
                                Label(Self.historyLabel(other), systemImage: "checkmark")
                            } else {
                                Text(Self.historyLabel(other))
                            }
                        }
                    }
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(history.count < 2)
                .help("This job's builds, newest first")
            }
        }
        .task(id: "\(jobID.rawValue)-\(newest?.id.uuidString ?? "")-\(newest?.status.rawValue ?? "")") {
            history = await model.builds(for: jobID)
        }
    }

    /// "Oct 26, 8:14 AM · Full · with cover letter".
    static func historyLabel(_ build: BuildRecord) -> String {
        let when = build.createdAt.formatted(date: .abbreviated, time: .shortened)
        let status: String? =
            switch build.status {
            case .done: build.coverLetter?.status == .done ? "with cover letter" : nil
            case .queued: "waiting"
            case .running: "building"
            case .failed: "didn't finish"
            }
        return ([when, BuildRow.modeName(build.mode)] + [status].compactMap { $0 }).joined(separator: " · ")
    }

    static func describe(_ step: BuildStep) -> String {
        switch step {
        case .selecting: "picking entries"
        case .writing: "writing sections"
        case .scoring: "scoring"
        case .rewriting(let section, let pass): "rewriting \(section.rawValue), pass \(pass)"
        case .gapBullets: "adding gap bullets"
        case .shortening: "shortening bullets that waste a line"
        case .coverLetter: "writing the cover letter"
        case .fitting(let pages): "fitting \(pages) pages onto one"
        }
    }
}

/// One build's page (UI v2): the job and how the build went, the decisions with their keys (Mark
/// applied, Open posting, Save PDF, Build again, Reveal), Resume or Cover letter, then the PDF
/// beside one inspector with the match, the build, the selected line and its checks.
struct ResumePage: View {
    @Environment(AppModel.self) private var model
    let build: BuildRecord
    let job: Job?
    /// Called when a new build starts from here, so a job's page shows the newest.
    var onBuildAgain: () -> Void = {}

    @State private var pdf: URL?
    @State private var letterPDF: URL?
    @State private var showing = BuildDocument.resume
    /// The finished build's PDF was looked for and isn't there.
    @State private var pdfMissing = false
    @AppStorage("buildCoverLetter") private var coverLetter = false
    @State private var problem: String?
    /// A finished build's model calls, from the log.
    @State private var stored: BuildActivity?

    /// The PDF shown in the middle.
    private var shown: URL? { showing == .letter ? letterPDF : pdf }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Spacing.space7)
                .padding(.top, Spacing.space6)
                .padding(.bottom, Spacing.space4)
                .background(Color(.surface))
            Divider()
            BuildView(
                build: build, job: job, pdf: shown, step: model.buildSteps[build.id],
                master: model.resume?.resume, pdfMissing: pdfMissing, letter: letterPDF != nil,
                activity: model.buildActivity[build.id] ?? stored, showing: $showing)
        }
        .task(id: "\(build.id.uuidString)-\(build.status.rawValue)") {
            pdf = nil
            letterPDF = nil
            showing = .resume
            pdfMissing = false
            stored = nil
            if build.status == .done || build.status == .failed {
                stored = await model.activity(for: build.id)
            }
            if build.status == .done {
                pdf = await model.pdf(of: build).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                pdfMissing = pdf == nil
                if build.coverLetter?.status == .done {
                    letterPDF = await model.pdf(of: build, kind: "cover_letter").flatMap {
                        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                    }
                }
            }
        }
        .alert("Can't build", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(job?.company ?? "A removed job").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(job?.title ?? "Resume").font(TypeStyle.title1).foregroundStyle(Color(.ink))
            Text(subtitle).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
            HStack(spacing: Spacing.space2) {
                actions
                Spacer(minLength: Spacing.space2)
                if letterPDF != nil {
                    Picker("Document", selection: $showing) {
                        Text("Resume").tag(BuildDocument.resume)
                        Text("Cover letter").tag(BuildDocument.letter)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .padding(.top, Spacing.space3)
        }
    }

    /// "Built 8:14 AM in 1 min 52 s · Full · Letter, 1 page · master resume version 12".
    private var subtitle: String {
        var parts: [String] = []
        switch build.status {
        case .done:
            let took = build.finishedAt.map {
                Duration.seconds($0.timeIntervalSince(build.createdAt).rounded())
                    .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            }
            parts.append(
                "Built \(build.finishedAt?.formatted(date: .omitted, time: .shortened) ?? "")"
                    + (took.map { " in \($0)" } ?? ""))
            parts.append(BuildRow.modeName(build.mode))
            if let pdf, let pages = PDFDocument(url: pdf)?.pageCount {
                parts.append("Letter, \(pages) page\(pages == 1 ? "" : "s")")
            }
        case .running, .queued:
            parts.append(
                "Building · \(model.buildSteps[build.id].map(BuildsView.describe) ?? "waiting for a free worker")")
        case .failed:
            parts.append("Didn't finish")
        }
        parts.append("master resume version \(build.masterVersion)")
        if build.coverLetter?.status == .done { parts.append("cover letter written") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let applied = job?.state == .applied
        if applied {
            Label("Applied", systemImage: "paperplane").font(TypeStyle.headline).foregroundStyle(Color(.inkSecondary))
                .padding(.trailing, Spacing.space2)
        } else {
            Button {
                Task { if let job { await model.markApplied(job, build: build.id) } }
            } label: {
                ActionLabel(title: "Mark applied", key: "A", primary: true)
            }
            .buttonStyle(.borderedProminent)
            .disabled(job == nil)
            .help("Records that you applied with this resume. Track it in Applied.")
        }
        Button {
            if let job { model.openPosting(job) }
        } label: {
            ActionLabel(title: "Open posting", key: "O")
        }
        .disabled(job == nil)
        Button {
            if let shown { save(shown) }
        } label: {
            ActionLabel(title: "Save PDF", key: "⌘S")
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(shown == nil)
        .help(showing == .letter ? "Save the cover letter where you choose" : "Save the resume where you choose")
        Menu {
            Button("Full: rewrite for this job") { buildAgain(.strict) }
            if model.stretch.enabled { Button("Stretch: rewrite, add gap bullets") { buildAgain(.stretch) } }
            Button("Lite: copy your bullets") { buildAgain(.lite) }
            Divider()
            Toggle("Write a cover letter too", isOn: $coverLetter)
        } label: {
            Text("Build again")
        }
        .fixedSize()
        .disabled(job == nil || build.status == .running || build.status == .queued)
        .help("Build this job's resume again, in any mode")
        Button {
            if let shown { NSWorkspace.shared.activateFileViewerSelecting([shown]) }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(shown == nil)
        .help("Show the PDF in Finder")
    }

    private func buildAgain(_ mode: BuildMode) {
        guard let job else { return }
        Task {
            problem = await model.startBuild(for: job, mode: mode, coverLetter: coverLetter, show: false)
            if problem == nil { onBuildAgain() }
        }
    }

    /// Saves a copy where you choose, named for the job.
    private func save(_ pdf: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue =
            ([model.resume?.resume.header.fullName, job?.company] + [showing == .letter ? "Cover letter" : nil])
            .compactMap { $0 }.joined(separator: " - ") + ".pdf"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: pdf, to: destination)
    }
}

/// Which of a build's PDFs the middle pane shows.
enum BuildDocument: Hashable { case resume, letter }

/// One build: the PDF on the left, and one inspector on the right with the match, the build, the
/// lines and the selected line's trace and checks.
struct BuildView: View {
    let build: BuildRecord
    let job: Job?
    let pdf: URL?
    let step: BuildStep?
    let master: MasterResume?
    let pdfMissing: Bool
    /// The build has a cover letter to show.
    let letter: Bool
    /// Its model calls: what each section is waiting on, and what was worked around.
    let activity: BuildActivity?
    @Binding var showing: BuildDocument
    @State private var selected: Int?

    init(
        build: BuildRecord, job: Job?, pdf: URL?, step: BuildStep?, master: MasterResume?, pdfMissing: Bool = false,
        letter: Bool = false, activity: BuildActivity? = nil, showing: Binding<BuildDocument> = .constant(.resume),
        selected: Int? = nil
    ) {
        self.build = build
        self.job = job
        self.pdf = pdf
        self.step = step
        self.master = master
        self.pdfMissing = pdfMissing
        self.letter = letter
        self.activity = activity
        _showing = showing
        _selected = State(initialValue: selected)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let notes = activity?.notes, !notes.isEmpty {
                    NotesBanner(notes: notes)
                }
                preview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.surfaceSunken))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space5) {
                    BuildInspector(build: build, step: step, pdf: pdf, job: job, master: master, activity: activity)
                    Divider()
                    BulletTraceView(build: build, master: master, company: job?.company, selected: $selected)
                }
                .padding(Spacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 320)
            .background(Color(.surface))
        }
        .onChange(of: build.id) { selected = nil }
    }

    /// The PDF shown, or why there isn't one yet.
    @ViewBuilder private var preview: some View {
        Group {
            if let pdf {
                PDFPreview(url: pdf) { text in if showing == .resume { select(text) } }
            } else if build.status == .failed {
                ContentUnavailableView(
                    "This build didn't finish", systemImage: "exclamationmark.triangle",
                    description: Text(build.error ?? "Something went wrong."))
            } else if pdfMissing {
                ContentUnavailableView(
                    "The PDF isn't there", systemImage: "doc.questionmark",
                    description: Text("It was moved or deleted. Build again to make a new one."))
            } else if build.status == .done {
                Color.clear
            } else {
                VStack(spacing: Spacing.space3) {
                    ProgressView()
                    Text("Building your resume…").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Text selected in the PDF picks the line it belongs to.
    private func select(_ text: String) {
        guard let content = build.content else { return }
        let bullets = (content.experience + content.projects).flatMap(\.bullets)
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let index = bullets.firstIndex(where: { $0.text.contains(words) || words.contains($0.text.prefix(30)) }) {
            selected = index
        }
    }
}

/// The inspector's top: the match as bars, the build's steps (open while it runs or failed,
/// folded once done), its model calls, and which master resume it came from.
private struct BuildInspector: View {
    let build: BuildRecord
    let step: BuildStep?
    let pdf: URL?
    let job: Job?
    let master: MasterResume?
    let activity: BuildActivity?
    @State private var stepsShown = false

    private var content: TailoredResume? { build.content }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space5) {
            if let score = build.score { scoreCard(score) }
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Button {
                    stepsShown.toggle()
                } label: {
                    HStack {
                        Text("Build").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                        Spacer()
                        Text("\(doneCount) of \(steps.count) steps").font(TypeStyle.callout).monospacedDigit()
                            .foregroundStyle(Color(.inkSecondary))
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(TypeStyle.caption)
                            .foregroundStyle(Color(.inkSecondary))
                    }
                }
                .buttonStyle(.plain)
                if open {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        row(
                            step.title, step.detail, state: state(of: index),
                            problem: index == letterIndex ? build.coverLetter?.error : build.error)
                    }
                } else {
                    Text(steps.filter { !$0.detail.isEmpty }.map(\.detail).joined(separator: " · "))
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let activity, !activity.runs.isEmpty, open { AICallsList(activity: activity) }
            version
        }
    }

    /// Open while the build runs or when it failed, or when you ask.
    private var open: Bool { stepsShown || build.status != .done }

    private var steps: [(title: String, detail: String)] {
        let bullets = content.map { ($0.experience + $0.projects).flatMap(\.bullets).count } ?? 0
        let gaps = content.map { ($0.experience + $0.projects).flatMap(\.bullets).count { $0.gap } } ?? 0
        let roles = content?.experience.count ?? 0
        let projects = content?.projects.count ?? 0
        let pages = pdf.flatMap { PDFDocument(url: $0)?.pageCount }
        let checked =
            gaps == 0
            ? "\(bullets) bullets, all traced to your master resume"
            : "\(bullets - gaps) traced to your master resume; \(gaps) gap bullet\(gaps == 1 ? "" : "s") within the hard limits"
        let stretch: [(title: String, detail: String)] =
            build.mode == .stretch
            ? [
                (
                    "Added gap bullets",
                    gaps == 0 ? "None needed" : "\(gaps) for Can-discuss skills, listed to prepare"
                )
            ] : []
        return [
            (
                "Picked entries",
                "\(roles) role\(roles == 1 ? "" : "s"), \(projects) project\(projects == 1 ? "" : "s"), \(bullets) bullets"
            ),
            (
                "Wrote sections",
                // A template without a summary (Harvard) doesn't write one.
                build.mode == .lite
                    ? (content?.summary == nil ? "Skills" : "Summary and skills") + "; bullets copied word for word"
                    : content?.summary == nil ? "Experience, projects, skills" : "Summary, experience, projects, skills"
            ),
            ("Checked every claim", checked),
            (
                "Polished",
                job?.country == .unitedStates ? "Phrasing, verbs, US spelling" : "Phrasing, verbs, Canadian spelling"
            ),
            ("Scored", build.score.map { "\(Int($0.total.rounded())) of 100" } ?? ""),
        ] + stretch + [
            ("Rendered", pages.map { "Letter PDF, \($0) page\($0 == 1 ? "" : "s")" } ?? "Letter PDF")
        ] + letter
    }

    /// The cover letter's step, when the build was asked for one.
    private var letter: [(title: String, detail: String)] {
        guard let record = build.coverLetter else { return [] }
        let paragraphs = record.letter?.paragraphs.count ?? 0
        return [("Wrote cover letter", paragraphs == 0 ? "" : "\(paragraphs) paragraphs, every claim checked")]
    }

    private var letterIndex: Int? { build.coverLetter == nil ? nil : steps.count - 1 }
    private var renderedIndex: Int { steps.count - (build.coverLetter == nil ? 1 : 2) }

    private enum StepState { case done, running, waiting, failed }

    /// Done for a finished build; for a running one, the steps before the current one. A failed
    /// build marks the step it stopped at, when this session saw it get there.
    private func state(of index: Int) -> StepState {
        let current: Int =
            switch step {
            case .selecting?, nil: 0
            case .writing?: 1
            case .scoring?, .rewriting?: 4
            case .gapBullets?: 5
            case .shortening?, .fitting?: renderedIndex
            case .coverLetter?: letterIndex ?? renderedIndex
            }
        switch build.status {
        case .done:
            // A letter that couldn't be written doesn't fail the build, only its own step.
            return index == letterIndex && build.coverLetter?.status == .failed ? .failed : .done
        case .failed:
            guard step != nil else { return .waiting }
            return index < current ? .done : index == current ? .failed : .waiting
        case .queued, .running: return index < current ? .done : index == current ? .running : .waiting
        }
    }

    private var doneCount: Int { steps.indices.count { state(of: $0) == .done } }

    private func row(_ title: String, _ detail: String, state: StepState, problem: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.yes))
                case .running: ProgressView().controlSize(.mini)
                case .waiting: Image(systemName: "circle.dashed").foregroundStyle(Color(.inkSecondary))
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(.error))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(TypeStyle.body).foregroundStyle(Color(.ink))
                if state == .done, !detail.isEmpty {
                    Text(detail).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                } else if state == .failed, let error = problem {
                    Text(error).font(TypeStyle.callout).foregroundStyle(Color(.error)).fixedSize(
                        horizontal: false, vertical: true)
                }
            }
        }
    }

    /// SPEC §5.3's components as bars against their weights, and the must-haves no bullet shows.
    private func scoreCard(_ score: MatchScore) -> some View {
        let parts: [(String, Double, Double)] = [
            ("Must-haves", score.breakdown.mustHaves, 40), ("Nice-to-haves", score.breakdown.niceToHaves, 10),
            ("Shown in bullets", score.breakdown.evidence, 15), ("Domain", score.breakdown.domain, 10),
            ("Numbers", score.breakdown.metrics, 10), ("Language", score.breakdown.language, 10),
            ("Structure", score.breakdown.structure, 5),
        ]
        let missing = score.findings(.experience).compactMap { finding -> String? in
            guard finding.hasPrefix("Not shown in any bullet: ") else { return nil }
            return String(finding.dropFirst("Not shown in any bullet: ".count).prefix { $0 != "." })
        }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Match").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Text("\(Int(score.total.rounded()))").font(TypeStyle.score).foregroundStyle(Color(.ink))
            }
            ForEach(parts, id: \.0) { part in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(part.0).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                        Spacer()
                        Text("\(part.1.formatted(.number.precision(.fractionLength(0...1)))) / \(Int(part.2))")
                            .font(TypeStyle.callout).monospacedDigit().foregroundStyle(Color(.inkSecondary))
                    }
                    ProgressBar(fraction: part.2 > 0 ? part.1 / part.2 : 0)
                }
            }
            if !missing.isEmpty {
                Text("Missing from your bullets: \(missing.joined(separator: "; ")).")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                        horizontal: false, vertical: true
                    )
                    .padding(.top, Spacing.space1)
            }
        }
    }

    /// "Built from version N", and whether your master resume has changed since.
    private var version: some View {
        let changed = master.map { $0.version > build.masterVersion } ?? false
        return Label {
            Text(
                "Built from master resume version \(build.masterVersion)."
                    + (changed ? " You've changed it since; build again to use the latest." : "")
            )
            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: changed ? "exclamationmark.circle" : "doc.text").foregroundStyle(
                Color(changed ? .maybe : .inkSecondary))
        }
    }
}

/// A 4 pt bar: `ink` over `separator`, always beside its numbers.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule().fill(Color(.separator))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(Color(.ink)).frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
    }
}

/// Each model call of a build: its section, the model, how long it has taken, and why it moved on
/// when a model failed. Ticks while anything is still running.
private struct AICallsList: View {
    let activity: BuildActivity

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            Text("AI calls").font(TypeStyle.headline).foregroundStyle(Color(.ink))
            if activity.runs.contains(where: { $0.finished == nil }) {
                TimelineView(.periodic(from: .now, by: 1)) { context in rows(at: context.date) }
            } else {
                rows(at: Date())
            }
        }
    }

    private func rows(at now: Date) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(activity.runs) { run in row(run, at: now) }
        }
    }

    private func row(_ run: BuildActivity.Run, at now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            icon(run.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(BuildActivity.name(run.task)).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    Spacer()
                    Text(time(run, at: now)).font(TypeStyle.callout).monospacedDigit()
                        .foregroundStyle(Color(.inkSecondary))
                }
                Text(status(run)).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(run.failures.enumerated()), id: \.offset) { _, failure in
                    Text("\(failure.model.model) \(failure.reason)").font(TypeStyle.callout)
                        .foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Always an icon with the words beside it.
    @ViewBuilder private func icon(_ state: BuildActivity.State) -> some View {
        switch state {
        case .asking: ProgressView().controlSize(.mini)
        case .retrying: Image(systemName: "arrow.clockwise").foregroundStyle(Color(.maybe))
        case .answered: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.yes))
        case .gaveUp: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.error))
        }
    }

    private func status(_ run: BuildActivity.Run) -> String {
        switch run.state {
        case .asking: "Asking \(run.model.model)"
        case .retrying(let reason): "\(run.model.model) \(reason); trying again"
        case .answered(let cached): cached ? "\(run.model.model), from earlier" : run.model.model
        case .gaveUp: "No model could answer"
        }
    }

    private func time(_ run: BuildActivity.Run, at now: Date) -> String {
        if case .answered(true) = run.state { return "saved" }
        return "\(Int(run.seconds(at: now).rounded())) s"
    }
}

/// What a build worked around, above its PDF: another model took over, or a step was left out.
/// One line, with each note in a popover: wrapped notes here made the window's minimum taller
/// than the screen (SwiftUI measures it at the column's narrowest), which pushed half the resume
/// off it (2026-10-26).
private struct NotesBanner: View {
    let notes: [BuildActivity.Note]
    @State private var details = false

    private var gaveUp: Bool { notes.contains { $0.kind == .gaveUp } }

    /// "A fallback model helped: Cover letter, Skills".
    private var summary: String {
        var parts: [String] = []
        for note in notes where !parts.contains(BuildActivity.name(note.task)) {
            parts.append(BuildActivity.name(note.task))
        }
        return (gaveUp ? "Some of this build was done without the AI: " : "A fallback model helped: ")
            + parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: gaveUp ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                .foregroundStyle(Color(.maybe)).accessibilityHidden(true)
            Text(summary).font(TypeStyle.callout).foregroundStyle(Color(.ink)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: Spacing.space2)
            Button("Details") { details = true }
                .buttonStyle(.link).font(TypeStyle.callout)
                .popover(isPresented: $details, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        ForEach(notes, id: \.self) { note in
                            Text(note.text).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(Spacing.space4)
                    .frame(width: 380, alignment: .leading)
                }
        }
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .background(Color(.maybeBg))
        .help(notes.map(\.text).joined(separator: "\n"))
    }
}
