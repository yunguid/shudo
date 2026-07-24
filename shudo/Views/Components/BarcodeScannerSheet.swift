import AVFoundation
import SwiftUI
import VisionKit

/// Live barcode/QR scanner that resolves packaged-food nutrition from
/// Open Food Facts and hands the composer an editable description.
/// Falls back to manual code entry when live scanning is unavailable
/// (Simulator, camera denied) or a code will not read.
struct BarcodeScannerSheet: View {
    enum LookupState: Equatable {
        case idle
        case looking(code: String)
        case missing(code: String)
        case failed
    }

    @Environment(\.dismiss) private var dismiss
    @State private var lookupState: LookupState = .idle
    @State private var manualCode = ""
    @State private var isShowingManualEntry = false
    @State private var handledPayloads: Set<String> = []
    @State private var lookupTask: Task<Void, Never>?

    let client: OpenFoodFactsClient
    let onProduct: (ScannedProduct) -> Void

    init(
        client: OpenFoodFactsClient = .live,
        onProduct: @escaping (ScannedProduct) -> Void
    ) {
        self.client = client
        self.onProduct = onProduct
    }

    private var liveScanningAvailable: Bool {
        DataScannerViewController.isSupported
            && DataScannerViewController.isAvailable
            && AVCaptureDevice.authorizationStatus(for: .video) != .denied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                VStack(spacing: 0) {
                    if liveScanningAvailable && !isShowingManualEntry {
                        LiveBarcodeScanner { payload in
                            handleScannedPayload(payload)
                        }
                        .clipShape(RoundedRectangle(
                            cornerRadius: Design.Radius.hero,
                            style: .continuous
                        ))
                        .overlay(
                            RoundedRectangle(
                                cornerRadius: Design.Radius.hero,
                                style: .continuous
                            )
                            .stroke(Design.Color.rule, lineWidth: Design.Stroke.hairline)
                        )
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    } else {
                        manualEntry
                    }

                    statusPanel

                    if !(liveScanningAvailable && !isShowingManualEntry) {
                        Spacer(minLength: 0)
                    }
                }
            }
            .navigationTitle("Scan a label")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Design.Color.muted)
                }
                if liveScanningAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isShowingManualEntry ? "Use camera" : "Type code") {
                            withAnimation(.snappy) { isShowingManualEntry.toggle() }
                        }
                        .foregroundStyle(Design.Color.accentSecondary)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        // Camera scanning wants the room; typing a code doesn't.
        .presentationDetents(
            liveScanningAvailable && !isShowingManualEntry ? [.large] : [.medium]
        )
        .onDisappear { lookupTask?.cancel() }
    }

    private var manualEntry: some View {
        VStack(spacing: 14) {
            Text("Type the number printed under the barcode.")
                .font(.subheadline)
                .foregroundStyle(Design.Color.muted)
                .multilineTextAlignment(.center)
                .padding(.top, 28)

            TextField("0 00000 00000 0", text: $manualCode)
                .keyboardType(.numberPad)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(
                    Design.Color.elevated,
                    in: RoundedRectangle(cornerRadius: Design.Radius.xl, style: .continuous)
                )
                .padding(.horizontal, 24)

            Button {
                handleScannedPayload(manualCode)
            } label: {
                Text("Look up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        LinearGradient(
                            colors: manualCodeIsValid
                                ? [Design.Color.ctaPrimary, Design.Color.ctaSecondary]
                                : [Design.Color.subtle, Design.Color.subtle],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!manualCodeIsValid)
            .padding(.horizontal, 24)
        }
    }

    private var manualCodeIsValid: Bool {
        BarcodeNutrition.normalizedGTIN(from: manualCode) != nil
    }

    private var statusPanel: some View {
        VStack(spacing: 8) {
            switch lookupState {
            case .idle:
                Label(
                    liveScanningAvailable && !isShowingManualEntry
                        ? "Point at the barcode on the package"
                        : "Nutrition comes from Open Food Facts",
                    systemImage: "barcode.viewfinder"
                )
                .font(.footnote)
                .foregroundStyle(Design.Color.muted)
            case .looking:
                HStack(spacing: 10) {
                    ProgressView().tint(Design.Color.accentSecondary)
                    Text("Looking up nutrition…")
                        .font(.footnote)
                        .foregroundStyle(Design.Color.ink)
                }
            case .missing(let code):
                VStack(spacing: 5) {
                    Text("No nutrition found for \(code).")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Design.Color.ink)
                    Text("Close this and photograph the nutrition label instead — Shudo reads labels from photos.")
                        .font(.caption)
                        .foregroundStyle(Design.Color.muted)
                        .multilineTextAlignment(.center)
                }
            case .failed:
                Text("Couldn’t reach the product database. Check your connection and try again.")
                    .font(.footnote)
                    .foregroundStyle(Design.Color.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func handleScannedPayload(_ payload: String) {
        guard let gtin = BarcodeNutrition.normalizedGTIN(from: payload) else { return }
        guard !handledPayloads.contains(gtin) else { return }
        if case .looking = lookupState { return }
        startLookup(gtin: gtin)
    }

    private func startLookup(gtin: String) {
        handledPayloads.insert(gtin)
        lookupState = .looking(code: gtin)
        lookupTask?.cancel()
        lookupTask = Task {
            do {
                let product = try await client.lookup(gtin)
                guard !Task.isCancelled else { return }
                if let product {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onProduct(product)
                    dismiss()
                } else {
                    lookupState = .missing(code: gtin)
                }
            } catch {
                guard !Task.isCancelled else { return }
                // Allow retrying the same code after a transport failure.
                handledPayloads.remove(gtin)
                lookupState = .failed
            }
        }
    }
}

/// Minimal VisionKit wrapper: recognizes retail barcodes and QR codes and
/// reports each distinct payload once.
private struct LiveBarcodeScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPayload: onPayload) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [
                .barcode(symbologies: [.ean13, .ean8, .upce, .qr])
            ],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(
        _ scanner: DataScannerViewController,
        context: Context
    ) {
        guard !scanner.isScanning else { return }
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(
        _ scanner: DataScannerViewController,
        coordinator: Coordinator
    ) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item,
                   let payload = barcode.payloadStringValue {
                    onPayload(payload)
                }
            }
        }
    }
}
