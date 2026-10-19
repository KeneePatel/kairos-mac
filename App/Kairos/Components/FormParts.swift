import MasterResume
import SwiftUI

/// A label above a full-width bordered field, an "Optional" tag when it is, and an error under it.
/// Fields read as boxes to type or paste into (the Add company sheet taught us that).
struct LabeledField<Field: View>: View {
    let title: String
    var optional = false
    var error: String?
    @ViewBuilder let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: Spacing.space1) {
                Text(title).font(TypeStyle.callout.weight(.semibold)).foregroundStyle(Color(.ink))
                if optional {
                    Text("Optional").font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
            }
            field
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(TypeStyle.callout)
                    .foregroundStyle(Color(.error))
            }
        }
    }
}

/// A section of a long form: a title, a caption, an optional control on the right, then content.
struct FormSection<Accessory: View, Content: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(TypeStyle.title3).foregroundStyle(Color(.ink))
                    if let caption {
                        Text(caption).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                    }
                }
                Spacer()
                accessory
            }
            content
        }
    }
}

extension FormSection where Accessory == EmptyView {
    init(title: String, caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, caption: caption, accessory: { EmptyView() }, content: content)
    }
}

/// A secondary pill button ("Add skill"): control fill, never the view's one primary action.
struct PillButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(TypeStyle.body.weight(.medium))
                .padding(.horizontal, Spacing.space3)
                .frame(height: 28)
                .background(Capsule().fill(Color(.controlFill)))
                .foregroundStyle(Color(.ink))
        }
        .buttonStyle(.plain)
    }
}

/// A month and year, either of which may be left empty ("—").
struct MonthField: View {
    let title: String
    var optional = true
    @Binding var value: YearMonth?
    @State private var yearText = ""

    private static let months = Calendar(identifier: .gregorian).shortMonthSymbols

    var body: some View {
        LabeledField(title: title, optional: optional) {
            HStack(spacing: 6) {
                Picker(title, selection: monthBinding) {
                    Text("—").tag(0)
                    ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) }
                }
                .frame(width: 84)
                TextField("Year", text: $yearText, prompt: Text("Year"))
                    .frame(width: 64)
                    .monospacedDigit()
            }
        }
        .onAppear { yearText = value.map { String($0.year) } ?? "" }
        .onChange(of: yearText) { _, text in
            if text.isEmpty {
                value = nil
            } else if text.count == 4, let year = Int(text), let month = YearMonth(year: year, month: value?.month ?? 1)
            {
                value = month
            }
        }
        .onChange(of: value) { _, new in
            let text = new.map { String($0.year) } ?? ""
            if text != yearText && !(new == nil && yearText.count < 4) { yearText = text }
        }
    }

    private var monthBinding: Binding<Int> {
        Binding(
            get: { value?.month ?? 0 },
            set: { month in
                if month == 0 {
                    value = nil
                    yearText = ""
                } else {
                    let year = value?.year ?? Int(yearText) ?? YearMonth.containing(Date()).year
                    value = YearMonth(year: year, month: month)
                    yearText = String(value?.year ?? year)
                }
            })
    }
}

/// Lays chips out in rows, wrapping at the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
