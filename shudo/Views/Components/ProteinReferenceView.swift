import SwiftUI

/// Educational food weights, never a photo-based portion measurement.
struct ProteinReferenceView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Food weight ≠ protein weight")
                    .font(.title2.bold())
                Text("An 85g portion of cooked chicken is about 26g of protein. The rest includes water, fat, and other components.")
                reference("Chicken breast, cooked", protein: 26, source: "Allina Health", url: "https://www.allinahealth.org/health-conditions-and-treatments/eat-healthy/nutrition-basics/protein/meat-poultry-and-fish")
                reference("Turkey breast, meat only, roasted", protein: 25.6, source: "USDA · SR Legacy (2018)", url: "https://www.nal.usda.gov/sites/default/files/page-files/Protein.pdf")
                reference("Coho salmon, wild, cooked with moist heat", protein: 23.3, source: "USDA · SR Legacy (2018)", url: "https://www.nal.usda.gov/sites/default/files/page-files/Protein.pdf")
                Text("Each bar represents 85g of cooked food by weight. The colored part represents its approximate protein content, not a visible part of the food or a life-size portion.")
                    .font(.footnote)
                Text("A palm-sized piece can help you picture a portion, but hands and food thickness vary. Weigh the edible portion for a better estimate and say whether it was weighed raw or cooked. Use your product’s label when available.")
                    .font(.footnote)
                Link("Portion guide · Johns Hopkins", destination: URL(string: "https://www.hopkinsmedicine.org/-/media/migration/all-childrens-hospital/documents/services/healthy-weight-initiative/goslowwhoafoodlistspdf.pdf")!)
                    .font(.footnote)
                Text("These are reference foods, not serving prescriptions. MyPlate’s “ounce-equivalents” describe food groups; they do not mean ounces of pure protein.")
                    .font(.footnote)
            }
            .foregroundStyle(Design.Color.ink)
            .padding(20)
        }
        .background(AppBackground())
        .navigationTitle("Protein portions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reference(_ name: String, protein: Double, source: String, url: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.headline)
            Text("3 oz (about 85g) cooked food → about \(Int(protein.rounded()))g protein")
                .font(.subheadline)
            GeometryReader { geometry in
                Capsule().fill(Design.Color.rule)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Design.Color.ringProtein)
                            .frame(width: geometry.size.width * protein / 85)
                    }
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            Link(source, destination: URL(string: url)!).font(.caption)
        }
        .padding(16)
        .background(Design.Color.glassFill, in: RoundedRectangle(cornerRadius: Design.Radius.card))
    }
}
