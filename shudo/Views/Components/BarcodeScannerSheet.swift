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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                if showsCamera {
                    LiveBarcodeScanner { payload in
                        handleScannedPayload(payload)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Design.Radius.cardLarge, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .transition(.opacity)
                } else {
                    manualEntry
                        .transition(.opacity)
                }
                statusPanel
                if !showsCamera {
                    Spacer(minLength: 0)
                }
            }
        }
        .preferredColorScheme(.dark)
        // Camera scanning wants the room; typing a code doesn't.
        .presentationDetents(showsCamera ? [.large] : [.medium])
        .onDisappear { lookupTask?.cancel() }
    }

    private var showsCamera: Bool { liveScanningAvailable && !isShowingManualEntry }

    /// The serif title on the left; on the right the camera ↔ typing switch
    /// (when there's a camera) and close.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(showsCamera ? "Scan a barcode" : "Barcode")
                .font(Design.Typeface.display(.title2, weight: .regular))
                .foregroundStyle(Design.Color.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if liveScanningAvailable {
                Button(isShowingManualEntry ? "Camera" : "Type it") {
                    withAnimation(Design.Motion.calm(Design.Motion.settle, reduceMotion: reduceMotion)) {
                        isShowingManualEntry.toggle()
                    }
                }
                .font(Design.Typeface.text(.subheadline, weight: .medium))
                .foregroundStyle(Design.Color.textSecondary)
                .buttonStyle(.plain)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.custom(Design.Typeface.faceName(.bold), fixedSize: 13))
                    .fontWeight(.semibold)
                    .foregroundStyle(Design.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(Design.Color.hinoki.opacity(0.08), in: Circle())
                    .contentShape(Circle().inset(by: -8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.leading, 24)
        .padding(.trailing, 18)
        .padding(.top, 30)
    }

    /// The number written on a ruled line, centred with room around it, and
    /// the one primary action under it.
    private var manualEntry: some View {
        VStack(spacing: Design.Space.xl) {
            VStack(spacing: 10) {
                TextField(
                    "",
                    text: $manualCode,
                    prompt: Text("0 00000 00000 0").foregroundStyle(Design.Color.textDisabled)
                )
                .keyboardType(.numberPad)
                .font(Design.Typeface.numeral(.title, weight: .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(Design.Color.textPrimary)
                .tint(Design.Color.ember)
                .accessibilityLabel("Barcode number")
                HairlineRule()
                Text("The number under the bars")
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.textTertiary)
            }

            Button {
                handleScannedPayload(manualCode)
            } label: {
                Text("Look up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!manualCodeIsValid)
        }
        .padding(.horizontal, 32)
        .padding(.top, Design.Space.section)
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
            .font(Design.Typeface.text(.footnote))
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
