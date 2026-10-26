import Pipeline
import Store
import SwiftUI
import Tailoring

/// Resumes (UI v2): every build in a list on the left, the ones under way first, then by day; the
/// chosen build's resume page on the right. A (mark applied) and O (open posting) act on the
/// chosen build while the list has focus.
struct ResumesView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [JobID] = []

    private var groups: [ResumesList.Group] { ResumesList.groups(model.builds) }

    private var selection: Binding<UUID?> {
        Binding(get: { model.selectedBuild }, set: { model.selectedBuild = $0 })
    }

    var body: some View {
        NavigationStack(path: $path) {
            ListPaneLayout {
                list
            } pane: {
                if let build = model.build(model.selectedBuild) ?? model.builds.first {
                    ResumePage(build: build, job: model.job(for: build))
                } else {
                    empty
                }
            }
            .navigationTitle("Resumes")
            .navigationDestination(for: JobID.self) { JobScreen(id: $0) }
        }
        .task(id: model.builds.map(\.id)) {
            if model.selectedBuild.map({ model.build($0) == nil }) ?? true {
                model.selectedBuild = model.builds.first?.id
            }
        }
        // The Job menu's ⌘⇧A and ⌘O act on the chosen build's job.
        .onChange(of: model.selectedBuild, initial: true) { _, id in
            model.selectedJob = model.build(id).flatMap { model.job(for: $0) }?.id
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            ColumnTitle(title: "Resumes", line: ResumesList.summary(model.builds))
            if groups.isEmpty {
                VStack(spacing: Spacing.space2) {
                    Text("No resumes yet").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                    Text("Press B on a job in the Inbox to build one.").font(TypeStyle.body)
                        .foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
                }
                .padding(Spacing.space7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: selection) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.builds) { build in
                                BuildRow(build: build, job: model.job(for: build), step: model.buildSteps[build.id])
                                    .tag(build.id)
                                    .listRowInsets(
                                        EdgeInsets(top: 0, leading: Spacing.space3, bottom: 0, trailing: Spacing.space3)
                                    )
                                    .contextMenu { rowMenu(build) }
                            }
                        } header: {
                            Text("\(group.kind.title) · \(group.builds.count)")
                                .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                                .padding(.horizontal, Spacing.space3).padding(.top, Spacing.space2)
                                .textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(characters: CharacterSet(charactersIn: "aoAO")) { press in
                    handle(press.characters.lowercased()) ? .handled : .ignored
                }
                .onKeyPress(.return) {
                    guard let build = model.build(model.selectedBuild), let job = model.job(for: build) else {
                        return .ignored
                    }
                    path.append(job.id)
                    return .handled
                }
            }
            Divider()
            Text("↑↓ move · ↩ open the job · A mark applied · O posting · ⌘S save PDF")
                .font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                .padding(.horizontal, Spacing.space6).padding(.vertical, Spacing.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func handle(_ key: String) -> Bool {
        guard let build = model.build(model.selectedBuild), let job = model.job(for: build) else { return false }
        switch key {
        case "a":
            guard job.state != .applied else { return true }
            Task { await model.markApplied(job, build: build.id) }
        case "o": model.openPosting(job)
        default: return false
        }
        return true
    }

    @ViewBuilder private func rowMenu(_ build: BuildRecord) -> some View {
        if let job = model.job(for: build) {
            Button("Open the job") { path.append(job.id) }
            Button("Open posting") { model.openPosting(job) }
            Divider()
            Button("Mark applied") { Task { await model.markApplied(job, build: build.id) } }
                .disabled(job.state == .applied)
        }
        if build.status == .failed {
            Button("Build again") { Task { _ = await model.rebuild(build.id) } }
        }
    }

    private var empty: some View {
        VStack(spacing: Spacing.space1) {
            Text("No resume selected").font(TypeStyle.title2).foregroundStyle(Color(.ink))
            Text("Choose a build in the list.").font(TypeStyle.body).foregroundStyle(Color(.inkSecondary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One build in the Resumes list: its state as an icon, the job, how it was built and when, the
/// score. Applied jobs' rows are dimmed, since their work is done.
struct BuildRow: View {
    let build: BuildRecord
    let job: Job?
    var step: BuildStep?

    private var dimmed: Bool { job?.state == .applied }

    var body: some View {
        HStack(spacing: Spacing.space3) {
            icon.frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(job?.title ?? "A removed job").font(TypeStyle.headline)
                    .foregroundStyle(dimmed ? Color(.inkDimmed) : Color(.ink)).lineLimit(1)
                Text(meta).font(TypeStyle.callout).foregroundStyle(dimmed ? Color(.inkDimmed) : Color(.inkSecondary))
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.space2)
            Text(build.score.map { "\(Int($0.total.rounded()))" } ?? "—").font(TypeStyle.scoreSmall)
                .foregroundStyle(dimmed ? Color(.inkDimmed) : Color(.ink)).frame(minWidth: 28, alignment: .trailing)
        }
        .frame(height: Spacing.rowHeight)
        .contentShape(Rectangle())
    }

    /// Always an icon with words beside it (the meta line names the state).
    @ViewBuilder private var icon: some View {
        switch build.status {
        case .queued: Image(systemName: "clock").foregroundStyle(Color(.inkSecondary))
        case .running: ProgressView().controlSize(.mini)
        case .done:
            if dimmed {
                Image(systemName: "paperplane").foregroundStyle(Color(.inkDimmed))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.yes))
            }
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(.error))
        }
    }

    /// "Northline Freight · Full · letter · 8:14 AM", or where a running build is.
    private var meta: String {
        var parts = [job?.company ?? ""]
        switch build.status {
        case .queued: parts.append("waiting for a free worker")
        case .running: parts.append(step.map(BuildsView.describe) ?? "building")
        case .failed: parts.append("didn't finish" + (build.error.map { " · \($0)" } ?? ""))
        case .done:
            parts.append(Self.modeName(build.mode))
            if build.coverLetter?.status == .done { parts.append("letter") }
            if job?.state == .applied { parts.append("applied") }
            parts.append((build.finishedAt ?? build.createdAt).formatted(date: .omitted, time: .shortened))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func modeName(_ mode: BuildMode) -> String {
        switch mode {
        case .strict: "Full"
        case .stretch: "Stretch"
        case .lite: "Lite"
        }
    }
}
