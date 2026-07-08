import CoreGraphics

/// Shape used for rendered node markers.
public enum MarkerShape: String, Sendable, CaseIterable {
    case circle
    case square
    case triangle
    case diamond
    case cross
}

/// Configuration for rendering pose overlays.
public struct RenderOptions: Sendable {
    /// Node (landmark) marker radius in points.
    public var nodeRadius: CGFloat

    /// Edge (limb) line width in points.
    public var edgeWidth: CGFloat

    /// Color palette name (e.g., "alphabet", "catscale").
    public var palette: String

    /// Strategy for choosing colors from the palette.
    public var colorBy: ColorBy

    /// Node marker shape.
    public var markerShape: MarkerShape

    /// Whether to draw per-node scores for predicted instances.
    public var showScores: Bool

    /// Whether to draw node labels.
    public var showLabels: Bool

    /// Whether to draw track names.
    public var showTrackNames: Bool

    /// Whether to draw bounding boxes.
    public var showBoundingBoxes: Bool

    /// Opacity for predicted instances (0.0–1.0).
    public var predictionOpacity: CGFloat

    /// Whether to draw skeleton edges.
    public var showEdges: Bool

    /// Whether to draw nodes.
    public var showNodes: Bool

    /// Whether to draw region-of-interest annotations.
    public var showROIs: Bool

    /// Whether to draw segmentation mask annotations.
    public var showMasks: Bool

    /// Whether to draw centroid annotations.
    public var showCentroids: Bool

    /// Opacity for segmentation mask overlays.
    public var maskOpacity: CGFloat

    /// Radius/half-size for centroid markers.
    public var centroidRadius: CGFloat

    /// Default rendering options.
    public static let defaults = RenderOptions()

    public init(
        nodeRadius: CGFloat = 4.0,
        edgeWidth: CGFloat = 2.0,
        palette: String = "standard",
        colorBy: ColorBy = .auto,
        markerShape: MarkerShape = .circle,
        showScores: Bool = false,
        showLabels: Bool = false,
        showTrackNames: Bool = false,
        showBoundingBoxes: Bool = false,
        predictionOpacity: CGFloat = 0.6,
        showEdges: Bool = true,
        showNodes: Bool = true,
        showROIs: Bool = false,
        showMasks: Bool = false,
        showCentroids: Bool = false,
        maskOpacity: CGFloat = 0.4,
        centroidRadius: CGFloat = 5.0
    ) {
        self.nodeRadius = nodeRadius
        self.edgeWidth = edgeWidth
        self.palette = palette
        self.colorBy = colorBy
        self.markerShape = markerShape
        self.showScores = showScores
        self.showLabels = showLabels
        self.showTrackNames = showTrackNames
        self.showBoundingBoxes = showBoundingBoxes
        self.predictionOpacity = predictionOpacity
        self.showEdges = showEdges
        self.showNodes = showNodes
        self.showROIs = showROIs
        self.showMasks = showMasks
        self.showCentroids = showCentroids
        self.maskOpacity = maskOpacity
        self.centroidRadius = centroidRadius
    }
}
