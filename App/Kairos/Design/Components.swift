import KairosKit
import Screening
import SwiftUI

// The design system's components (design/kairos/components), built from native controls and the
// generated tokens. Colours come only from the asset catalog: Color(.ink), Color(.yes)…

extension Verdict {
    var symbol: String {
        switch self {
        case .yes: "checkmark.circle"
        case .maybe: "circle.lefthalf.filled"
        case .no: "minus.circle"
        }
    }

    var color: Color {
        switch self {
        case .yes: Color(.yes)
        case .maybe: Color(.maybe)
        case .no: Color(.no)
        }
    }

    var background: Color {
        switch self {
        case .yes: Color(.yesBg)
        case .maybe: Color(.maybeBg)
        case .no: Color(.noBg)
        }
    }
}

/// A verdict as the design draws it: colour, icon and word together, never colour alone.
struct VerdictPill: View {
    let verdict: Verdict
    var large = false

    var body: some View {
        Label(verdict.title, systemImage: verdict.symbol)
            .font(large ? TypeStyle.headline : TypeStyle.callout.weight(.semibold))
            .foregroundStyle(verdict.color)
            .padding(.horizontal, large ? Spacing.space3 : 6)
            .frame(height: large ? 28 : 20)
            .background(Capsule().fill(verdict.background))
    }
}

/// The key that triggers a control, drawn on it. Hidden from assistive tech: the control's own
/// shortcut carries it.
struct KeyCap: View {
    let key: String
    /// On the accent button the cap reverses onto the fill.
    var onAccent = false

    var body: some View {
        Text(key)
            .font(TypeStyle.caption)
            .foregroundStyle(onAccent ? Color.white : Color(.inkSecondary))
            .padding(.horizontal, Spacing.space1)
            .frame(minWidth: 16, minHeight: 16)
            .background(
                RoundedRectangle(cornerRadius: Radius.keycap)
                    .fill(onAccent ? Color.white.opacity(0.18) : Color(.surfaceRaised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.keycap)
                    .strokeBorder(onAccent ? Color.white.opacity(0.45) : Color(.outline), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

/// A decision button's label: its title and, at the trailing edge, its key.
struct ActionLabel: View {
    let title: String
    let key: String?
    var primary = false

    var body: some View {
        HStack(spacing: Spacing.space2) {
            Text(title)
            if let key { KeyCap(key: key, onAccent: primary) }
        }
    }
}

/// A section's content: the list column, a hairline, and the pane for what's selected. One panel,
/// not a third navigation column, so a pane can take two thirds of the window.
struct ListPaneLayout<ListContent: View, PaneContent: View>: View {
    var listWidth: CGFloat = Spacing.listWidth
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let pane: () -> PaneContent

    var body: some View {
        HStack(spacing: 0) {
            list().frame(width: listWidth).frame(maxHeight: .infinity)
            Divider()
            pane().frame(minWidth: Spacing.paneMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.surface))
    }
}

/// The list column's title: the section's name and one line of counts.
struct ColumnTitle: View {
    let title: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(title).font(TypeStyle.pageTitle).foregroundStyle(Color(.ink))
            Text(line).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit().lineLimit(2)
        }
        .padding(.top, Spacing.space7)
        .padding(.horizontal, Spacing.space6)
        .padding(.bottom, Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group's or a column's header in a list: caption, secondary ink, with a count.
struct GroupHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack {
            Text(title.uppercased()).font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary))
            if let count {
                Text("\(count)").font(TypeStyle.caption).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
            }
            Spacer()
        }
    }
}

/// How far something is, or how much is left: a 6 pt capsule on the separator track. Always shown
/// beside words, so it never rests on colour alone.
struct ProgressMeter: View {
    /// 0 to 1.
    let fraction: Double
    /// Amber after a stop, or when little is left.
    var warning = false

    var body: some View {
        Capsule().fill(Color(.separator))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(warning ? Color(.maybe) : Color(.accent))
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}

/// What a column or pane shows when it has nothing: a title, one line on what happens next, and
/// at most one button. Centred, no icon.
struct EmptyState<Action: View>: View {
    let title: String
    let line: String
    @ViewBuilder var action: Action

    init(_ title: String, _ line: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.line = line
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Spacing.space2) {
            Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink)).multilineTextAlignment(.center)
            Text(line).font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            action.padding(.top, Spacing.space2)
        }
        .padding(Spacing.space7)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(_ title: String, _ line: String) {
        self.init(title, line) { EmptyView() }
    }
}

/// A raised card: `surface-raised` with a hairline, never a filled box without an edge.
struct Card<Content: View>: View {
    var padding: CGFloat = Spacing.space4
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.card).fill(Color(.surfaceRaised)))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color(.separator), lineWidth: 1))
    }
}

/// A titled section of a pane: a `title2` heading and its content, `space-6` apart from the next.
struct PaneSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Spacer()
                if let trailing {
                    Text(trailing).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                }
            }
            content()
        }
    }
}

/// A skill chip: Proven solid, Can discuss dashed.
struct SkillChip: View {
    let name: String
    var proven = true

    var body: some View {
        Text(name)
            .font(TypeStyle.callout)
            .foregroundStyle(Color(.ink))
            .padding(.horizontal, Spacing.space2)
            .frame(height: 22)
            .background(Capsule().fill(proven ? Color(.chipProvenBg) : Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    proven ? Color.clear : Color(.chipDiscussBorder),
                    style: StrokeStyle(lineWidth: 1, dash: proven ? [] : [3, 2])))
    }
}

/// A label and its value on one line, for inspectors.
struct FactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Spacer(minLength: Spacing.space3)
            Text(value).font(TypeStyle.callout).foregroundStyle(Color(.ink)).multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
    }
}

/// Wraps its children onto as many lines as they need: chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.space2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + line), points)
    }
}

/// A posting's Markdown as blocks: headings, paragraphs, lists; bold, italics and links inline.
/// The text is the employer's, so links open in the browser and nothing else is interpreted.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(_, let text):
                    inline(text).font(TypeStyle.headline).foregroundStyle(Color(.ink)).padding(.top, Spacing.space2)
                case .paragraph(let text):
                    inline(text).font(TypeStyle.body).foregroundStyle(Color(.ink2))
                case .item(let marker, let depth, let text):
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Text(marker).monospacedDigit().foregroundStyle(Color(.inkSecondary))
                        inline(text).foregroundStyle(Color(.ink2))
                    }
                    .font(TypeStyle.body)
                    .padding(.leading, CGFloat(depth) * Spacing.space4)
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let attributed = try? AttributedString(markdown: text, options: options) else { return Text(text) }
        return Text(attributed)
    }
}

extension Date {
    /// "Today", "Yesterday", "Mon", or "Oct 12": short enough for a row.
    var shortDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}
