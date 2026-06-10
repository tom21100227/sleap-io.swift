import Foundation
import simd

/// Canonical coordinate and visibility conventions for SLEAP pose data.
///
/// These rules are an implicit, cross-cutting invariant in the data format. A
/// rendering layer and a SwiftUI `Canvas` overlay **must** agree on them or every
/// annotation will be mirrored / offset. This type documents them in one place and
/// provides the small conversions needed to honor them.
///
/// ## Image coordinate space (the storage convention)
///
/// - Coordinates are stored in **pixel units** in the video's native image space.
/// - The origin `(0, 0)` is the **top-left** corner; **x** increases to the right,
///   **y** increases **downward** (image / "y-down" convention). This matches how
///   SwiftUI's `Canvas`, AppKit `CGContext` flipped contexts, and most image
///   pipelines address pixels.
/// - A coordinate addresses the **center** of a pixel. SLP format versions < 1.1
///   stored corner-indexed coordinates; the reader applies a
///   ``pixelCenterCorrection`` of `-0.5` on read so all in-memory coordinates use
///   the pixel-center convention. See `SLPReader`.
///
/// ## Y-axis when drawing
///
/// Some drawing back ends (e.g. a non-flipped Core Graphics / Quartz context, or a
/// 3D/visionOS scene) use a **y-up** coordinate system with the origin at the
/// bottom-left. When targeting such a context, flip y with ``flipY(_:imageHeight:)``
/// (it is its own inverse). SwiftUI `Canvas` is already y-down, so no flip is needed
/// there.
///
/// ## Invisible points
///
/// Visibility is carried by the **`visible` flag**, not by the coordinate value.
/// The canonical "missing" sentinel for array/tensor export is **`NaN`**:
/// ``Instance/numpy(invisibleAsNaN:)`` emits `[NaN, NaN]` for any point whose
/// `visible` flag is `false`, regardless of the stored coordinate. Consumers that
/// reduce over points (centroid, bounding box, training tensors) should treat
/// `visible == false` (equivalently, a `NaN` row) as absent.
public enum CoordinateConventions {

    /// The per-axis correction applied on read for SLP format versions < 1.1 to
    /// convert corner-indexed coordinates to the pixel-center convention.
    ///
    /// Stored value is the amount **subtracted** from each legacy coordinate.
    public static let pixelCenterCorrection: Float = 0.5

    /// Convert a y coordinate between the image (y-down, top-left origin) convention
    /// and a y-up (bottom-left origin) convention for an image of the given height.
    ///
    /// This is an involution: applying it twice returns the original value.
    ///
    /// - Parameters:
    ///   - y: The y coordinate to convert.
    ///   - imageHeight: The height of the image in pixels.
    @inline(__always)
    public static func flipY(_ y: Float, imageHeight: Float) -> Float {
        imageHeight - y
    }

    /// Convert a point's y between image (y-down) and y-up conventions for an image
    /// of the given height. Its own inverse.
    @inline(__always)
    public static func flipY(_ point: SIMD2<Float>, imageHeight: Float) -> SIMD2<Float> {
        SIMD2(point.x, imageHeight - point.y)
    }
}
