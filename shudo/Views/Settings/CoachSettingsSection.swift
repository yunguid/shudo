import SwiftUI
import UIKit
import UserNotifications

/// Settings → Coach: whether Shudo texts at all, how hard he pushes, how he
/// talks, when he stays quiet, nearby-store recs (When-In-Use location) and
/// the opt-in physique review. Every change saves to `profiles` and re-plans
/// the day's texts (`CoachSync.apply(settings:)`).
struct CoachSettingsSection: View {
    let service: any CoachServing
    let loadsRemotely: Bool
    var onSettingsChanged: (CoachSettings) -> Void

    @State private var settings: CoachSettings = .defaults
    @State private var loaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var notificationsDenied = false
    @State private var locationDenied = false
    @State private var quietSaveTask: Task<Void, Never>?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SettingsSectionLabel(text: "COACH")
                Spacer()
                if isSaving {
                    ProgressView().controlSize(.small).tint(Design.Color.ember)
                }
            }
            VStack(spacing: 0) {
                enabledRow
                if settings.enabled {
                    HairlineRule().padding(.leading, 16)
                    pickerRow(title: "Intensity", detail: intensityDetail) {
                        Picker("Intensity", selection: binding(\.intensity)) {
                            ForEach(CoachSettings.Intensity.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settings.coach.intensity")
                    }
                    HairlineRule().padding(.leading, 16)
                    pickerRow(title: "Language", detail: profanityDetail) {
                        Picker("Language", selection: binding(\.profanity)) {
                            ForEach(CoachSettings.Profanity.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("settings.coach.profanity")
                    }
                    HairlineRule().padding(.leading, 16)
                    quietHoursRow
                }
                HairlineRule().padding(.leading, 16)
                toggleRow(
                    title: "Nearby store recs",
                    detail: locationDenied
                        ? "Location is off for Shudo. Turn it on in Settings to get snack picks near you."
                        : "When you ask what to grab, Shudo checks stores near you. Location stays on your iPhone; only store names are sent.",
                    isOn: Binding(get: { settings.locationRecsEnabled }, set: { setNearby($0) }),
                    identifier: "settings.coach.nearby"
                )
                if locationDenied {
                    settingsLink.padding(.leading, 16).padding(.bottom, 10)
                }
                HairlineRule().padding(.leading, 16)
                toggleRow(
                    title: "Physique review",
                    detail: "Each Monday Shudo looks at your check-in photos and tells you what’s changing. Off unless you turn it on.",
                    isOn: binding(\.physiqueAIReviewEnabled),
                    identifier: "settings.coach.physique"
                )
            }
            .background(Design.Color.surface1, in: RoundedRectangle(cornerRadius: Design.Radius.l, style: .continuous))

            if notificationsDenied, settings.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notifications are off, so Shudo’s texts only show up in Today.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.honey)
                        .fixedSize(horizontal: false, vertical: true)
                    settingsLink
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Design.Color.danger)
            }
        }
        .task { await load() }
    }

    // MARK: Rows

    private var enabledRow: some View {
        Toggle(isOn: Binding(get: { settings.enabled }, set: { setEnabled($0) })) {
            HStack(spacing: 12) {
                CoachAvatar(size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Shudo texts you")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.textPrimary)
                    Text("Game plan, nudges, reactions to what you log, and a nightly recap.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(Design.Color.ember)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("settings.coach.enabled")
    }

    private func pickerRow<Control: View>(title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                Spacer()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Design.Color.textTertiary)
            }
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var quietHoursRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Quiet hours")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                Text("Texts still land in Today, just silently.")
                    .font(.caption)
                    .foregroundStyle(Design.Color.textSecondary)
            }
            Spacer(minLength: 8)
            DatePicker("Quiet from", selection: clockBinding(\.quietHoursStart), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("–").foregroundStyle(Design.Color.textTertiary)
            DatePicker("Quiet until", selection: clockBinding(\.quietHoursEnd), displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .tint(Design.Color.ember)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>, identifier: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Design.Color.ember)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier(identifier)
    }

    private var settingsLink: some View {
        Button("Open Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Design.Color.ember)
        .buttonStyle(.plain)
    }

    private var intensityDetail: String {
        switch settings.intensity {
        case .chill: return "Up to 4 texts a day"
        case .lockedIn: return "Up to 7 texts a day"
        case .drillSergeant: return "Up to 10. You asked."
        }
    }

    private var profanityDetail: String {
        switch settings.profanity {
        case .off: return "No swearing"
        case .mild: return "The odd “damn”"
        case .salty: return "Gym-floor language"
        }
    }

    // MARK: Bindings

    private func binding<Value: Equatable>(_ keyPath: WritableKeyPath<CoachSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                guard settings[keyPath: keyPath] != value else { return }
                var next = settings
                next[keyPath: keyPath] = value
                save(next)
            }
        )
    }

    private func clockBinding(_ keyPath: WritableKeyPath<CoachSettings, CoachClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let time = settings[keyPath: keyPath]
                return Calendar.current.date(
                    bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let time = CoachClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
                guard settings[keyPath: keyPath] != time else { return }
                settings[keyPath: keyPath] = time
                // Wheel spins fire many changes; save once it settles.
                quietSaveTask?.cancel()
                quietSaveTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled else { return }
                    guard settings.quietHoursStart != settings.quietHoursEnd else {
                        errorMessage = "Quiet hours need a start and an end that differ."
                        return
                    }
                    save(settings)
                }
            }
        )
    }

    // MARK: Flows

    private func setEnabled(_ enabled: Bool) {
        let previous = settings
        var next = settings
        next.enabled = enabled
        settings = next
        guard enabled else {
            save(next)
            return
        }
        Task { @MainActor in
            let granted = await CoachNotificationAuthorization.request()
            notificationsDenied = !granted
            if loadsRemotely {
                // One voice: the 1.x pacing nudges and weigh-in reminder
                // stand down when the coach takes over.
                UserDefaults.standard.set(false, forKey: DayNotificationScheduler.enabledDefaultsKey)
                try? await DayNotificationScheduler.applyEnabled(
                    false,
                    weighInSecondsFromMidnight: DayNotificationScheduler.defaultWeighInSecondsFromMidnight
                )
            }
            save(next, revertTo: previous)
        }
    }

    /// Nearby recs need When-In-Use location: ask first, keep it off if the
    /// answer is no.
    private func setNearby(_ enabled: Bool) {
        var next = settings
        next.locationRecsEnabled = enabled
        guard enabled else {
            locationDenied = false
            save(next)
            return
        }
        guard loadsRemotely else {
            save(next)
            return
        }
        Task { @MainActor in
            let status = await LocationFixProvider.shared.requestWhenInUseAuthorization()
            guard status.isAuthorized else {
                locationDenied = true
                return
            }
            locationDenied = false
            save(next)
            _ = await NearbyStoreScout.shared.refresh()
        }
    }

    private func save(_ next: CoachSettings, revertTo fallback: CoachSettings? = nil) {
        let previous = fallback ?? settings
        settings = next
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let saved = try await service.updateSettings(next)
                settings = saved
                onSettingsChanged(saved)
            } catch {
                settings = previous
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn’t save that. Try again."
            }
            isSaving = false
        }
    }

    private func load() async {
        guard !loaded else { return }
        if let fetched = try? await service.fetchSettings() {
            settings = fetched
        }
        loaded = true
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied
        if loadsRemotely {
            locationDenied = settings.locationRecsEnabled && !LocationFixProvider.shared.authorization.isAuthorized
        }
    }
}

struct SettingsSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Design.Color.textSecondary)
            .tracking(0.5)
    }
}
