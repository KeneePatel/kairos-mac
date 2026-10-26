import SwiftUI

/// Settings (UI v2): a list of pages on the left and the chosen page on the right. General
/// (resume length, Stretch mode), Search and AI are built; Account arrives with accounts (R3).
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case search = "Search"
        case ai = "AI"
        case account = "Account"
        var id: Self { self }

        var caption: String {
            switch self {
            case .general: "Resume length and Stretch mode"
            case .search: "Roles, titles, levels, where, limits, verdict, work authorization"
            case .ai: "Providers, keys, which model does what, privacy"
            case .account: "Sign-in and sync, when accounts arrive"
            }
        }
    }

    @Environment(AISettingsModel.self) private var model
    @Environment(AppModel.self) private var app

    /// Kept on the app model, so Filtered out can open Search directly.
    private var tab: Binding<Tab?> {
        Binding(get: { app.settingsTab }, set: { if let tab = $0 { app.settingsTab = tab } })
    }

    var body: some View {
        ListPaneLayout(listWidth: 232) {
            VStack(spacing: 0) {
                ColumnTitle(title: "Settings", line: "This Mac only · keys never leave it")
                List(selection: tab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: Spacing.space3, bottom: 0, trailing: Spacing.space3))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        } pane: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(app.settingsTab.rawValue).font(TypeStyle.title1).foregroundStyle(Color(.ink))
                    Text(app.settingsTab.caption).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
                }
                .padding(.horizontal, Spacing.space7)
                .padding(.top, Spacing.space6)
                .padding(.bottom, Spacing.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                page
            }
        }
        .navigationTitle("Settings")
        .task { await model.refreshUsage() }
    }

    @ViewBuilder private var page: some View {
        switch app.settingsTab {
        case .ai:
            ProvidersView()
        case .search:
            SearchPreferencesView()
        case .general:
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space6) {
                    ResumeLengthView()
                    StretchModeView()
                }
                .padding(Spacing.space6)
                .frame(maxWidth: Spacing.formWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .account:
            VStack(spacing: Spacing.space2) {
                Text("No account yet").font(TypeStyle.title2).foregroundStyle(Color(.ink))
                Text("Kairos works on this Mac alone for now. Sign-in and sync come with accounts.")
                    .font(TypeStyle.body).foregroundStyle(Color(.inkSecondary)).multilineTextAlignment(.center)
            }
            .padding(Spacing.space7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
