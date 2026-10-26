import MasterResume
import SwiftUI
import Tailoring

/// "Be ready to discuss" (SPEC §5.3, Flagging; design `Build.dc.html`): a Stretch build's gap
/// bullets, each with the requirement it answers and the Can-discuss skills it names. The PDF never
/// marks them, so this is where they show. The switch is the same setting as Settings, General.
struct ReadyToDiscussView: View {
    @Environment(AppModel.self) private var model
    let build: BuildRecord
    /// Every line of the build, in the trace's order.
    let lines: [TailoredBullet]
    let master: MasterResume?
    @Binding var selected: Int?

    private var gaps: [(index: Int, bullet: TailoredBullet)] {
        lines.enumerated().filter { $0.element.gap }.map { ($0.offset, $0.element) }
    }

    private var canDiscuss: [Skill] { master?.skills.filter { $0.level == .canDiscuss } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text("Be ready to discuss").font(TypeStyle.headline).foregroundStyle(Color(.ink))
                Spacer()
                Toggle("Stretch mode", isOn: enabled).toggleStyle(.switch).controlSize(.mini)
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            }
            if gaps.isEmpty {
                Text(emptyMessage).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(gaps, id: \.index) { gap in row(gap.index, gap.bullet) }
            }
        }
    }

    private func row(_ index: Int, _ bullet: TailoredBullet) -> some View {
        Button {
            selected = index
        } label: {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(bullet.text).font(TypeStyle.body).foregroundStyle(Color(.ink))
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if let covers = bullet.covers {
                    Text("Covers: \(covers)").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                let named = Self.skills(in: bullet.text, from: canDiscuss)
                if !named.isEmpty {
                    FlowLayout(spacing: 6) { ForEach(named, id: \.id) { SkillChip(skill: $0) } }
                }
            }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card).fill(Color(selected == index ? .accentTint : .surface))
            )
            .overlay(GapOutline())
        }
        .buttonStyle(.plain)
    }

    private var emptyMessage: String {
        let example = canDiscuss.first.map { ", like \($0.name)," } ?? ""
        if build.mode == .stretch {
            return "Nothing here. No requirement left uncovered was one your Can-discuss skills answer."
        }
        if model.stretch.enabled {
            return
                "Stretch mode is on. Build again in Stretch to add lines for Can discuss skills\(example) and they'll be listed here to prepare."
        }
        return
            "Nothing here. Stretch mode is off, so this resume only claims Proven skills. Turn it on to include Can discuss skills\(example) and they'll be listed here to prepare."
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.stretch.enabled },
            set: { on in
                var stretch = model.stretch
                stretch.enabled = on
                Task { await model.save(stretch) }
            })
    }

    /// Your Can-discuss skills a line names, for its chips.
    static func skills(in text: String, from skills: [Skill]) -> [Skill] {
        skills.filter {
            text.range(
                of: "\\b\(NSRegularExpression.escapedPattern(for: $0.name))\\b",
                options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}

/// The dashed outline Can-discuss chips use, on anything Stretch mode added.
struct GapOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card)
            .strokeBorder(Color(.chipDiscussBorder), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }
}
