import Store
import SwiftUI

/// A verdict as the design draws it: colour, icon and word together, never colour alone.
struct VerdictPill: View {
    let verdict: Verdict
    var large = false

    var body: some View {
        Label(verdict.title, systemImage: verdict.symbol)
            .font(large ? TypeStyle.headline : TypeStyle.callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, large ? Spacing.space3 : Spacing.space2)
            .frame(height: large ? 28 : 22)
            .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch verdict {
        case .yes: Color(.yes)
        case .maybe: Color(.maybe)
        case .no: Color(.no)
        }
    }

    private var background: Color {
        switch verdict {
        case .yes: Color(.yesBg)
        case .maybe: Color(.maybeBg)
        case .no: Color(.noBg)
        }
    }
}
