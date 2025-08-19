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
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Spacing.xl) {
                    header

                    SectionCard { macroSection }

                    SectionCard {
                        VStack(alignment: .leading, spacing: Design.Spacing.m) {
                            SectionHeader("Meals")
                            if vm.entries.isEmpty {
                                Text("No entries yet.")
                                    .foregroundStyle(Design.Color.muted)
                            } else {
                                LazyVStack(spacing: 14) {
                                    ForEach(vm.entries) { entry in
                                        EntryCard(entry: entry) {
                                            Task { await vm.deleteEntry(entry) }
                                        }
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
                        .font(.title2.weight(.bold))
                        .padding(.leading, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Sign Out") { AuthSessionManager.shared.signOut() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Design.Color.accentPrimary)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
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

                        Button {
                            vm.isPresentingComposer = true
                        } label: {
                            Label("Add Entry", systemImage: "plus.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.headline.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Design.Color.accentPrimary)

                        Spacer(minLength: 12)

                        Button { shiftDay(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(Design.Color.ink)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .sheet(isPresented: $vm.isPresentingComposer) {
            EntryComposerView { text, audioURL, image in
                await vm.submitEntry(text: text, audioURL: audioURL, image: image)
            }
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
        guard let day = Calendar.current.date(byAdding: .day, value: delta, to: vm.currentDay) else { return }
        Task { await vm.load(day: day) }
    }
}
