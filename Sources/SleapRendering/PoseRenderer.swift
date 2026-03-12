import CoreGraphics
import CoreText
import SleapIO

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

    /// Render a full labeled frame. Since video frame loading is not yet implemented
    /// (Phase 2 SleapVideo), this creates a blank canvas and draws the overlays.
    public func render(frame: LabeledFrame, options: RenderOptions) async throws -> CGImage {
        guard let skeleton = frame.instances.first?.skeleton else {
            // Return a minimal blank image if no instances.
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(
                data: nil, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ), let img = ctx.makeImage() else {
                throw SleapIOError.videoError("Failed to create minimal CGImage")
            }
            return img
        }

        // Determine canvas size from bounding box of all instances.
        var maxX: CGFloat = 640
        var maxY: CGFloat = 480
        for instance in frame.instances {
            if let box = instance.boundingBox {
                maxX = max(maxX, box.maxX + 20)
                maxY = max(maxY, box.maxY + 20)
            }
        }

        let width = Int(maxX)
        let height = Int(maxY)

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            throw SleapIOError.videoError("Failed to create CGContext for LabeledFrame rendering")
        }

        // Fill with black background.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Use a renderer configured with the provided options.
        let renderer = PoseRenderer(options: options)
        renderer.render(
            instances: frame.instances,
            in: context,
            skeleton: skeleton,
            transform: .identity
        )

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

        // Transform the corners of the bounding box.
        let topLeft = CGPoint(x: box.minX, y: box.minY).applying(transform)
        let bottomRight = CGPoint(x: box.maxX, y: box.maxY).applying(transform)

        let transformedRect = CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )

        context.setStrokeColor(color)
        context.setLineWidth(1.0)
        context.setLineDash(phase: 0, lengths: [4, 4])
        context.stroke(transformedRect)
        context.setLineDash(phase: 0, lengths: [])
    }
}
