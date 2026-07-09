import Foundation
import simd

/// A single triangulated 3D landmark point.
///
/// The 3D counterpart of ``Point``: a body-part location reconstructed from
/// two or more calibrated camera views. An invisible point carries `NaN`
/// coordinates and ``visible`` `false` (see ``missing``).
public struct Point3D: Hashable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    /// Whether this point has a valid (visible) 3D estimate.
    public var visible: Bool

    public init(x: Float, y: Float, z: Float, visible: Bool = true) {
        self.x = x
        self.y = y
        self.z = z
        self.visible = visible
    }

    /// SIMD representation for math operations.
    public var simd: SIMD3<Float> {
        get { SIMD3(x, y, z) }
        set {
            x = newValue.x
            y = newValue.y
            z = newValue.z
        }
    }

    /// An invisible (missing) 3D point with `NaN` coordinates.
    public static var missing: Point3D {
        Point3D(x: .nan, y: .nan, z: .nan, visible: false)
    }
}

/// A triangulated 3D pose: one 3D landmark per skeleton node.
///
/// `Instance3D` is the 3D analogue of ``Instance`` used by multi-view
/// ``RecordingSession`` reconstruction. Its ``points`` are produced by
/// triangulating an ``InstanceGroup``'s corresponding per-camera 2D instances
/// (see ``InstanceGroup/triangulate(minimumViews:)``) and are indexed
/// positionally by node, matching the owning ``skeleton``'s node order.
public class Instance3D: Hashable, @unchecked Sendable {
    /// The skeleton defining the landmark topology and node order.
    public var skeleton: Skeleton

    /// 3D landmark points, one per skeleton node, in node order.
    public var points: [Point3D]

    /// Optional aggregate reconstruction score (e.g. a reprojection quality).
    public var score: Float?

    /// Create a 3D instance.
    ///
    /// When `points` is `nil`, every node starts missing (invisible, `NaN`). A
    /// supplied `points` array must have exactly one entry per skeleton node.
    ///
    /// - Parameters:
    ///   - skeleton: The skeleton defining node order.
    ///   - points: Per-node 3D points (length must equal `skeleton.nodes.count`),
    ///     or `nil` to start all-missing.
    ///   - score: Optional aggregate reconstruction score.
    public init(skeleton: Skeleton, points: [Point3D]? = nil, score: Float? = nil) {
        self.skeleton = skeleton
        if let points = points {
            precondition(
                points.count == skeleton.nodes.count,
                "Instance3D points count (\(points.count)) must equal node count "
                    + "(\(skeleton.nodes.count))")
            self.points = points
        } else {
            self.points = Array(repeating: .missing, count: skeleton.nodes.count)
        }
        self.score = score
    }

    // MARK: - Point access

    public subscript(index: Int) -> Point3D {
        get { points[index] }
        set { points[index] = newValue }
    }

    public subscript(node: Node) -> Point3D {
        get {
            guard let idx = skeleton.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            return points[idx]
        }
        set {
            guard let idx = skeleton.index(of: node) else {
                preconditionFailure("Node '\(node.name)' not found in skeleton")
            }
            points[idx] = newValue
        }
    }

    public subscript(name: String) -> Point3D {
        get {
            guard let node = skeleton.node(named: name),
                  let idx = skeleton.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            return points[idx]
        }
        set {
            guard let node = skeleton.node(named: name),
                  let idx = skeleton.index(of: node) else {
                preconditionFailure("Node named '\(name)' not found in skeleton")
            }
            points[idx] = newValue
        }
    }

    // MARK: - Derived

    /// Points as an `(nNodes, 3)` array of `[x, y, z]` rows.
    ///
    /// - Parameter invisibleAsNaN: When `true` (default), invisible points are
    ///   emitted as `[NaN, NaN, NaN]`; when `false`, the stored coordinates are
    ///   returned regardless of visibility. Mirrors `Instance.numpy`.
    public func numpy(invisibleAsNaN: Bool = true) -> [[Float]] {
        points.map { p in
            (invisibleAsNaN && !p.visible) ? [.nan, .nan, .nan] : [p.x, p.y, p.z]
        }
    }

    /// Number of visible points.
    public var nVisible: Int {
        points.reduce(0) { $0 + ($1.visible ? 1 : 0) }
    }

    /// Whether no points are visible.
    public var isEmpty: Bool {
        !points.contains { $0.visible }
    }

    // MARK: - Identity equality

    public static func == (lhs: Instance3D, rhs: Instance3D) -> Bool {
        lhs === rhs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// Multi-view geometry helpers: camera projection matrices, forward projection,
/// and linear (DLT) triangulation of 3D points from two or more calibrated views.
///
/// Mirrors the pinhole-camera math used by Python sleap-io's `Camera` /
/// `CameraGroup.triangulate`. All computation is performed in `Double` for
/// numerical stability and cast to `Float` at the boundaries.
public enum Triangulation {

    /// The 3×4 pinhole projection matrix `P = K · [R | t]` for `camera`, as a
    /// row-major `[Double]` of length 12.
    ///
    /// Returns `nil` when the camera lacks a full intrinsic matrix
    /// (``Camera/matrix``) or extrinsics (``Camera/rvec`` + ``Camera/tvec``). The
    /// rotation is derived from ``Camera/rvec`` via ``Camera/rotationMatrix(fromRotationVector:)``
    /// (the #57 camera math). Distortion is not applied — supply undistorted 2D
    /// observations when triangulating.
    public static func projectionMatrix(for camera: Camera) -> [Double]? {
        guard let k = camera.matrix, k.count == 9,
              let rvec = camera.rvec, rvec.count == 3,
              let tvec = camera.tvec, tvec.count == 3,
              let r = try? Camera.rotationMatrix(fromRotationVector: rvec)
        else { return nil }

        // Extrinsic 3×4 [R | t], row-major.
        let ext: [Double] = [
            Double(r[0]), Double(r[1]), Double(r[2]), Double(tvec[0]),
            Double(r[3]), Double(r[4]), Double(r[5]), Double(tvec[1]),
            Double(r[6]), Double(r[7]), Double(r[8]), Double(tvec[2]),
        ]
        let kd = k.map(Double.init)

        // P = K (3×3) · ext (3×4).
        var p = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            for j in 0..<4 {
                var sum = 0.0
                for m in 0..<3 {
                    sum += kd[i * 3 + m] * ext[m * 4 + j]
                }
                p[i * 4 + j] = sum
            }
        }
        return p
    }

    /// Project a world 3D point to 2D pixel coordinates using a 3×4 projection
    /// matrix (row-major, length 12).
    ///
    /// Returns `nil` when the projection matrix is malformed or the point lies on
    /// the camera plane (`w ≈ 0`), which would divide by zero.
    public static func project(_ point: SIMD3<Float>, using p: [Double]) -> SIMD2<Float>? {
        guard p.count == 12 else { return nil }
        let x = Double(point.x), y = Double(point.y), z = Double(point.z)
        let u = p[0] * x + p[1] * y + p[2] * z + p[3]
        let v = p[4] * x + p[5] * y + p[6] * z + p[7]
        let w = p[8] * x + p[9] * y + p[10] * z + p[11]
        guard abs(w) > 1e-12 else { return nil }
        return SIMD2(Float(u / w), Float(v / w))
    }

    /// Project a world 3D point through a ``Camera``'s derived projection matrix.
    ///
    /// Returns `nil` when the camera is not fully calibrated or the point cannot
    /// be projected. Distortion is not applied.
    public static func project(_ point: SIMD3<Float>, with camera: Camera) -> SIMD2<Float>? {
        guard let p = projectionMatrix(for: camera) else { return nil }
        return project(point, using: p)
    }

    /// Triangulate a single 3D point from two or more views by linear least
    /// squares (the inhomogeneous Direct Linear Transform).
    ///
    /// Each observation `(P, (u, v))` contributes two rows to an over-determined
    /// system `A · [X Y Z]ᵀ = b`, derived from `u·(P₂·X̃) = P₀·X̃` and the
    /// analogous `v` equation (where `X̃ = [X, Y, Z, 1]ᵀ` and `Pᵢ` is row `i` of
    /// `P`). The normal equations `(AᵀA)·g = Aᵀb` are then solved by inverting
    /// the 3×3 `AᵀA`. For finite, well-conditioned points this recovers the same
    /// result as the homogeneous SVD-based DLT while staying dependency-free.
    ///
    /// - Parameter observations: `(projection, point)` pairs. `projection` must be
    ///   a row-major 3×4 matrix (length 12); malformed entries are ignored.
    /// - Returns: The triangulated point, or `nil` when fewer than two valid
    ///   observations are supplied or the system is degenerate (near-singular
    ///   `AᵀA`, e.g. coincident/collinear camera centers).
    public static func triangulate(
        observations: [(projection: [Double], point: SIMD2<Float>)]
    ) -> SIMD3<Float>? {
        let valid = observations.filter { $0.projection.count == 12 }
        guard valid.count >= 2 else { return nil }

        // Accumulate AᵀA (3×3 symmetric) and Aᵀb (3) directly to avoid materializing A.
        var ata = [Double](repeating: 0, count: 9)
        var atb = [Double](repeating: 0, count: 3)
        for obs in valid {
            let p = obs.projection
            let u = Double(obs.point.x), v = Double(obs.point.y)
            let rows: [(coeffs: [Double], rhs: Double)] = [
                ([u * p[8] - p[0], u * p[9] - p[1], u * p[10] - p[2]], p[3] - u * p[11]),
                ([v * p[8] - p[4], v * p[9] - p[5], v * p[10] - p[6]], p[7] - v * p[11]),
            ]
            for (coeffs, rhs) in rows {
                for i in 0..<3 {
                    atb[i] += coeffs[i] * rhs
                    for j in 0..<3 {
                        ata[i * 3 + j] += coeffs[i] * coeffs[j]
                    }
                }
            }
        }
        guard let g = solve3x3(ata, atb) else { return nil }
        return SIMD3(Float(g[0]), Float(g[1]), Float(g[2]))
    }

    /// Solve a 3×3 linear system `M · x = b` by cofactor (adjugate) inversion.
    /// Returns `nil` when `M` is near-singular. `M` is row-major, length 9.
    private static func solve3x3(_ m: [Double], _ b: [Double]) -> [Double]? {
        let a = m[0], b1 = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]

        let det = a * (e * i - f * h) - b1 * (d * i - f * g) + c * (d * h - e * g)
        guard abs(det) > 1e-12 else { return nil }
        let inv = 1.0 / det

        // Inverse = adjugate / det.
        let m00 = (e * i - f * h) * inv
        let m01 = (c * h - b1 * i) * inv
        let m02 = (b1 * f - c * e) * inv
        let m10 = (f * g - d * i) * inv
        let m11 = (a * i - c * g) * inv
        let m12 = (c * d - a * f) * inv
        let m20 = (d * h - e * g) * inv
        let m21 = (b1 * g - a * h) * inv
        let m22 = (a * e - b1 * d) * inv

        return [
            m00 * b[0] + m01 * b[1] + m02 * b[2],
            m10 * b[0] + m11 * b[1] + m12 * b[2],
            m20 * b[0] + m21 * b[1] + m22 * b[2],
        ]
    }
}
