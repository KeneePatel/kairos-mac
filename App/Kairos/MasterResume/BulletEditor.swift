import MasterResume
import SwiftUI

/// Edits an entry's bullets in place: text, metric chips and skill chips; add, move and remove.
/// Bullet ids are kept, because tailored resumes cite them.
struct BulletEditor: View {
    @Binding var bullets: [ResumeBullet]
    let skills: [Skill]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text("Bullets").font(TypeStyle.callout.weight(.semibold)).foregroundStyle(Color(.ink))
                Text("What you did, with numbers where you have them.")
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                Spacer()
                PillButton(title: "Add bullet", symbol: "plus") { bullets.append(ResumeBullet(text: "")) }
            }
            ForEach($bullets) { $bullet in
                BulletField(
                    bullet: $bullet, skills: skills, position: position(of: bullet.id),
                    move: { move(bullet.id, by: $0) }, remove: { bullets.removeAll { $0.id == bullet.id } })
            }
        }
    }

    private func position(of id: UUID) -> (index: Int, count: Int) {
        (bullets.firstIndex { $0.id == id } ?? 0, bullets.count)
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = bullets.firstIndex(where: { $0.id == id }), bullets.indices.contains(index + offset) else {
            return
        }
        bullets.swapAt(index, index + offset)
    }
}

private struct BulletField: View {
    @Binding var bullet: ResumeBullet
    let skills: [Skill]
    let position: (index: Int, count: Int)
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var newMetric = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .top, spacing: Spacing.space2) {
                TextField(
                    "Bullet", text: $bullet.text, prompt: Text("Cut p95 latency of the tracking API by 40%"),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .labelsHidden()
                Menu {
                    Button("Move up") { move(-1) }.disabled(position.index == 0)
                    Button("Move down") { move(1) }.disabled(position.index >= position.count - 1)
                    Divider()
                    Button("Remove bullet", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("Bullet actions")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            FlowLayout(spacing: 6) {
                ForEach(bullet.metrics, id: \.self) { metric in
                    removable {
                        MetricChip(text: metric)
                    } remove: {
                        bullet.metrics.removeAll { $0 == metric }
                    }
                }
                TextField("Add a number", text: $newMetric, prompt: Text("Add a number, like 40% faster"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(addMetric)
                ForEach(bullet.skills, id: \.self) { name in
                    removable {
                        SkillChip(skill: skills.first { $0.name == name } ?? Skill(name: name))
                    } remove: {
                        bullet.skills.removeAll { $0 == name }
                    }
                }
                skillMenu
            }
        }
        .padding(Spacing.space3)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
    }

    private var skillMenu: some View {
        let unused = skills.filter { !bullet.skills.contains($0.name) }
        return Menu {
            if unused.isEmpty {
                Text(skills.isEmpty ? "Add skills in the Skills section first" : "Every skill is already here")
            }
            ForEach(unused) { skill in
                Button(skill.level == .proven ? skill.name : "\(skill.name) (Can discuss)") {
                    bullet.skills.append(skill.name)
                }
            }
        } label: {
            Label("Skill", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func removable(@ViewBuilder _ chip: () -> some View, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            chip()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Color(.inkSecondary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
        }
    }

    private func addMetric() {
        let metric = newMetric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metric.isEmpty, !bullet.metrics.contains(metric) else { return }
        bullet.metrics.append(metric)
        newMetric = ""
    }
}
