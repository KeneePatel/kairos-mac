import Screening
import SwiftUI

/// One requirement as the screener read it: what it is, whether your master resume shows it, and
/// the evidence quoted. Soft skills and the conditions code takes as met are shown but never count.
struct RequirementRow: View {
    let requirement: JobAnalysis.Requirement
    /// An evidence id in words: a skill, a degree, a role or a bullet.
    var describe: (String) -> String? = { _ in nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(requirement.text).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        guard requirement.counts else { return "minus.circle" }
        switch requirement.effectiveMatch {
        case .yes: return "checkmark.circle.fill"
        case .partial: return "circle.lefthalf.filled"
        case .no, .notJudged: return "circle.dashed"
        }
    }

    private var color: Color {
        guard requirement.counts else { return Color(.inkSecondary) }
        switch requirement.effectiveMatch {
        case .yes: return Color(.yes)
        case .partial: return Color(.maybe)
        case .no, .notJudged: return Color(.inkSecondary)
        }
    }

    private var meta: String {
        let category = requirement.category.map { $0.rawValue.capitalized + " · " } ?? ""
        guard requirement.counts else {
            return requirement.category == .soft
                ? "\(category)Not judged: a personal quality" : "\(category)Taken as met"
        }
        let quoted =
            (requirement.evidence ?? []).compactMap(describe).map { $0.count > 90 ? $0.prefix(90) + "…" : $0 }
            + [requirement.matchedSkill].compactMap { $0 }
        let shown = quoted.isEmpty ? "" : ": " + quoted.joined(separator: "; ")
        switch requirement.effectiveMatch {
        case .yes: return "\(category)Shown\(shown)"
        case .partial: return "\(category)Partly shown\(shown)"
        case .no, .notJudged: return "\(category)Not in your master resume"
        }
    }
}

extension Array where Element == JobAnalysis.Requirement {
    /// "3.5 of 5 shown": yes 1, partial ½, over the requirements that count.
    var shownSummary: String {
        let counted = filter(\.counts)
        guard !counted.isEmpty else { return "None to compare" }
        let credit = counted.reduce(0) { $0 + $1.effectiveMatch.credit }
        return "\(credit.formatted()) of \(counted.count) shown"
    }
}
