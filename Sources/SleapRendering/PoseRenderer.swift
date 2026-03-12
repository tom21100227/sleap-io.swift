import CoreGraphics
import CoreText
import SleapIO
import SleapVideo

/// Renders pose overlays onto images using CoreGraphics.
public struct PoseRenderer: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults) {
        self.options = options
    }

    // MARK: - Render onto CGImage

    /// Render instances onto an image, returning a new composited image.
    public func render(
        instances: [Instance],
        onto image: CGImage,
        skeleton: Skeleton
    ) -> CGImage {
        let width = image.width
        let height = image.height

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            return image
        }

        // Draw the base image.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Draw pose overlays using identity transform (already in image pixel coordinates).
        render(instances: instances, in: context, skeleton: skeleton, transform: .identity)

        guard let result = context.makeImage() else {
            return image
        }
        return result
    }

    // MARK: - Render into CGContext

    /// Render instances into an existing CoreGraphics context.
    public func render(
        instances: [Instance],
        in context: CGContext,
        skeleton: Skeleton,
        transform: CGAffineTransform
    ) {
        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let palette = ColorPalette.palette(named: options.palette)

        for (instanceIndex, instance) in instances.enumerated() {
            let isPredicted = instance is PredictedInstance
            let alpha = isPredicted ? options.predictionOpacity : 1.0

            // Determine color: by instance index, wrapping around the palette.
            let colorIndex = instanceIndex
            let baseColor = palette[colorIndex % palette.count]
            let color = baseColor.copy(alpha: alpha) ?? baseColor

            // Draw edges first (so nodes appear on top).
            drawEdges(
                instance: instance,
                skeleton: skeleton,
                color: color,
                transform: transform,
                in: context
            )

            // Draw nodes.
            drawNodes(
                instance: instance,
                skeleton: skeleton,
                color: color,
                transform: transform,
                in: context
            )

            // Draw labels if requested.
            if options.showLabels {
                drawNodeLabels(
                    instance: instance,
                    skeleton: skeleton,
                    color: color,
                    transform: transform,
                    in: context
                )
            }

            // Draw track name if requested.
            if options.showTrackNames, let track = instance.track {
                drawTrackName(
                    track: track,
                    instance: instance,
                    color: color,
                    transform: transform,
                    in: context
                )
            }

            // Draw bounding box if requested.
            if options.showBoundingBoxes {
                drawBoundingBox(
                    instance: instance,
                    color: color,
                    transform: transform,
                    in: context
                )
            }
        }

        context.restoreGState()
    }

    // MARK: - Render LabeledFrame

    public func render(frame: LabeledFrame, options: RenderOptions) async throws -> CGImage {
        if frame.video.backend == nil {
            try await frame.video.open()
        }

        let image = try await frame.video.frame(at: frame.frameIndex)
        guard !frame.instances.isEmpty else {
            return image
        }

        let width = image.width
        let height = image.height

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            throw SleapIOError.videoError("Failed to create CGContext for LabeledFrame rendering")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let renderer = PoseRenderer(options: options)
        let groupedInstances = Dictionary(grouping: frame.instances) { ObjectIdentifier($0.skeleton) }
        for instances in groupedInstances.values {
            guard let skeleton = instances.first?.skeleton else { continue }
            renderer.render(
                instances: instances,
                in: context,
                skeleton: skeleton,
                transform: .identity
            )
        }

        guard let result = context.makeImage() else {
            throw SleapIOError.videoError("Failed to create CGImage from rendered context")
        }
        return result
    }

    // MARK: - Private helpers

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

    static func transformedBoundingRect(_ rect: CGRect, by transform: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.minY).applying(transform),
            CGPoint(x: rect.minX, y: rect.maxY).applying(transform),
            CGPoint(x: rect.maxX, y: rect.maxY).applying(transform),
        ]

        let minX = corners.map(\.x).min() ?? rect.minX
        let maxX = corners.map(\.x).max() ?? rect.maxX
        let minY = corners.map(\.y).min() ?? rect.minY
        let maxY = corners.map(\.y).max() ?? rect.maxY

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Private drawing helpers

    private func drawEdges(
        instance: Instance,
        skeleton: Skeleton,
        color: CGColor,
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        context.setStrokeColor(color)
        context.setLineWidth(options.edgeWidth)
        context.setLineCap(.round)

        let points = instance.points
        context.beginPath()
        for edge in skeleton.edges {
            guard let srcIdx = skeleton.index(of: edge.source),
                  let dstIdx = skeleton.index(of: edge.destination) else {
                continue
            }

            guard srcIdx < points.count, dstIdx < points.count else { continue }
            let src = points[srcIdx], dst = points[dstIdx]
            guard src.visible, dst.visible else { continue }
            guard !src.x.isNaN && !src.y.isNaN && !dst.x.isNaN && !dst.y.isNaN else { continue }

            let srcPoint = CGPoint(x: CGFloat(src.x), y: CGFloat(src.y)).applying(transform)
            let dstPoint = CGPoint(x: CGFloat(dst.x), y: CGFloat(dst.y)).applying(transform)

            context.move(to: srcPoint)
            context.addLine(to: dstPoint)
        }
        context.strokePath()
    }

    private func drawNodes(
        instance: Instance,
        skeleton: Skeleton,
        color: CGColor,
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        context.setFillColor(color)
        let r = options.nodeRadius
        let points = instance.points

        for i in 0..<points.count {
            let pt = points[i]
            guard pt.visible, !pt.x.isNaN, !pt.y.isNaN else { continue }

            let center = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y)).applying(transform)
            let rect = CGRect(
                x: center.x - r, y: center.y - r,
                width: r * 2, height: r * 2
            )
            context.fillEllipse(in: rect)
        }
    }

    private func drawNodeLabels(
        instance: Instance,
        skeleton: Skeleton,
        color: CGColor,
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        let points = instance.points
        let fontSize: CGFloat = 10.0
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

        for (i, node) in skeleton.nodes.enumerated() {
            guard i < points.count else { continue }
            let pt = points[i]
            guard pt.visible, !pt.x.isNaN, !pt.y.isNaN else { continue }

            let center = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y)).applying(transform)

            let attributes: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorFromContextAttributeName: true,
            ]
            let attrString = CFAttributedStringCreate(
                kCFAllocatorDefault, node.name as CFString, attributes as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrString)

            // The context is flipped for image drawing, so flip text back.
            context.saveGState()
            context.setFillColor(color)
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(
                x: center.x + options.nodeRadius + 2,
                y: center.y + fontSize / 2
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }

    private func drawTrackName(
        track: Track,
        instance: Instance,
        color: CGColor,
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        // Position the track name above the topmost visible point.
        var anchorY: CGFloat = .greatestFiniteMagnitude
        var anchorX: CGFloat = .greatestFiniteMagnitude
        let points = instance.points

        for i in 0..<points.count {
            let pt = points[i]
            guard pt.visible, !pt.x.isNaN, !pt.y.isNaN else { continue }
            let p = CGPoint(x: CGFloat(pt.x), y: CGFloat(pt.y)).applying(transform)
            if p.y < anchorY {
                anchorY = p.y
                anchorX = p.x
            }
        }
        guard anchorY < .greatestFiniteMagnitude else { return }

        let fontSize: CGFloat = 12.0
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let attrString = CFAttributedStringCreate(
            kCFAllocatorDefault, track.name as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)

        context.saveGState()
        context.setFillColor(color)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: anchorX, y: anchorY - 4)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawBoundingBox(
        instance: Instance,
        color: CGColor,
        transform: CGAffineTransform,
        in context: CGContext
    ) {
        guard let box = instance.boundingBox else { return }
        let transformedRect = Self.transformedBoundingRect(box, by: transform)

        context.setStrokeColor(color)
        context.setLineWidth(1.0)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.stroke(transformedRect)
        context.setLineDash(phase: 0, lengths: [])
    }
}
