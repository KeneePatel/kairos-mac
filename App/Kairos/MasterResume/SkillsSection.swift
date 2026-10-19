import MasterResume
import SwiftUI

/// Skills in two groups: Proven (solid chips) and Can discuss (dashed). Drag a chip to reorder it or
/// to move it to the other group; click one to edit it.
struct SkillsSection: View {
    @Environment(ResumeModel.self) private var model
    @State private var adding = false
    @State private var editing: Skill?

    var body: some View {
        FormSection(
            title: "Skills", caption: "Resumes only claim Proven skills. Can discuss ones appear only in Stretch mode."
        ) {
            PillButton(title: "Add skill", symbol: "plus") { adding = true }
                .popover(isPresented: $adding, arrowEdge: .bottom) {
                    SkillEditor(skill: Skill(name: ""), isNew: true) { adding = false }
                }
        } content: {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                group(.proven, title: "Proven", caption: "used at work or in a shipped project")
                group(.canDiscuss, title: "Can discuss", caption: "known, not shipped")
            }
        }
    }

    private func group(_ level: SkillLevel, title: String, caption: String) -> some View {
        let skills = model.resume.skills.filter { $0.level == level }
        return VStack(alignment: .leading, spacing: Spacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                Text(title).font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Text("\(skills.count) · \(caption)").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .monospacedDigit()
            }
            FlowLayout(spacing: 6) {
                ForEach(skills) { skill in
                    SkillChip(skill: skill)
                        .onTapGesture { editing = skill }
                        .popover(
                            isPresented: Binding(get: { editing?.id == skill.id }, set: { if !$0 { editing = nil } })
                        ) {
                            SkillEditor(skill: skill, isNew: false) { editing = nil }
                        }
                        .draggable(skill.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            drop(items, before: skill.id, level: level)
                        }
                        .contextMenu {
                            Button(level == .proven ? "Mark as Can discuss" : "Mark as Proven") {
                                var changed = skill
                                changed.level = level == .proven ? .canDiscuss : .proven
                                Task { await model.save(changed) }
                            }
                            Button("Edit…") { editing = skill }
                            Divider()
                            Button("Remove \(skill.name)", role: .destructive) {
                                Task { await model.deleteSkill(skill.id) }
                            }
                        }
                }
                if skills.isEmpty {
                    Text(level == .proven ? "Add the skills you've used at work." : "Drag a skill here, or add one.")
                        .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                        .frame(height: 24)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in drop(items, before: nil, level: level) }
        }
    }

    private func drop(_ items: [String], before target: UUID?, level: SkillLevel) {
        guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return }
        Task { await model.moveSkill(id, before: target, level: level) }
    }
}

/// Proven: solid fill. Can discuss: dashed outline, no fill. The words carry the meaning too, in
/// the group titles, so the dashes are never the only signal.
struct SkillChip: View {
    let skill: Skill

    var body: some View {
        Text(skill.name)
            .font(TypeStyle.callout)
            .foregroundStyle(Color(skill.level == .proven ? .ink : .ink2))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background {
                if skill.level == .proven {
                    Capsule().fill(Color(.chipProvenBg))
                }
            }
            .overlay {
                if skill.level == .canDiscuss {
                    Capsule().strokeBorder(Color(.chipDiscussBorder), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
            .help(skill.category.isEmpty ? skill.name : "\(skill.name) · \(skill.category)")
            .accessibilityLabel("\(skill.name), \(skill.level == .proven ? "Proven" : "Can discuss")")
    }
}

/// Name, category and level for a new or existing skill.
private struct SkillEditor: View {
    @Environment(ResumeModel.self) private var model
    @State var skill: Skill
    let isNew: Bool
    let done: () -> Void
    @FocusState private var nameFocused: Bool

    private static let categories = ["Language", "Framework", "Database", "Cloud", "Tool", "Practice", "Other"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            LabeledField(title: "Skill") {
                TextField("Skill", text: $skill.name, prompt: Text("PostgreSQL"))
                    .focused($nameFocused)
                    .onSubmit(save)
            }
            LabeledField(title: "Category", optional: true) {
                Picker("Category", selection: $skill.category) {
                    Text("None").tag("")
                    ForEach(Self.categories, id: \.self) { Text($0).tag($0) }
                    if !skill.category.isEmpty && !Self.categories.contains(skill.category) {
                        Text(skill.category).tag(skill.category)
                    }
                }
            }
            Picker("Level", selection: $skill.level) {
                Text("Proven").tag(SkillLevel.proven)
                Text("Can discuss").tag(SkillLevel.canDiscuss)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                if !isNew {
                    Button("Remove", role: .destructive) {
                        Task { await model.deleteSkill(skill.id) }
                        done()
                    }
                }
                Spacer()
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(skill.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Spacing.space4)
        .frame(width: 280)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard !skill.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let skill = self.skill
        Task { await model.save(skill) }
        done()
    }
}
