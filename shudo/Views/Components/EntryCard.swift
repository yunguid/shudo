import SwiftUI

struct EntryCard: View {
    let entry: Entry
    
    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.summary)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                macroLine
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardStyle()
    }
    
    private var thumbnail: some View {
        ZStack {
            if let url = entry.imageURL {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    case .empty: Color.gray.opacity(0.08)
                    case .failure: Color.gray.opacity(0.08)
                    @unknown default: Color.gray.opacity(0.08)
                    }
                }
            } else {
                Color.gray.opacity(0.08)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
    
    private var macroLine: some View {
        HStack(spacing: 10) {
            Text("P \(Int(entry.proteinG))")
            Text("C \(Int(entry.carbsG))")
            Text("F \(Int(entry.fatG))")
            Text("\(Int(entry.caloriesKcal)) kcal")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}


