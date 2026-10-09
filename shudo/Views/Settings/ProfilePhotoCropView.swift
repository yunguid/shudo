import SwiftUI
import UIKit

enum ProfilePhotoInputPolicy {
    static let maximumSourceBytes = 25_000_000
    static let maximumPixelDimension: CGFloat = 12_000
    static let maximumPixelCount: CGFloat = 50_000_000

    static func accepts(byteCount: Int, pixelWidth: CGFloat, pixelHeight: CGFloat) -> Bool {
        guard byteCount > 0, byteCount <= maximumSourceBytes,
            pixelWidth.isFinite, pixelHeight.isFinite,
            pixelWidth >= 1, pixelHeight >= 1,
            pixelWidth <= maximumPixelDimension,
            pixelHeight <= maximumPixelDimension
        else { return false }
        return pixelWidth * pixelHeight <= maximumPixelCount
    }
}

struct ProfilePhotoCropSource: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ProfilePhotoCropView: View {
    @Environment(\.dismiss) private var dismiss
    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero

    let image: UIImage
    let onUse: (UIImage) -> Void

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let side = min(geometry.size.width - 40, geometry.size.height - 130)
                VStack(spacing: Design.Space.xl) {
                    Spacer(minLength: 8)
                    cropCanvas(side: side)
                    HStack(spacing: Design.Space.m) {
                        Image(systemName: "minus.magnifyingglass")
                        Slider(value: $zoom, in: 1...4)
                            .tint(Design.Color.pernambuco)
                            .accessibilityLabel("Photo zoom")
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .font(Design.Typeface.text(.footnote))
                    .foregroundStyle(Design.Color.textTertiary)
                    .padding(.horizontal, Design.Space.xxl)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .settlesOnAppear()
                .onChange(of: zoom) { _, updated in
                    offset = clampedOffset(offset, side: side, zoom: updated)
                }
                .safeAreaInset(edge: .bottom) {
                    Button {
                        onUse(renderedCrop(side: side))
                    } label: {
                        Text("Use photo").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, Design.Space.xl)
                    .padding(.vertical, Design.Space.s)
                }
            }
            .background(Design.Color.canvas.ignoresSafeArea())
            .navigationTitle("Move and scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Move and scale")
                        .font(AccountView.barTitleFont)
                        .foregroundStyle(Design.Color.textPrimary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .tint(Design.Color.textPrimary)
                }
            }
        }
    }

    private func cropCanvas(side: CGFloat) -> some View {
        let liveZoom = min(max(zoom * magnification, 1), 4)
        let liveOffset = clampedOffset(
            CGSize(
                width: offset.width + dragTranslation.width,
                height: offset.height + dragTranslation.height
            ),
            side: side,
            zoom: liveZoom
        )
        return Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .scaleEffect(liveZoom)
            .offset(liveOffset)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous))
            .overlay {
                Circle()
                    .stroke(Design.Color.hinoki.opacity(0.8), lineWidth: 1)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.hero, style: .continuous)
                    .strokeBorder(Design.Color.hairline, lineWidth: Design.Stroke.hairline)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragTranslation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset = clampedOffset(
                            CGSize(
                                width: offset.width + value.translation.width,
                                height: offset.height + value.translation.height
                            ),
                            side: side,
                            zoom: zoom
                        )
                    }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($magnification) { value, state, _ in state = value.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 1), 4)
                        offset = clampedOffset(offset, side: side, zoom: zoom)
                    }
            )
            .accessibilityLabel("Profile photo crop area")
            .accessibilityHint("Drag to reposition the photo, or use the zoom slider")
    }

    private func clampedOffset(_ proposed: CGSize, side: CGFloat, zoom: CGFloat) -> CGSize {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let baseWidth = imageAspect >= 1 ? side * imageAspect : side
        let baseHeight = imageAspect >= 1 ? side : side / max(imageAspect, 0.001)
        let maximumX = max(0, (baseWidth * zoom - side) / 2)
        let maximumY = max(0, (baseHeight * zoom - side) / 2)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func renderedCrop(side: CGFloat) -> UIImage {
        let outputSide: CGFloat = 512
        let imageAspect = image.size.width / max(image.size.height, 1)
        let baseWidth = imageAspect >= 1 ? outputSide * imageAspect : outputSide
        let baseHeight = imageAspect >= 1 ? outputSide : outputSide / max(imageAspect, 0.001)
        let outputOffset = CGSize(
            width: offset.width / max(side, 1) * outputSide,
            height: offset.height / max(side, 1) * outputSide
        )
        return UIGraphicsImageRenderer(size: CGSize(width: outputSide, height: outputSide)).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: CGSize(width: outputSide, height: outputSide)))
            image.draw(
                in: CGRect(
                    x: (outputSide - baseWidth * zoom) / 2 + outputOffset.width,
                    y: (outputSide - baseHeight * zoom) / 2 + outputOffset.height,
                    width: baseWidth * zoom,
                    height: baseHeight * zoom
                ))
        }
    }
}

extension UIImage {
    func normalizedForDisplay() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func profilePhotoJPEG() -> Data? {
        let maxBytes = 2_000_000
        for quality in [0.86, 0.74, 0.62, 0.50] {
            if let data = jpegData(compressionQuality: quality), data.count <= maxBytes {
                return data
            }
        }
        return nil
    }
}
