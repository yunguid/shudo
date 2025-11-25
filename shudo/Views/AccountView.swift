import SwiftUI

struct AccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: Profile?
    @State private var isLoading = true
    @State private var error: String?
    @State private var email: String = "-"

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Profile Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Design.Color.accentPrimary.opacity(0.2), Design.Color.accentPrimary.opacity(0.05)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                        Image(systemName: "person.fill")
                            .font(.title)
                            .foregroundStyle(Design.Color.accentPrimary)
                    }
                    
                    VStack(spacing: 4) {
                        Text(email)
                            .font(.headline)
                            .foregroundStyle(Design.Color.ink)
                        Text("Member")
                            .font(.caption)
                            .foregroundStyle(Design.Color.muted)
                    }
                }
                .padding(.top, 20)
                
                if let p = profile {
                    // Profile Details
                    VStack(alignment: .leading, spacing: 16) {
                        sectionLabel("PROFILE")
                        
                        VStack(spacing: 0) {
                            infoRow(icon: "globe", label: "Timezone", value: p.timezone)
                            Divider().background(Design.Color.rule)
                            infoRow(icon: "ruler", label: "Units", value: p.units.capitalized)
                            if let h = p.heightCM {
                                Divider().background(Design.Color.rule)
                                infoRow(icon: "arrow.up.and.down", label: "Height", value: "\(Int(h)) cm")
                            }
                            if let w = p.weightKG {
                                Divider().background(Design.Color.rule)
                                infoRow(icon: "scalemass", label: "Weight", value: "\(String(format: "%.1f", w)) kg")
                            }
                            if let t = p.targetWeightKG {
                                Divider().background(Design.Color.rule)
                                infoRow(icon: "target", label: "Goal", value: "\(String(format: "%.1f", t)) kg")
                            }
                        }
                        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.l))
                    }
                    
                    // Macro Targets
                    VStack(alignment: .leading, spacing: 16) {
                        sectionLabel("DAILY TARGETS")
                        
                        let target = p.dailyMacroTarget
                        HStack(spacing: 12) {
                            targetCard("Calories", "\(Int(target.caloriesKcal))", "kcal", Design.Color.warning)
                            targetCard("Protein", "\(Int(target.proteinG))", "g", Design.Color.ringProtein)
                        }
                        HStack(spacing: 12) {
                            targetCard("Carbs", "\(Int(target.carbsG))", "g", Design.Color.ringCarb)
                            targetCard("Fat", "\(Int(target.fatG))", "g", Design.Color.ringFat)
                        }
                    }
                }
                
                if isLoading {
                    ProgressView()
                        .tint(Design.Color.accentPrimary)
                        .padding(.top, 40)
                }
                
                if let e = error {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Design.Color.danger)
                        Text(e)
                            .font(.caption)
                            .foregroundStyle(Design.Color.danger)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                }
                
                Spacer(minLength: 40)
                
                // Sign Out Button
                Button {
                    AuthSessionManager.shared.signOut()
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("Sign Out")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Design.Color.danger)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Design.Color.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: Design.Radius.m))
                }
            }
            .padding(20)
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .background(Design.Color.paper)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Design.Color.accentPrimary)
            }
        }
        .task { await load() }
    }
    
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Design.Color.muted)
            .tracking(0.5)
    }
    
    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
                    .frame(width: 20)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Design.Color.muted)
            }
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Design.Color.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    
    private func targetCard(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Design.Color.ink)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(Design.Color.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Design.Color.elevated, in: RoundedRectangle(cornerRadius: Design.Radius.m))
    }

    private func load() async {
        let svc = SupabaseService()
        isLoading = true
        do {
            if let id = AuthSessionManager.shared.userId, let p = try await svc.fetchProfile(userId: id) {
                profile = p
            }
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
