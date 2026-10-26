import SwiftUI

/// What a column or a pane shows when it has nothing (UI v2): a `title2` title, one `body` line in
/// `ink-secondary` that says what happens next or where things are, and at most one button.
/// Centred, no icon.
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
