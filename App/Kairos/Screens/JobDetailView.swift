import Store
import SwiftUI

/// The selected job, in the inspector: the facts, a link to the posting and its description.
struct JobDetailView: View {
    let job: Job
    let source: Source?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(job.title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
                    Text(job.company).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                }
                Grid(alignment: .leading, horizontalSpacing: Spacing.space3, verticalSpacing: Spacing.space1) {
                    fact("Location", job.location.isEmpty ? job.placeLabel : job.location)
                    fact("Work", job.workLabel)
                    fact("Posted", job.postedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Not stated")
                    fact("Found on", source?.kind.displayName ?? "A removed source")
                }
                if let url = URL(string: job.url) {
                    Link(destination: url) {
                        Label("Open posting", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.bordered)
                }
                Divider()
                if let description = job.descriptionMarkdown {
                    MarkdownView(description)
                } else {
                    Text("This posting has no description.").font(TypeStyle.callout)
                        .foregroundStyle(Color(.inkSecondary))
                }
            }
            .padding(Spacing.space5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(value).font(TypeStyle.callout).foregroundStyle(Color(.ink))
        }
    }
}
