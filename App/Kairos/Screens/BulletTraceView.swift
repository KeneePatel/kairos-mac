import MasterResume
import Store
import SwiftUI
import Tailoring

/// Every line of a build, and the selected one traced to the master-resume bullets it came from,
/// with the checks it passes (design `Build.dc.html`, right column). Lines Stretch mode added have
/// the Can-discuss dashed outline and the word "Stretch".
struct BulletTraceView: View {
    let build: BuildRecord
    let master: MasterResume?
    let company: String?
    @Binding var selected: Int?

    private var lines: [(entry: TailoredResume.Entry, bullet: TailoredBullet)] {
        guard let content = build.content else { return [] }
        return (content.experience + content.projects).flatMap { entry in entry.bullets.map { (entry, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lines").font(TypeStyle.headline).foregroundStyle(Color(.ink)).padding(.bottom, Spacing.space1)
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button {
                            selected = index
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                                Text(line.bullet.text).font(TypeStyle.callout).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(Color(selected == index ? .ink : .ink2))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if line.bullet.gap {
                                    Text("Stretch").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
                                }
                            }
                            .padding(.horizontal, Spacing.space2).padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.card)
                                    .fill(selected == index ? Color(.accentTint) : .clear)
                            )
                            .overlay { if line.bullet.gap { GapOutline() } }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.space4)
            }
            .frame(maxHeight: 260)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space5) {
                    if let index = selected, lines.indices.contains(index) {
                        trace(lines[index].entry, lines[index].bullet)
                    } else {
                        Text("Choose a line, or select text in the resume, to see where it came from.")
                            .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                    ReadyToDiscussView(build: build, lines: lines.map(\.bullet), master: master, selected: $selected)
                }
                .padding(Spacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(.surface))
    }

    @ViewBuilder private func trace(_ entry: TailoredResume.Entry, _ bullet: TailoredBullet) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text("Selected line · \(entry.title)").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
            Text(bullet.text).font(TypeStyle.body).foregroundStyle(Color(.ink)).fixedSize(
                horizontal: false, vertical: true)
        }
        if bullet.gap {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("Not from your master resume").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text(
                    "Stretch mode added this line"
                        + (bullet.covers.map { " to cover “\($0)”" } ?? "")
                        + ". It cites nothing in your master resume and any number in it is an estimate, so be ready to discuss it."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
                let named = ReadyToDiscussView.skills(
                    in: bullet.text, from: master?.skills.filter { $0.level == .canDiscuss } ?? [])
                if !named.isEmpty {
                    FlowLayout(spacing: 6) { ForEach(named, id: \.id) { SkillChip(skill: $0) } }
                }
            }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(GapOutline())
        } else {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Text("Traced to your master resume").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                ForEach(bullet.sourceIDs, id: \.self) { id in source(id) }
            }
        }
        checks(bullet)
    }

    /// One cited bullet: where it sits in your master resume, its words, its metrics and skills.
    @ViewBuilder private func source(_ id: UUID) -> some View {
        if let entry = master?.entries.first(where: { $0.bullets.contains { $0.id == id } }),
            let position = entry.bullets.firstIndex(where: { $0.id == id })
        {
            let original = entry.bullets[position]
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("\(name(entry)) · bullet \(position + 1) of \(entry.bullets.count)")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                Text(original.text).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                    .fixedSize(horizontal: false, vertical: true)
                if !original.metrics.isEmpty || !original.skills.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(original.metrics, id: \.self) { metric in
                            Label(metric, systemImage: "chart.bar.fill").font(TypeStyle.caption)
                                .padding(.horizontal, 6).frame(height: 20)
                                .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color(.chipMetricBg)))
                        }
                        ForEach(original.skills, id: \.self) { skill in
                            Text(skill).font(TypeStyle.caption).padding(.horizontal, 8).frame(height: 20)
                                .background(Capsule().fill(Color(.chipProvenBg)))
                        }
                    }
                }
            }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
        } else {
            Text("This line's source has since been changed or deleted in your master resume.")
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
        }
    }

    /// The verifier's rules, run again on this line against your master resume as it is now:
    /// strict for a line it backs, the hard limits for a Stretch line.
    @ViewBuilder private func checks(_ bullet: TailoredBullet) -> some View {
        if let master {
            let violations = Verifier(resume: master, mode: bullet.gap ? .stretch : .strict, hiringCompany: company)
                .check(bullet).map(\.rule)
            let rows: [(String, Bool)] =
                bullet.gap
                ? stretchRows(bullet, violations)
                : [
                    (
                        "Cites bullets from your master resume",
                        !violations.contains { [.missingSource, .unknownSource].contains($0) }
                    ),
                    ("Every number is in the source", !violations.contains(.unsupportedNumber)),
                    (
                        "Every technology is in the source or your Proven skills",
                        !violations.contains(.unsupportedTechnology)
                    ),
                    ("Nothing about the company you're applying to", !violations.contains(.hiringCompanyProduct)),
                    ("Fits the length", bullet.text.count <= Polish.maxBulletLength),
                ]
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack {
                    Text("Checks").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                    Spacer()
                    Text("\(rows.count { $0.1 }) of \(rows.count) passed").font(TypeStyle.callout).monospacedDigit()
                        .foregroundStyle(Color(.inkSecondary))
                }
                ForEach(rows, id: \.0) { row in
                    Label {
                        Text(row.0).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
                    } icon: {
                        Image(systemName: row.1 ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(row.1 ? Color(.yes) : Color(.error))
                    }
                }
            }
        }
    }

    /// The hard limits a Stretch line must still keep (SPEC §5.3).
    private func stretchRows(_ bullet: TailoredBullet, _ violations: [VerificationRule]) -> [(String, Bool)] {
        [
            ("Only your Proven or Can-discuss skills", !violations.contains(.unsupportedTechnology)),
            ("No more years than yours", !violations.contains(.yearsOverstated)),
            (
                "No degree, certification, title or promotion you don't have",
                !violations.contains { [.credential, .employerOrTitle].contains($0) }
            ),
            ("Nothing about the company you're applying to", !violations.contains(.hiringCompanyProduct)),
            ("Fits the length", bullet.text.count <= Polish.maxBulletLength),
        ]
    }

    private func name(_ entry: ResumeEntry) -> String {
        switch entry.fields {
        case .experience(let role): "\(role.employer) · \(role.title)"
        case .project(let project): project.name
        default: "Entry"
        }
    }
}
