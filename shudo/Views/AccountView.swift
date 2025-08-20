import SwiftUI

struct AccountView: View {
	@State private var profile: Profile?
	@State private var isLoading = true
	@State private var error: String?
	@State private var email: String = "-"

	var body: some View {
		Form {
			if let p = profile {
				Section("Account") {
					Text("Email: \(email)")
				}
				Section("Profile") {
					Text("Timezone: \(p.timezone)")
					Text("Units: \(p.units)")
					if let h = p.heightCM { Text("Height: \(Int(h)) cm") }
					if let w = p.weightKG { Text("Weight: \(String(format: "%.1f", w)) kg") }
					if let t = p.targetWeightKG { Text("Target: \(String(format: "%.1f", t)) kg") }
				}
			}
			if isLoading { ProgressView() }
			if let e = error { Text(e).foregroundStyle(.red) }
		}
		.navigationTitle("Account")
		.task { await load() }
	}

	private func load() async {
		let svc = SupabaseService()
		isLoading = true
		do {
			if let id = AuthSessionManager.shared.userId, let p = try await svc.fetchProfile(userId: id) {
				profile = p
			}
			// Fetch email from auth user endpoint
			let token = try await AuthSessionManager.shared.getAccessToken()
			var req = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("/auth/v1/user"))
			req.httpMethod = "GET"
			req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
			req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
			let (data, resp) = try await URLSession.shared.data(for: req)
			if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
			   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
				email = (obj["email"] as? String) ?? email
			}
			isLoading = false
		} catch {
			isLoading = false
			self.error = error.localizedDescription
		}
	}
}


