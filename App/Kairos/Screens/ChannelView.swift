import JobSources
import Store
import SwiftUI

/// One search channel's page (job collection v3, C4): whether it's set up, what it found this
/// week, its plan, and what to change. Google Jobs shows its places and its turns; Adzuna shows
/// its leads and the boards found behind them, with its credit.
struct ChannelView: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let facts: AppModel.ChannelFacts
    var changeKey: () -> Void = {}
    @State private var removing = false

    private var source: Source? { channel.kind.flatMap(model.source(of:)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                header
                if source != nil {
                    thisWeek
                    if channel == .googleJobs { plan }
                    if channel == .adzuna { leads }
                }
                about
            }
            .padding(.horizontal, Spacing.space7).padding(.vertical, Spacing.space6)
            .frame(maxWidth: Spacing.formWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.surface))
        .navigationTitle(channel.title)
        .confirmationDialog("Remove \(channel.title)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let source { Task { await model.remove(source) } } }
        } message: {
            Text("Kairos stops asking it. Its jobs stay; its keys are forgotten.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(channel.purpose).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
            Text(channel.title).font(TypeStyle.title1).foregroundStyle(Color(.ink))
            HStack(spacing: Spacing.space2) {
                Circle().fill(
                    source == nil ? Color(.inkSecondary) : source?.enabled == true ? Color(.yes) : Color(.inkSecondary)
                )
                .frame(width: 8, height: 8).accessibilityHidden(true)
                Text(statusLine).font(TypeStyle.callout).foregroundStyle(Color(.ink2))
            }
            HStack(spacing: Spacing.space2) {
                if let source {
                    Button {
                        Task { await model.setEnabled(!source.enabled, for: source) }
                    } label: {
                        ActionLabel(title: source.enabled ? "Pause" : "Resume", key: "P")
                    }
                    Button(channel == .adzuna ? "Change keys…" : channel == .himalayas ? "Change key…" : "Change key…")
                    {
                        changeKey()
                    }
                    Button("Remove", role: .destructive) { removing = true }
                } else {
                    Button(channel == .adzuna ? "Add Adzuna…" : "Add \(channel.title)…") { changeKey() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, Spacing.space3)
        }
    }

    private var statusLine: String {
        guard let source else { return "Not set up" }
        var parts = [source.enabled ? "Active" : "Paused by you"]
        if let checked = source.lastRunAt { parts.append("checked \(SourcesTable.checked(checked))") }
        if let failure = model.failures[source.id] { parts.append("can't reach · \(failure)") }
        return parts.joined(separator: " · ")
    }

    private var thisWeek: some View {
        section("This week") {
            let week = model.jobsThisWeek(from: channel)
            row("Jobs found", "\(week.found) at your roles, \(week.kept) still open for you")
            if let source, let used = facts.requests[source.kind] {
                row("Searches", "\(used.today) today · \(used.month) this month")
            }
            if channel == .adzuna {
                row(
                    "Leads",
                    "\(facts.leads) postings at \(facts.leadCompanies) compan\(facts.leadCompanies == 1 ? "y" : "ies"), kept 30 days"
                )
            }
        }
    }

    /// Google Jobs's plan: the pairs, the share, and how often each comes round.
    private var plan: some View {
        let places = model.searchPreferences.effectivePlaces
        let phrases = model.searchPreferences.roleMatcher.googlePhrases
        let pairs = phrases.count * (places.count + model.searchPreferences.countries.count)
        let share = GoogleJobsSource.budget.day
        let days = pairs == 0 ? 0 : Int((Double(pairs) / Double(share)).rounded(.up))
        return section("The plan") {
            row("Roles", phrases.isEmpty ? "none: choose roles in Settings, Search" : phrases.joined(separator: " · "))
            row("Places", places.map(\.displayName).joined(separator: " · ") + " · remote in each country")
            row(
                "Searches",
                "\(share) a day, \(GoogleJobsSource.budget.month) a month on SerpApi's free plan · \(pairs) role-and-place pairs, each about every \(days) day\(days == 1 ? "" : "s")"
            )
            Button("Change places in Settings, Search") {
                model.settingsTab = .search
                model.section = .settings
            }
        }
    }

    /// Adzuna's leads: what Kairos learned from it, and its credit, as its terms ask.
    private var leads: some View {
        section("Leads and boards") {
            row("Boards found behind leads", "\(facts.boardsFromLeads), watched from then on")
            row(
                "What a lead is",
                "A posting Adzuna sent as a snippet: a company name to look up on boards Kairos reads in full. Leads never become jobs."
            )
            AdzunaCredit()
        }
    }

    private var about: some View {
        section("About") {
            switch channel {
            case .googleJobs:
                Text(
                    "Each job keeps the page Google took it from; Apply goes to the employer's own page when Google lists one. Boards Kairos reads behind those links are watched from then on."
                )
            case .himalayas:
                Text(
                    "Jobs say \"via Himalayas\" and open on Himalayas; Apply opens the application link unchanged, as its terms ask. Boards behind those links are watched from then on."
                )
            case .adzuna:
                Text(
                    "Kairos never opens an Adzuna advert itself: advertisers pay for those clicks. Adzuna's free plan allows 250 searches a day; Kairos keeps under 200."
                )
            case .boards: EmptyView()
            }
        }
        .font(TypeStyle.body).foregroundStyle(Color(.ink2))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title).font(TypeStyle.title2).foregroundStyle(Color(.ink))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
            Text(label).font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).frame(
                width: 120, alignment: .leading)
            Text(value).font(TypeStyle.body).foregroundStyle(Color(.ink)).fixedSize(horizontal: false, vertical: true)
        }
    }
}
