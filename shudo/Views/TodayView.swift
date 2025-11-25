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
                                emptyState
                            } else {
                                LazyVStack(spacing: 8) {
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
                .padding(.top, 16)
                .padding(.bottom, 100)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("shudo")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Design.Color.ink)
                        .padding(.leading, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { isShowingAccount = true } label: {
                            Label("Account", systemImage: "person.circle")
                        }
                        Button(role: .destructive) { AuthSessionManager.shared.signOut() } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.body.weight(.medium))
                            .foregroundStyle(Design.Color.muted)
                            .frame(width: 36, height: 36)
                            .background(Design.Color.elevated, in: Circle())
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .safeAreaInset(edge: .bottom) {
                bottomToolbar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }
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
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "fork.knife")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Design.Color.subtle)
            Text("No entries yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.muted)
            Text("Tap the buttons below to log your first meal")
                .font(.caption)
                .foregroundStyle(Design.Color.subtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
    
    // MARK: - Meals Header with Processing Indicator
    
    private var mealsHeader: some View {
        HStack {
            Text("MEALS")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .tracking(0.5)
            
            Spacer()
            
            if vm.hasProcessingEntries {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Design.Color.accentPrimary)
                    Text("Processing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Design.Color.accentPrimary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Design.Color.accentPrimary.opacity(0.1), in: Capsule())
            }
        }
    }
    
    // MARK: - Bottom Toolbar
    
    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            // Day navigation - left
            Button { shiftDay(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                    .frame(width: 44, height: 44)
                    .background(Design.Color.elevated, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            // Entry creation buttons - center
            HStack(spacing: 12) {
                // Voice button
                Button {
                    vm.isShowingVoiceRecorder = true
                } label: {
                    Image(systemName: "waveform")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(
                            LinearGradient(
                                colors: [Design.Color.accentPrimary, Design.Color.accentSecondary],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                
                // Photo button
                Button {
                    vm.isPresentingComposer = true
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                        .frame(width: 48, height: 48)
                        .background(Design.Color.elevated, in: Circle())
                        .overlay(
                            Circle()
                                .stroke(Design.Color.rule, lineWidth: Design.Stroke.thin)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Day navigation - right
            Button { shiftDay(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Calendar.current.isDate(vm.currentDay, inSameDayAs: Date()) ? Design.Color.subtle : Design.Color.ink)
                    .frame(width: 44, height: 44)
                    .background(Design.Color.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(Calendar.current.isDate(vm.currentDay, inSameDayAs: Date()))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            Capsule()
                .fill(Design.Color.glassFill)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial.opacity(0.5))
                )
                .overlay(
                    Capsule()
                        .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                )
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.currentDay, style: .date)
                .font(.title.weight(.bold))
                .foregroundStyle(Design.Color.ink)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption)
                    Text(timezoneLabel)
                }
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
                
                countdownPill
            }
        }
    }

    private var macroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MACROS")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .tracking(0.5)

            if let profile = vm.profile {
                MacroRingsView(target: profile.dailyMacroTarget, current: vm.todayTotals)
                    .frame(height: 220)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Macro progress")
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.l)
                    .fill(Design.Color.elevated)
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
                HStack(spacing: 6) {
                    Image(systemName: info.isOver ? "moon.fill" : "clock")
                        .font(.caption)
                    Text(info.text)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(info.isOver ? Design.Color.warning : Design.Color.success)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill((info.isOver ? Design.Color.warning : Design.Color.success).opacity(0.12))
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
        let text = beforeCutoff ? "\(hhmm) left" : "Fasting"
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
        let today = Date()
        if cal.compare(candidate, to: today, toGranularity: .day) == .orderedDescending { return }
        Task {
            vm.isPinnedToToday = cal.isDate(candidate, inSameDayAs: today)
            await vm.load(day: candidate)
        }
    }
}
