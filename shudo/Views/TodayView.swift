import SwiftUI

struct ContentView: View {
    @StateObject private var vm = TodayViewModel(api: APIService(
        supabaseUrl: AppConfig.supabaseURL,
        supabaseAnonKey: AppConfig.supabaseAnonKey,
        sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
    ))

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    macroSection
                    Divider()
                    entryList
                }
                .padding(20)
            }
            .overlay(alignment: .bottom) {
                if vm.isSubmitting {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Analyzing…")
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") { AuthSessionManager.shared.signOut() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(action: { vm.isPresentingComposer = true }) {
                        Label("Add Entry", systemImage: "plus.circle.fill").labelStyle(.titleAndIcon)
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading) {
                Text(Date.now, style: .date).font(.title2.weight(.semibold))
                Text(TimeZone.autoupdatingCurrent.identifier)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Today's Macros").font(.headline)
            if let p = vm.profile {
                MacroRingsView(target: p.dailyMacroTarget, current: vm.todayTotals)
                    .frame(height: 160)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Macro progress")
            } else {
                RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.1)).frame(height: 160)
            }
            if let err = vm.errorMessage { Text(err).font(.caption).foregroundStyle(.red) }
        }
    }

    private var entryList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meals so far").font(.headline)
            if vm.entries.isEmpty {
                Text("No entries yet.").foregroundStyle(.secondary)
            } else {
                ForEach(vm.entries) { entry in EntryCard(entry: entry) }
            }
        }
    }
}


