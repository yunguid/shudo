import SwiftUI

struct TodayView: View {
    @StateObject private var vm = TodayViewModel(api: APIService(
        supabaseUrl: AppConfig.supabaseURL,
        supabaseAnonKey: AppConfig.supabaseAnonKey,
        sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
    ))

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.xl) {
                    header

                    SectionCard { macroSection }

                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Meals")
                            if vm.entries.isEmpty {
                                Text("No entries yet.")
                                    .foregroundStyle(Design.Color.muted)
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(vm.entries) { entry in
                                        EntryCard(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 40)
            }
            .overlay(alignment: .bottom) {
                if vm.isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Analyzing…")
                            .font(.subheadline)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("shudo")
                        .font(.title3.weight(.semibold))
                        .padding(.leading, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign Out") { AuthSessionManager.shared.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        vm.isPresentingComposer = true
                    } label: {
                        Label("Add Entry", systemImage: "plus.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $vm.isPresentingComposer) {
            EntryComposerView { text, audioURL, image in
                await vm.submitEntry(text: text, audioURL: audioURL, image: image)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Date.now, style: .date).font(.title2.weight(.semibold))
            Text(TimeZone.autoupdatingCurrent.identifier)
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
        }
    }

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Today’s Macros")

            if let profile = vm.profile {
                MacroRingsView(target: profile.dailyMacroTarget, current: vm.todayTotals)
                    .frame(height: 220)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Macro progress")
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.l)
                    .fill(Design.Color.fill)
                    .frame(height: 220)
            }

            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
