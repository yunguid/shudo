import SwiftUI
import UIKit

enum DayEdgeSwipePolicy {
    enum Edge: Equatable {
        case left
        case right
    }

    static let edgeWidth: CGFloat = 24
    static let minimumTravel: CGFloat = 72
    static let minimumFlickTravel: CGFloat = 28
    static let projectedFlickTravel: CGFloat = 130
    static let horizontalDominance: CGFloat = 1.35

    static func originatingEdge(startX: CGFloat, containerWidth: CGFloat) -> Edge? {
        guard containerWidth > edgeWidth * 2 else { return nil }
        if startX <= edgeWidth { return .left }
        if startX >= containerWidth - edgeWidth { return .right }
        return nil
    }

    static func dayDelta(
        startX: CGFloat,
        translation: CGSize,
        predictedEndTranslation: CGSize,
        containerWidth: CGFloat
    ) -> Int? {
        guard let edge = originatingEdge(startX: startX, containerWidth: containerWidth) else {
            return nil
        }

        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal >= minimumFlickTravel,
            horizontal >= vertical * horizontalDominance
        else { return nil }

        let directionMatchesEdge =
            switch edge {
            case .left:
                translation.width > 0 && predictedEndTranslation.width > 0
            case .right:
                translation.width < 0 && predictedEndTranslation.width < 0
            }
        guard directionMatchesEdge else { return nil }

        let passedDistance = horizontal >= minimumTravel
        let passedVelocityProjection = abs(predictedEndTranslation.width) >= projectedFlickTravel
        guard passedDistance || passedVelocityProjection else { return nil }
        return edge == .left ? -1 : 1
    }

    static func previewOffset(
        startX: CGFloat,
        translation: CGSize,
        containerWidth: CGFloat
    ) -> CGFloat {
        // Same thresholds dayDelta accepts: without them, a diagonal drag
        // that starts near a bezel nudges the whole day sideways and snaps
        // back — pure jitter for a gesture that was never going to commit.
        guard let edge = originatingEdge(startX: startX, containerWidth: containerWidth),
            abs(translation.width) >= minimumFlickTravel,
            abs(translation.width) >= abs(translation.height) * horizontalDominance
        else { return 0 }
        switch edge {
        case .left where translation.width > 0:
            return min(18, translation.width * 0.12)
        case .right where translation.width < 0:
            return max(-18, translation.width * 0.12)
        default:
            return 0
        }
    }
}

/// Shown under a meal whose estimate update failed: the previous estimate is
/// back on the card, and the preserved correction can be retried or let go
/// without retyping or re-recording anything. A quiet note beneath the
/// receipt, not another box: one line of what happened, two text actions.
struct CorrectionRetryBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(EntryCorrectionPresentation.failureHeadline)
                    .font(Design.Typeface.text(.caption, weight: .semibold))
                    .foregroundStyle(Design.Color.danger)
                Text(message)
                    .font(Design.Typeface.text(.caption))
                    .foregroundStyle(Design.Color.textSecondary)
            }
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)

            HStack(spacing: Design.Space.l) {
                Button("Let it go", action: onDismiss)
                    .foregroundStyle(Design.Color.textSecondary)
                    .accessibilityLabel("Dismiss update failure")
                    .accessibilityHint("Discards the correction")
                Button("Retry", action: onRetry)
                    .foregroundStyle(Design.Color.ember)
                    .accessibilityLabel("Retry meal update")
            }
            .font(Design.Typeface.text(.footnote, weight: .semibold))
            .buttonStyle(.plain)
            // ~44pt tap targets beyond the words.
            .contentShape(Rectangle().inset(by: -12))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, Design.Space.xs)
        .padding(.top, 2)
    }
}

/// The account button's avatar. Settings owns uploading and caching the
/// photo; this reuses the same disk cache first and falls back to one
/// network fetch, so the corner shows an initial only when the user has no
/// photo (or a transient fetch fails — the next appearance retries).
struct AccountAvatarIcon: View {
    let userId: String
    let avatarPath: String?
    var displayName: String?
    var loadsRemotely = true
    @State private var avatar: UIImage?

    var body: some View {
        Group {
            if let avatar {
                Image(uiImage: avatar)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Design.Color.hairline, lineWidth: Design.Stroke.hairline))
            } else {
                // A quiet seal, not a bright disc: the initial in serif on
                // walnut, so the corner doesn't compete with the day.
                Text(initial)
                    .font(Design.Typeface.display(.subheadline, weight: .medium))
                    .foregroundStyle(Design.Color.honey)
                    .frame(width: 30, height: 30)
                    .background(Design.Color.surface2, in: Circle())
                    .overlay(Circle().stroke(Design.Color.hairline, lineWidth: Design.Stroke.hairline))
            }
        }
        .task(id: avatarPath) { await loadAvatar() }
    }

    private var initial: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.first.map { String($0).uppercased() } ?? "•"
    }

    private func loadAvatar() async {
        guard let avatarPath else {
            avatar = nil
            return
        }
        if let cached = ProfilePhotoCache.load(userId: userId, expectedPath: avatarPath),
            let image = UIImage(data: cached)
        {
            avatar = image
            return
        }
        guard loadsRemotely else { return }
        do {
            let data = try await SupabaseService().fetchProfilePhoto(path: avatarPath)
            guard let image = UIImage(data: data) else { return }
            avatar = image
            ProfilePhotoCache.save(data, userId: userId, path: avatarPath)
        } catch {
            // Keep the initial; Settings and later appearances retry the fetch.
        }
    }
}

/// DateFormatter setup is expensive and body reads these on every render, so
/// hold the instances in @State and rebuild only when the timezone changes.
final class DayFormatterCache {
    private(set) var calendar = Calendar(identifier: .gregorian)
    private(set) var localDayFormatter = DateFormatter()
    private(set) var timeFormatter = DateFormatter()
    private var timezoneIdentifier: String?

    func resolved(for timezoneIdentifier: String) -> DayFormatterCache {
        guard timezoneIdentifier != self.timezoneIdentifier else { return self }
        self.timezoneIdentifier = timezoneIdentifier
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezoneIdentifier) ?? .autoupdatingCurrent
        localDayFormatter.calendar = calendar
        localDayFormatter.locale = Locale(identifier: "en_US_POSIX")
        localDayFormatter.timeZone = calendar.timeZone
        localDayFormatter.dateFormat = "yyyy-MM-dd"
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.locale = Locale(identifier: "en_US")
        timeFormatter.dateFormat = "h:mm a"
        return self
    }

    /// Noon on `localDay` in this timezone — a safe `Date` for day-keyed APIs.
    func date(forLocalDay localDay: String) -> Date? {
        guard let midnight = localDayFormatter.date(from: localDay) else { return nil }
        return calendar.date(byAdding: .hour, value: 12, to: midnight)
    }
}
