import Store
import SwiftUI

/// One job in a list (UI v2): the verdict pill, the title, a meta line (company · place · the
/// deciding reason for a Maybe or No), the match at the trailing edge, and a document glyph when a
/// resume exists. 36 pt, one line each. Dimmed rows set every text to `ink-dimmed`.
struct JobRow: View {
    let job: Job
    /// The screening's first reason, shown after the company for a Maybe or No.
    var reason: String?
    var score: Int?
    var hasResume = false
    var dimmed = false

    var body: some View {
        HStack(spacing: Spacing.space3) {
            if let verdict = job.verdict {
                VerdictPill(verdict: verdict).frame(width: 74)
            } else {
                Text("Waiting").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).frame(width: 74)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(job.title).font(TypeStyle.headline).foregroundStyle(primary).lineLimit(1)
                Text(meta).font(TypeStyle.callout).foregroundStyle(secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.space2)
            if hasResume {
                Image(systemName: "doc.text").font(TypeStyle.callout).foregroundStyle(Color(.accentText))
                    .accessibilityLabel("Resume built")
            }
            Text(score.map(String.init) ?? "—").font(TypeStyle.scoreSmall).foregroundStyle(primary)
                .frame(minWidth: 28, alignment: .trailing)
                .accessibilityLabel(score.map { "Match \($0)" } ?? "No match score")
        }
        .frame(height: Spacing.rowHeight)
        .contentShape(Rectangle())
    }

    /// "Northline Freight · Toronto, ON · Hybrid", with the reason instead of the work kind for a
    /// Maybe or No.
    private var meta: String {
        var parts = [job.company]
        let place = job.location.isEmpty ? job.placeLabel : job.location
        if place != "—", !place.isEmpty { parts.append(place) }
        if let reason, job.verdict != .yes {
            parts.append(reason)
        } else if job.workLabel != "—" {
            parts.append(job.workLabel)
        }
        return parts.joined(separator: " · ")
    }

    private var primary: Color { dimmed ? Color(.inkDimmed) : Color(.ink) }
    private var secondary: Color { dimmed ? Color(.inkDimmed) : Color(.inkSecondary) }
}
