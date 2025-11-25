import SwiftUI
import Combine

struct TodayView: View {
    let profile: Profile
    @StateObject private var vm: TodayViewModel
    
    init(profile: Profile) {
        self.profile = profile
        _vm = StateObject(wrappedValue: TodayViewModel(
            profile: profile,
            api: APIService(
                supabaseUrl: AppConfig.supabaseURL,
                supabaseAnonKey: AppConfig.supabaseAnonKey,
                sessionJWTProvider: { try await AuthSessionManager.shared.getAccessToken() }
            )
        ))
    }
    @State private var now = Date()
    @State private var isShowingAccount = false
    @State private var showErrorAlert = false
    @State private var showEntryMenu = false
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.xl) {
                    header

                    SectionCard { macroSection }

                    SectionCard {
                        VStack(alignment: .leading, spacing: Design.Spacing.m) {
                            mealsHeader
                            
                            if vm.entries.isEmpty {
                                Text("No entries yet.")
                                    .foregroundStyle(Design.Color.muted)
                            } else {
                                LazyVStack(spacing: 14) {
                                    ForEach(vm.entries) { entry in
                                        let isProcessing = vm.processingEntryIds.contains(entry.id)
                                        
                                        NavigationLink {
                                            EntryDetailView(entryId: entry.id)
                                        } label: {
                                            EntryCard(entry: entry, isProcessing: isProcessing) {
                                                Task { await vm.deleteEntry(entry) }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isProcessing)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("shudo")
                        .font(.title2.weight(.bold))
                        .padding(.leading, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Account") { isShowingAccount = true }
                        Button("Sign Out") { AuthSessionManager.shared.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Design.Color.accentPrimary)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    bottomToolbar
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .sheet(isPresented: $vm.isPresentingComposer) {
            EntryComposerView { text, image in
                await vm.submitTextEntry(text: text, image: image)
            }
        }
        .sheet(isPresented: $isShowingAccount) {
            NavigationStack {
                AccountView()
            }
        }
        .fullScreenCover(isPresented: $vm.isShowingVoiceRecorder) {
            VoiceRecorderOverlay(
                onSubmit: { audioData in
                    await vm.submitVoiceEntry(audioData: audioData)
                },
                onDismiss: {
                    vm.isShowingVoiceRecorder = false
                }
            )
        }
        .onReceive(countdownTimer) { d in
            now = d
            // If user is pinned to "today", auto-advance when local date rolls over.
            if vm.isPinnedToToday {
                let cal = Calendar(identifier: .gregorian)
                if cal.isDate(d, inSameDayAs: vm.currentDay) == false {
                    Task { await vm.jumpToToday() }
                }
            }
        }
        .alert("Error", isPresented: $showErrorAlert, presenting: vm.errorMessage) { _ in
            Button("OK") { vm.errorMessage = nil }
        } message: { error in
            Text(error)
        }
        .onChange(of: vm.errorMessage) { _, newValue in
            if newValue != nil {
                showErrorAlert = true
            }
        }
    }
    
    // MARK: - Meals Header with Processing Indicator
    
    private var mealsHeader: some View {
        HStack {
            Text("Meals")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
            
            Spacer()
            
            if vm.hasProcessingEntries {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Design.Color.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Design.Color.fill, in: Capsule())
            }
        }
    }
    
    // MARK: - Bottom Toolbar
    
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            Button { shiftDay(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Design.Color.ink)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 12)

            // Entry creation buttons
            HStack(spacing: 12) {
                // Voice button
                Button {
                    vm.isShowingVoiceRecorder = true
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Design.Color.danger, in: Circle())
                }
                .buttonStyle(.plain)
                
                // Text/Photo button
                Button {
                    vm.isPresentingComposer = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Design.Color.accentPrimary, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            Button { shiftDay(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Calendar.current.isDate(vm.currentDay, inSameDayAs: Date()) ? Design.Color.muted : Design.Color.ink)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(Calendar.current.isDate(vm.currentDay, inSameDayAs: Date()))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(vm.currentDay, style: .date).font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Text(timezoneLabel)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
                countdownPill
            }
        }
    }

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Today's Macros")

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
        }
    }

    // MARK: - Countdown

    private var timezoneLabel: String {
        vm.profile?.timezone ?? TimeZone.autoupdatingCurrent.identifier
    }

    private var countdownPill: some View {
        let info = cutoffLabel(now: now,
                               tzId: vm.profile?.timezone,
                               cutoffLocal: vm.profile?.cutoffTimeLocal)
        return Group {
            if let info = info {
                Label(info.text, systemImage: "clock")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(info.isOver ? Design.Color.danger : Design.Color.ink)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Design.Radius.pill, style: .continuous)
                            .fill(Design.Color.fill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Design.Radius.pill, style: .continuous)
                            .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                    )
                    .accessibilityLabel(info.isOver ? "Fasting for improved sleep" : "Stop eating in \(info.accessible)")
            }
        }
    }

    private func cutoffLabel(now: Date, tzId: String?, cutoffLocal: String?) -> (text: String, accessible: String, isOver: Bool)? {
        let tz = TimeZone(identifier: tzId ?? "") ?? .autoupdatingCurrent
        let (h, m) = parseHourMinute(from: cutoffLocal)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let cutoffToday = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }

        let beforeCutoff = now <= cutoffToday
        let interval = beforeCutoff ? cutoffToday.timeIntervalSince(now) : now.timeIntervalSince(cutoffToday)
        let hhmm = formatHoursMinutes(interval: interval)
        let text = beforeCutoff ? "Stop in \(hhmm)" : "Over by \(hhmm)"
        return (text, hhmm, !beforeCutoff)
    }

    private func parseHourMinute(from cutoff: String?) -> (Int, Int) {
        let trimmed = (cutoff?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "20:00"
        let parts = trimmed.split(separator: ":")
        guard parts.count >= 2, let hh = Int(parts[0]), let mm = Int(parts[1]), (0..<24).contains(hh), (0..<60).contains(mm) else {
            return (20, 0)
        }
        return (hh, mm)
    }

    private func formatHoursMinutes(interval: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .positional
        f.zeroFormattingBehavior = [.pad]
        return f.string(from: max(0, interval)) ?? "0:00"
    }

    private func shiftDay(_ delta: Int) {
        let cal = Calendar(identifier: .gregorian)
        guard let candidate = cal.date(byAdding: .day, value: delta, to: vm.currentDay) else { return }
        // Prevent traveling into the future
        let today = Date()
        if cal.compare(candidate, to: today, toGranularity: .day) == .orderedDescending { return }
        Task {
            vm.isPinnedToToday = cal.isDate(candidate, inSameDayAs: today)
            await vm.load(day: candidate)
        }
    }
}
