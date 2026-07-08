import CoreGraphics
import Foundation
import ImageIO
import SleapIO
import UniformTypeIdentifiers

/// Background source for a single-image render.
public enum RenderBackground: Sendable {
    /// Use a provided image as the background (its pixel size defines the canvas).
    case image(CGImage)
    /// Synthesize a solid-color canvas of the given pixel size.
    case solid(CGColor, width: Int, height: Int)
}

/// Output format for image export.
public enum ImageExportFormat: Sendable {
    case png
    /// JPEG at the given quality in 0...1 (clamped).
    case jpeg(quality: CGFloat)
}

/// High-level single-image pose render + file export (parity: render_image).
public struct RenderImage: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults) {
        self.options = options
    }

    /// Render instances onto a background, returning the composited image.
    public func render(
        instances: [Instance],
        skeleton: Skeleton,
        background: RenderBackground
    ) -> CGImage {
        let width: Int
        let height: Int
        switch background {
        case .image(let image):
            width = image.width
            height = image.height
        case .solid(_, let solidWidth, let solidHeight):
            width = solidWidth
            height = solidHeight
        }

        guard width > 0, height > 0 else {
            if case .image(let image) = background {
                return image
            }
            return Self.makeFallbackImage()
        }

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            if case .image(let image) = background {
                return image
            }
            return Self.makeFallbackImage()
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        switch background {
        case .image(let image):
            context.draw(image, in: bounds)
        case .solid(let color, _, _):
            context.setFillColor(color)
            context.fill(bounds)
        }

        PoseRenderer(options: options).render(
            instances: instances,
            in: context,
            skeleton: skeleton,
            transform: .identity
        )

        if let result = context.makeImage() {
            return result
        }
        if case .image(let image) = background {
            return image
        }
        return Self.makeFallbackImage()
    }

    /// Convenience: render instances on a synthesized solid canvas.
    public func render(
        instances: [Instance],
        skeleton: Skeleton,
        width: Int,
        height: Int,
        backgroundColor: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> CGImage {
        render(
            instances: instances,
            skeleton: skeleton,
            background: .solid(backgroundColor, width: width, height: height)
        )
    }

    /// Render a LabeledFrame using its decoded video frame as background.
    public func render(frame: LabeledFrame) async throws -> CGImage {
        try await PoseRenderer(options: options).render(frame: frame, options: options)
    }

    /// Write a CGImage to disk as PNG or JPEG.
    public func write(_ image: CGImage, to url: URL, format: ImageExportFormat = .png) throws {
        let type: UTType
        let properties: CFDictionary?
        switch format {
        case .png:
            type = .png
            properties = nil
        case .jpeg(let quality):
            type = .jpeg
            let clampedQuality = max(0, min(1, quality))
            properties = [
                kCGImageDestinationLossyCompressionQuality: clampedQuality,
            ] as CFDictionary
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        ) else {
            throw SleapIOError.videoError("Failed to create image destination for \(url)")
        }

        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw SleapIOError.videoError("Failed to finalize image destination for \(url)")
        }
    }

    /// Create an RGBA CGContext with top-left origin (Y-flipped).
    private static func makeFlippedContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    private static func makeFallbackImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()!
    }
}
