import SwiftUI

struct EntryDetailView: View {
	let entryId: UUID
	@State private var detail: SupabaseService.EntryDetail?
	@State private var isLoading = true
	@State private var error: String?
	@State private var showDebug = false

	var body: some View {
		ScrollView {
			VStack(alignment: .leading, spacing: 16) {
				if let url = detail?.imageURL {
					AsyncImage(url: url) { img in
						img.resizable().scaledToFit()
					} placeholder: { ProgressView() }
					.clipShape(RoundedRectangle(cornerRadius: Design.Radius.l))
				}

				if let d = detail {
					if let parsed = parseModelOutput(d.modelOutput) {
						// Totals
						SectionHeader("Totals")
						TotalsView(macros: parsed.entryMacros)

						// Items
						if parsed.items.isEmpty == false {
							SectionHeader("Items")
							VStack(alignment: .leading, spacing: 12) {
								ForEach(Array(parsed.items.enumerated()), id: \.0) { _, it in
									ItemRow(item: it)
								}
							}
						}

						// Notes
						if let t = parsed.notes, t.isEmpty == false {
							SectionHeader("Notes")
							Text(t).foregroundStyle(Design.Color.ink)
						} else if let t = d.rawText, t.isEmpty == false {
							SectionHeader("Notes")
							Text(t).foregroundStyle(Design.Color.ink)
						}

						#if DEBUG
						SectionHeader("Developer Info")
						Button(action: { showDebug.toggle() }) {
							Text(showDebug ? "Hide Raw" : "Show Raw")
						}
						.buttonStyle(.bordered)
						if showDebug {
							KeyValueListView(object: d.modelOutput)
						}
						#endif
					} else {
						SectionHeader("Details")
						Text("No structured details available.")
							.foregroundStyle(Design.Color.muted)
					}
				}

				if isLoading { ProgressView().padding(.top, 20) }
				if let e = error { Text(e).foregroundStyle(.red).font(.footnote) }
			}
			.padding(16)
		}
		.navigationTitle("Entry Details")
		.navigationBarTitleDisplayMode(.inline)
		.task { await load() }
	}

	private func load() async {
		let svc = SupabaseService()
		isLoading = true; error = nil
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

private struct KeyValueListView: View {
	let object: [String: Any]

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(sortedPairs(), id: \.0) { key, value in
				VStack(alignment: .leading, spacing: 4) {
					Text(key).font(.caption).foregroundStyle(Design.Color.muted)
					Text(stringify(value)).font(.body).foregroundStyle(Design.Color.ink).textSelection(.enabled)
				}
				.padding(12)
				.background(RoundedRectangle(cornerRadius: Design.Radius.m).fill(Design.Color.fill))
				.overlay(RoundedRectangle(cornerRadius: Design.Radius.m).stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline))
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


// MARK: - Structured Parsing & Views

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
	let confidence: Double?
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
			let conf = it["confidence"] as? Double
			let q: Double? = quantity == 0 ? nil : quantity
			items.append(ParsedItem(name: (name?.isEmpty == false ? name! : "Item"), quantity: q, unit: unit, macros: macros, confidence: conf))
		}
	}

	let notes = (root["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
	return ParsedDetail(entryMacros: entryMacros, items: items, notes: (notes?.isEmpty == false ? notes : nil))
}

private struct TotalsView: View {
	let macros: MacrosSummary
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				MacroPill(label: "P", value: macros.proteinG, unit: "g")
				MacroPill(label: "C", value: macros.carbsG, unit: "g")
				MacroPill(label: "F", value: macros.fatG, unit: "g")
				Spacer(minLength: 0)
				MacroPill(label: nil, value: macros.caloriesKcal, unit: "kcal")
			}
		}
	}
}

private struct MacroPill: View {
	let label: String?
	let value: Double
	let unit: String
	var body: some View {
		HStack(spacing: 6) {
			if let label {
				 Text(label)
				 .font(.body)
				 .foregroundStyle(Design.Color.muted)
			}

			Text("\(Int(value.rounded()))\(unit)")
				.font(.footnote)
				.monospacedDigit()
				.foregroundStyle(Design.Color.ink)
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.background(RoundedRectangle(cornerRadius: Design.Radius.m).fill(Design.Color.fill))
		.overlay(RoundedRectangle(cornerRadius: Design.Radius.m).stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline))
	}
}

private struct ItemRow: View {
	let item: ParsedItem
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline) {
				Text(item.name)
					.font(.subheadline.weight(.semibold))
					.foregroundStyle(Design.Color.ink)
				Spacer(minLength: 8)
				if let c = item.confidence {
					ConfidencePill(value: c)
				}
			}
			if let q = item.quantity {
				Text("\(q.clean) \(item.unit ?? "")")
					.font(.footnote)
					.foregroundStyle(Design.Color.muted)
			}
			HStack(spacing: 12) {
				MacroPill(label: "P", value: item.macros.proteinG, unit: "g")
				MacroPill(label: "C", value: item.macros.carbsG, unit: "g")
				MacroPill(label: "F", value: item.macros.fatG, unit: "g")
				Spacer(minLength: 0)
				MacroPill(label: nil, value: item.macros.caloriesKcal, unit: "kcal")
			}
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: Design.Radius.l).fill(Design.Color.fill))
		.overlay(RoundedRectangle(cornerRadius: Design.Radius.l).stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline))
	}
}

private struct ConfidencePill: View {
	let value: Double // 0...1
	var body: some View {
		let pct = max(0, min(1, value))
		HStack(spacing: 6) {
			Image(systemName: "checkmark.seal")
				.imageScale(.small)
				.foregroundStyle(Design.Color.muted)
			Text("\(Int((pct * 100).rounded()))%")
				.font(.footnote)
				.foregroundStyle(Design.Color.muted)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(RoundedRectangle(cornerRadius: Design.Radius.pill).fill(Design.Color.fill))
		.overlay(RoundedRectangle(cornerRadius: Design.Radius.pill).stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline))
		.accessibilityLabel("Confidence \(Int((pct * 100).rounded())) percent")
	}
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


