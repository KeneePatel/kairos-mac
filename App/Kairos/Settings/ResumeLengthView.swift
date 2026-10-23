import SwiftUI
import Tailoring

/// Settings › General › Resume length: one page, or two when a job's evidence needs them. Off
/// unless you turn it on.
struct ResumeLengthView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        FormSection(
            title: "Two pages when needed",
            caption: "Off unless you turn it on. Applies to builds you start afterwards."
        ) {
            Toggle("Two pages when needed", isOn: twoPages).toggleStyle(.switch).labelsHidden()
        } content: {
            Text(
                "Resumes fill one page. With this on, a build uses a second page only when what answers the posting runs at least half a page past the first, so a second page is never padding."
            )
            .font(TypeStyle.body).foregroundStyle(Color(.ink2)).fixedSize(horizontal: false, vertical: true)
            .padding(Spacing.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color(.surfaceGrouped)))
        }
    }

    private var twoPages: Binding<Bool> {
        Binding(
            get: { model.pages.twoPagesWhenNeeded },
            set: { on in Task { await model.save(PageSettings(twoPagesWhenNeeded: on)) } })
    }
}
