import SwiftUI

/// A meal in the day thread, on Luke's side: title, P/C/F and the kcal
/// number. While Shudo works on it the macro line is one quiet shimmer —
/// the research, sources and confidence live in the meal's detail, not
/// here — and the receipt settles in place when the numbers land.
struct MealReceiptCard: View {
    let entry: Entry
    var isRetrying = false
    var onRetry: (() -> Void)?
    var animateCompletion = false
    var onCompletionRevealFinished: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSettled: Bool { entry.status == .complete && !isRetrying }
    private var isWorking: Bool { isRetrying || entry.status.isProcessing }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let url = entry.imageURL {
                MealPhotoTile(url: url)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSettled ? Design.Color.textPrimary : Design.Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                detail
            }
            Spacer(minLength: 8)
            if isSettled {
                kcal.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .trailing)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Design.Layout.threadCardWidth, alignment: .leading)
        .cardSurface(radius: Design.Radius.card)
        .overlay {
            if entry.status == .failed {
                RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                    .stroke(Design.Color.danger.opacity(0.4), lineWidth: 1)
            }
        }
        .animation(Design.Motion.gated(Design.Motion.arrive, reduceMotion: reduceMotion), value: isSettled)
        .task(id: animateCompletion) {
            guard animateCompletion else { return }
            // The receipt settling in place is the reveal; hand the flag back.
            try? await Task.sleep(for: .milliseconds(450))
            onCompletionRevealFinished?()
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isSettled {
            MacroInline(p: entry.proteinG, c: entry.carbsG, f: entry.fatG)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Protein \(Int(entry.proteinG.rounded()))g, Carbs \(Int(entry.carbsG.rounded()))g, Fat \(Int(entry.fatG.rounded()))g, Calories \(Int(entry.caloriesKcal.rounded()))kcal"
                )
        } else if isWorking {
            ThreadShimmerLine()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isRetrying ? "Retrying" : entry.displayStatusMessage)
                .accessibilityAddTraits(.updatesFrequently)
        } else if entry.status == .failed {
            HStack(spacing: 10) {
                Text(entry.displayStatusMessage)
                    .font(.caption)
                    .foregroundStyle(Design.Color.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.canRetry, let onRetry {
                    Button("Retry", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Design.Color.ember)
                        .buttonStyle(.plain)
                        .contentShape(Rectangle().inset(by: -10))
                        .accessibilityLabel("Retry meal analysis")
                }
            }
        } else {
            Text(entry.displayStatusMessage)
                .font(.caption)
                .foregroundStyle(Design.Color.textTertiary)
                .lineLimit(1)
        }
    }

    private var kcal: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(Int(entry.caloriesKcal.rounded()).formatted())
                .font(Design.Typeface.numeral(.title3, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Design.Color.textPrimary)
                .contentTransition(.numericText(value: entry.caloriesKcal))
            Text("kcal")
                .font(Design.Typeface.meta)
                .foregroundStyle(Design.Color.textTertiary)
        }
        .accessibilityHidden(true)
    }
}

/// The one processing line every thread card uses: a short shimmering bar
/// where the numbers will land. No phases, no narration.
struct ThreadShimmerLine: View {
    var width: CGFloat = 112

    var body: some View {
        Capsule()
            .fill(Design.Color.surface3)
            .frame(width: width, height: 8)
            .shimmering()
            .padding(.vertical, 3)
    }
}

private struct MealPhotoTile: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
            if case .success(let image) = phase {
                image.resizable().scaledToFill()
            } else {
                Design.Color.surface2
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityLabel("Meal photo")
    }
}

/// A finished workout in the thread, matching the meal receipt: a small
/// kind glyph, the session, its one-line summary, and minutes as the
/// number. PRs are Shudo's to celebrate (his card follows), and live or
/// unsent states use the Train tab's full `ActivityCard`.
struct WorkoutReceiptCard: View {
    let activity: Activity
    let units: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Design.Color.textPrimary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: activity.kind.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(ActivityKindTile.tint(for: activity.kind))
                }
                .labelStyle(TightLabelStyle())
                if let subtitle = ActivitySummaryFormatter.subtitle(for: activity, units: units) {
                    Text(subtitle)
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let minutes = activity.durationMin, minutes > 0 {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(Int(minutes.rounded()).formatted())
                        .font(Design.Typeface.numeral(.title3, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Design.Color.textPrimary)
                    Text("min")
                        .font(Design.Typeface.meta)
                        .foregroundStyle(Design.Color.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: Design.Layout.threadCardWidth, alignment: .leading)
        .cardSurface(radius: Design.Radius.card)
        .accessibilityElement(children: .combine)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// The day's body check-in on Luke's side: a veiled photo (tap to peek),
/// "Check-in", and the weight — or the bulk day when there's no scale.
struct CheckInThreadCard: View {
    let checkIn: WeightCheckIn
    let dayLabel: String?
    let units: String
    let photoLoader: BodyPhotoLoader
    var onOpenBody: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 14) {
            if checkIn.hasPhoto {
                thumbnail
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Check-in")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Design.Typeface.numeral(.footnote, weight: .medium))
                        .foregroundStyle(Design.Color.textSecondary)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Design.Layout.threadCardWidth)
        .cardSurface(radius: Design.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .onTapGesture(perform: onOpenBody)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the Body tab")
        .task(id: checkIn.progressPhotoPath) {
            guard let path = checkIn.progressPhotoPath else { return }
            image = photoLoader.cachedImage(path: path, maxPixel: BodyPhotoSize.thumb)
            if image == nil { image = await photoLoader.image(path: path, maxPixel: BodyPhotoSize.thumb) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { revealed = false }
        }
    }

    private var detail: String? {
        if let kilograms = checkIn.weightKG {
            return "\(String(format: "%.1f", BodyUnits.display(kilograms, units: units))) \(BodyUnits.label(units))"
        }
        return dayLabel
    }

    private var thumbnail: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x3A2C20), Color(hex: 0x1A1511)], startPoint: .top, endPoint: .bottom)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: revealed ? 0 : 12)
                    .allowsHitTesting(false)
            }
            if !revealed {
                Image(systemName: "eye.slash.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary.opacity(0.7))
            }
        }
        .frame(width: 48, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Design.Motion.snap) { revealed.toggle() }
        }
        .accessibilityLabel(revealed ? "Check-in photo" : "Hidden check-in photo")
        .accessibilityHint("Shows or hides the photo")
    }
}
