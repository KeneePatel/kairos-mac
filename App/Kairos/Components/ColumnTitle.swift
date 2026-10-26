import SwiftUI

/// The list column's title (UI v2): the section's name in `page-title` with one `callout` line of
/// counts beneath, `space-7` from the top and `space-6` from the sides. It replaces the window title
/// on list screens; the window keeps a short title for Mission Control.
struct ColumnTitle: View {
    let title: String
    /// "247 to decide · 283 need a full read", under 60 characters.
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(title).font(TypeStyle.pageTitle).foregroundStyle(Color(.ink))
            Text(line).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).monospacedDigit()
                .lineLimit(2)
        }
        .padding(.top, Spacing.space7)
        .padding(.horizontal, Spacing.space6)
        .padding(.bottom, Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
