import SwiftUI

/// Settings, in the design's tabs. AI providers is built; the others arrive with their tasks.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case schedule = "Schedule"
        case ai = "AI providers"
        case account = "Account"
        var id: Self { self }
    }

    @Environment(AISettingsModel.self) private var model
    @State private var tab = Tab.ai

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.vertical, Spacing.space3)
            Divider()
            switch tab {
            case .ai:
                ProvidersView()
            case .general, .schedule, .account:
                ContentUnavailableView(
                    tab.rawValue, systemImage: "gearshape",
                    description: Text("This part of Settings isn't built yet.").foregroundStyle(Color(.inkSecondary)))
            }
        }
        .background(Color(.surface))
        .navigationTitle("Settings")
        .task { await model.refreshUsage() }
    }
}
