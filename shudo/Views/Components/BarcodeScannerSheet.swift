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
            .navigationTitle("Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(Design.Color.textSecondary)
                }
                if liveScanningAvailable {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(isShowingManualEntry ? "Camera" : "Type it") {
                            withAnimation(.snappy) { isShowingManualEntry.toggle() }
                        }
                        .foregroundStyle(Design.Color.textSecondary)
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
            TextField(
                "",
                text: $manualCode,
                prompt: Text("Barcode number").foregroundStyle(Design.Color.textTertiary)
            )
            .keyboardType(.numberPad)
            .font(Design.Typeface.numeral(.title2))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(Design.Color.textPrimary)
            .padding(.vertical, 16)
            .background(
                Design.Color.surface1,
                in: RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
            )
            .accessibilityLabel("Barcode number")

            Button {
                handleScannedPayload(manualCode)
            } label: {
                Text("Look up")
                    .font(.headline)
                    .foregroundStyle(manualCodeIsValid ? Design.Color.onEmber : Design.Color.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        manualCodeIsValid ? AnyShapeStyle(Design.Color.emberFill) : AnyShapeStyle(Design.Color.surface2),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .disabled(!manualCodeIsValid)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    private var manualCodeIsValid: Bool {
        BarcodeNutrition.normalizedGTIN(from: manualCode) != nil
    }

    /// One quiet line at most: a spinner while looking, a short miss or
    /// failure line. Nothing at rest — the viewfinder says what to do.
    @ViewBuilder
    private var statusPanel: some View {
        Group {
            switch lookupState {
            case .idle:
                EmptyView()
            case .looking:
                ProgressView()
                    .tint(Design.Color.textSecondary)
                    .accessibilityLabel("Looking it up")
            case .missing:
                statusLine("Not found. Snap the label instead.")
            case .failed:
                statusLine("Couldn’t look that up. Try again.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Design.Color.honey)
            .multilineTextAlignment(.center)
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
