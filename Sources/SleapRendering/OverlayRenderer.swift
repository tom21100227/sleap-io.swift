import CoreGraphics
import SleapIO

/// Renders annotation overlays; label-image overlays are deferred to E7.
public struct OverlayRenderer: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults) {
        self.options = options
    }

    /// Draw enabled overlays into an existing context (image-pixel coords via transform).
    public func render(
        rois: [ROI] = [],
        masks: [SegmentationMask] = [],
        boundingBoxes: [CGRect] = [],
        centroids: [CGPoint] = [],
        in context: CGContext,
        transform: CGAffineTransform
    ) {
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        if options.showMasks {
            drawMasks(masks, transform: transform, in: context)
        }

        if options.showROIs {
            drawROIs(rois, transform: transform, in: context)
        }

        if options.showBoundingBoxes {
            drawBoundingBoxes(boundingBoxes, transform: transform, in: context)
        }

        if options.showCentroids {
            drawCentroids(centroids, transform: transform, in: context)
        }

        context.restoreGState()
    }

    /// Convenience: composite the enabled overlays onto a copy of `image`.
    public func render(
        onto image: CGImage,
        rois: [ROI] = [],
        masks: [SegmentationMask] = [],
        boundingBoxes: [CGRect] = [],
        centroids: [CGPoint] = []
    ) -> CGImage {
        let width = image.width
        let height = image.height

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        render(
            rois: rois,
            masks: masks,
            boundingBoxes: boundingBoxes,
            centroids: centroids,
            in: context,
            transform: .identity
        )

        return context.makeImage() ?? image
    }

    private func drawROIs(_ rois: [ROI], transform: CGAffineTransform, in context: CGContext) {
        context.setLineWidth(options.edgeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [])

        for (index, roi) in rois.enumerated() {
            guard !roi.points.isEmpty else { continue }

            let color = ColorPalette.color(at: index, palette: options.palette)
            context.setStrokeColor(color)
            context.setFillColor(color)

            switch roi.annotationType {
            case .boundingBox:
                let rect = PoseRenderer.transformedBoundingRect(roi.boundingBox, by: transform)
                context.stroke(rect)
            case .polygon:
                drawPolygon(points: roi.points, transform: transform, in: context)
            case .ellipse:
                drawEllipse(roi: roi, transform: transform, in: context)
            case .point:
                drawPoint(roi: roi, transform: transform, in: context)
            default:
                continue
            }
        }
    }

    private func drawPolygon(
        points: [SIMD2<Float>],
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        guard let first = points.first else { return }
        let start = CGPoint(x: CGFloat(first.x), y: CGFloat(first.y)).applying(transform)

        context.beginPath()
        context.move(to: start)
        for point in points.dropFirst() {
            let transformedPoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)).applying(transform)
            context.addLine(to: transformedPoint)
        }
        context.closePath()
        context.strokePath()
    }

    private func drawEllipse(roi: ROI, transform: CGAffineTransform, in context: CGContext) {
        guard roi.points.count >= 2 else { return }

        let center = roi.points[0]
        let radiusPoint = roi.points[1]
        let radiusX = abs(CGFloat(radiusPoint.x - center.x))
        let radiusY = abs(CGFloat(radiusPoint.y - center.y))
        let bounds = CGRect(
            x: CGFloat(center.x) - radiusX,
            y: CGFloat(center.y) - radiusY,
            width: radiusX * 2,
            height: radiusY * 2
        )
        context.strokeEllipse(in: PoseRenderer.transformedBoundingRect(bounds, by: transform))
    }

    private func drawPoint(roi: ROI, transform: CGAffineTransform, in context: CGContext) {
        guard let point = roi.points.first else { return }

        let center = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)).applying(transform)
        let radius = options.nodeRadius
        context.fillEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    private func drawMasks(
        _ masks: [SegmentationMask],
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        for (index, mask) in masks.enumerated() {
            guard mask.width > 0, mask.height > 0 else { continue }
            guard let maskImage = makeMaskImage(mask, color: ColorPalette.color(at: index, palette: options.palette)) else {
                continue
            }

            let rect = CGRect(
                x: 0,
                y: 0,
                width: CGFloat(mask.width),
                height: CGFloat(mask.height)
            ).applying(transform)
            context.draw(maskImage, in: rect)
        }
    }

    private func makeMaskImage(_ mask: SegmentationMask, color: CGColor) -> CGImage? {
        let width = mask.width
        let height = mask.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        let decoded = mask.decode()
        let components = rgbaComponents(color)
        let alpha = max(0.0, min(1.0, options.maskOpacity))
        let red = UInt8((components.red * alpha * 255.0).rounded())
        let green = UInt8((components.green * alpha * 255.0).rounded())
        let blue = UInt8((components.blue * alpha * 255.0).rounded())
        let alphaByte = UInt8((alpha * 255.0).rounded())

        for row in 0..<min(height, decoded.count) {
            let decodedRow = decoded[row]
            for col in 0..<min(width, decodedRow.count) where decodedRow[col] {
                let offset = row * bytesPerRow + col * 4
                data[offset] = red
                data[offset + 1] = green
                data[offset + 2] = blue
                data[offset + 3] = alphaByte
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            return context.makeImage()
        }
    }

    private func drawBoundingBoxes(
        _ boundingBoxes: [CGRect],
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        context.setLineWidth(1.0)
        context.setLineDash(phase: 0, lengths: [4, 4])

        for (index, boundingBox) in boundingBoxes.enumerated() {
            let color = ColorPalette.color(at: index, palette: options.palette)
            context.setStrokeColor(color)
            context.stroke(PoseRenderer.transformedBoundingRect(boundingBox, by: transform))
        }

        context.setLineDash(phase: 0, lengths: [])
    }

    private func drawCentroids(
        _ centroids: [CGPoint],
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        context.setLineWidth(max(1.0, options.edgeWidth))
        context.setLineCap(.round)
        context.setLineDash(phase: 0, lengths: [])

        for (index, centroid) in centroids.enumerated() {
            let color = ColorPalette.color(at: index, palette: options.palette)
            let center = centroid.applying(transform)
            let radius = options.centroidRadius

            context.setStrokeColor(color)
            context.beginPath()
            context.move(to: CGPoint(x: center.x - radius, y: center.y - radius))
            context.addLine(to: CGPoint(x: center.x + radius, y: center.y + radius))
            context.move(to: CGPoint(x: center.x + radius, y: center.y - radius))
            context.addLine(to: CGPoint(x: center.x - radius, y: center.y + radius))
            context.strokePath()
        }
    }

    private func rgbaComponents(_ color: CGColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let rgbColor = color.converted(
            to: CGColorSpaceCreateDeviceRGB(),
            intent: .defaultIntent,
            options: nil
        ) ?? color
        let components = rgbColor.components ?? [0, 0, 0, 1]

        if components.count >= 4 {
            return (components[0], components[1], components[2], components[3])
        }
        if components.count >= 2 {
            return (components[0], components[0], components[0], components[1])
        }
        return (0, 0, 0, 1)
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
}
