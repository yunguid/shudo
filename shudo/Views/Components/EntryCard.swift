import SwiftUI

struct EntryCard: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                if let url = entry.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure: Color.gray.opacity(0.1)
                        case .empty: ProgressView()
                        @unknown default: Color.gray.opacity(0.1)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary).font(.subheadline.weight(.semibold))
                Text("P \(Int(entry.proteinG)) • C \(Int(entry.carbsG)) • F \(Int(entry.fatG)) • \(Int(entry.caloriesKcal)) kcal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}


