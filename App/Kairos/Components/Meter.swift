import SwiftUI

/// How much of something is left, as the menu bar design's progress bar: a 6 pt capsule, the
/// separator track and an accent fill, amber when little is left. Always shown with words, so it
/// never rests on colour alone.
struct Meter: View {
    /// 0 to 1.
    let left: Double

    var body: some View {
        Capsule().fill(Color(.separator))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(left < 0.15 ? Color(.maybe) : Color(.accent))
                        .frame(width: proxy.size.width * min(1, max(0, left)))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
    }
}
