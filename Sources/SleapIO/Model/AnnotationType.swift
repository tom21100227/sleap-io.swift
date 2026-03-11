import Foundation

/// The type of spatial annotation.
public enum AnnotationType: String, Codable, Sendable {
    case boundingBox = "bounding_box"
    case polygon = "polygon"
    case polyline = "polyline"
    case point = "point"
    case ellipse = "ellipse"
    case segmentationMask = "segmentation_mask"
}
