import Screening
import Store
import SwiftUI

/// Where you may work, per country, and whether you hold a security clearance (SPEC §5.9). Kept
/// only on this Mac (`private_setting`), never synced and never sent to an AI provider.
struct WorkAuthorizationView: View {
    @Environment(AppModel.self) private var model
    @State private var profile = WorkProfile()
    @State private var loaded = false

    var body: some View {
        FormSection(
            title: "Work authorization",
            caption:
                "Screening uses this to skip jobs you couldn't take. A country you leave unset never rules a job out."
        ) {
            Label("Stays on this Mac", systemImage: "lock.fill")
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary))
        } content: {
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Grid(alignment: .leading, horizontalSpacing: Spacing.space4, verticalSpacing: Spacing.space2) {
                    ForEach(Country.allCases, id: \.self) { country in
                        GridRow {
                            Text(country.displayName).font(TypeStyle.body).foregroundStyle(Color(.ink))
                            Picker(country.displayName, selection: statusBinding(country)) {
                                Text("Not set").tag(WorkProfile.Status?.none)
                                ForEach(WorkProfile.Status.allCases, id: \.self) { status in
                                    Text(status.title).tag(WorkProfile.Status?.some(status))
                                }
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                }
                Toggle("I hold an active security clearance", isOn: $profile.hasClearance).toggleStyle(.checkbox)
                HStack(spacing: Spacing.space4) {
                    Text("Student status").font(TypeStyle.body).foregroundStyle(Color(.ink))
                    Picker("Student status", selection: $profile.enrolment) {
                        Text("Not set").tag(WorkProfile.Enrolment?.none)
                        Text("Currently a student").tag(WorkProfile.Enrolment?.some(.student))
                        Text("Graduated").tag(WorkProfile.Enrolment?.some(.graduated))
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
                Text(
                    "For internships and co-ops that ask for a current student. Graduated rules those out; not set takes them as open to you."
                )
                .font(TypeStyle.callout).foregroundStyle(Color(.inkSecondary)).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .task {
            guard !loaded else { return }
            profile = model.workProfile
            loaded = true
        }
        .onChange(of: profile) { _, changed in
            guard loaded else { return }
            Task { await model.save(changed) }
        }
    }

    private func statusBinding(_ country: Country) -> Binding<WorkProfile.Status?> {
        Binding(get: { profile.authorization[country] }, set: { profile.authorization[country] = $0 })
    }
}
