import SwiftUI

/// One workout in full: stats, the set table with e1RMs, PRs, the photo it
/// was read from, how the burn was estimated, what was said, and delete.
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
    @State private var imageURL: URL?
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var showsBurnMath = false

    private var prs: [ActivityPR] { activity.prs.isEmpty ? fallbackPRs : activity.prs }
    private var exercises: [ActivityExercise] { activity.exercises.filter { !$0.sets.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                if !stats.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(stats, id: \.label) { stat in
                            ActivityStatTile(stat: stat)
                        }
                    }
                }
                if !prs.isEmpty { prCard }
                ForEach(Array(exercises.enumerated()), id: \.offset) { _, exercise in
                    ExerciseSetTable(
                        exercise: exercise,
                        units: units,
                        isPR: prs.contains { LiftIdentity.normalizedName($0.exercise) == LiftIdentity.normalizedName(exercise.name) }
                    )
                }
                if activity.imagePath != nil { photoCard }
                if activity.activeKcal != nil, activity.status == .complete { burnCard }
                if let input = activity.inputText?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
                    quoteCard(input)
                }
                if onDelete != nil, !activity.isProcessing || activity.isLocalOnly {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        HStack(spacing: 6) {
                            if isDeleting { ProgressView().tint(Design.Color.danger) }
                            Text(activity.isLocalOnly ? "Discard" : "Delete workout")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.danger)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDeleting)
                    .padding(.top, 8)
                }
            }
            .padding(16)
        }
        .background(Design.Color.canvas.ignoresSafeArea())
        .navigationTitle(activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this workout?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task {
                    isDeleting = true
                    let deleted = await onDelete?() ?? false
                    isDeleting = false
                    if deleted { dismiss() }
                }
            }
        } message: {
            Text("It comes off your history, PR board and weekly count.")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: isDeleting) { _, new in new }
        .task(id: activity.imagePath) {
            guard let path = activity.imagePath, let loadImageURL else { return }
            imageURL = await loadImageURL(path)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ActivityKindTile(kind: activity.kind, isProcessing: activity.isProcessing, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(activity.kind.label) · \(dateText)")
                    .eyebrowStyle()
                Text(activity.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if !prs.isEmpty {
                    TrainPRBadge(count: prs.count)
                }
            }
        }
    }

    private var dateText: String {
        let day = TrainSnapshot.displayTitle(localDay: activity.localDay)
        return "\(day) · \(activity.occurredAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder
    private var statusCard: some View {
        if activity.isNotSent {
            noticeCard(
                symbol: "wifi.exclamationmark",
                tint: Design.Color.danger,
                title: "Not sent",
                text: activity.errorMessage ?? ActivityLoggingController.notSentStatusMessage,
                actionTitle: onRetry == nil ? nil : "Retry",
                action: onRetry)
        } else if activity.isProcessing {
            HStack(alignment: .top, spacing: 12) {
                CoachAvatar(size: 30, isThinking: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reading your session").eyebrowStyle(Design.Color.ember)
                    Text(activity.analysisPreview ?? "Counting sets, checking PRs, estimating the burn…")
                        .font(.subheadline)
                        .foregroundStyle(Design.Color.textSecondary)
                        .shimmering()
                    if case .stalled(let message) = activity.localState {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        } else if activity.status == .failed {
            noticeCard(
                symbol: "exclamationmark.triangle.fill",
                tint: Design.Color.danger,
                title: "Couldn’t read this one",
                text: (activity.errorMessage.map { $0 + " " } ?? "") + "Delete it and log it again in your own words.",
                actionTitle: nil,
                action: nil)
        }
    }

    private func noticeCard(
        symbol: String, tint: Color, title: String, text: String, actionTitle: String?, action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Design.Color.textSecondary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(TrainCapsuleButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    struct Stat {
        var value: String
        var unit: String
        var label: String
    }

    private var stats: [Stat] {
        guard activity.status == .complete, activity.localState == nil else { return [] }
        var stats: [Stat] = []
        if let minutes = activity.durationMin, minutes > 0 {
            stats.append(Stat(value: "\(Int(minutes.rounded()))", unit: "min", label: "Time"))
        }
        if let kcal = activity.activeKcal, kcal >= 1 {
            stats.append(Stat(value: Int(kcal.rounded()).formatted(), unit: "kcal", label: "Burned"))
        }
        if let km = activity.distanceKm, km > 0 {
            let parts = ActivitySummaryFormatter.distanceText(kilometers: km, units: units).split(separator: " ")
            stats.append(Stat(value: String(parts.first ?? ""), unit: String(parts.last ?? ""), label: "Distance"))
        }
        if let volume = ActivitySummaryFormatter.volume(of: activity, units: units) {
            stats.append(Stat(
                value: Int(volume.rounded()).formatted(), unit: WeightUnit(preference: units).rawValue,
                label: "Volume"))
        }
        let workingSets = activity.exercises.flatMap(\.workingSets).count
        if workingSets > 0 {
            stats.append(Stat(value: "\(workingSets)", unit: "", label: "Sets"))
        }
        if let heartRate = activity.avgHeartRate {
            stats.append(Stat(value: "\(heartRate)", unit: "bpm", label: "Avg HR"))
        }
        if let rpe = activity.rpe {
            stats.append(Stat(value: StrengthMath.formatWeight(rpe), unit: "/10", label: "RPE"))
        } else if let intensity = activity.intensity {
            stats.append(Stat(value: intensity.label, unit: "", label: "Effort"))
        }
        return stats
    }

    private var prCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Design.Color.ember)
                Text(prs.count == 1 ? "New PR" : "\(prs.count) new PRs").eyebrowStyle(Design.Color.ember)
            }
            ForEach(Array(prs.enumerated()), id: \.offset) { _, pr in
                HStack(alignment: .firstTextBaseline) {
                    Text(ActivitySummaryFormatter.shortLiftName(pr.exercise))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Design.Color.textPrimary)
                    Spacer(minLength: 8)
                    Text(Self.prText(pr))
                        .font(Design.Typeface.numeral(.subheadline, weight: .bold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Design.Color.ember.opacity(0.16), Design.Color.surface1],
                startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(Design.Color.ember.opacity(0.4), lineWidth: 1))
    }

    /// "e1RM 239 lb (was 231)", "225 lb", "15 reps (was 12)".
    static func prText(_ pr: ActivityPR) -> String {
        let value = StrengthMath.formatWeight(pr.value)
        let unit = pr.unit.map { " \($0)" } ?? ""
        let previous = pr.previous.map { " (was \(StrengthMath.formatWeight($0)))" } ?? ""
        switch pr.kind {
        case .e1rm: return "e1RM \(value)\(unit)\(previous)"
        case .weight, .reps, .other: return "\(value)\(unit)\(previous)"
        }
    }

    private var photoCard: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        photoPlaceholder("Photo unavailable")
                    default:
                        photoPlaceholder(nil)
                    }
                }
            } else {
                photoPlaceholder(loadImageURL == nil ? "Photo attached" : nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(Design.Color.hairline, lineWidth: Design.Stroke.hairline))
        .accessibilityLabel("Workout photo")
    }

    private func photoPlaceholder(_ text: String?) -> some View {
        ZStack {
            Design.Color.surface1
            if let text {
                Label(text, systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
            } else {
                ProgressView().tint(Design.Color.ember)
            }
        }
        .frame(height: 180)
    }

    private var burnCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Design.Motion.snap) { showsBurnMath.toggle() }
            } label: {
                HStack {
                    Label("How the burn was estimated", systemImage: "flame.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Design.Color.textTertiary)
                        .rotationEffect(.degrees(showsBurnMath ? 180 : 0))
                }
            }
            .buttonStyle(.plain)
            if showsBurnMath {
                Text(Self.burnExplanation(for: activity, units: units))
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    static func burnExplanation(for activity: Activity, units: String) -> String {
        let method: String
        switch activity.details.burnMethod {
        case .device:
            let source: String
            switch activity.details.deviceLabel {
            case "apple_watch": source = "your Apple Watch"
            case "strava": source = "Strava"
            case "gym_machine": source = "the machine’s display, trimmed 15% because consoles run high"
            case let label?: source = label.replacingOccurrences(of: "_", with: " ")
            case nil: source = "your device"
            }
            method = "Taken from \(source). Device numbers beat estimates."
        case .met:
            var inputs: [String] = []
            if let met = activity.details.met { inputs.append("MET \(StrengthMath.formatWeight(met))") }
            if let kilograms = activity.details.weightKgUsed {
                let unit = WeightUnit(preference: units)
                let weight = unit == .kg ? kilograms : kilograms * WeightUnit.poundsPerKilogram
                inputs.append("\(Int(weight.rounded())) \(unit.rawValue) body weight")
            }
            if let minutes = activity.durationMin { inputs.append(ActivitySummaryFormatter.durationText(minutes: minutes)) }
            method = inputs.isEmpty
                ? "Estimated from the session’s length and effort, net of what you’d burn sitting still."
                : "Estimated from effort: \(inputs.joined(separator: " × ")), net of what you’d burn sitting still."
        case nil:
            method = "Estimated from the session’s length and effort."
        }
        return method + " It isn’t added back to your food targets — your plan already counts training."
    }

    private func quoteCard(_ input: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What you logged").eyebrowStyle()
            Text(input)
                .font(.subheadline)
                .foregroundStyle(Design.Color.textSecondary)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

struct ActivityStatTile: View {
    let stat: ActivityDetailView.Stat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(stat.value)
                    .font(Design.Typeface.numeral(.title3, weight: .bold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !stat.unit.isEmpty {
                    Text(stat.unit)
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
            Text(stat.label).eyebrowStyle()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Design.Radius.control)
        .accessibilityElement(children: .combine)
    }
}

struct ExerciseSetTable: View {
    let exercise: ActivityExercise
    var units: String
    var isPR: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(exercise.name)
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                if isPR { TrainPRBadge() }
                Spacer(minLength: 6)
                if let best = exercise.workingSets.compactMap(StrengthMath.e1rmPounds).max() {
                    let unit = WeightUnit(preference: units)
                    Text("e1RM \(Int(StrengthMath.convert(pounds: best, to: unit).rounded()))")
                        .font(Design.Typeface.numeral(.caption, weight: .semibold))
                        .foregroundStyle(Design.Color.textTertiary)
                        .monospacedDigit()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("Set").eyebrowStyle()
                    Text("Weight").eyebrowStyle()
                    Text("Reps").eyebrowStyle()
                    Text("e1RM").eyebrowStyle()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                }
                ForEach(Array(numberedSets.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(row.set.isWarmup ? Design.Color.textTertiary : Design.Color.textSecondary)
                        Text(ActivitySummaryFormatter.weightLabel(row.set, units: units).map { $0 + (row.set.unit == WeightUnit(preference: units) ? " \(row.set.unit.rawValue)" : "") } ?? "BW")
                            .foregroundStyle(row.set.isWarmup ? Design.Color.textTertiary : Design.Color.textPrimary)
                        Text("\(row.set.reps)")
                            .foregroundStyle(row.set.isWarmup ? Design.Color.textTertiary : Design.Color.textPrimary)
                        Text(StrengthMath.e1rmPounds(row.set).map {
                            "\(Int(StrengthMath.convert(pounds: $0, to: WeightUnit(preference: units)).rounded()))"
                        } ?? "—")
                        .foregroundStyle(Design.Color.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                    }
                    .font(Design.Typeface.numeral(.subheadline, weight: .medium))
                    .monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    /// Warmups read "W"; working sets are numbered 1…n.
    private var numberedSets: [(label: String, set: ActivitySet)] {
        var number = 0
        return exercise.sets.map { set in
            if set.isWarmup { return ("W", set) }
            number += 1
            return ("\(number)", set)
        }
    }
}
