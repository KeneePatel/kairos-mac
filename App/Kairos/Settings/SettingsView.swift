import SwiftUI

/// Settings, in the design's tabs. General (Stretch mode), Search and AI providers are built; the
/// others arrive with their tasks.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case search = "Search"
        case schedule = "Schedule"
        case ai = "AI providers"
        case account = "Account"
        var id: Self { self }
    }

    @Environment(AISettingsModel.self) private var model
    @Environment(AppModel.self) private var app

    /// Kept on the app model, so Filtered out can open Search directly.
    private var tab: Binding<Tab> { Binding(get: { app.settingsTab }, set: { app.settingsTab = $0 }) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 460)
            .padding(.vertical, Spacing.space3)
            Divider()
            switch tab.wrappedValue {
            case .ai:
                ProvidersView()
            case .search:
                SearchPreferencesView()
            case .general:
                ScrollView {
                    StretchModeView()
                        .padding(Spacing.space6)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .schedule, .account:
                ContentUnavailableView(
                    tab.wrappedValue.rawValue, systemImage: "gearshape",
                    description: Text("This part of Settings isn't built yet.").foregroundStyle(Color(.inkSecondary)))
            }
        }
        .background(Color(.surface))
        .navigationTitle("Settings")
        .task { await model.refreshUsage() }
    }
}
