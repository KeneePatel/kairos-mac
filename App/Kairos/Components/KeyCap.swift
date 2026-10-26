import SwiftUI

/// The key that triggers a control, drawn on it (UI v2): `caption` on `surface-raised` with an
/// `outline` border, 16 pt tall. Hidden from assistive tech; the control's shortcut carries it.
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

/// A decision button with its key shown at the trailing edge: one `accent` primary per view, the
/// rest bordered. The key cap is drawn; the real shortcut is the Job menu's and the list's.
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
