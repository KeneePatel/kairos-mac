import MasterResume
import SwiftUI
import Tailoring

/// Settings › General › Stretch mode (SPEC §5.3, ADR-008): off until you turn it on, with what it
/// changes and what it never does.
struct StretchModeView: View {
    @Environment(AppModel.self) private var model

    private var canDiscuss: [Skill] { model.resume?.resume.skills.filter { $0.level == .canDiscuss } ?? [] }

    var body: some View {
        FormSection(
            title: "Stretch mode", caption: "Off unless you turn it on. Applies to builds you start afterwards."
        ) {
            Toggle("Stretch", isOn: enabled).toggleStyle(.switch).labelsHidden()
        } content: {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                point(
                    "lock.doc",
                    "Off: every line comes from your master resume, and only your Proven skills appear.")
                point(
                    "plus.bubble",
                    "On: each role may get extra lines for requirements your resume doesn't show yet, using only the skills you marked Can discuss. Numbers in them may be estimates."
                )
                point(
                    "list.bullet.clipboard",
                    "Every extra line is listed under “Be ready to discuss” on its build, so you can prepare. The PDF doesn't mark them."
                )
                point(
                    "hand.raised",
                    "Never, in any mode: other employers, titles or dates, degrees or certifications you don't have, more years than yours, or anything about the company you're applying to."
                )
                Picker("Extra lines per role", selection: perRole) {
                    Text("Up to 1").tag(1)
                    Text("Up to 2").tag(2)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(!model.stretch.enabled)
                if model.stretch.enabled, canDiscuss.isEmpty {
                    Label(
                        "You have no Can-discuss skills yet, so builds won't stretch. Mark some in Master resume, Skills.",
                        systemImage: "info.circle"
                    )
                    .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            .padding(Spacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color(.inkSecondary)).frame(width: 20)
        }
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

    private var perRole: Binding<Int> {
        Binding(
            get: { max(1, model.stretch.limit) },
            set: { count in
                var stretch = model.stretch
                stretch.perRole = count
                Task { await model.save(stretch) }
            })
    }
}
