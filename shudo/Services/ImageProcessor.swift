import ImageIO
import UIKit

enum ImageProcessor {
    static let uploadMaxPixelSize = 1_600
    static let uploadJPEGQuality: CGFloat = 0.78

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
        let width = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
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
            image.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    static func jpegData(
        from image: UIImage,
        maxPixelSize: Int = uploadMaxPixelSize,
        quality: CGFloat = uploadJPEGQuality
    ) -> Data? {
        resizedForUpload(image, maxPixelSize: maxPixelSize)
            .jpegData(compressionQuality: quality)
    }
}
