import SwiftUI

struct EntryDetailView: View {
    let entryId: UUID
    @State private var detail: SupabaseService.EntryDetail?
    @State private var isLoading = true
    @State private var error: String?
    @State private var showDebug = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Photo section
                if let url = detail?.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img
                                .resizable()
                                .scaledToFill()
                                .frame(maxHeight: 280)
                                .clipped()
                        case .empty:
                            Rectangle()
                                .fill(Design.Color.elevated)
                                .frame(height: 200)
                                .overlay(ProgressView().tint(Design.Color.muted))
                        case .failure:
                            Rectangle()
                                .fill(Design.Color.elevated)
                                .frame(height: 100)
                                .overlay(
                                    Image(systemName: "photo")
                                        .foregroundStyle(Design.Color.muted)
                                )
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.l))
                }

                if let d = detail {
                    if let parsed = parseModelOutput(d.modelOutput) {
                        // Totals Card
                        VStack(alignment: .leading, spacing: 12) {
                            Label("TOTAL NUTRITION", systemImage: "flame.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Design.Color.muted)
                                .tracking(0.5)
                            
                            TotalsCard(macros: parsed.entryMacros)
                        }

                        // Items breakdown
                        if !parsed.items.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("BREAKDOWN", systemImage: "list.bullet")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Design.Color.muted)
                                    .tracking(0.5)
                                
                                VStack(spacing: 8) {
                                    ForEach(Array(parsed.items.enumerated()), id: \.0) { _, item in
                                        ItemCard(item: item)
                                    }
                                }
                            }
                        }

                        // Notes
                        if let notes = parsed.notes, !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("NOTES", systemImage: "text.alignleft")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Design.Color.muted)
                                    .tracking(0.5)
                                
                                Text(notes)
                                    .font(.subheadline)
                                    .foregroundStyle(Design.Color.ink)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            }
                        } else if let rawText = d.rawText, !rawText.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("NOTES", systemImage: "text.alignleft")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Design.Color.muted)
                                    .tracking(0.5)
                                
                                Text(rawText)
                                    .font(.subheadline)
                                    .foregroundStyle(Design.Color.ink)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
                            }
                        }

                        #if DEBUG
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                showDebug.toggle()
                            } label: {
                                HStack {
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(showDebug ? 90 : 0))
                                    Text("Developer Info")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundStyle(Design.Color.subtle)
                            }
                            .buttonStyle(.plain)
                            
                            if showDebug {
                                KeyValueListView(object: d.modelOutput)
                            }
                        }
                        .padding(.top, 8)
                        #endif
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.questionmark")
                                .font(.title)
                                .foregroundStyle(Design.Color.muted)
                            Text("No detailed nutrition data")
                                .font(.subheadline)
                                .foregroundStyle(Design.Color.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView().tint(Design.Color.accentPrimary)
                        Spacer()
                    }
                    .padding(.top, 40)
                }
                
                if let e = error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Design.Color.danger)
                        Text(e)
                            .font(.footnote)
                            .foregroundStyle(Design.Color.danger)
                    }
                    .padding(12)
                    .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                }
            }
            .padding(20)
        }
        .navigationTitle("Entry Details")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.Color.paper)
        .task { await load() }
    }

    private func load() async {
        let svc = SupabaseService()
        isLoading = true
        error = nil
        do {
            let userId = AuthSessionManager.shared.userId ?? ""
            if let profile = try await svc.fetchProfile(userId: userId) {
                detail = try await svc.fetchEntryDetail(id: entryId, timezone: profile.timezone)
            } else {
                detail = try await svc.fetchEntryDetail(id: entryId, timezone: TimeZone.autoupdatingCurrent.identifier)
            }
            isLoading = false
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Supporting Views

private struct TotalsCard: View {
    let macros: MacrosSummary
    
    var body: some View {
        VStack(spacing: 16) {
            // Calories - prominent
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calories")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                    Text("\(Int(macros.caloriesKcal.rounded()))")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Design.Color.ink)
                }
                Spacer()
                Text("kcal")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
            }
            
            // Macro pills
            HStack(spacing: 12) {
                MacroBadge(label: "Protein", value: macros.proteinG, color: Design.Color.ringProtein)
                MacroBadge(label: "Carbs", value: macros.carbsG, color: Design.Color.ringCarb)
                MacroBadge(label: "Fat", value: macros.fatG, color: Design.Color.ringFat)
            }
        }
        .padding(16)
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.l)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
    }
}

private struct MacroBadge: View {
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(Int(value.rounded()))g")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Design.Color.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: Design.Radius.m))
    }
}

private struct ItemCard: View {
    let item: ParsedItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Name and quantity
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.ink)
                
                Spacer()
                
                if let q = item.quantity {
                    Text("\(q.clean) \(item.unit ?? "")")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                }
            }
            
            // Compact macro row
            HStack(spacing: 16) {
                macroLabel("P", item.macros.proteinG, Design.Color.ringProtein)
                macroLabel("C", item.macros.carbsG, Design.Color.ringCarb)
                macroLabel("F", item.macros.fatG, Design.Color.ringFat)
                
                Spacer()
                
                Text("\(Int(item.macros.caloriesKcal.rounded())) kcal")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Design.Color.muted)
                    .monospacedDigit()
            }
        }
        .padding(14)
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
        .overlay(
            RoundedRectangle(cornerRadius: Design.Radius.m)
                .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
        )
    }
    
    private func macroLabel(_ letter: String, _ value: Double, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(Int(value.rounded()))g")
                .font(.caption)
                .foregroundStyle(Design.Color.ink)
                .monospacedDigit()
        }
    }
}

private struct KeyValueListView: View {
    let object: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sortedPairs(), id: \.0) { key, value in
                VStack(alignment: .leading, spacing: 2) {
                    Text(key)
                        .font(.caption2)
                        .foregroundStyle(Design.Color.subtle)
                    Text(stringify(value))
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.s))
            }
        }
    }

    private func sortedPairs() -> [(String, Any)] {
        object.keys.sorted().map { ($0, object[$0] as Any) }
    }

    private func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let dict = value as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { return s }
        if let arr = value as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
           let s = String(data: data, encoding: .utf8) { return s }
        return String(describing: value)
    }
}

// MARK: - Parsing

private struct MacrosSummary {
    let proteinG: Double
    let carbsG: Double
    let fatG: Double
    let caloriesKcal: Double
}

private struct ParsedItem: Identifiable {
    let id = UUID()
    let name: String
    let quantity: Double?
    let unit: String?
    let macros: MacrosSummary
}

private struct ParsedDetail {
    let entryMacros: MacrosSummary
    let items: [ParsedItem]
    let notes: String?
}

private func parseModelOutput(_ model: [String: Any]) -> ParsedDetail? {
    let root = (model["parsed"] as? [String: Any]) ?? model

    func toDouble(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) ?? 0 }
        return 0
    }

    func parseMacros(_ any: Any?) -> MacrosSummary {
        let m = (any as? [String: Any]) ?? [:]
        let nested = (m["macros_g"] as? [String: Any]) ?? (m["macros"] as? [String: Any]) ?? m
        let protein = toDouble(nested["protein_g"] ?? nested["protein"])
        let carbs = toDouble(nested["carbs_g"] ?? nested["carbohydrates_g"] ?? nested["carbohydrates"] ?? nested["carb"])
        let fat = toDouble(nested["fat_g"] ?? nested["fat"])
        let kcal = toDouble(nested["calories_kcal"] ?? nested["kcal"] ?? nested["calories"])
        return MacrosSummary(proteinG: protein, carbsG: carbs, fatG: fat, caloriesKcal: kcal)
    }

    let entryMacros = parseMacros(root["entry_macros"])

    var items: [ParsedItem] = []
    if let arr = root["items"] as? [[String: Any]] {
        for it in arr {
            let name = (it["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let quantity = toDouble(it["quantity"])
            let unit = it["unit"] as? String
            let macros = parseMacros(it)
            let q: Double? = quantity == 0 ? nil : quantity
            items.append(ParsedItem(name: (name?.isEmpty == false ? name! : "Item"), quantity: q, unit: unit, macros: macros))
        }
    }

    let notes = (root["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ParsedDetail(entryMacros: entryMacros, items: items, notes: (notes?.isEmpty == false ? notes : nil))
}

private extension Double {
    var clean: String {
        let v = self
        if v.rounded() == v { return String(Int(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
