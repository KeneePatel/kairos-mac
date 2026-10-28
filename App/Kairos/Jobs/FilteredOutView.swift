import Engine
import Screening
import Store
import SwiftUI

/// Filtered out: the reasons your filters dropped jobs, with counts, and the jobs under the chosen
/// reason, each with Bring back. Nothing here is lost: a filter's drop is one click from the AI.
struct FilteredOutView: View {
    @Environment(AppModel.self) private var model
    @State private var rule: String?
    @State private var selection: String?

    var body: some View {
        let jobs = model.filteredOut
        let reasons = Dictionary(grouping: jobs) { $0.screening?.rule ?? "" }
            .map { (rule: $0.key, jobs: $0.value) }
            .sorted { ($0.jobs.count, $1.rule) > ($1.jobs.count, $0.rule) }
        ListPaneLayout(listWidth: 300) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Filtered out", line: "\(jobs.count) jobs your filters dropped")
                List(selection: $rule) {
                    ForEach(reasons, id: \.rule) { reason in
                        HStack {
                            Text(PrefilterRule(rawValue: reason.rule)?.title ?? "Other").font(TypeStyle.headline)
                            Spacer()
                            Text("\(reason.jobs.count)").font(TypeStyle.callout).monospacedDigit()
                                .foregroundStyle(Color(.inkSecondary))
                        }
                        .frame(height: Spacing.rowHeight)
                        .tag(reason.rule)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .overlay {
                    if jobs.isEmpty { EmptyState("Nothing filtered out", "Your filters haven't dropped any open job.") }
                }
            }
        } pane: {
            if let chosen = reasons.first(where: { $0.rule == (rule ?? reasons.first?.rule) }) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(PrefilterRule(rawValue: chosen.rule)?.title ?? "Other").font(TypeStyle.title1)
                        Spacer()
                        Button("Change your filters") {
                            model.settingsPage = .search
                            model.section = .settings
                        }
                    }
                    .padding(.horizontal, Spacing.space7)
                    .padding(.top, Spacing.space7)
                    .padding(.bottom, Spacing.space3)
                    List(selection: $selection) {
                        ForEach(chosen.jobs) { job in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(job.title).font(TypeStyle.headline).lineLimit(1)
                                    Text(
                                        [job.company, job.placeLine, job.screening?.reasons.first ?? ""]
                                            .filter { !$0.isEmpty }.joined(separator: " · ")
                                    )
                                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).lineLimit(1)
                                }
                                Spacer()
                                Button("Bring back") { model.bringBack(job.id) }
                                    .help("Your filters will never drop it again; the AI judges it next.")
                            }
                            .frame(height: Spacing.rowHeightComfortable)
                            .tag(job.id)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } else {
                EmptyState("Nothing to show", "Jobs your filters drop are listed here by reason.")
            }
        }
        .navigationTitle("Filtered out")
    }
}
