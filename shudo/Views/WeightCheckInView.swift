import SwiftUI

/// 1.x entry point, kept source-compatible for callers that still present
/// "the weigh-in sheet". It is now the 2.0 body check-in: photo first, weight
/// optional. A day that already has its photo opens straight on the weight
/// entry (voice first) so adding the weight later never retakes the photo.
struct WeightCheckInView: View {
    let localDay: String
    let units: String
    let existing: WeightCheckIn?
    let service: SupabaseService
    let onSaved: (WeightCheckIn) -> Void

    init(
        localDay: String,
        units: String,
        existing: WeightCheckIn?,
        service: SupabaseService = SupabaseService(),
        onSaved: @escaping (WeightCheckIn) -> Void
    ) {
        self.localDay = localDay
        self.units = units
        self.existing = existing
        self.service = service
        self.onSaved = onSaved
    }

    var body: some View {
        BodyCheckInFlow(
            localDay: localDay,
            units: units,
            existing: existing,
            start: existing?.hasPhoto == true ? .weight : .camera,
            service: LiveBodyService(supabase: service),
            onSaved: onSaved
        )
    }
}
