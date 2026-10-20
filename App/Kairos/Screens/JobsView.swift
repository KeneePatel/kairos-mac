import Store
import SwiftUI

/// Every stored job, Canada first, with the selected one in the inspector and "Fetch now" in the toolbar.
struct JobsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: JobID?
    @State private var showsInspector = true

    var body: some View {
        content
            .navigationTitle("Jobs")
            .navigationSubtitle(model.fetchSummary)
            .toolbar { RunControls(model: model, title: "Fetch now") }
            .inspector(isPresented: $showsInspector) {
                inspector.inspectorColumnWidth(min: 320, ideal: 400, max: 560)
            }
    }

    @ViewBuilder private var content: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView {
                Label("No jobs yet", systemImage: "briefcase")
            } description: {
                Text(
                    model.sources.isEmpty
                        ? "Add a company in Sources, then fetch."
                        : "Choose Fetch now to check your companies' boards.")
            }
        } else {
            table
        }
    }

    private var table: some View {
        Table(of: Job.self, selection: $selection) {
            TableColumn("Role") { job in
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                    Text(job.company).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                .padding(.vertical, Spacing.space1)
            }
            .width(min: 220, ideal: 320)
            TableColumn("Location") { job in Text(job.placeLabel).foregroundStyle(Color(.ink2)) }
                .width(min: 110, ideal: 150)
            TableColumn("Work") { job in Text(job.workLabel).foregroundStyle(Color(.ink2)) }
                .width(min: 90, ideal: 140)
            TableColumn("Source") { job in
                Text(model.source(job.sourceID)?.kind.displayName ?? "—").foregroundStyle(Color(.inkSecondary))
            }
            .width(min: 80, ideal: 100)
            TableColumn("Posted") { job in
                Text(job.postedAt?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                    .monospacedDigit().foregroundStyle(Color(.inkSecondary))
            }
            .width(min: 80, ideal: 100)
        } rows: {
            ForEach(model.jobSections) { section in
                Section("\(section.title) · \(section.jobs.count) job\(section.jobs.count == 1 ? "" : "s")") {
                    ForEach(section.jobs) { TableRow($0) }
                }
            }
        }
    }

    @ViewBuilder private var inspector: some View {
        if let job = model.job(selection) {
            JobDetailView(job: job, source: model.source(job.sourceID))
        } else {
            ContentUnavailableView("Select a job", systemImage: "sidebar.right")
        }
    }
}
