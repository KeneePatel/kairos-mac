import AppKit
import MasterResume
import PDFKit
import Store
import SwiftUI
import Tailoring

/// Builds (design `Build.dc.html`): one build at a time, chosen in the toolbar. Its steps and
/// score, the PDF, and each line traced to your master resume; build again in either mode, save the
/// PDF, reveal it in Finder, or mark the job applied.
struct BuildsView: View {
    @Environment(AppModel.self) private var model
    @State private var pdf: URL?
    @State private var letterPDF: URL?
    @State private var showing = BuildDocument.resume
    /// The finished build's PDF was looked for and isn't there.
    @State private var pdfMissing = false
    @AppStorage("buildCoverLetter") private var coverLetter = false
    @State private var mode = BuildMode.strict
    @State private var problem: String?

    private var build: BuildRecord? { model.build(model.selectedBuild) ?? model.builds.first }
    private var job: Job? { build.flatMap { build in model.jobs.first { $0.id.rawValue == build.jobID } } }

    var body: some View {
        Group {
            if let build {
                BuildView(
                    build: build, job: job, pdf: shown, step: model.buildSteps[build.id],
                    master: model.resume?.resume, pdfMissing: pdfMissing, letter: letterPDF != nil,
                    showing: $showing)
            } else {
                ContentUnavailableView {
                    Label("No builds yet", systemImage: "doc.text")
                } description: {
                    Text("Open a job in Today and choose Build resume.")
                }
            }
        }
        .navigationTitle(job.map { "\($0.title) · \($0.company)" } ?? "Builds")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .task(id: "\(build?.id.uuidString ?? "")-\(build?.status.rawValue ?? "")") {
            pdf = nil
            letterPDF = nil
            showing = .resume
            pdfMissing = false
            if let build, build.status == .done {
                pdf = await model.pdf(of: build).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                pdfMissing = pdf == nil
                if build.coverLetter?.status == .done {
                    letterPDF = await model.pdf(of: build, kind: "cover_letter").flatMap {
                        FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
                    }
                }
            }
            if let build { mode = build.mode == .stretch && !model.stretch.enabled ? .strict : build.mode }
        }
        .onChange(of: model.stretch.enabled) { _, on in
            if !on, mode == .stretch { mode = .strict }
        }
        .alert("Can't build", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    /// The PDF in the middle pane.
    private var shown: URL? { showing == .letter ? letterPDF : pdf }

    private var subtitle: String {
        guard let build else { return "" }
        switch build.status {
        case .done:
            // How long it took, from queued to saved: S8's measure, so a week of builds can be judged.
            let took = build.finishedAt.map {
                " · took "
                    + Duration.seconds($0.timeIntervalSince(build.createdAt).rounded())
                    .formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            }
            return "Resume build · finished \(build.finishedAt?.formatted(date: .omitted, time: .shortened) ?? "")"
                + (took ?? "") + (build.mode == .lite ? " · lite" : build.mode == .stretch ? " · stretch" : "")
        case .running, .queued:
            return "Building · \(model.buildSteps[build.id].map(Self.describe) ?? "waiting for a free worker")"
        case .failed:
            return "Didn't finish"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.builds) { other in
                    Button {
                        model.selectedBuild = other.id
                    } label: {
                        let title = model.jobs.first { $0.id.rawValue == other.jobID }.map {
                            "\($0.title) · \($0.company)"
                        }
                        Text(
                            "\(title ?? "A removed job") · \(other.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        )
                    }
                }
            } label: {
                Label("Builds", systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.builds.isEmpty)
            .help("Choose another build")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Mode", selection: $mode) {
                Text("Full").tag(BuildMode.strict)
                if model.stretch.enabled { Text("Stretch").tag(BuildMode.stretch) }
                Text("Lite").tag(BuildMode.lite)
            }
            .pickerStyle(.segmented)
            .help(
                "Full rewrites your bullets for the job"
                    + (model.stretch.enabled ? "; Stretch also adds gap bullets for your Can-discuss skills" : "")
                    + "; Lite copies them word for word and writes only the summary and skills."
            )
            Button {
                Task { if let job { problem = await model.startBuild(for: job, mode: mode, coverLetter: coverLetter) } }
            } label: {
                Label("Build again", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(job == nil || build?.status == .running || build?.status == .queued)
            Toggle(isOn: $coverLetter) {
                Label("Cover letter", systemImage: "envelope")
            }
            .help("Also write a cover letter when you build again.")
            Button {
                if let shown { save(shown) }
            } label: {
                Label("Save PDF", systemImage: "square.and.arrow.down")
            }
            .disabled(shown == nil)
            .help(showing == .letter ? "Save the cover letter" : "Save the resume")
            Button {
                if let shown { NSWorkspace.shared.activateFileViewerSelecting([shown]) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(shown == nil)
            Button {
                Task { if let job { await model.markApplied(job) } }
            } label: {
                Label("Mark applied", systemImage: "paperplane")
            }
            .disabled(job == nil || job?.state == .applied)
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

    static func describe(_ step: BuildStep) -> String {
        switch step {
        case .selecting: "picking entries"
        case .writing: "writing sections"
        case .scoring: "scoring"
        case .rewriting(let section, let pass): "rewriting \(section.rawValue), pass \(pass)"
        case .gapBullets: "adding gap bullets"
        case .coverLetter: "writing the cover letter"
        case .fitting(let pages): "fitting \(pages) pages onto one"
        }
    }
}

/// Which of a build's PDFs the middle pane shows.
enum BuildDocument: Hashable { case resume, letter }

/// One build in three columns: steps and score, the PDF, and the trace.
struct BuildView: View {
    let build: BuildRecord
    let job: Job?
    let pdf: URL?
    let step: BuildStep?
    let master: MasterResume?
    let pdfMissing: Bool
    /// The build has a cover letter to show.
    let letter: Bool
    @Binding var showing: BuildDocument
    @State private var selected: Int?

    init(
        build: BuildRecord, job: Job?, pdf: URL?, step: BuildStep?, master: MasterResume?, pdfMissing: Bool = false,
        letter: Bool = false, showing: Binding<BuildDocument> = .constant(.resume), selected: Int? = nil
    ) {
        self.build = build
        self.job = job
        self.pdf = pdf
        self.step = step
        self.master = master
        self.pdfMissing = pdfMissing
        self.letter = letter
        _showing = showing
        _selected = State(initialValue: selected)
    }

    var body: some View {
        HStack(spacing: 0) {
            BuildStepsColumn(build: build, step: step, pdf: pdf, job: job, master: master).frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                if letter {
                    Picker("Document", selection: $showing) {
                        Text("Resume").tag(BuildDocument.resume)
                        Text("Cover letter").tag(BuildDocument.letter)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.vertical, Spacing.space2)
                }
                preview
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.surfaceGrouped))
            Divider()
            BulletTraceView(build: build, master: master, company: job?.company, selected: $selected).frame(width: 340)
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

/// The left column: what the build did, its score, and which master resume it came from.
private struct BuildStepsColumn: View {
    let build: BuildRecord
    let step: BuildStep?
    let pdf: URL?
    let job: Job?
    let master: MasterResume?

    private var content: TailoredResume? { build.content }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space5) {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    HStack {
                        Text("Build steps").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                        Spacer()
                        Text("\(doneCount) of \(steps.count) done").font(TypeStyle.callout).monospacedDigit()
                            .foregroundStyle(Color(.inkSecondary))
                    }
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        row(
                            step.title, step.detail, state: state(of: index),
                            problem: index == letterIndex ? build.coverLetter?.error : build.error)
                    }
                }
                if let score = build.score { scoreCard(score) }
                version
            }
            .padding(Spacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
    }

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
                build.mode == .lite
                    ? "Summary and skills; bullets copied word for word" : "Summary, experience, projects, skills"
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
            case .fitting?: renderedIndex
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

    /// SPEC §5.3's components, each against its weight, and the must-haves no bullet shows.
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
                Text("Match score").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Text("\(Int(score.total.rounded()))").font(.system(size: 28, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Color(.ink))
            }
            ForEach(parts, id: \.0) { part in
                HStack {
                    Text(part.0).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                    Spacer()
                    Text("\(part.1.formatted(.number.precision(.fractionLength(0...1)))) / \(Int(part.2))")
                        .font(TypeStyle.callout).monospacedDigit().foregroundStyle(Color(.inkSecondary))
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
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
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
