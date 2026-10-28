import Engine
import Store
import SwiftUI

/// The window: the sidebar with its status footer, and the selected section.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch model.phase {
            case .opening:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyState("Kairos couldn't start", message)
            case .ready:
                SectionView(section: model.section)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .background(Color(.window))
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
            presenting: model.notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
    }
}

/// The selected section's screen.
struct SectionView: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .inbox, .saved, .skipped: JobsView(section: section)
        case .filtered: FilteredOutView()
        case .resumes: ResumesView()
        case .applied: AppliedView()
        case .interviews: InterviewsView()
        case .improve: ImproveView()
        case .masterResume: MasterResumeView()
        case .sources: SourcesView()
        case .settings: SettingsView()
        }
    }
}

/// The sidebar: the working sections with ⌘ numbers, the reports, setup, and the status footer.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })) {
            Section {
                ForEach(AppSection.working) { row($0) }
            }
            Section("Reports") {
                ForEach(AppSection.reports) { row($0) }
            }
            Section("Setup") {
                ForEach(AppSection.setup) { row($0) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter() }
    }

    private func row(_ section: AppSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(model.count(section).flatMap { $0 > 0 ? $0 : nil } ?? 0)
            .tag(section)
    }
}

/// The one place Kairos says what it's doing: a line, a meter while something runs, a detail line,
/// and the one action that fits (Stop while a run goes).
struct StatusFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Divider()
            Text(title).font(TypeStyle.callout).foregroundStyle(Color(.ink)).lineLimit(1).monospacedDigit()
            if let fraction { ProgressMeter(fraction: fraction) }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                if let detail {
                    Text(detail).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(2)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                action
            }
        }
        .padding(Spacing.space3)
    }

    private var title: String {
        switch model.activity {
        case .fetching(let progress):
            progress.phase == .lookingUp ? "Looking up companies' boards" : "Finding new jobs"
        case .screening(let progress):
            progress.phase == .analyzing ? "Analysing jobs" : "Screening jobs"
        case .idle:
            if let building = model.builds.first(where: { $0.status == .running }) {
                "Building a resume for \(model.summary(building.jobID)?.company ?? "a job")"
            } else if let last = model.lastFetch?.finishedAt {
                "Checked \(last.formatted(.relative(presentation: .named)))"
            } else {
                "Not checked yet"
            }
        }
    }

    private var fraction: Double? {
        switch model.activity {
        case .fetching(let progress): progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
        case .screening(let progress): progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total)
        case .idle: nil
        }
    }

    private var detail: String? {
        switch model.activity {
        case .fetching(let progress):
            "\(progress.done) of \(progress.total) sources · \(progress.stats.added ?? 0) new"
        case .screening(let progress):
            "\(progress.done) of \(progress.total) · \(progress.yes) yes, \(progress.maybe) maybe"
        case .idle:
            if model.waitingForAI > 0 {
                "\(model.waitingForAI) waiting for the AI"
            } else if let stats = model.lastFetch?.stats, let added = stats.added {
                "\(added) new last time"
            } else {
                nil
            }
        }
    }

    @ViewBuilder private var action: some View {
        if model.activity.isRunning {
            link("Stop", help: "Stop. Jobs keep what they have; the rest wait for the next run.") { model.stop() }
        } else if model.waitingForAI > 0, model.canAnalyze {
            link("Screen now", help: "Analyse the jobs waiting for the AI, one call each.") { model.screenNow() }
        } else {
            link("Find now", help: "Check every source, then screen what's new (⌘R).") { model.findNewJobs() }
        }
    }

    private func link(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain).foregroundStyle(Color(.accentText)).font(TypeStyle.caption)
            .help(help)
    }
}
