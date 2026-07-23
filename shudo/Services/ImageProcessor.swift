import CoreImage
import ImageIO
import UIKit

enum ImageProcessor {
    static let uploadMaxPixelSize = 1_600
    static let uploadJPEGQuality: CGFloat = 0.78
    static let maximumPhotoCount = 4

    /// CIContext creation is expensive; orientation normalization shares one.
    /// CIContext is thread-safe for rendering.
    private static let orientationContext = CIContext(options: [.cacheIntermediates: false])

    /// Produces the final upload-ready JPEG in a single render + encode pass.
    /// One photo is bounded to `maxPixelSize`; several photos become one
    /// collage. The collage/resize output is already opaque and bounded, so it
    /// is encoded directly instead of being redrawn a second time.
    static func uploadJPEGData(
        from images: [UIImage],
        maxPixelSize: Int = uploadMaxPixelSize,
        quality: CGFloat = uploadJPEGQuality
    ) -> Data? {
        let selected = Array(images.prefix(maximumPhotoCount))
        guard !selected.isEmpty else { return nil }
        let composed = selected.count == 1
            ? resizedForUpload(selected[0], maxPixelSize: maxPixelSize)
            : collageForUpload(selected, maxPixelSize: maxPixelSize)
        return composed?.jpegData(compressionQuality: quality)
    }

    static func downsample(data: Data, maxPixelSize: Int = uploadMaxPixelSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    static func resizedForUpload(_ image: UIImage, maxPixelSize: Int = uploadMaxPixelSize) -> UIImage {
        let normalized = normalizedForUpload(image)
        let width = CGFloat(normalized.cgImage?.width ?? Int(normalized.size.width * normalized.scale))
        let height = CGFloat(normalized.cgImage?.height ?? Int(normalized.size.height * normalized.scale))
        let longestSide = max(width, height)
        guard longestSide > 0 else { return image }

        let scale = min(1, CGFloat(maxPixelSize) / longestSide)
        let outputSize = CGSize(
            width: max(1, (width * scale).rounded()),
            height: max(1, (height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: outputSize))
            normalized.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    static func collageForUpload(
        _ images: [UIImage],
        maxPixelSize: Int = uploadMaxPixelSize
    ) -> UIImage? {
        let selected = Array(images.prefix(maximumPhotoCount)).map(normalizedForUpload)
        guard let first = selected.first, maxPixelSize > 0 else { return nil }
        if selected.count == 1 {
            return resizedForUpload(first, maxPixelSize: maxPixelSize)
        }

        let columns = 2
        let rows = Int(ceil(Double(selected.count) / Double(columns)))
        let cellSize = CGFloat(maxPixelSize) / CGFloat(columns)
        let outputSize = CGSize(
            width: CGFloat(maxPixelSize),
            height: cellSize * CGFloat(rows)
        )
        let gutter = max(2, CGFloat(maxPixelSize) * 0.004)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            UIColor.black.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))

            for (index, image) in selected.enumerated() {
                let column = index % columns
                let row = index / columns
                let cell = CGRect(
                    x: CGFloat(column) * cellSize,
                    y: CGFloat(row) * cellSize,
                    width: cellSize,
                    height: cellSize
                ).insetBy(dx: gutter, dy: gutter)
                drawAspectFill(image, in: cell, context: context.cgContext)
            }
        }
    }

    static func normalizedForUpload(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, let cgImage = image.cgImage else { return image }
        let orientation: CGImagePropertyOrientation = switch image.imageOrientation {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
        let oriented = CIImage(cgImage: cgImage).oriented(orientation)
        let extent = oriented.extent.integral
        let translated = oriented.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        guard let output = orientationContext.createCGImage(
            translated,
            from: translated.extent
        ) else { return image }
        return UIImage(cgImage: output, scale: 1, orientation: .up)
    }

    private static func drawAspectFill(
        _ image: UIImage,
        in destination: CGRect,
        context: CGContext
    ) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(
            destination.width / image.size.width,
            destination.height / image.size.height
        )
        let drawSize = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
        let drawRect = CGRect(
            x: destination.midX - drawSize.width / 2,
            y: destination.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        context.saveGState()
        context.clip(to: destination)
        image.draw(in: drawRect)
        context.restoreGState()
    }
}
