import SwiftUI

/// A meal in the day thread, on Luke's side. While it analyzes (or fails,
/// or is being corrected) it is the existing streaming `EntryCard` — status
/// typewriter, researching globe, live analysis preview — on a receipt
/// surface; once complete it settles into the receipt: tile or photo,
/// title, P/C/F, and the big kcal number.
struct MealReceiptCard: View {
    let entry: Entry
    var isRetrying = false
    var onRetry: (() -> Void)?
    var animateCompletion = false
    var onCompletionRevealFinished: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSettled: Bool { entry.status == .complete && !isRetrying }

    private var wasCheckedOnline: Bool {
        entry.status == .complete && EntryResearchPresentation.hasVerifiedResearch(notes: entry.analysisNotes)
    }

    var body: some View {
        Group {
            if isSettled {
                receipt
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)))
            } else {
                EntryCard(
                    entry: entry,
                    isRetrying: isRetrying,
                    onRetry: onRetry
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .frame(width: Design.Layout.threadCardWidth, alignment: .leading)
                .cardSurface(radius: Design.Radius.card)
                .overlay {
                    if entry.status == .failed {
                        RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                            .stroke(Design.Color.danger.opacity(0.45), lineWidth: 1)
                    }
                }
            }
        }
        .animation(Design.Motion.gated(Design.Motion.arrive, reduceMotion: reduceMotion), value: isSettled)
        .task(id: animateCompletion) {
            guard animateCompletion else { return }
            // The receipt's own arrival is the reveal; hand the flag back.
            try? await Task.sleep(for: .milliseconds(450))
            onCompletionRevealFinished?()
        }
    }

    private var receipt: some View {
        HStack(alignment: .center, spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    MacroInline(p: entry.proteinG, c: entry.carbsG, f: entry.fatG)
                    if wasCheckedOnline {
                        Image(systemName: "globe")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Design.Color.textTertiary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Protein \(Int(entry.proteinG.rounded()))g, Carbs \(Int(entry.carbsG.rounded()))g, Fat \(Int(entry.fatG.rounded()))g, Calories \(Int(entry.caloriesKcal.rounded()))kcal"
                        + (wasCheckedOnline ? ", checked online" : "")
                )
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 0) {
                Text(Int(entry.caloriesKcal.rounded()).formatted())
                    .font(Design.Typeface.numeral(.title3, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Design.Color.textPrimary)
                    .contentTransition(.numericText(value: entry.caloriesKcal))
                Text("kcal").eyebrowStyle()
            }
            .accessibilityHidden(true)
        }
        .padding(12)
        .frame(width: Design.Layout.threadCardWidth)
        .cardSurface(radius: Design.Radius.card)
    }

    @ViewBuilder
    private var tile: some View {
        if let url = entry.imageURL {
            AsyncImage(url: url, transaction: .init(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: glyphTile
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityLabel("Meal photo")
        } else {
            glyphTile
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        }
    }

    private var glyphTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(hex: 0x5B3A1E), Color(hex: 0x2A1D12)],
                startPoint: .top,
                endPoint: .bottom
            ))
            .overlay(
                Image(systemName: MealGlyphPolicy.symbol(for: entry.summary))
                    .foregroundStyle(Design.Color.honey.opacity(0.85))
            )
    }
}

/// The day's body check-in on Luke's side: a veiled photo thumbnail (tap
/// the eye to peek), "Check-in · Day N", and the weight or "no scale yet".
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
        HStack(spacing: 12) {
            if checkIn.hasPhoto {
                thumbnail
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(dayLabel.map { "Check-in · \($0)" } ?? "Check-in")
                    .eyebrowStyle(Design.Color.honey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(checkIn.hasPhoto ? "Photo logged" : "Weight logged")
                    .font(.headline)
                    .foregroundStyle(Design.Color.textPrimary)
                Text(weightLine)
                    .font(.footnote)
                    .foregroundStyle(Design.Color.textTertiary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: Design.Layout.threadCardWidth)
        .background(Design.Color.surface1, in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .stroke(Design.Color.ember.opacity(0.45), lineWidth: 1)
        )
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

    private var weightLine: String {
        guard let kilograms = checkIn.weightKG else { return "Weight — no scale yet" }
        return "\(String(format: "%.1f", BodyUnits.display(kilograms, units: units))) \(BodyUnits.label(units))"
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Design.Color.textPrimary.opacity(0.8))
            }
        }
        .frame(width: 66, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(Design.Motion.snap) { revealed.toggle() }
        }
        .accessibilityLabel(revealed ? "Check-in photo" : "Hidden check-in photo")
        .accessibilityHint("Shows or hides the photo")
    }
}
