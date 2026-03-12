import CoreGraphics

/// Configuration for rendering pose overlays.
public struct RenderOptions: Sendable {
    /// Node (landmark) marker radius in points.
    public var nodeRadius: CGFloat

    /// Edge (limb) line width in points.
    public var edgeWidth: CGFloat

    /// Color palette name (e.g., "alphabet", "catscale").
    public var palette: String

    /// Whether to draw node labels.
    public var showLabels: Bool

    /// Whether to draw track names.
    public var showTrackNames: Bool

    /// Whether to draw bounding boxes.
    public var showBoundingBoxes: Bool

    /// Opacity for predicted instances.
    public var predictionOpacity: CGFloat

    /// Default rendering options.
    public static let defaults = RenderOptions()

    public init(
        nodeRadius: CGFloat = 4.0,
        edgeWidth: CGFloat = 2.0,
        palette: String = "alphabet",
        showLabels: Bool = false,
        showTrackNames: Bool = false,
        showBoundingBoxes: Bool = false,
        predictionOpacity: CGFloat = 0.6
    ) {
        self.nodeRadius = nodeRadius
        self.edgeWidth = edgeWidth
        self.palette = palette
        self.showLabels = showLabels
        self.showTrackNames = showTrackNames
        self.showBoundingBoxes = showBoundingBoxes
        self.predictionOpacity = predictionOpacity
    }
}
