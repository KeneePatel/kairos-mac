import SwiftUI

/// A section's content area (UI v2): the list column on the left, a hairline, and the pane for the
/// selected item filling the rest. One content panel, not a third navigation column, so a job
/// pane can take two thirds of the window.
struct ListPaneLayout<ListContent: View, PaneContent: View>: View {
    var listWidth: CGFloat = Spacing.listWidth
    @ViewBuilder let list: () -> ListContent
    @ViewBuilder let pane: () -> PaneContent

    var body: some View {
        HStack(spacing: 0) {
            list()
                .frame(width: listWidth)
                .frame(maxHeight: .infinity)
            Divider()
            pane()
                .frame(minWidth: Spacing.paneMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.surface))
    }
}
