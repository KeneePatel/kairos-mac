import MasterResume
import SwiftUI

/// Entries shown as cards with their bullets: roles and projects under "Experience" (as the design
/// groups them), and education on its own.
struct EntrySection: View {
    @Environment(ResumeModel.self) private var model
    let title: String
    let kinds: [EntryKind]
    @Binding var editing: ResumeEntry?
    @Binding var deleting: ResumeEntry?

    var body: some View {
        let entries = kinds.flatMap { model.resume.entries($0) }
        FormSection(title: title, caption: caption(entries)) {
            Menu {
                ForEach(kinds, id: \.self) { kind in
                    Button(kind.itemName) { editing = ResumeEntry(fields: kind.blank()) }
                }
            } label: {
                PillLabel(title: "Add", symbol: "plus")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        } content: {
            VStack(spacing: Spacing.space3) {
                ForEach(entries) { entry in
                    EntryCard(entry: entry, editing: $editing, deleting: $deleting)
                }
            }
        }
    }

    private func caption(_ entries: [ResumeEntry]) -> String {
        guard !entries.isEmpty else {
            return kinds.contains(.experience) ? "Required: at least one role with a bullet" : "Optional"
        }
        let bullets = entries.reduce(0) { $0 + $1.bullets.count }
        let counts = kinds.compactMap { kind -> String? in
            let count = entries.count { $0.kind == kind }
            guard count > 0 else { return nil }
            let noun = kind == .experience ? "role" : kind == .project ? "project" : "entry"
            return "\(count) \(noun)\(count == 1 ? "" : noun.hasSuffix("y") ? "" : "s")"
                .replacing("entrys", with: "entries")
        }
        return counts.joined(separator: ", ") + " · \(bullets) bullet\(bullets == 1 ? "" : "s")"
    }
}

/// One entry: its header (click to edit) and its bullets, the first three until you ask for more.
private struct EntryCard: View {
    @Environment(ResumeModel.self) private var model
    let entry: ResumeEntry
    @Binding var editing: ResumeEntry?
    @Binding var deleting: ResumeEntry?
    @State private var expanded = false

    private static let collapsedCount = 3

    var body: some View {
        let summary = entry.summary
        VStack(alignment: .leading, spacing: 0) {
            Button {
                editing = entry
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title.isEmpty ? "Untitled" : summary.title)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(.ink))
                        if !summary.meta.isEmpty {
                            Text(summary.meta).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        }
                    }
                    Spacer()
                    Text("\(entry.bullets.count) bullet\(entry.bullets.count == 1 ? "" : "s")")
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, Spacing.space3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu { EntryMenu(entry: entry, editing: $editing, deleting: $deleting) }

            if !entry.bullets.isEmpty {
                Divider().overlay(Color(.separatorRow))
                VStack(alignment: .leading, spacing: 0) {
                    let shown = expanded ? entry.bullets : Array(entry.bullets.prefix(Self.collapsedCount))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, bullet in
                        if index > 0 { Divider().overlay(Color(.separatorRow)).padding(.leading, 14) }
                        BulletRow(bullet: bullet, skills: model.resume.skills)
                    }
                    if entry.bullets.count > Self.collapsedCount {
                        Button(
                            expanded
                                ? "Show fewer bullets"
                                : "Show \(entry.bullets.count - Self.collapsedCount) more bullet\(entry.bullets.count - Self.collapsedCount == 1 ? "" : "s")"
                        ) { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(TypeStyle.body.weight(.medium))
                        .foregroundStyle(Color(.accentText))
                        .padding(.horizontal, 14)
                        .padding(.vertical, Spacing.space2)
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.group).fill(Color(.surface)))
        .overlay(RoundedRectangle(cornerRadius: Radius.group).strokeBorder(Color(.separator)))
    }
}

/// Edit, move and delete (after confirming), shared by every entry list.
struct EntryMenu: View {
    @Environment(ResumeModel.self) private var model
    let entry: ResumeEntry
    @Binding var editing: ResumeEntry?
    @Binding var deleting: ResumeEntry?

    var body: some View {
        let siblings = model.resume.entries(entry.kind).map(\.id)
        let index = siblings.firstIndex(of: entry.id) ?? 0
        Button("Edit…") { editing = entry }
        Button("Move up") { Task { await model.move(entry, by: -1) } }.disabled(index == 0)
        Button("Move down") { Task { await model.move(entry, by: 1) } }.disabled(index >= siblings.count - 1)
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }
    }
}

/// A bullet's text, then its metric chips and the skills it shows.
struct BulletRow: View {
    let bullet: ResumeBullet
    let skills: [Skill]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bullet.text).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                .fixedSize(horizontal: false, vertical: true)
            if !bullet.metrics.isEmpty || !bullet.skills.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(bullet.metrics, id: \.self) { MetricChip(text: $0) }
                    if !bullet.metrics.isEmpty && !bullet.skills.isEmpty {
                        Rectangle().fill(Color(.separator)).frame(width: 1, height: 14).padding(.horizontal, 2)
                            .padding(.vertical, 4)
                    }
                    ForEach(bullet.skills, id: \.self) { name in
                        SkillChip(skill: skills.first { $0.name == name } ?? Skill(name: name))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A number from a bullet ("40% faster"): square-cornered, with a small chart mark (design rule 7).
struct MetricChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.fill").font(.system(size: 9)).foregroundStyle(Color(.inkSecondary))
                .accessibilityHidden(true)
            Text(text).font(TypeStyle.callout).monospacedDigit().foregroundStyle(Color(.ink))
        }
        .padding(.horizontal, Spacing.space2)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: Radius.chip).fill(Color(.chipMetricBg)))
    }
}
