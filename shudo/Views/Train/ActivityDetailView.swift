import SwiftUI

/// One workout in full: the numbers, any PRs, every lift, the photo it was
/// read from and what was said. Delete lives in the toolbar; how the burn
/// was estimated sits behind a tap on the number.
/// Pure presentation: the owner supplies the row and the side effects.
struct ActivityDetailView: View {
    let activity: Activity
    var units: String
    /// Shown when the server flagged no PRs (client-side detection).
    var fallbackPRs: [ActivityPR]
    var loadImageURL: ((String) async -> URL?)?
    var onRetry: (() -> Void)?
    var onDelete: (() async -> Bool)?

    init(
        activity: Activity,
        units: String = "imperial",
        fallbackPRs: [ActivityPR] = [],
        loadImageURL: ((String) async -> URL?)? = nil,
        onRetry: (() -> Void)? = nil,
        onDelete: (() async -> Bool)? = nil
    ) {
        self.activity = activity
        self.units = units
        self.fallbackPRs = fallbackPRs
        self.loadImageURL = loadImageURL
        self.onRetry = onRetry
        self.onDelete = onDelete
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imageURL: URL?
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var showsBurnMath = false

    private var prs: [ActivityPR] { activity.prs.isEmpty ? fallbackPRs : activity.prs }
    private var exercises: [ActivityExercise] { activity.exercises.filter { !$0.workingSets.isEmpty } }
    private var isSettled: Bool { activity.status == .complete && activity.localState == nil }
    private var canDelete: Bool { onDelete != nil && (!activity.isProcessing || activity.isLocalOnly) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.xxl) {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    Text(dateText)
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textTertiary)
                    statusView
                    if isSettled { statsRow }
                }
                Group {
                    if !prs.isEmpty { prSection }
                    if !exercises.isEmpty { exercisesSection }
                    if activity.imagePath != nil { photoCard }
                    if let input = activity.inputText?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
                        saidLine(input)
                    }
                }
                .transition(.ink(reduceMotion: reduceMotion))
            }
            .padding(.horizontal, TrainStyle.gutter)
            .padding(.top, Design.Space.xs)
            .padding(.bottom, Design.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Design.Motion.calm(Design.Motion.arrive, reduceMotion: reduceMotion), value: isSettled)
        }
        .scrollIndicators(.hidden)
        .background(AppBackground())
        .navigationTitle(activity.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .largeTitle) {
                TrainLargeTitle(text: activity.title)
            }
            if canDelete {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Image(systemName: "trash")
                                .foregroundStyle(Design.Color.textPrimary)
                        }
                    }
                    .disabled(isDeleting)
                    .accessibilityLabel(activity.isLocalOnly ? "Discard workout" : "Delete workout")
                }
            }
        }
        .confirmationDialog(
            activity.isLocalOnly ? "Discard this workout?" : "Delete this workout?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(activity.isLocalOnly ? "Discard" : "Delete", role: .destructive) {
                Task {
                    isDeleting = true
                    let deleted = await onDelete?() ?? false
                    isDeleting = false
                    if deleted { dismiss() }
                }
            }
        }
        .task(id: activity.imagePath) {
            guard let path = activity.imagePath, let loadImageURL else { return }
            imageURL = await loadImageURL(path)
        }
    }

    // MARK: Sections

    private var dateText: String {
        let day = TrainSnapshot.displayTitle(localDay: activity.localDay)
        return "\(day) · \(activity.occurredAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private var statusView: some View {
        if activity.isNotSent {
            HStack(spacing: 12) {
                Label(activity.errorMessage ?? "Not sent", systemImage: "wifi.exclamationmark")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.danger)
                Spacer(minLength: 8)
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(TrainCapsuleButtonStyle(prominent: true))
                }
            }
            .padding(14)
            .cardSurface()
        } else if activity.isProcessing {
            Text(ActivityCard.readingLine(for: activity))
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .shimmering()
        } else if activity.status == .failed {
            Text("Couldn’t read this one. Delete it and log it again in your own words.")
                .font(.subheadline)
                .foregroundStyle(Design.Color.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Stats

    struct Stat: Identifiable {
        var value: String
        var unit: String
        var isBurn = false
        var id: String { unit }
    }

    private var stats: [Stat] {
        var stats: [Stat] = []
        if let minutes = activity.durationMin, minutes > 0 {
            stats.append(Stat(value: "\(Int(minutes.rounded()))", unit: "min"))
        }
        if let km = activity.distanceKm, km > 0 {
            let parts = ActivitySummaryFormatter.distanceText(kilometers: km, units: units).split(separator: " ")
            stats.append(Stat(value: String(parts.first ?? ""), unit: String(parts.last ?? "")))
        }
        let workingSets = exercises.flatMap(\.workingSets).count
        if workingSets > 0 {
            stats.append(Stat(value: "\(workingSets)", unit: workingSets == 1 ? "set" : "sets"))
        }
        if let heartRate = activity.avgHeartRate {
            stats.append(Stat(value: "\(heartRate)", unit: "bpm"))
        }
        if let kcal = activity.activeKcal, kcal >= 1 {
            let estimate = activity.details.burnMethod != .device
            stats.append(Stat(value: (estimate ? "~" : "") + Int(kcal.rounded()).formatted(), unit: "kcal", isBurn: true))
        }
        return stats
    }

    /// One line of numbers; stacked when large type can't fit them across.
    @ViewBuilder
    private var statsRow: some View {
        let stats = stats
        if !stats.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 26) {
                    ForEach(stats) { stat($0) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(stats) { stat($0) }
                }
            }
            .popover(isPresented: $showsBurnMath, arrowEdge: .top) {
                Text(Self.burnExplanation(for: activity, units: units))
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 250, alignment: .leading)
                    .padding(14)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    @ViewBuilder
    private func stat(_ stat: Stat) -> some View {
        if stat.isBurn {
            Button {
                showsBurnMath = true
            } label: {
                statLabel(stat)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows how it was estimated")
        } else {
            statLabel(stat)
        }
    }

    private func statLabel(_ stat: Stat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(stat.value)
                .font(Design.Typeface.numeral(.title2, weight: .regular))
                .foregroundStyle(Design.Color.textPrimary)
                .monospacedDigit()
            Text(stat.unit)
                .font(.footnote)
                .foregroundStyle(Design.Color.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    /// One or two plain sentences: where the number came from, and that it
    /// never feeds back into the food targets.
    static func burnExplanation(for activity: Activity, units: String) -> String {
        let source: String
        switch activity.details.burnMethod {
        case .device:
            switch activity.details.deviceLabel {
            case "apple_watch": source = "From your Apple Watch."
            case "strava": source = "From Strava."
            case "gym_machine": source = "From the machine, trimmed 15% — consoles run high."
            case let label?: source = "From \(label.replacingOccurrences(of: "_", with: " "))."
            case nil: source = "From your device."
            }
        case .met:
            var inputs: [String] = []
            if let minutes = activity.durationMin { inputs.append(ActivitySummaryFormatter.durationText(minutes: minutes)) }
            if let kilograms = activity.details.weightKgUsed {
                let unit = WeightUnit(preference: units)
                let weight = unit == .kg ? kilograms : kilograms * WeightUnit.poundsPerKilogram
                inputs.append("\(Int(weight.rounded())) \(unit.rawValue)")
            }
            source = inputs.isEmpty
                ? "Estimated from how long and how hard you went."
                : "Estimated from \(inputs.joined(separator: " at ")) and how hard you went."
        case nil:
            source = "Estimated from how long and how hard you went."
        }
        return source + " Not added back to your food targets."
    }

    // MARK: PRs

    /// The records this session set — no panel, no glow: a Pernambuco line
    /// and the numbers, the gain in the accent.
    private var prSection: some View {
        VStack(alignment: .leading, spacing: TrainStyle.rowSpacing) {
            Text(prs.count == 1 ? "New record" : "\(prs.count) new records")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Design.Color.pernambuco)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(prs.enumerated()), id: \.offset) { _, pr in
                let parts = Self.prParts(pr)
                TrainValueRow(ActivitySummaryFormatter.shortLiftName(pr.exercise)) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(parts.value)
                            .font(Design.Typeface.numeral(.body, weight: .medium))
                            .foregroundStyle(Design.Color.textPrimary)
                            .monospacedDigit()
                        Text(parts.unit)
                            .font(.caption)
                            .foregroundStyle(Design.Color.textTertiary)
                        if let delta = parts.delta {
                            Text(delta)
                                .font(Design.Typeface.numeral(.footnote, weight: .semibold))
                                .foregroundStyle(Design.Color.pernambuco)
                                .monospacedDigit()
                                .padding(.leading, 6)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "228" "lb e1RM" "+6"; "15" "reps" "+3".
    static func prParts(_ pr: ActivityPR) -> (value: String, unit: String, delta: String?) {
        let unit = [pr.unit, pr.kind == .e1rm ? "e1RM" : nil].compactMap { $0 }.joined(separator: " ")
        let delta = pr.previous.flatMap { previous -> String? in
            let gain = pr.value - previous
            return gain > 0 ? "+\(StrengthMath.formatWeight(gain))" : nil
        }
        return (StrengthMath.formatWeight(pr.value), unit, delta)
    }

    // MARK: Lifts

    /// Every lift as a ledger line — the canvas is the page.
    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: TrainStyle.rowSpacing) {
            TrainStyle.sectionLabel("Lifts")
            ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                TrainValueRow(
                    ActivitySummaryFormatter.shortLiftName(exercise.name),
                    value: ActivitySummaryFormatter.setsSummary(exercise, units: units))
                    .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What was said, set as a quotation in New York italic.
    private func saidLine(_ input: String) -> some View {
        Text("“\(input)”")
            .font(Design.Typeface.display(.callout).italic())
            .foregroundStyle(Design.Color.textSecondary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("You said: \(input)")
    }

    // MARK: Photo

    private var photoCard: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        photoPlaceholder(failed: true)
                    default:
                        photoPlaceholder(failed: false)
                    }
                }
            } else {
                photoPlaceholder(failed: loadImageURL == nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .accessibilityLabel("Workout photo")
    }

    private func photoPlaceholder(failed: Bool) -> some View {
        ZStack {
            Design.Color.surface1
            if failed {
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(Design.Color.textTertiary)
            } else {
                ProgressView().tint(Design.Color.ember)
            }
        }
        .frame(height: 180)
    }
}
