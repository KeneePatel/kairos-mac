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
    @State private var mode = BuildMode.strict
    @State private var problem: String?

    private var build: BuildRecord? { model.build(model.selectedBuild) ?? model.builds.first }
    private var job: Job? { build.flatMap { build in model.jobs.first { $0.id.rawValue == build.jobID } } }

    var body: some View {
        Group {
            if let build {
                BuildView(
                    build: build, job: job, pdf: pdf, step: model.buildSteps[build.id],
                    master: model.resume?.resume)
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
            if let build, build.status == .done { pdf = await model.pdf(of: build) }
            if let build { mode = build.mode == .lite ? .lite : .strict }
        }
        .alert("Can't build", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private var subtitle: String {
        guard let build else { return "" }
        switch build.status {
        case .done:
            return "Resume build · finished \(build.finishedAt?.formatted(date: .omitted, time: .shortened) ?? "")"
                + (build.mode == .lite ? " · lite" : "")
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
                Text("Lite").tag(BuildMode.lite)
            }
            .pickerStyle(.segmented)
            .help(
                "Full rewrites your bullets for the job; Lite copies them word for word and writes only the summary and skills."
            )
            Button {
                Task { if let job { problem = await model.startBuild(for: job, mode: mode) } }
            } label: {
                Label("Build again", systemImage: "arrow.clockwise").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(job == nil || build?.status == .running || build?.status == .queued)
            Button {
                if let pdf { save(pdf) }
            } label: {
                Label("Save PDF", systemImage: "square.and.arrow.down")
            }
            .disabled(pdf == nil)
            Button {
                if let pdf { NSWorkspace.shared.activateFileViewerSelecting([pdf]) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .disabled(pdf == nil)
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
            [model.resume?.resume.header.fullName, job?.company].compactMap { $0 }.joined(separator: " - ") + ".pdf"
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
        case .fitting(let pages): "fitting \(pages) pages onto one"
        }
    }
}

/// One build in three columns: steps and score, the PDF, and the trace.
struct BuildView: View {
    let build: BuildRecord
    let job: Job?
    let pdf: URL?
    let step: BuildStep?
    let master: MasterResume?
    @State private var selected: Int?

    init(build: BuildRecord, job: Job?, pdf: URL?, step: BuildStep?, master: MasterResume?, selected: Int? = nil) {
        self.build = build
        self.job = job
        self.pdf = pdf
        self.step = step
        self.master = master
        _selected = State(initialValue: selected)
    }

    var body: some View {
        HStack(spacing: 0) {
            BuildStepsColumn(build: build, step: step, pdf: pdf, job: job, master: master).frame(width: 280)
            Divider()
            Group {
                if let pdf {
                    PDFPreview(url: pdf) { text in select(text) }
                } else if build.status == .failed {
                    ContentUnavailableView(
                        "This build didn't finish", systemImage: "exclamationmark.triangle",
                        description: Text(build.error ?? "Something went wrong."))
                } else {
                    VStack(spacing: Spacing.space3) {
                        ProgressView()
                        Text("Building your resume…").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.surfaceGrouped))
            Divider()
            BulletTraceView(build: build, master: master, company: job?.company, selected: $selected).frame(width: 340)
        }
        .onChange(of: build.id) { selected = nil }
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
                        row(step.title, step.detail, state: state(of: index))
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
        let roles = content?.experience.count ?? 0
        let projects = content?.projects.count ?? 0
        let pages = pdf.flatMap { PDFDocument(url: $0)?.pageCount }
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
            ("Checked every claim", "\(bullets) bullets, all traced to your master resume"),
            (
                "Polished",
                job?.country == .unitedStates ? "Phrasing, verbs, US spelling" : "Phrasing, verbs, Canadian spelling"
            ),
            ("Scored", build.score.map { "\(Int($0.total.rounded())) of 100" } ?? ""),
            ("Rendered", pages.map { "Letter PDF, \($0) page\($0 == 1 ? "" : "s")" } ?? "Letter PDF"),
        ]
    }

    private enum StepState { case done, running, waiting, failed }

    /// Done for a finished build; for a running one, the steps before the current one. A failed
    /// build marks the step it stopped at, when this session saw it get there.
    private func state(of index: Int) -> StepState {
        let current: Int =
            switch step {
            case .selecting?, nil: 0
            case .writing?: 1
            case .scoring?, .rewriting?: 4
            case .fitting?: 5
            }
        switch build.status {
        case .done: return .done
        case .failed:
            guard step != nil else { return .waiting }
            return index < current ? .done : index == current ? .failed : .waiting
        case .queued, .running: return index < current ? .done : index == current ? .running : .waiting
        }
    }

    private var doneCount: Int { steps.indices.count { state(of: $0) == .done } }

    private func row(_ title: String, _ detail: String, state: StepState) -> some View {
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
                } else if state == .failed, let error = build.error {
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
