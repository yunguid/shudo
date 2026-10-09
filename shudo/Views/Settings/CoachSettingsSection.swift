import SwiftUI
import UIKit
import UserNotifications

/// Settings → Coach and Notifications: whether Shudo texts at all, how hard
/// he pushes, how he talks, nearby-store recs (When-In-Use location), the
/// opt-in physique review, notification permission and quiet hours. Every
/// change saves to `profiles` and re-plans the day's texts
/// (`CoachSync.apply(settings:)`).
struct CoachSettingsSection: View {
    let service: any CoachServing
    let loadsRemotely: Bool
    var onSettingsChanged: (CoachSettings) -> Void

    @State private var settings: CoachSettings = .defaults
    @State private var loaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var locationDenied = false
    @State private var quietSaveTask: Task<Void, Never>?
    /// Which quiet-hours edge has its wheel open under the row.
    @State private var editingQuietEdge: QuietEdge?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.section) {
            SettingsGroup(label: "Coach") {
                enabledRow
                if settings.enabled {
                    SettingsRow(title: "Intensity", subtitle: intensityDetail) {
                        menu("Intensity", selection: binding(\.intensity), options: CoachSettings.Intensity.allCases, title: \.title)
                            .accessibilityIdentifier("settings.coach.intensity")
                    }
                    SettingsRow(title: "Language") {
                        menu("Language", selection: binding(\.profanity), options: CoachSettings.Profanity.allCases, title: \.title)
                            .accessibilityIdentifier("settings.coach.profanity")
                    }
                }
                toggleRow(
                    "Nearby store recs",
                    subtitle: locationDenied ? "Location is off for Shudo" : nil,
                    isOn: Binding(get: { settings.locationRecsEnabled }, set: { setNearby($0) }),
                    identifier: "settings.coach.nearby"
                )
                if locationDenied { openSettingsRow("Turn on location") }
                toggleRow(
                    "Physique review",
                    subtitle: "Mondays, from your check-in photos",
                    isOn: binding(\.physiqueAIReviewEnabled),
                    identifier: "settings.coach.physique"
                )
            } accessory: {
                if isSaving {
                    ProgressView().controlSize(.mini).tint(Design.Color.textTertiary)
                        .transition(.opacity)
                }
            }
            .disabled(!loaded)

            if settings.enabled {
                // "Allow notifications" names itself; ma is the only header.
                SettingsGroup {
                    notificationsRow
                    quietHoursRow
                    if let edge = editingQuietEdge {
                        quietWheel(edge)
                            .transition(.opacity)
                    }
                }
                .transition(.shoji(.top, reduceMotion: reduceMotion))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: settings.enabled)
        .animation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion), value: editingQuietEdge)
        .task { await load() }
        #if DEBUG
        .onAppear {
            // PolishPreview screenshots: `-shudoQuietWheel` opens the wheel.
            if ProcessInfo.processInfo.arguments.contains("-shudoQuietWheel") { editingQuietEdge = .start }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings: reflect what changed there.
            guard phase == .active else { return }
            Task { await refreshPermissions() }
        }
    }

    // MARK: Rows

    private var enabledRow: some View {
        SettingsToggleRow(isOn: Binding(get: { settings.enabled }, set: { setEnabled($0) })) {
            HStack(spacing: Design.Space.m) {
                CoachAvatar(size: 26)
                Text("Shudo texts you")
                    .font(Design.Typeface.text(.body))
                    .foregroundStyle(Design.Color.textPrimary)
            }
        }
        .accessibilityIdentifier("settings.coach.enabled")
    }

    private func toggleRow(_ title: String, subtitle: String?, isOn: Binding<Bool>, identifier: String) -> some View {
        SettingsToggleRow(isOn: isOn) {
            SettingsRowTitle(title: title, subtitle: subtitle)
        }
        .accessibilityIdentifier(identifier)
    }

    private func menu<Option: Hashable>(
        _ label: String,
        selection: Binding<Option>,
        options: [Option],
        title: KeyPath<Option, String>
    ) -> some View {
        SettingsMenuPicker(label: label, selection: selection, options: options) { $0[keyPath: title] }
    }

    /// iOS permission for Shudo's texts: on, off (fix it in Settings), or not
    /// asked yet (ask now).
    private var notificationsRow: some View {
        Button {
            if notificationStatus == .notDetermined {
                Task {
                    _ = await CoachNotificationAuthorization.request()
                    await refreshPermissions()
                }
            } else {
                openSystemSettings()
            }
        } label: {
            SettingsValueLabel(
                title: "Allow notifications",
                value: notificationValue,
                valueColor: notificationsAllowed ? Design.Color.textSecondary : Design.Color.honey
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.notifications")
    }

    private enum QuietEdge: Hashable {
        case start, end

        var keyPath: WritableKeyPath<CoachSettings, CoachClockTime> {
            self == .start ? \.quietHoursStart : \.quietHoursEnd
        }

        var label: String { self == .start ? "Quiet from" : "Quiet until" }
    }

    /// Two times set in the app's typeface; tapping one opens a wheel under
    /// the row (tap it again, or the other time, to move on).
    private var quietHoursRow: some View {
        SettingsRow(title: "Quiet hours") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    quietChip(.start)
                    Text("–")
                        .foregroundStyle(Design.Color.textTertiary)
                        .accessibilityHidden(true)
                    quietChip(.end)
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    quietChip(.start)
                    quietChip(.end)
                }
            }
        }
    }

    private func quietChip(_ edge: QuietEdge) -> some View {
        let isEditing = editingQuietEdge == edge
        return Button {
            editingQuietEdge = isEditing ? nil : edge
        } label: {
            Text(clockText(settings[keyPath: edge.keyPath]))
                .font(Design.Typeface.numeral(.body, weight: .regular))
                .foregroundStyle(isEditing ? Design.Color.pernambuco : Design.Color.textPrimary)
                .padding(.horizontal, Design.Space.m)
                .padding(.vertical, 7)
                .background(Design.Color.surface2, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(edge.label)
        .accessibilityValue(clockText(settings[keyPath: edge.keyPath]))
        .accessibilityHint(isEditing ? "Closes the time wheel" : "Opens a time wheel")
    }

    private func quietWheel(_ edge: QuietEdge) -> some View {
        ClockWheel(label: edge.label, date: clockBinding(edge.keyPath))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Design.Space.s)
            .id(edge)
    }

    private func clockText(_ time: CoachClockTime) -> String {
        ClockWheel.text(hour: time.hour, minute: time.minute)
    }

    private func openSettingsRow(_ title: String) -> some View {
        Button(action: openSystemSettings) {
            SettingsValueLabel(title: title, value: nil)
        }
        .buttonStyle(.plain)
    }

    private var notificationsAllowed: Bool {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    private var notificationValue: String {
        if notificationsAllowed { return "On" }
        return notificationStatus == .notDetermined ? "Turn on" : "Off"
    }

    private var intensityDetail: String {
        switch settings.intensity {
        case .chill: return "Up to 4 texts a day"
        case .lockedIn: return "Up to 7 texts a day"
        case .drillSergeant: return "Up to 10 texts a day"
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
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
                        errorMessage = "Quiet hours need a different start and end."
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
            _ = await CoachNotificationAuthorization.request()
            await refreshPermissions()
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
        await refreshPermissions()
    }

    private func refreshPermissions() async {
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if loadsRemotely {
            locationDenied = settings.locationRecsEnabled && !LocationFixProvider.shared.authorization.isAuthorized
        }
    }
}

/// A time wheel set in the app's typeface (the system wheel draws SF):
/// hour, minute and, on 12-hour clocks, a lowercase am/pm.
private struct ClockWheel: View {
    let label: String
    @Binding var date: Date

    private static var uses12Hour: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? true
    }

    /// "11:00 pm", or "23:00" on a 24-hour clock: sentence case, no capitals.
    static func text(hour: Int, minute: Int) -> String {
        guard uses12Hour else { return String(format: "%02d:%02d", hour, minute) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "am" : "pm")
    }

    private var hour: Int { Calendar.current.component(.hour, from: date) }
    private var minute: Int { Calendar.current.component(.minute, from: date) }

    var body: some View {
        HStack(spacing: 0) {
            if Self.uses12Hour {
                wheel("Hour", selection: Binding(
                    get: { hour % 12 == 0 ? 12 : hour % 12 },
                    set: { set(hour: ($0 % 12) + (hour >= 12 ? 12 : 0)) }
                ), values: Array(1...12)) { "\($0)" }
            } else {
                wheel("Hour", selection: Binding(get: { hour }, set: { set(hour: $0) }), values: Array(0...23)) {
                    String(format: "%02d", $0)
                }
            }
            wheel("Minute", selection: Binding(get: { minute }, set: { set(minute: $0) }), values: Array(0...59)) {
                String(format: "%02d", $0)
            }
            if Self.uses12Hour {
                wheel("Morning or evening", selection: Binding(
                    get: { hour >= 12 },
                    set: { isEvening in set(hour: hour % 12 + (isEvening ? 12 : 0)) }
                ), values: [false, true]) { $0 ? "pm" : "am" }
            }
        }
        .frame(height: 150)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func wheel<Value: Hashable>(
        _ title: String,
        selection: Binding<Value>,
        values: [Value],
        text: @escaping (Value) -> String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(values, id: \.self) { value in
                Text(text(value))
                    .font(Design.Typeface.numeral(.title3, weight: .regular))
                    .foregroundStyle(Design.Color.textPrimary)
                    .tag(value)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .frame(width: 76)
        .clipped()
    }

    private func set(hour newHour: Int? = nil, minute newMinute: Int? = nil) {
        date = Calendar.current.date(
            bySettingHour: newHour ?? hour, minute: newMinute ?? minute, second: 0, of: date
        ) ?? date
    }
}
