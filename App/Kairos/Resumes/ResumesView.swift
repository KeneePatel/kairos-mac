import AI
import AppKit
import Engine
import PDFKit
import Store
import SwiftUI
import Tailoring
import UniformTypeIdentifiers

/// Resumes: every build, grouped Building, Today, Yesterday and Earlier, and the selected build's
/// page: the PDF, its letter, and the inspector with the match, the checks and what to be ready
/// to discuss.
struct ResumesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ListPaneLayout {
            VStack(spacing: 0) {
                ColumnTitle(title: "Resumes", line: line)
                List(selection: $model.selectedBuild) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.builds) { build in BuildRow(build: build).tag(build.id) }
                        } header: {
                            GroupHeader(title: group.title, count: group.builds.count)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if model.builds.isEmpty {
                        EmptyState("No resumes yet", "Build one from a job with B: it takes a minute or two.")
                    }
                }
                .onDeleteCommand { if let id = model.selectedBuild { model.deleteBuild(id) } }
            }
        } pane: {
            if let build = model.builds.first(where: { $0.id == model.selectedBuild }) {
                BuildPage(build: build)
            } else {
                EmptyState("No resume selected", "Choose a build to see its PDF and how it matches the job.")
            }
        }
        .navigationTitle("Resumes")
        .onAppear { if model.selectedBuild == nil { model.selectedBuild = model.builds.first?.id } }
    }

    private var line: String {
        let done = model.builds.filter { $0.status == .done }.count
        let running = model.builds.filter { !$0.status.isFinished }.count
        return "\(done) built" + (running > 0 ? " · \(running) building" : "")
    }

    private var groups: [(title: String, builds: [BuildRecord])] {
        let calendar = Calendar.current
        var building: [BuildRecord] = []
        var today: [BuildRecord] = []
        var yesterday: [BuildRecord] = []
        var earlier: [BuildRecord] = []
        for build in model.builds {
            if !build.status.isFinished {
                building.append(build)
            } else if calendar.isDateInToday(build.createdAt) {
                today.append(build)
            } else if calendar.isDateInYesterday(build.createdAt) {
                yesterday.append(build)
            } else {
                earlier.append(build)
            }
        }
        return [("Building", building), ("Today", today), ("Yesterday", yesterday), ("Earlier", earlier)]
            .filter { !$0.1.isEmpty }
    }
}

struct BuildRow: View {
    let build: BuildRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        let job = model.summary(build.jobID)
        HStack(spacing: Spacing.space3) {
            status.frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(job?.title ?? "A job no longer listed").font(TypeStyle.headline).lineLimit(1)
                Text(
                    [job?.company ?? "", build.mode.title, build.createdAt.shortDay].filter { !$0.isEmpty }
                        .joined(separator: " · ")
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
            }
            Spacer()
            if let score = build.score {
                Text("\(Int(score.rounded()))").font(TypeStyle.scoreSmall).foregroundStyle(Color(.ink))
            }
        }
        .frame(height: Spacing.rowHeight)
    }

    @ViewBuilder private var status: some View {
        switch build.status {
        case .queued, .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "doc.text").foregroundStyle(Color(.accentText))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.error))
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(Color(.inkSecondary))
        }
    }
}

/// One build's page.
struct BuildPage: View {
    let build: BuildRecord
    @Environment(AppModel.self) private var model
    @State private var showing = Document.resume
    @State private var inspector = true

    enum Document: String, CaseIterable {
        case resume = "Resume"
        case letter = "Cover letter"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .inspector(isPresented: $inspector) {
            BuildInspector(build: build).inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.space2) {
            if build.status == .done {
                let applied = model.applications.contains { $0.jobID == build.jobID }
                Button {
                    model.markApplied(build.jobID)
                } label: {
                    ActionLabel(title: applied ? "Applied" : "Mark applied", key: "A", primary: !applied)
                }
                .buttonStyle(.borderedProminent)
                .disabled(applied)
                Button("Open posting") { model.openPosting(build.jobID) }
                Button("Save PDF…") { save() }
                    .disabled(build.file(showing == .resume ? .resume : .letter) == nil)
            }
            if !build.status.isFinished {
                Button("Stop") { model.stopBuild(build.id) }
            } else {
                Button("Build again") { model.build(build.jobID, mode: build.mode, letter: build.wantsLetter) }
            }
            Spacer()
            if build.wantsLetter {
                Picker("Show", selection: $showing) {
                    ForEach(Document.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button {
                inspector.toggle()
            } label: {
                Label("Details", systemImage: "sidebar.trailing")
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space3)
    }

    @ViewBuilder private var content: some View {
        switch build.status {
        case .queued, .running:
            let live = model.liveBuilds[build.id]
            EmptyState("Building", live?.step.map(Self.describe) ?? "Waiting for a free worker.") {
                ProgressView().controlSize(.small)
            }
        case .failed:
            EmptyState("This build failed", build.error ?? "Something went wrong.")
        case .stopped:
            EmptyState("Stopped", "Build again when you're ready.")
        case .done:
            if showing == .letter, build.file(.letter) == nil {
                EmptyState("No cover letter", build.letterError ?? "The letter couldn't be written.")
            } else if let file = build.file(showing == .resume ? .resume : .letter), let url = model.fileURL(file) {
                PDFPreview(url: url)
            } else {
                EmptyState("The PDF is missing", "Build again to make it.")
            }
        }
    }

    static func describe(_ step: BuildStep) -> String {
        switch step {
        case .selecting: "Choosing what to show from your master resume"
        case .writing: "Writing the sections"
        case .gapBullets: "Adding what you're ready to discuss"
        case .shortening: "Tightening long bullets"
        case .fitting(let pages): "Fitting it on \(pages == 1 ? "one page" : "\(pages) pages")"
        case .coverLetter: "Writing the cover letter"
        }
    }

    private func save() {
        guard let file = build.file(showing == .resume ? .resume : .letter), let source = model.fileURL(file) else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = source.lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            model.notice = AppModel.Notice(title: "The PDF couldn't be saved", message: error.localizedDescription)
        }
    }
}

/// The build's details: the match, what it shows, what to be ready to discuss, and its notes.
struct BuildInspector: View {
    let build: BuildRecord
    @Environment(AppModel.self) private var model
    @State private var calls: [AICall] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                if let score = build.score {
                    VStack(alignment: .leading, spacing: Spacing.space1) {
                        Text("\(Int(score.rounded()))").font(TypeStyle.score)
                        Text("match with the posting").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
                    }
                }
                PaneSection(title: "Build") {
                    FactRow(label: "Mode", value: build.mode.title)
                    FactRow(label: "Master resume", value: "version \(build.resumeVersion)")
                    if let seconds = build.seconds { FactRow(label: "Took", value: "\(Int(seconds)) s") }
                    if let pages = build.report?.report?.pages {
                        FactRow(label: "Pages", value: "\(pages)")
                    }
                }
                if let report = build.report?.report {
                    PaneSection(title: "Checks") {
                        FactRow(label: "Must-haves shown", value: "\(Int((report.mustHaves * 100).rounded()))%")
                        FactRow(label: "Bullets", value: "\(report.bullets)")
                        FactRow(label: "Numbers kept", value: "\(Int((report.numbersKept * 100).rounded()))%")
                        if report.dropped > 0 { FactRow(label: "Cut to fit", value: "\(report.dropped)") }
                        if !report.leftOut.isEmpty {
                            Text("Not shown: \(report.leftOut.joined(separator: ", "))")
                                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        }
                    }
                }
                let discuss = build.resume?.readyToDiscuss ?? []
                if !discuss.isEmpty {
                    PaneSection(title: "Be ready to discuss") {
                        ForEach(Array(discuss.enumerated()), id: \.offset) { _, bullet in
                            Text(bullet.text).font(TypeStyle.callout).foregroundStyle(Color(.ink))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                let notes =
                    (build.report?.fellBack ?? []).map { "\($0.capitalized) used your own words: its writer failed." }
                    + (build.report?.notes ?? [])
                if !notes.isEmpty {
                    PaneSection(title: "Notes") {
                        ForEach(notes, id: \.self) { note in
                            Text(note).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !calls.isEmpty {
                    PaneSection(title: "Model calls") {
                        ForEach(Array(calls.enumerated()), id: \.offset) { _, call in
                            HStack {
                                Text(call.task.rawValue).font(TypeStyle.callout)
                                Spacer()
                                Text(
                                    "\(call.model) · \(call.outcome == .ok ? "\(call.milliseconds / 1000) s" : call.outcome.rawValue)"
                                )
                                .font(TypeStyle.mono).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: build.status) { calls = (try? await model.workspace?.store.ai.calls(build: build.id)) ?? [] }
    }
}

/// A PDF, shown with PDFKit: selectable text, the page at its width.
struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor(named: "surface-sunken") ?? .windowBackgroundColor
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
