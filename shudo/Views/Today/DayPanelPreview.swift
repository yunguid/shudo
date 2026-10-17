import SwiftUI
import UIKit

/// Offline extras for the open day's meal list (DEBUG previews only):
/// `-shudoDayPanelPreview photos` gives two meals a photo, `long` adds a
/// grazing afternoon so the list has to scroll inside the panel (comma-
/// separate to combine). Only the header's list changes; release builds
/// pass the meals straight through.
enum DayPanelPreview {
    static func meals(_ meals: [Entry]) -> [Entry] {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-shudoDayPanelPreview"),
              arguments.indices.contains(flag + 1),
              let first = meals.first
        else { return meals }
        let options = Set(arguments[flag + 1].split(separator: ",").map(String.init))
        var result = meals
        if options.contains("long") {
            result += grazing(on: first)
            result.sort { $0.createdAt < $1.createdAt }
        }
        if options.contains("photos") {
            for (index, tint) in [(0, UIColor(red: 0.86, green: 0.62, blue: 0.30, alpha: 1)),
                                  (1, UIColor(red: 0.48, green: 0.62, blue: 0.36, alpha: 1))]
            where result.indices.contains(index) {
                result[index].imageURL = plate(named: "day-panel-plate-\(index)", tint: tint)
            }
        }
        return result
        #else
        return meals
        #endif
    }

    #if DEBUG
    /// `-shudoDayPanelMotion`: opens the day the way a tap does 2 s after
    /// launch and folds it 2.5 s later, for frame-by-frame motion review.
    @MainActor
    static func playMotion(_ setOpen: (Bool) -> Void) async {
        guard ProcessInfo.processInfo.arguments.contains("-shudoDayPanelMotion") else { return }
        try? await Task.sleep(for: .seconds(2))
        setOpen(true)
        try? await Task.sleep(for: .seconds(2.5))
        setOpen(false)
    }

    /// Five more small meals through the afternoon, on the same day.
    private static func grazing(on anchor: Entry) -> [Entry] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: ShellPreviewFixtures.timezone) ?? .autoupdatingCurrent
        let start = calendar.startOfDay(for: anchor.createdAt)
        func at(_ hour: Int, _ minute: Int) -> Date {
            start.addingTimeInterval(TimeInterval(hour * 3_600 + minute * 60))
        }
        let rows: [(Int, Int, String, Double, Double, Double, Double)] = [
            (10, 5, "Protein shake, whole milk", 44, 28, 12, 400),
            (11, 20, "Banana, peanut butter", 9, 31, 16, 290),
            (13, 30, "Rice cakes, honey", 3, 46, 1, 210),
            (16, 45, "Greek yogurt, granola", 26, 48, 9, 380),
            (17, 30, "Beef jerky", 18, 6, 2, 120),
        ]
        return rows.enumerated().map { index, row in
            Entry(
                id: UUID(uuidString: String(format: "44444444-4444-4444-8444-%012d", index))!,
                createdAt: at(row.0, row.1), summary: row.2, imageURL: nil,
                proteinG: row.3, carbsG: row.4, fatG: row.5, caloriesKcal: row.6,
                localDay: anchor.localDay, status: .complete
            )
        }
    }

    /// A stand-in plate written to the caches folder once, so the thumb
    /// loads like a real photo URL.
    private static func plate(named name: String, tint: UIColor) -> URL? {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let url = folder.appendingPathComponent("\(name).jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let size = CGSize(width: 240, height: 240)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            UIColor(red: 0.20, green: 0.15, blue: 0.11, alpha: 1).setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 24, y: 24, width: 192, height: 192))
            tint.setFill()
            cg.fillEllipse(in: CGRect(x: 60, y: 62, width: 110, height: 84))
            UIColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 120, y: 120, width: 70, height: 60))
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        try? data.write(to: url)
        return url
    }
    #endif
}
