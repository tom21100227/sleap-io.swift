import CoreGraphics
import SleapIO

/// Draws per-node motion trails for tracked instances over a frame window.
/// Trails require track identity; untracked instances are ignored.
public struct TrailRenderer: Sendable {
    public var options: RenderOptions

    public init(options: RenderOptions = .defaults) {
        self.options = options
    }

    /// Draw trails into an existing context.
    /// - Parameters:
    ///   - history: Frames oldest-first, newest-last. The current frame is last.
    ///   - skeleton: Skeleton defining available node indices.
    ///   - nodeIndices: Node selection. `nil` draws all nodes.
    ///   - context: Destination graphics context.
    ///   - transform: Coordinate transform from image pixels to context coordinates.
    public func render(
        history: [[Instance]],
        skeleton: Skeleton,
        nodeIndices: [Int]? = nil,
        in context: CGContext,
        transform: CGAffineTransform
    ) {
        guard options.showTrails else { return }

        let window = Array(history.suffix(max(0, options.trailLength)))
        guard window.count >= 2 else { return }

        let tracks = Self.uniqueTracks(in: window)
        guard !tracks.isEmpty else { return }

        let selectedNodeIndices = nodeIndices ?? Array(0..<skeleton.nodes.count)

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setLineWidth(options.trailWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineDash(phase: 0, lengths: [])

        for (trackIndex, track) in tracks.enumerated() {
            let trackColor = ColorPalette.color(at: trackIndex, palette: options.palette)

            for nodeIndex in selectedNodeIndices {
                guard nodeIndex >= 0 else { continue }

                var samples: [(ordinal: Int, point: CGPoint)] = []
                for (ordinal, instances) in window.enumerated() {
                    guard let instance = instances.first(where: { $0.track === track }) else {
                        continue
                    }

                    let points = instance.points
                    guard nodeIndex < points.count else { continue }

                    let point = points[nodeIndex]
                    guard point.visible, !point.x.isNaN, !point.y.isNaN else { continue }

                    let transformedPoint = CGPoint(
                        x: CGFloat(point.x),
                        y: CGFloat(point.y)
                    ).applying(transform)
                    samples.append((ordinal: ordinal, point: transformedPoint))
                }

                guard samples.count >= 2 else { continue }

                for index in 1..<samples.count {
                    let newerOrdinal = samples[index].ordinal
                    let alpha = 0.15 + 0.85 * (Double(newerOrdinal) / Double(window.count - 1))
                    let color = trackColor.copy(alpha: CGFloat(alpha)) ?? trackColor

                    context.setStrokeColor(color)
                    context.beginPath()
                    context.move(to: samples[index - 1].point)
                    context.addLine(to: samples[index].point)
                    context.strokePath()
                }
            }
        }

        context.restoreGState()
    }

    /// Convenience: composite trails onto a copy of `image`.
    public func render(
        onto image: CGImage,
        history: [[Instance]],
        skeleton: Skeleton,
        nodeIndices: [Int]? = nil
    ) -> CGImage {
        let width = image.width
        let height = image.height

        guard let context = Self.makeFlippedContext(width: width, height: height) else {
            return image
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        render(
            history: history,
            skeleton: skeleton,
            nodeIndices: nodeIndices,
            in: context,
            transform: .identity
        )

        return context.makeImage() ?? image
    }

    private static func uniqueTracks(in history: [[Instance]]) -> [Track] {
        var tracks: [Track] = []
        for instances in history {
            for instance in instances {
                guard let track = instance.track else { continue }
                if !tracks.contains(where: { $0 === track }) {
                    tracks.append(track)
                }
            }
        }
        return tracks
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
